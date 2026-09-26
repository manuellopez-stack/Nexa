// "Descargar para DVD": arma en streaming un único ZIP con el paquete de
// medios DICOM de Orthanc (DICOMDIR + IMAGES/), el visor Weasis portable para
// Windows (weasisPortable.mjs), un autorun.inf, un lanzador "Abrir_imagenes"
// y un LEAME.txt. La ruta HTTP vive en server.mjs.
//
// De dónde salen las imágenes (openOrderMedia):
//   - Estudios vinculados desde la Fase 2A: siguen en Orthanc (ver
//     orthancStudies.mjs), así que se pide /studies/{id}/media directo. Nunca
//     se borran.
//   - Filas antiguas (DICOM copiado a Storage, estudio ya borrado de
//     Orthanc): openOrderMedia sube de nuevo a Orthanc, de a una, esas
//     instancias, les pone la label DVD_TEMP_LABEL (syncOrthanc.mjs ignora
//     esos estudios) y, al terminar la descarga, borra de Orthanc los
//     estudios que subió ella misma.
//   - Una orden con ambas: un solo paquete (/tools/create-media) con los
//     estudios vinculados más los rehidratados; solo se borran estos últimos.
import { finished, pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import path from "node:path";
import { ZipArchive } from "archiver";
import unzipper from "unzipper";
import {
  orthancDelete,
  orthancGetJson,
  orthancPut,
  orthancStream,
  orthancUploadInstance,
} from "./orthancClient.mjs";

export const DVD_TEMP_LABEL = "imagenda-dvd-temporal";
export const VIEWER_FOLDER = "viewer";
export const LAUNCHER_NAME = "Abrir_imagenes.cmd";

const CLINIC_TIME_ZONE = "America/Santiago";

// ----------------------------------------------------------------------------
// Nombre del archivo y textos del disco
// ----------------------------------------------------------------------------

function asciiSlug(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^A-Za-z0-9-]+/g, "");
}

// patients.name es un solo campo ("Nombres ApellidoPaterno ApellidoMaterno").
// Con tres palabras o más se toma la penúltima (apellido paterno); con dos,
// la última.
export function surnameFromFullName(fullName) {
  const words = String(fullName ?? "").trim().split(/\s+/).filter(Boolean);
  const surname = words.length >= 3 ? words[words.length - 2] : words[words.length - 1];
  return asciiSlug(surname) || "Paciente";
}

function formatDate(value, locale) {
  const date = value ? new Date(value) : null;
  if (!date || Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale, {
    timeZone: CLINIC_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

// DVD_<apellido>_<fecha>_<accession>.zip, fecha AAAA-MM-DD.
export function dvdFilename({ patientName, examDate, accessionNumber }) {
  const date = formatDate(examDate, "en-CA") ?? "sin-fecha";
  const accession = asciiSlug(accessionNumber) || "sin-acceso";
  return `DVD_${surnameFromFullName(patientName)}_${date}_${accession}.zip`;
}

// Informe aprobado en la raíz del disco: INFORME_<accession>.pdf.
export function reportPdfName(accessionNumber) {
  return `INFORME_${asciiSlug(accessionNumber) || "sin-acceso"}.pdf`;
}

// Texto para el Bloc de notas de Windows: UTF-8 con BOM y fin de línea CRLF.
function windowsText(lines) {
  return "﻿" + lines.join("\r\n") + "\r\n";
}

export function buildLeame({
  clinicName,
  patientName,
  patientRut,
  examDate,
  examTypes,
  accessionNumber,
  viewer,
  reportName = null,
}) {
  const lines = [
    "IMÁGENES DE SU EXAMEN",
    "=====================",
    "",
    `Clínica:          ${clinicName || "-"}`,
    `Paciente:         ${patientName || "-"}`,
    `RUT:              ${patientRut || "-"}`,
    `Fecha del examen: ${formatDate(examDate, "es-CL") ?? "-"}`,
    `Tipo de examen:   ${examTypes?.length ? examTypes.join(", ") : "-"}`,
    `N° de acceso:     ${accessionNumber || "-"}`,
    "",
    "CÓMO ABRIR LAS IMÁGENES EN WINDOWS",
    "----------------------------------",
  ];

  if (viewer) {
    lines.push(
      "Este disco incluye un visor de imágenes (Weasis), no hace falta instalar nada.",
      "1. Inserte el disco. Si Windows pregunta qué hacer con él, elija \"Abrir imagenes\".",
      "2. Si no pregunta, abra el disco en el Explorador de archivos y haga doble clic",
      "   en \"Abrir_imagenes\".",
      "El visor se ejecuta desde el disco, así que puede tardar un poco en abrir.",
    );
  } else {
    lines.push(
      "Este disco NO incluye un visor de imágenes.",
      "Use cualquier visor DICOM instalado en su computador (por ejemplo Weasis,",
      "gratuito en https://weasis.org) o el que indique su médico, y abra con él",
      "el archivo DICOMDIR de este disco.",
    );
  }

  lines.push(
    "",
    "CÓMO ABRIR LAS IMÁGENES EN MAC",
    "------------------------------",
    ...(viewer ? ["El visor incluido funciona solo en Windows."] : []),
    "Use cualquier visor DICOM, por ejemplo Horos o el que indique su médico, y abra",
    "con él el archivo DICOMDIR de este disco.",
    "",
    "IMPORTANTE",
    "----------",
    "El visor incluido sirve para ver las imágenes; el diagnóstico oficial es el informe del radiólogo.",
    reportName
      ? `El informe del examen, aprobado por un médico, está en este disco: ${reportName}.`
      : "El informe se entrega por separado.",
    "",
    "CONTENIDO DEL DISCO",
    "-------------------",
    "DICOMDIR y carpeta IMAGES: las imágenes del examen en formato DICOM.",
  );
  if (reportName) {
    lines.push(`${reportName}: informe del examen en PDF (se abre con cualquier lector de PDF).`);
  }

  if (viewer) {
    lines.push(
      `${VIEWER_FOLDER}: visor Weasis ${viewer.version} para Windows, software libre`,
      "  (licencia EPL 2.0, https://github.com/nroduit/Weasis).",
      "Abrir_imagenes y autorun.inf: abren el visor con las imágenes del disco.",
    );
  }

  return windowsText(lines);
}

// Cómo abre Weasis 4.x las imágenes de un disco (código de Weasis 4.7.3):
// - `$dicom:get -l <ruta>` carga la ruta como imagen o carpeta suelta; si la
//   ruta es el archivo DICOMDIR NO lo interpreta, por eso el lanzador viejo
//   (`-l DICOMDIR`) abría Weasis vacío.
// - `$dicom:get -p` (modo portable) lee <weasis.portable.dir>\DICOMDIR. Es lo
//   que usan el Autorun.inf y el RUN.bat que el propio Weasis pone en sus CD
//   (app\resources\isowriter), con weasis.portable.dir = "." (la carpeta de
//   trabajo). Aquí va la ruta ABSOLUTA de la raíz del disco.
// - Los argumentos pueden ir sin URI weasis:// (ConfigData.splitArgToCmd):
//   cada argumento que empieza con $ abre un comando y los siguientes se le
//   suman separados por espacio. Así la ruta no pasa por URLDecoder, que
//   rompería rutas con "%" o "+", ni por el corte en "$" de la URI.
// - `$weasis:config pro="weasis.portable.dir <ruta>"`: las comillas protegen
//   los espacios (Utils.splitSpaceExceptInQuotes) y el valor es todo lo que
//   sigue al primer espacio, espacios incluidos.
//
// En el .cmd, %~dp0 es la carpeta del lanzador con "\" final:
// - Se le agrega "." para que el argumento no termine en \\" (en la línea de
//   comandos de Windows eso cierra las comillas en vez de dar una comilla
//   literal); "D:\." es la raíz, igual que el "." oficial.
// - cmd.exe no entiende \" y alterna comillas en cada ", así que dentro de
//   pro=\"...\" la ruta le queda SIN comillas: si llevara & o ^ cortaría el
//   comando. Por eso va en una variable leída con expansión diferida (!DISCO!),
//   que cmd reemplaza después de interpretar esos caracteres. El set se hace
//   antes del setlocal y la línea del start no usa %~dp0 (se expandiría antes
//   y pasaría por la expansión diferida) para que un "!" en la ruta no se
//   pierda.
export function buildLauncherCmd() {
  return [
    "@echo off",
    "REM Abre las imagenes de este disco con el visor incluido.",
    'set "DISCO=%~dp0."',
    'cd /d "%~dp0"',
    "setlocal EnableDelayedExpansion",
    `start "" "!DISCO!\\${VIEWER_FOLDER}\\Weasis.exe" "$dicom:get" "-p" "$weasis:config" "pro=\\"weasis.portable.dir !DISCO!\\""`,
    "",
  ].join("\r\n");
}

// open= del autorun.inf no puede armar rutas absolutas (no expande %~dp0), así
// que el autorun ejecuta el lanzador; shellexecute= abre también un .cmd
// (open= solo acepta ejecutables). Windows lo ejecuta con la raíz del disco
// como carpeta de trabajo.
export function buildAutorunInf() {
  return [
    "[autorun]",
    `shellexecute=${LAUNCHER_NAME}`,
    "action=Abrir imagenes",
    `icon=${VIEWER_FOLDER}\\Weasis.exe,0`,
    "label=Imagenes",
    "",
  ].join("\r\n");
}

// ----------------------------------------------------------------------------
// Armado del ZIP en streaming
// ----------------------------------------------------------------------------

const RESERVED_ROOT_NAMES = new Set(
  ["leame.txt", "autorun.inf", LAUNCHER_NAME.toLowerCase(), VIEWER_FOLDER].map((n) => n.toLowerCase()),
);
// INFORME_<accession>.pdf (reportPdfName): reservado siempre, vaya o no el
// informe, para que nada del paquete de Orthanc pase por el informe.
const RESERVED_ROOT_PATTERN = /^informe_.*\.pdf$/i;

// Ruta segura dentro del ZIP de salida, o null si la entrada se descarta
// (absoluta, con "..", o que pisaría un archivo nuestro de la raíz).
function safeMediaEntryName(rawPath) {
  const normalized = String(rawPath).replaceAll("\\", "/").replace(/^\/+/, "");
  const segments = normalized.split("/").filter(Boolean);
  if (segments.length === 0 || segments.some((s) => s === "." || s === "..")) return null;
  const root = segments[0].toLowerCase();
  if (RESERVED_ROOT_NAMES.has(root)) return null;
  if (RESERVED_ROOT_PATTERN.test(root)) return null;
  return segments.join("/");
}

/**
 * Escribe en `output` el ZIP del DVD. Nada se carga entero en memoria: cada
 * entrada del ZIP de Orthanc (`mediaZip`, un Readable) pasa directo del
 * lector al compresor, y los archivos del visor se leen del disco uno a uno.
 *
 * viewer: { dir, version, files: [{ path, size }] } o null (sin visor: no
 * van autorun.inf ni el lanzador, y el LEAME lo dice).
 *
 * report: { name, data: Buffer } o null. El informe aprobado en PDF, que va
 * en la raíz como `name` (reportPdfName); el LEAME lo menciona (buildLeame
 * con reportName).
 */
export async function writeDvdZip({ mediaZip, output, viewer, leame, report = null }) {
  const archive = new ZipArchive({ zlib: { level: 1 } });
  const written = pipeline(archive, output);
  written.catch(() => {}); // el error se re-lanza abajo con await

  const date = new Date();
  let mediaEntries = 0;

  try {
    archive.append(leame, { name: "LEAME.txt", date });
    if (report) archive.append(report.data, { name: report.name, date });
    if (viewer) {
      archive.append(buildAutorunInf(), { name: "autorun.inf", date });
      archive.append(buildLauncherCmd(), { name: LAUNCHER_NAME, date });
    }

    const entries = mediaZip.pipe(unzipper.Parse({ forceStream: true }));
    mediaZip.on("error", (error) => entries.destroy(error));

    for await (const entry of entries) {
      const name = entry.type === "File" ? safeMediaEntryName(entry.path) : null;
      if (!name) {
        entry.autodrain();
        continue;
      }
      archive.append(entry, { name, date });
      // El lector no entrega la entrada siguiente hasta que esta se consuma:
      // así nunca hay más de una entrada de Orthanc en vuelo.
      await finished(entry);
      mediaEntries += 1;
    }

    if (mediaEntries === 0) throw new Error("El paquete de medios de Orthanc vino vacío.");

    if (viewer) {
      for (const file of viewer.files) {
        archive.file(path.join(viewer.dir, ...file.path.split("/")), {
          name: `${VIEWER_FOLDER}/${file.path}`,
          date,
        });
      }
    }

    await archive.finalize();
    await written;
    return { mediaEntries };
  } catch (error) {
    archive.abort();
    mediaZip.destroy?.();
    throw error;
  }
}

// ----------------------------------------------------------------------------
// Estudio en Orthanc para /media (rehidratación temporal)
// ----------------------------------------------------------------------------

// Estudios que este proceso subió a Orthanc y que todavía usa alguna
// descarga: studyId -> cuántas descargas lo usan. Solo se borran de Orthanc
// cuando la última termina.
const temporaryStudies = new Map();

async function releaseStudies(ownedStudyIds) {
  for (const studyId of ownedStudyIds) {
    const users = (temporaryStudies.get(studyId) ?? 1) - 1;
    if (users > 0) {
      temporaryStudies.set(studyId, users);
      continue;
    }
    temporaryStudies.delete(studyId);
    try {
      await orthancDelete(`/studies/${studyId}`);
    } catch (error) {
      console.error(`[DVD] No se pudo borrar de Orthanc el estudio temporal ${studyId}:`, error);
    }
  }
}

/**
 * Abre el ZIP de medios de la orden. Devuelve { body: Readable, release } --
 * release() debe llamarse siempre al terminar (borra solo lo que se subió
 * para esto; nunca un estudio vinculado).
 *
 * orthancStudyIds: estudios vinculados a la orden que viven en Orthanc
 *   (orthanc_studies.linked_order_id). Los que ya no estén en Orthanc (p. ej.
 *   copiados y borrados antes de la Fase 2A) se omiten: sus imágenes salen
 *   de dicomPaths.
 * dicomPaths: rutas en el bucket "imaging" (imaging_files.dicom_path) de las
 *   filas antiguas, que se rehidratan en Orthanc.
 */
export async function openOrderMedia({ supabase, dicomPaths = [], orthancStudyIds = [], signal }) {
  const studies = new Set();
  const owned = new Set();

  try {
    for (const studyId of orthancStudyIds) {
      signal?.throwIfAborted();
      if (temporaryStudies.has(studyId)) continue; // rehidratación en curso de otra descarga
      if (!(await orthancGetJson(`/studies/${studyId}`))) continue;
      // Ya en `studies`: si una instancia rehidratada cae en este mismo
      // estudio, se salta abajo y nunca queda como propio (no se borra).
      studies.add(studyId);
    }

    for (const dicomPath of dicomPaths) {
      signal?.throwIfAborted();
      const { data, error } = await supabase.storage.from("imaging").download(dicomPath);
      if (error || !data) {
        throw new Error(`No se pudo leer ${dicomPath} de Storage: ${error?.message ?? "sin datos"}`);
      }
      const buffer = Buffer.from(await data.arrayBuffer());
      const result = await orthancUploadInstance(buffer);
      const studyId = result?.ParentStudy;
      if (!studyId) throw new Error(`Orthanc no aceptó ${dicomPath} como DICOM.`);
      if (studies.has(studyId)) continue;

      studies.add(studyId);
      // "AlreadyStored" en la primera instancia = el estudio ya estaba en
      // Orthanc por otra vía (p. ej. sin vincular): no es nuestro, no se borra.
      const isOurs = result.Status === "Success" || temporaryStudies.has(studyId);
      if (!isOurs) continue;

      owned.add(studyId);
      temporaryStudies.set(studyId, (temporaryStudies.get(studyId) ?? 0) + 1);
      try {
        await orthancPut(`/studies/${studyId}/labels/${DVD_TEMP_LABEL}`);
      } catch (labelError) {
        console.warn(`[DVD] No se pudo etiquetar el estudio temporal ${studyId}:`, labelError.message);
      }
    }

    if (studies.size === 0) throw new Error("La orden no tiene instancias DICOM.");

    const ids = [...studies];
    const response =
      ids.length === 1
        ? await orthancStream(`/studies/${ids[0]}/media`, { signal })
        : await orthancStream("/tools/create-media", {
            method: "POST",
            json: { Resources: ids, Synchronous: true },
            signal,
          });
    if (!response?.body) throw new Error("Orthanc no devolvió el paquete de medios.");

    let released = false;
    return {
      body: Readable.fromWeb(response.body),
      studyIds: ids,
      release: async () => {
        if (released) return;
        released = true;
        await releaseStudies(owned);
      },
    };
  } catch (error) {
    await releaseStudies(owned);
    throw error;
  }
}
