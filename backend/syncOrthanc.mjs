// ============================================================================
// DICOM/PACS (Orthanc) — sincronización Orthanc -> Imagenda
// ----------------------------------------------------------------------------
// Script standalone (NO middleware HTTP): se ejecuta por línea de comandos,
// pensado para correr como Render Cron Job en un horario fijo, no como parte
// del servidor Express (server.mjs) que ya está desplegado.
//
// Qué hace cada corrida:
//   1. Lee el cursor persistente (orthanc_sync_state.last_seq, la fila única
//      id=1) y recorre /changes?since={cursor} hasta agotar el log, juntando
//      los IDs internos de los estudios que terminaron de llegar (evento
//      "StableStudy" -- evita procesar un estudio a medio subir).
//   2. Para cada estudio: lee su AccessionNumber (MainDicomTags) y busca una
//      fila en imaging_orders con ese mismo accession_number.
//        - Si hay match: descarga cada instancia DICOM del estudio que
//          todavía no se haya copiado antes (ver idempotencia más abajo), la
//          sube a Supabase Storage (bucket "imaging", mismo patrón
//          orders/{orderId}/{timestamp}-... que usa la subida manual desde
//          imaging_section.dart) e inserta una fila en imaging_files por
//          instancia. Solo si TODAS las instancias del estudio quedan
//          copiadas sin error, el estudio se marca "linked" en
//          orthanc_studies y se borra en Orthanc.
//        - Si no hay match: registra el estudio en orthanc_studies con
//          status "unlinked" (accession_number_received / patient_name_received
//          / patient_id_received / study_date, para que una futura pantalla
//          de reconciliación pueda casarlo a mano). No lo borra de Orthanc.
//   3. El cursor (orthanc_sync_state.last_seq) solo avanza si NINGÚN estudio
//      del lote falló. Si algo falló, el cursor no se mueve: la próxima
//      corrida vuelve a traer el mismo lote de /changes y reintenta.
//
// Idempotencia ante reintentos (dos niveles):
//   - Por estudio: un estudio ya copiado y borrado de Orthanc simplemente ya
//     no está ahí en el reintento (GET /studies/{id} devuelve 404) y se
//     omite. Uno "unlinked" se vuelve a upsertear sobre la misma fila.
//   - Por instancia dentro de un estudio: antes de subir una instancia se
//     chequea si ya existe una fila en imaging_files con ese mismo
//     (order_id, orthanc_instance_id). Si ya existe, se omite. Así, si el
//     estudio A falla subiendo la instancia 3 de 5 (las 2 primeras ya
//     quedaron copiadas), el reintento solo sube la 3, 4 y 5 -- no duplica
//     las 2 que ya estaban.
//
// Variables de entorno requeridas (además de las que ya usa server.mjs):
//   ORTHANC_URL       ej. http://137.184.27.186:8042
//   ORTHANC_USER      usuario de la autenticación básica de Orthanc
//   ORTHANC_PASSWORD  contraseña de esa cuenta (solo en backend/.env local y
//                      en las variables de entorno del Render Cron Job -- NO
//                      va en el código ni en ningún archivo versionado)
//
// Requiere haber corrido backend/sql/dicom_pacs_stage1.sql y
// dicom_pacs_stage1b.sql en Supabase (accession_number, orthanc_studies,
// orthanc_sync_state, imaging_files.orthanc_instance_id).
//
// Cómo correrlo a mano para probar:
//   cd backend && node syncOrthanc.mjs
// ============================================================================

import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";
import { convertDicomToPng } from "./dicomPreview.mjs";

dotenv.config({ quiet: true });

const REQUIRED_ENV = [
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "ORTHANC_URL",
  "ORTHANC_USER",
  "ORTHANC_PASSWORD",
];

const missingEnv = REQUIRED_ENV.filter((key) => !process.env[key]);
if (missingEnv.length > 0) {
  console.error(
    `Faltan variables de entorno: ${missingEnv.join(", ")}. Revisa backend/.env.`,
  );
  process.exit(1);
}

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
);

const ORTHANC_URL = process.env.ORTHANC_URL.replace(/\/+$/, "");
const ORTHANC_AUTH_HEADER =
  "Basic " +
  Buffer.from(
    `${process.env.ORTHANC_USER}:${process.env.ORTHANC_PASSWORD}`,
  ).toString("base64");

async function orthancRequest(path, { method = "GET" } = {}) {
  const response = await fetch(`${ORTHANC_URL}${path}`, {
    method,
    headers: { Authorization: ORTHANC_AUTH_HEADER },
  });

  if (response.status === 404) return null;

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Orthanc respondió ${response.status} en ${method} ${path}: ${detail}`,
    );
  }

  return response;
}

async function orthancGetJson(path) {
  const response = await orthancRequest(path);
  return response ? response.json() : null;
}

async function orthancGetBinary(path) {
  const response = await orthancRequest(path);
  if (!response) return null;
  return Buffer.from(await response.arrayBuffer());
}

async function orthancDelete(path) {
  await orthancRequest(path, { method: "DELETE" });
}

// ----------------------------------------------------------------------------
// Cursor persistente (orthanc_sync_state, fila única id=1)
// ----------------------------------------------------------------------------
async function getSyncCursor() {
  const { data, error } = await supabase
    .from("orthanc_sync_state")
    .select("last_seq")
    .eq("id", 1)
    .maybeSingle();
  if (error) throw error;

  if (data) return data.last_seq;

  // No debería pasar si se corrió dicom_pacs_stage1b.sql (que ya siembra esta
  // fila), pero por si acaso: la crea en vez de fallar.
  const { error: insertError } = await supabase
    .from("orthanc_sync_state")
    .insert({ id: 1, last_seq: 0 });
  if (insertError) throw insertError;
  return 0;
}

async function saveSyncCursor(lastSeq) {
  const { error } = await supabase
    .from("orthanc_sync_state")
    .update({ last_seq: lastSeq })
    .eq("id", 1);
  if (error) throw error;
}

// Recorre /changes desde el cursor hasta que Orthanc marca Done, juntando los
// IDs de estudios que llegaron a estado estable (StableStudy). Devuelve
// también el nuevo cursor a guardar si todo el lote se procesa sin error.
async function collectStableStudyIds(sinceCursor) {
  const studyIds = new Set();
  let cursor = sinceCursor;
  let newCursor = sinceCursor;

  while (true) {
    const page = await orthancGetJson(`/changes?since=${cursor}&limit=100`);
    if (!page) break;

    for (const change of page.Changes ?? []) {
      if (change.ChangeType === "StableStudy" && change.ResourceType === "Study") {
        studyIds.add(change.ID);
      }
    }

    newCursor = page.Last;
    if (page.Done) break;
    cursor = page.Last;
  }

  return { studyIds: [...studyIds], newCursor };
}

async function upsertOrthancStudy(fields) {
  const { error } = await supabase
    .from("orthanc_studies")
    .upsert(fields, { onConflict: "orthanc_study_id" });
  if (error) throw error;
}

async function getAlreadyCopiedInstanceIds(orderId) {
  const { data, error } = await supabase
    .from("imaging_files")
    .select("orthanc_instance_id")
    .eq("order_id", orderId)
    .not("orthanc_instance_id", "is", null);
  if (error) throw error;
  return new Set((data ?? []).map((row) => row.orthanc_instance_id));
}

// Copia a Storage + imaging_files cada instancia del estudio que todavía no
// se haya copiado en un intento anterior, igual que la subida manual de un
// archivo DICOM (POST /patients/:id/imaging-orders/:orderId/image en
// server.mjs): un archivo DICOM + un preview PNG (si se puede convertir) por
// fila. Si una instancia falla, lanza el error y deja las anteriores ya
// insertadas tal cual (el próximo reintento las detecta por
// orthanc_instance_id y no las vuelve a subir).
async function copyStudyToOrder(orthancStudyId, orderId) {
  const instances = (await orthancGetJson(`/studies/${orthancStudyId}/instances`)) ?? [];
  const alreadyCopied = await getAlreadyCopiedInstanceIds(orderId);

  let copiedNow = 0;

  for (const instance of instances) {
    if (alreadyCopied.has(instance.ID)) {
      console.log(`  Instancia ${instance.ID} ya estaba copiada (reintento), se omite.`);
      continue;
    }

    const dicomBuffer = await orthancGetBinary(`/instances/${instance.ID}/file`);
    if (!dicomBuffer) {
      console.warn(`  Instancia ${instance.ID} ya no está en Orthanc, se omite.`);
      continue;
    }

    const timestamp = Date.now();
    const dicomPath = `orders/${orderId}/${timestamp}-${instance.ID}.dcm`;

    const { error: dicomUploadError } = await supabase.storage
      .from("imaging")
      .upload(dicomPath, dicomBuffer, { contentType: "application/dicom" });
    if (dicomUploadError) throw dicomUploadError;

    let pngPath = null;
    try {
      const pngBuffer = await convertDicomToPng(dicomBuffer);
      pngPath = `orders/${orderId}/${timestamp}-preview.png`;
      const { error: pngUploadError } = await supabase.storage
        .from("imaging")
        .upload(pngPath, pngBuffer, { contentType: "image/png" });
      if (pngUploadError) throw pngUploadError;
    } catch (error) {
      console.warn(
        `  No fue posible generar preview para la instancia ${instance.ID}: ${error.message}`,
      );
      pngPath = null;
    }

    const { error: fileInsertError } = await supabase.from("imaging_files").insert({
      order_id: orderId,
      dicom_path: dicomPath,
      png_path: pngPath,
      orthanc_instance_id: instance.ID,
    });
    if (fileInsertError) throw fileInsertError;

    copiedNow += 1;
  }

  return { totalInstances: instances.length, copiedNow };
}

async function processStudy(orthancStudyId) {
  const study = await orthancGetJson(`/studies/${orthancStudyId}`);
  if (!study) {
    console.log(`  Ya no está en Orthanc (probablemente ya se procesó antes), se omite.`);
    return;
  }

  const studyTags = study.MainDicomTags ?? {};
  const patientTags = study.PatientMainDicomTags ?? {};

  const accessionNumber = (studyTags.AccessionNumber ?? "").trim() || null;
  const patientNameReceived = patientTags.PatientName ?? null;
  const patientIdReceived = patientTags.PatientID ?? null;
  const studyDate = studyTags.StudyDate ?? null;

  let matchedOrderId = null;
  if (accessionNumber) {
    const { data, error } = await supabase
      .from("imaging_orders")
      .select("id")
      .eq("accession_number", accessionNumber)
      .maybeSingle();
    if (error) throw error;
    matchedOrderId = data?.id ?? null;
  }

  if (!matchedOrderId) {
    console.log(
      `  Sin match (accession_number recibido: ${accessionNumber ?? "(vacío)"}). Queda registrado como 'unlinked'.`,
    );
    await upsertOrthancStudy({
      orthanc_study_id: orthancStudyId,
      accession_number_received: accessionNumber,
      patient_name_received: patientNameReceived,
      patient_id_received: patientIdReceived,
      study_date: studyDate,
      status: "unlinked",
    });
    return;
  }

  console.log(`  Match: accession_number ${accessionNumber} -> orden ${matchedOrderId}. Copiando estudio...`);

  // Si esto lanza (una instancia falló), NO se marca 'linked' ni se borra de
  // Orthanc -- las instancias que sí se alcanzaron a copiar quedan en
  // imaging_files con su orthanc_instance_id, así el reintento no las duplica.
  const { totalInstances, copiedNow } = await copyStudyToOrder(orthancStudyId, matchedOrderId);

  await upsertOrthancStudy({
    orthanc_study_id: orthancStudyId,
    accession_number_received: accessionNumber,
    patient_name_received: patientNameReceived,
    patient_id_received: patientIdReceived,
    study_date: studyDate,
    status: "linked",
    linked_order_id: matchedOrderId,
    linked_at: new Date().toISOString(),
  });

  await orthancDelete(`/studies/${orthancStudyId}`);

  console.log(
    `  ${copiedNow}/${totalInstances} instancia(s) copiada(s) recién (el resto ya estaba de un intento previo). Estudio borrado de Orthanc.`,
  );
}

async function main() {
  console.log("Sincronización Orthanc -> Imagenda\n");

  const cursor = await getSyncCursor();
  console.log(`Cursor actual (last_seq): ${cursor}`);

  const { studyIds, newCursor } = await collectStableStudyIds(cursor);
  console.log(`${studyIds.length} estudio(s) estable(s) por revisar.\n`);

  let processedCount = 0;
  let failedCount = 0;

  for (const studyId of studyIds) {
    console.log(`Estudio ${studyId}:`);
    try {
      await processStudy(studyId);
      processedCount += 1;
    } catch (error) {
      failedCount += 1;
      console.error(`  ERROR: ${error.message}`);
    }
  }

  if (failedCount === 0) {
    await saveSyncCursor(newCursor);
    console.log(`\nCursor actualizado a ${newCursor}.`);
  } else {
    console.log(
      "\nHubo errores en esta corrida: el cursor no avanza, se reintenta el mismo lote en la próxima.",
    );
  }

  console.log(`\nListo. ${processedCount} estudio(s) procesado(s), ${failedCount} con error.`);
  process.exit(failedCount > 0 ? 1 : 0);
}

main().catch((error) => {
  console.error("Error fatal en la sincronización:", error);
  process.exit(1);
});
