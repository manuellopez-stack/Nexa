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
//        - Si hay match: registra en imaging_files una fila por instancia
//          del estudio (orthanc_instance_id + serie, sin dicom_path ni
//          png_path) y marca el estudio "linked" en orthanc_studies (Fase 2A,
//          ver orthancStudies.mjs). El estudio se QUEDA en Orthanc: no se
//          copia a Storage ni se borra; las imágenes se sirven desde Orthanc
//          a través del backend.
//        - Si el estudio ya estaba "linked" (vuelve a aparecer en /changes
//          porque le llegaron instancias nuevas), se registran las instancias
//          que falten en la misma orden a la que ya estaba vinculado.
//        - Si no hay match: registra el estudio en orthanc_studies con
//          status "unlinked" (accession_number_received / patient_name_received
//          / patient_id_received / study_date, para que una futura pantalla
//          de reconciliación pueda casarlo a mano). No lo borra de Orthanc.
//      En ambos casos se resuelve orthanc_studies.clinic_id a partir de las
//      labels del estudio (plugin MultitenantDicom de Orthanc, Etapa 4): si
//      ninguna label calza con una fila real de clinics, queda null.
//   3. El cursor (orthanc_sync_state.last_seq) solo avanza si NINGÚN estudio
//      del lote falló. Si algo falló, el cursor no se mueve: la próxima
//      corrida vuelve a traer el mismo lote de /changes y reintenta.
//
// Idempotencia ante reintentos: antes de registrar una instancia se chequea
// si ya existe una fila en imaging_files con ese mismo (order_id,
// orthanc_instance_id). Si ya existe, se omite. Un estudio "unlinked" se
// vuelve a upsertear sobre la misma fila.
//
// Variables de entorno requeridas (además de las que ya usa server.mjs):
//   ORTHANC_URL       ej. http://137.184.27.186:8042
//   ORTHANC_USER      usuario de la autenticación básica de Orthanc
//   ORTHANC_PASSWORD  contraseña de esa cuenta (solo en backend/.env local y
//                      en las variables de entorno del Render Cron Job -- NO
//                      va en el código ni en ningún archivo versionado)
//
// Requiere haber corrido backend/sql/dicom_pacs_stage1.sql,
// dicom_pacs_stage1b.sql y fase2_orthanc_directo.sql en Supabase
// (accession_number, orthanc_studies, orthanc_sync_state,
// imaging_files.orthanc_instance_id / orthanc_series_*, dicom_path nullable).
//
// Cómo correrlo a mano para probar:
//   cd backend && node syncOrthanc.mjs
// ============================================================================

import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";
import { orthancGetJson } from "./orthancClient.mjs";
import { linkOrthancStudyToOrder } from "./orthancStudies.mjs";
import { DVD_TEMP_LABEL } from "./dvdExport.mjs";

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

// Etapa 4 (paso 2): el plugin MultitenantDicom de Orthanc le pone al estudio,
// como label, el clinic_id real de la clínica dueña del AE Title por el que
// llegó (asignación todavía manual/hardcodeada en la config de Orthanc, ver
// plan-dicom-pacs.md). Acá solo se resuelve esa label contra clinics.id: si
// ninguna label calza con una clínica real (AE Title de prueba, label vieja,
// etc.), clinic_id queda null -- nunca hace fallar la sincronización.
async function getValidClinicIds() {
  const { data, error } = await supabase.from("clinics").select("id");
  if (error) throw error;
  return new Set((data ?? []).map((row) => row.id));
}

function resolveClinicIdFromLabels(labels, validClinicIds) {
  for (const label of labels ?? []) {
    if (validClinicIds.has(label)) return label;
  }
  return null;
}

async function processStudy(orthancStudyId, validClinicIds) {
  const study = await orthancGetJson(`/studies/${orthancStudyId}`);
  if (!study) {
    console.log(`  Ya no está en Orthanc, se omite.`);
    return;
  }

  // Estudio que el servidor subió solo para armar una descarga para DVD (ver
  // dvdExport.mjs): ya está vinculado y el propio servidor lo borra al
  // terminar la descarga. No se toca.
  if ((study.Labels ?? []).includes(DVD_TEMP_LABEL)) {
    console.log(`  Estudio temporal de una descarga para DVD, se omite.`);
    return;
  }

  const studyTags = study.MainDicomTags ?? {};
  const patientTags = study.PatientMainDicomTags ?? {};

  const accessionNumber = (studyTags.AccessionNumber ?? "").trim() || null;
  const patientNameReceived = patientTags.PatientName ?? null;
  const patientIdReceived = patientTags.PatientID ?? null;
  const studyDate = studyTags.StudyDate ?? null;
  const clinicId = resolveClinicIdFromLabels(study.Labels, validClinicIds);

  // Ya vinculado (a mano o por una corrida anterior): se completa en esa
  // misma orden, sin volver a buscar por accession_number.
  const { data: existing, error: existingError } = await supabase
    .from("orthanc_studies")
    .select("status, linked_order_id")
    .eq("orthanc_study_id", orthancStudyId)
    .maybeSingle();
  if (existingError) throw existingError;

  let matchedOrderId = existing?.status === "linked" ? existing.linked_order_id : null;
  if (!matchedOrderId && accessionNumber) {
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
      clinic_id: clinicId,
      status: "unlinked",
    });
    return;
  }

  console.log(`  Match: accession_number ${accessionNumber ?? "(vacío)"} -> orden ${matchedOrderId}. Vinculando estudio...`);

  // Si esto lanza, NO se marca 'linked'; el reintento registra lo que falte
  // sin duplicar (idempotente por orthanc_instance_id).
  const { totalInstances, linkedNow } = await linkOrthancStudyToOrder(supabase, {
    orthancStudyId,
    orderId: matchedOrderId,
    studyMeta: {
      accession_number_received: accessionNumber,
      patient_name_received: patientNameReceived,
      patient_id_received: patientIdReceived,
      study_date: studyDate,
      clinic_id: clinicId,
    },
  });

  console.log(
    `  ${linkedNow}/${totalInstances} instancia(s) registrada(s) recién (el resto ya estaba). El estudio queda en Orthanc.`,
  );
}

async function main() {
  console.log("Sincronización Orthanc -> Imagenda\n");

  const cursor = await getSyncCursor();
  console.log(`Cursor actual (last_seq): ${cursor}`);

  const { studyIds, newCursor } = await collectStableStudyIds(cursor);
  console.log(`${studyIds.length} estudio(s) estable(s) por revisar.\n`);

  const validClinicIds = await getValidClinicIds();

  let processedCount = 0;
  let failedCount = 0;

  for (const studyId of studyIds) {
    console.log(`Estudio ${studyId}:`);
    try {
      await processStudy(studyId, validClinicIds);
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
