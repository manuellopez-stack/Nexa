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
//      En ambos casos se resuelve orthanc_studies.clinic_id a partir de las
//      labels del estudio (plugin MultitenantDicom de Orthanc, Etapa 4): si
//      ninguna label calza con una fila real de clinics, queda null.
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
    console.log(`  Ya no está en Orthanc (probablemente ya se procesó antes), se omite.`);
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
      clinic_id: clinicId,
      status: "unlinked",
    });
    return;
  }

  console.log(`  Match: accession_number ${accessionNumber} -> orden ${matchedOrderId}. Copiando estudio...`);

  // Si esto lanza (una instancia falló), NO se marca 'linked' ni se borra de
  // Orthanc -- las instancias que sí se alcanzaron a copiar quedan en
  // imaging_files con su orthanc_instance_id, así el reintento no las duplica.
  const { totalInstances, copiedNow } = await linkOrthancStudyToOrder(supabase, {
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
    `  ${copiedNow}/${totalInstances} instancia(s) copiada(s) recién (el resto ya estaba de un intento previo). Estudio borrado de Orthanc.`,
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
