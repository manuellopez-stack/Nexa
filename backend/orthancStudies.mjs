// Lógica compartida de "copiar un estudio de Orthanc a Storage + imaging_files
// y borrarlo de Orthanc". La usan:
//   - syncOrthanc.mjs: cuando el cron encuentra un match automático por
//     accession_number.
//   - server.mjs (POST /orthanc-studies/:id/link): cuando alguien del staff
//     vincula un estudio "unlinked" a mano, eligiendo la orden (no depende
//     del accession number).
//
// El caller pasa su propio cliente de Supabase (server.mjs y syncOrthanc.mjs
// ya tienen cada uno el suyo con la service role key) para no crear una
// segunda conexión.
import { orthancGetJson, orthancGetBinary, orthancDelete } from "./orthancClient.mjs";
import { convertDicomToPng } from "./dicomPreview.mjs";

async function getAlreadyCopiedInstanceIds(supabase, orderId) {
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
// insertadas tal cual (un reintento las detecta por orthanc_instance_id y no
// las vuelve a subir).
async function copyStudyInstances(supabase, orthancStudyId, orderId) {
  const instances = (await orthancGetJson(`/studies/${orthancStudyId}/instances`)) ?? [];
  const alreadyCopied = await getAlreadyCopiedInstanceIds(supabase, orderId);

  let copiedNow = 0;

  for (const instance of instances) {
    if (alreadyCopied.has(instance.ID)) continue;

    const dicomBuffer = await orthancGetBinary(`/instances/${instance.ID}/file`);
    if (!dicomBuffer) continue;

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

// Copia todas las instancias pendientes de un estudio a una orden, marca
// orthanc_studies como 'linked' y borra el estudio en Orthanc. Si
// copyStudyInstances lanza (una instancia falló), NO se marca 'linked' ni se
// borra de Orthanc -- las instancias que sí se copiaron quedan registradas
// con su orthanc_instance_id, así un reintento no las duplica.
//
// studyMeta es opcional: en el match automático del cron ya se tienen los
// datos recién leídos de Orthanc (accession_number_received, etc.) y se
// pasan para dejarlos guardados si la fila todavía no existía. En el vínculo
// manual la fila ya existe (viene de la lista de "unlinked"), así que se
// puede omitir y esos campos quedan tal cual estaban.
export async function linkOrthancStudyToOrder(supabase, { orthancStudyId, orderId, studyMeta = {} }) {
  const { totalInstances, copiedNow } = await copyStudyInstances(supabase, orthancStudyId, orderId);

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

  await orthancDelete(`/studies/${orthancStudyId}`);

  return { totalInstances, copiedNow };
}
