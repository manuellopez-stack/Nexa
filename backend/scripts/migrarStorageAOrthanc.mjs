// ============================================================================
// Fase 2B: migrar a Orthanc las imágenes que siguen en Supabase Storage
// (bucket "imaging") y después liberar ese bucket.
// ----------------------------------------------------------------------------
// Las filas antiguas de imaging_files tienen dicom_path/png_path (copiadas a
// Storage por el vínculo anterior a la Fase 2A, que además borró el estudio de
// Orthanc) y orthanc_instance_id. Este script devuelve cada DICOM a Orthanc y
// deja la fila como las de la Fase 2A (dicom_path/png_path null + serie), así
// el backend la sirve desde Orthanc.
//
// Modos (se corre desde backend/, con backend/.env):
//   node scripts/migrarStorageAOrthanc.mjs
//       Simulación (por defecto): cuenta y lista por orden. No escribe nada.
//   node scripts/migrarStorageAOrthanc.mjs --migrate
//       Antes de tocar filas escribe/actualiza el manifiesto (file_id, order,
//       dicom_path, png_path, orthanc_instance_id). Por cada fila con
//       dicom_path, de a 6 en paralelo y con reintentos:
//         1. descarga el DICOM de Storage y lo sube a Orthanc (POST /instances);
//         2. exige que el ID devuelto sea el orthanc_instance_id de la fila
//            (si difiere, detiene esa orden y lo reporta);
//         3. con la primera instancia de cada estudio: label = clinic_id de la
//            orden y upsert en orthanc_studies ('linked', con los datos del
//            estudio leídos de Orthanc) para que el cron no lo deje "unlinked";
//         4. en un solo UPDATE completa orthanc_series_id/_number e
//            orthanc_instance_number y deja dicom_path/png_path en null (la
//            fila nunca queda en null sin su serie).
//       Reanudable: lo ya migrado tiene dicom_path null y no se vuelve a
//       tocar; re-subir una instancia a Orthanc da "AlreadyStored" con el
//       mismo ID, y el manifiesto se completa sin perder entradas anteriores.
//   node scripts/migrarStorageAOrthanc.mjs --delete-storage
//       Lee el manifiesto y borra del bucket (lotes de 100) solo las rutas de
//       filas verificadas: dicom_path ya null y la instancia presente en
//       Orthanc (GET /instances/{id}). Al final muestra objetos y MB que
//       quedan en "imaging" y lista, sin borrarlos, los que no estaban en el
//       manifiesto.
//
// Nunca borra nada de Orthanc. No imprime credenciales.
// Opcional: --manifest <ruta> (por defecto /workspaces/Nexa/tmp/migracion-storage-manifest.json).
// ============================================================================
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";
import { orthancGetJson, orthancPut, orthancUploadInstance } from "../orthancClient.mjs";
import { dicomInteger } from "../orthancStudies.mjs";

export const BUCKET = "imaging";
export const DEFAULT_MANIFEST = "/workspaces/Nexa/tmp/migracion-storage-manifest.json";
const CONCURRENCY = 6;
const PROGRESS_EVERY = 50;
const REMOVE_BATCH = 100;
const PAGE = 500;

// ----------------------------------------------------------------------------
// Utilidades
// ----------------------------------------------------------------------------

async function withRetry(label, fn, { attempts = 3, delayMs = 1000 } = {}) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt < attempts) await new Promise((r) => setTimeout(r, delayMs * attempt));
    }
  }
  throw new Error(`${label}: ${lastError?.message ?? lastError} (tras ${attempts} intentos)`);
}

async function runPool(items, concurrency, worker) {
  let next = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      await worker(item);
    }
  });
  await Promise.all(runners);
}

function chunk(items, size) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

const mb = (bytes) => (bytes / 1024 / 1024).toFixed(1);

// Todas las filas de imaging_files que cumplen el filtro, paginando por id.
async function fetchAllFiles(supabase, applyFilter, columns = "*") {
  const rows = [];
  let lastId = null;
  for (;;) {
    let query = supabase.from("imaging_files").select(columns).order("id", { ascending: true }).limit(PAGE);
    query = applyFilter(query);
    if (lastId !== null) query = query.gt("id", lastId);
    const { data, error } = await query;
    if (error) throw error;
    rows.push(...(data ?? []));
    if (!data || data.length < PAGE) break;
    lastId = data[data.length - 1].id;
  }
  return rows;
}

async function fetchOrders(supabase, orderIds) {
  const orders = new Map();
  for (const ids of chunk([...new Set(orderIds)], 100)) {
    const { data, error } = await supabase
      .from("imaging_orders")
      .select("id, accession_number, clinic_id")
      .in("id", ids);
    if (error) throw error;
    for (const order of data ?? []) orders.set(order.id, order);
  }
  return orders;
}

// Objetos del bucket, recorriendo carpetas (list() de Storage no es recursivo:
// las carpetas vienen con id null).
async function listBucket(supabase, prefix = "") {
  const objects = [];
  let offset = 0;
  for (;;) {
    const { data, error } = await supabase.storage
      .from(BUCKET)
      .list(prefix, { limit: 1000, offset, sortBy: { column: "name", order: "asc" } });
    if (error) throw error;
    for (const entry of data ?? []) {
      const fullPath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.id === null || entry.id === undefined) {
        objects.push(...(await listBucket(supabase, fullPath)));
      } else {
        objects.push({ path: fullPath, size: Number(entry.metadata?.size ?? 0) });
      }
    }
    if (!data || data.length < 1000) break;
    offset += data.length;
  }
  return objects;
}

function readManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) return null;
  return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
}

function writeManifest(manifestPath, entries) {
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  const tmp = `${manifestPath}.tmp`;
  fs.writeFileSync(
    tmp,
    JSON.stringify({ createdAt: new Date().toISOString(), bucket: BUCKET, entries }, null, 2),
    { mode: 0o600 },
  );
  fs.renameSync(tmp, manifestPath);
}

function orderLabel(order, orderId) {
  return order?.accession_number ? `${order.accession_number} (${orderId})` : orderId;
}

// ----------------------------------------------------------------------------
// Simulación
// ----------------------------------------------------------------------------

export async function simulate({ supabase, manifestPath = DEFAULT_MANIFEST, log = console.log }) {
  log("== Simulación (no se cambia nada)");
  const pending = await fetchAllFiles(supabase, (q) => q.not("dicom_path", "is", null));
  const orders = await fetchOrders(supabase, pending.map((row) => row.order_id));

  const byOrder = new Map();
  for (const row of pending) {
    const stats = byOrder.get(row.order_id) ?? { rows: 0, withPng: 0, withoutInstance: 0 };
    stats.rows += 1;
    if (row.png_path) stats.withPng += 1;
    if (!row.orthanc_instance_id) stats.withoutInstance += 1;
    byOrder.set(row.order_id, stats);
  }

  log(`Filas con dicom_path (por migrar): ${pending.length} en ${byOrder.size} orden(es)`);
  for (const [orderId, stats] of byOrder) {
    const order = orders.get(orderId);
    log(
      `  ${orderLabel(order, orderId)}  clínica ${order?.clinic_id ?? "(sin clínica)"}: ` +
        `${stats.rows} fila(s), ${stats.withPng} con PNG, ${stats.withoutInstance} sin orthanc_instance_id`,
    );
  }

  const system = await orthancGetJson("/system").catch((error) => {
    throw new Error(`No se pudo consultar Orthanc (${new URL(process.env.ORTHANC_URL).origin}/system): ${error.cause?.code ?? error.message}`);
  });
  log(`Orthanc: responde (versión ${system?.Version ?? "?"})`);

  const objects = await listBucket(supabase);
  log(`Bucket "${BUCKET}": ${objects.length} objeto(s), ${mb(objects.reduce((s, o) => s + o.size, 0))} MB`);

  const manifest = readManifest(manifestPath);
  log(`Manifiesto ${manifestPath}: ${manifest ? `${manifest.entries.length} entrada(s)` : "no existe todavía"}`);
  return { pendingRows: pending.length, orders: byOrder.size, bucketObjects: objects.length };
}

// ----------------------------------------------------------------------------
// --migrate
// ----------------------------------------------------------------------------

export async function migrate({
  supabase,
  manifestPath = DEFAULT_MANIFEST,
  log = console.log,
  concurrency = CONCURRENCY,
  retryDelayMs = 1000,
}) {
  log("== Migración Storage -> Orthanc");
  const pending = await fetchAllFiles(supabase, (q) => q.not("dicom_path", "is", null));
  const orders = await fetchOrders(supabase, pending.map((row) => row.order_id));

  // 1. Manifiesto antes de tocar nada: se agregan las filas nuevas y se
  //    conservan las de corridas anteriores (ya migradas, con dicom_path null
  //    en la base, pero con sus rutas acá para --delete-storage).
  const previous = readManifest(manifestPath)?.entries ?? [];
  const known = new Set(previous.map((entry) => entry.file_id));
  const entries = [
    ...previous,
    ...pending
      .filter((row) => !known.has(row.id))
      .map((row) => ({
        file_id: row.id,
        order: row.order_id,
        dicom_path: row.dicom_path,
        png_path: row.png_path ?? null,
        orthanc_instance_id: row.orthanc_instance_id ?? null,
      })),
  ];
  writeManifest(manifestPath, entries);
  log(`Manifiesto: ${manifestPath} (${entries.length} entrada(s), ${entries.length - previous.length} nueva(s))`);
  log(`Filas por migrar: ${pending.length}`);

  const retry = (label, fn) => withRetry(label, fn, { delayMs: retryDelayMs });
  const stoppedOrders = new Map(); // orderId -> motivo
  const studyReady = new Map(); // `${orderId}|${studyId}` -> Promise
  const seriesNumbers = new Map(); // seriesId -> Promise<number|null>
  const failures = [];
  let migrated = 0;
  let processed = 0;

  const stopOrder = (orderId, reason) => {
    if (!stoppedOrders.has(orderId)) {
      stoppedOrders.set(orderId, reason);
      log(`  ORDEN DETENIDA ${orderLabel(orders.get(orderId), orderId)}: ${reason}`);
    }
  };

  // Primera instancia de cada estudio: label + orthanc_studies 'linked'.
  async function prepareStudy(studyId, order) {
    const { data: existing, error: existingError } = await supabase
      .from("orthanc_studies")
      .select("status, linked_order_id")
      .eq("orthanc_study_id", studyId)
      .maybeSingle();
    if (existingError) throw existingError;
    if (existing?.linked_order_id && existing.linked_order_id !== order.id) {
      throw new Error(`el estudio ${studyId} ya está vinculado a otra orden (${existing.linked_order_id})`);
    }

    await retry(`label del estudio ${studyId}`, () => orthancPut(`/studies/${studyId}/labels/${order.clinic_id}`));
    const study = await retry(`GET /studies/${studyId}`, () => orthancGetJson(`/studies/${studyId}`));
    if (!study) throw new Error(`el estudio ${studyId} no aparece en Orthanc tras subir la instancia`);

    const tags = study.MainDicomTags ?? {};
    const patient = study.PatientMainDicomTags ?? {};
    const { error } = await supabase.from("orthanc_studies").upsert(
      {
        orthanc_study_id: studyId,
        accession_number_received: (tags.AccessionNumber ?? "").trim() || null,
        patient_name_received: patient.PatientName ?? null,
        patient_id_received: patient.PatientID ?? null,
        study_date: tags.StudyDate ?? null,
        clinic_id: order.clinic_id,
        status: "linked",
        linked_order_id: order.id,
        linked_at: new Date().toISOString(),
      },
      { onConflict: "orthanc_study_id" },
    );
    if (error) throw error;
    log(`  estudio ${studyId} -> orden ${orderLabel(order, order.id)}: label y orthanc_studies 'linked'`);
  }

  function seriesNumber(seriesId) {
    if (!seriesNumbers.has(seriesId)) {
      seriesNumbers.set(
        seriesId,
        retry(`GET /series/${seriesId}`, () => orthancGetJson(`/series/${seriesId}`)).then((serie) =>
          dicomInteger(serie?.MainDicomTags?.SeriesNumber),
        ),
      );
    }
    return seriesNumbers.get(seriesId);
  }

  async function migrateRow(row) {
    const order = orders.get(row.order_id);
    if (stoppedOrders.has(row.order_id)) return;
    if (!order) return stopOrder(row.order_id, "la orden no existe");
    if (!order.clinic_id) return stopOrder(row.order_id, "la orden no tiene clinic_id (no hay label que poner)");
    if (!row.orthanc_instance_id) return stopOrder(row.order_id, `la fila ${row.id} no tiene orthanc_instance_id`);

    const dicom = await retry(`descargar ${row.dicom_path}`, async () => {
      const { data, error } = await supabase.storage.from(BUCKET).download(row.dicom_path);
      if (error || !data) throw new Error(error?.message ?? "sin datos");
      return Buffer.from(await data.arrayBuffer());
    });
    if (stoppedOrders.has(row.order_id)) return;

    const uploaded = await retry(`subir ${row.id} a Orthanc`, () => orthancUploadInstance(dicom));
    if (!uploaded?.ID || !uploaded?.ParentStudy) throw new Error(`Orthanc no aceptó ${row.dicom_path} como DICOM`);
    if (uploaded.ID !== row.orthanc_instance_id) {
      return stopOrder(
        row.order_id,
        `la fila ${row.id} (${row.dicom_path}) esperaba la instancia ${row.orthanc_instance_id} y Orthanc devolvió ${uploaded.ID}`,
      );
    }

    const studyKey = `${order.id}|${uploaded.ParentStudy}`;
    if (!studyReady.has(studyKey)) studyReady.set(studyKey, prepareStudy(uploaded.ParentStudy, order));
    try {
      await studyReady.get(studyKey);
    } catch (error) {
      return stopOrder(row.order_id, error.message);
    }

    const instance = await retry(`GET /instances/${uploaded.ID}`, () => orthancGetJson(`/instances/${uploaded.ID}`));
    const seriesId = instance?.ParentSeries ?? null;
    const update = {
      orthanc_series_id: seriesId,
      orthanc_series_number: seriesId ? await seriesNumber(seriesId) : null,
      orthanc_instance_number: dicomInteger(instance?.MainDicomTags?.InstanceNumber),
      dicom_path: null,
      png_path: null,
    };
    // Condicionado a que dicom_path siga igual: si otra corrida ya la migró,
    // no se toca de nuevo.
    const { data: updated, error } = await supabase
      .from("imaging_files")
      .update(update)
      .eq("id", row.id)
      .eq("dicom_path", row.dicom_path)
      .select("id");
    if (error) throw error;
    if ((updated ?? []).length === 1) migrated += 1;
  }

  await runPool(pending, concurrency, async (row) => {
    try {
      await migrateRow(row);
    } catch (error) {
      failures.push({ fileId: row.id, orderId: row.order_id, message: error.message });
      log(`  ERROR fila ${row.id} (${row.dicom_path}): ${error.message}`);
    }
    processed += 1;
    if (processed % PROGRESS_EVERY === 0 || processed === pending.length) {
      log(`  progreso: ${processed}/${pending.length} (${migrated} migrada(s))`);
    }
  });

  const remaining = pending.length - migrated;
  log("== Resumen");
  log(`Migradas en esta corrida: ${migrated}`);
  log(`Pendientes: ${remaining}${remaining ? " (volver a correr --migrate las retoma)" : ""}`);
  log(`Errores: ${failures.length}`);
  for (const [orderId, reason] of stoppedOrders) {
    log(`Orden detenida ${orderLabel(orders.get(orderId), orderId)}: ${reason}`);
  }
  return { migrated, remaining, failures, stoppedOrders: [...stoppedOrders.keys()] };
}

// ----------------------------------------------------------------------------
// --delete-storage
// ----------------------------------------------------------------------------

export async function deleteStorage({
  supabase,
  manifestPath = DEFAULT_MANIFEST,
  log = console.log,
  concurrency = CONCURRENCY,
}) {
  log("== Liberar Storage (bucket imaging)");
  const manifest = readManifest(manifestPath);
  if (!manifest) throw new Error(`No existe el manifiesto ${manifestPath}: corre primero --migrate.`);
  const entries = manifest.entries ?? [];
  log(`Manifiesto: ${entries.length} entrada(s)`);

  const rows = new Map();
  for (const ids of chunk(entries.map((e) => e.file_id), 100)) {
    const { data, error } = await supabase
      .from("imaging_files")
      .select("id, dicom_path, orthanc_instance_id")
      .in("id", ids);
    if (error) throw error;
    for (const row of data ?? []) rows.set(row.id, row);
  }

  const verified = [];
  const skipped = { notMigrated: 0, missingRow: 0, missingInOrthanc: 0, instanceChanged: 0 };
  let checked = 0;
  await runPool(entries, concurrency, async (entry) => {
    const row = rows.get(entry.file_id);
    if (!row) skipped.missingRow += 1;
    else if (row.dicom_path) skipped.notMigrated += 1;
    else if (row.orthanc_instance_id !== entry.orthanc_instance_id) skipped.instanceChanged += 1;
    else if (!(await withRetry(`GET /instances/${row.orthanc_instance_id}`, () => orthancGetJson(`/instances/${row.orthanc_instance_id}`)))) {
      skipped.missingInOrthanc += 1;
    } else verified.push(entry);
    checked += 1;
    if (checked % PROGRESS_EVERY === 0 || checked === entries.length) log(`  verificadas: ${checked}/${entries.length}`);
  });

  log(
    `Filas verificadas (dicom_path null + instancia en Orthanc): ${verified.length}. ` +
      `No se borran: ${skipped.notMigrated} sin migrar, ${skipped.missingInOrthanc} sin la instancia en Orthanc, ` +
      `${skipped.instanceChanged} con otro orthanc_instance_id, ${skipped.missingRow} sin fila en la base.`,
  );

  const paths = [...new Set(verified.flatMap((entry) => [entry.dicom_path, entry.png_path]).filter(Boolean))];
  let removed = 0;
  for (const batch of chunk(paths, REMOVE_BATCH)) {
    const { error } = await supabase.storage.from(BUCKET).remove(batch);
    if (error) throw new Error(`No se pudo borrar un lote de Storage: ${error.message}`);
    removed += batch.length;
    log(`  borrados de Storage: ${removed}/${paths.length}`);
  }

  const manifestPaths = new Set(entries.flatMap((entry) => [entry.dicom_path, entry.png_path]).filter(Boolean));
  const objects = await listBucket(supabase);
  const outside = objects.filter((object) => !manifestPaths.has(object.path));
  log("== Resumen");
  log(`Rutas borradas del bucket: ${removed}`);
  log(`Quedan en "${BUCKET}": ${objects.length} objeto(s), ${mb(objects.reduce((s, o) => s + o.size, 0))} MB`);
  log(`Objetos que no estaban en el manifiesto (no se borraron): ${outside.length}`);
  for (const object of outside) log(`  ${object.path} (${mb(object.size)} MB)`);
  return { removed, verified: verified.length, skipped, remainingObjects: objects.length, outside: outside.map((o) => o.path) };
}

// ----------------------------------------------------------------------------
// Línea de comandos
// ----------------------------------------------------------------------------

async function main(argv) {
  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  dotenv.config({ path: path.join(__dirname, "..", ".env"), quiet: true });
  const missing = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "ORTHANC_URL", "ORTHANC_USER", "ORTHANC_PASSWORD"].filter(
    (key) => !process.env[key],
  );
  if (missing.length) throw new Error(`Faltan variables en backend/.env: ${missing.join(", ")}`);

  const manifestIndex = argv.indexOf("--manifest");
  const manifestPath = manifestIndex >= 0 ? argv[manifestIndex + 1] : DEFAULT_MANIFEST;
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
  console.log(`Orthanc: ${new URL(process.env.ORTHANC_URL).origin}`);

  if (argv.includes("--migrate") && argv.includes("--delete-storage")) {
    throw new Error("Usa --migrate o --delete-storage, no ambos.");
  }
  if (argv.includes("--migrate")) {
    const result = await migrate({ supabase, manifestPath });
    return result.failures.length || result.stoppedOrders.length ? 1 : 0;
  }
  if (argv.includes("--delete-storage")) {
    await deleteStorage({ supabase, manifestPath });
    return 0;
  }
  await simulate({ supabase, manifestPath });
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2))
    .then((code) => {
      console.log("== listo");
      process.exit(code);
    })
    .catch((error) => {
      console.error(`ERROR: ${error.message}`);
      process.exit(1);
    });
}
