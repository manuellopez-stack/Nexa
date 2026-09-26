// Lógica compartida de "vincular un estudio de Orthanc a una orden". La usan:
//   - syncOrthanc.mjs: cuando el cron encuentra un match automático por
//     accession_number.
//   - server.mjs (POST /orthanc-studies/:id/link): cuando alguien del staff
//     vincula un estudio "unlinked" a mano, eligiendo la orden (no depende
//     del accession number).
//
// Fase 2A: el estudio se queda en Orthanc. Vincular solo registra en
// imaging_files una fila por instancia (orthanc_instance_id + su serie), sin
// dicom_path ni png_path: no se descarga nada, no se sube nada a Storage y NO
// se borra el estudio de Orthanc. Las imágenes se sirven después desde
// Orthanc a través del backend (URLs firmadas, ver imageTokens.mjs).
//
// PENDIENTE: hoy ningún flujo de Imagenda borra filas de imaging_files,
// archivos del bucket "imaging" ni órdenes de imagenología. Si se agrega uno,
// para las filas de Orthanc (dicom_path null) no debe intentar borrar
// Storage, y borrar el estudio en Orthanc queda por definir (retención).
//
// El caller pasa su propio cliente de Supabase (server.mjs y syncOrthanc.mjs
// ya tienen cada uno el suyo con la service role key) para no crear una
// segunda conexión.
import { orthancGetJson } from "./orthancClient.mjs";

async function getAlreadyLinkedInstanceIds(supabase, orderId) {
  const { data, error } = await supabase
    .from("imaging_files")
    .select("orthanc_instance_id")
    .eq("order_id", orderId)
    .not("orthanc_instance_id", "is", null);
  if (error) throw error;
  return new Set((data ?? []).map((row) => row.orthanc_instance_id));
}

// SeriesNumber / InstanceNumber vienen como texto (y a veces vacíos).
export function dicomInteger(value) {
  const number = Number.parseInt(String(value ?? "").trim(), 10);
  return Number.isFinite(number) ? number : null;
}

// Inserta en imaging_files las instancias del estudio que todavía no estén
// registradas para esa orden (idempotente por orthanc_instance_id: un
// reintento o un segundo vínculo no duplica filas).
async function registerStudyInstances(supabase, orthancStudyId, orderId) {
  const [instances, series] = await Promise.all([
    orthancGetJson(`/studies/${orthancStudyId}/instances`),
    orthancGetJson(`/studies/${orthancStudyId}/series`),
  ]);
  if (!instances) throw new Error(`El estudio ${orthancStudyId} no está en Orthanc.`);

  // instancia -> serie, desde la lista de series (Instances de cada una); si
  // una instancia no aparece ahí, se usa su ParentSeries.
  const seriesByInstance = new Map();
  const seriesNumbers = new Map();
  for (const serie of series ?? []) {
    seriesNumbers.set(serie.ID, dicomInteger(serie.MainDicomTags?.SeriesNumber));
    for (const instanceId of serie.Instances ?? []) seriesByInstance.set(instanceId, serie.ID);
  }

  const alreadyLinked = await getAlreadyLinkedInstanceIds(supabase, orderId);
  const rows = instances
    .filter((instance) => !alreadyLinked.has(instance.ID))
    .map((instance) => {
      const seriesId = seriesByInstance.get(instance.ID) ?? instance.ParentSeries ?? null;
      return {
        order_id: orderId,
        orthanc_instance_id: instance.ID,
        orthanc_series_id: seriesId,
        orthanc_series_number: seriesId ? seriesNumbers.get(seriesId) ?? null : null,
        orthanc_instance_number: dicomInteger(instance.MainDicomTags?.InstanceNumber),
        dicom_path: null,
        png_path: null,
      };
    });

  if (rows.length > 0) {
    const { error } = await supabase.from("imaging_files").insert(rows);
    if (error) throw error;
  }

  return { totalInstances: instances.length, linkedNow: rows.length };
}

// Registra las instancias del estudio en la orden y marca orthanc_studies
// como 'linked'. Si el registro falla, NO se marca 'linked' (un reintento
// completa lo que falte sin duplicar).
//
// studyMeta es opcional: en el match automático del cron ya se tienen los
// datos recién leídos de Orthanc (accession_number_received, etc.) y se
// pasan para dejarlos guardados si la fila todavía no existía. En el vínculo
// manual la fila ya existe (viene de la lista de "unlinked"), así que se
// puede omitir y esos campos quedan tal cual estaban.
export async function linkOrthancStudyToOrder(supabase, { orthancStudyId, orderId, studyMeta = {} }) {
  const { totalInstances, linkedNow } = await registerStudyInstances(supabase, orthancStudyId, orderId);

  const { error: upsertError } = await supabase
    .from("orthanc_studies")
    .upsert(
      {
        orthanc_study_id: orthancStudyId,
        ...studyMeta,
        status: "linked",
        linked_order_id: orderId,
        linked_at: new Date().toISOString(),
      },
      { onConflict: "orthanc_study_id" },
    );
  if (upsertError) throw upsertError;

  // Recibir el estudio implica que el examen se hizo. Solo avanza órdenes en
  // 'ordenado' para no retroceder una orden ya informada o validada.
  const { error: orderError } = await supabase
    .from("imaging_orders")
    .update({ status: "realizado", performed_at: new Date().toISOString() })
    .eq("id", orderId)
    .eq("status", "ordenado");
  if (orderError) throw orderError;

  return { totalInstances, linkedNow };
}
