// Armado del ZIP "Descargar para DVD" (dvdExport.mjs) con un paquete de
// medios de Orthanc simulado y un visor falso. No toca Orthanc, Supabase ni
// GitHub.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable, Writable } from "node:stream";
import { after, test } from "node:test";
import { ZipArchive } from "archiver";
import unzipper from "unzipper";

import {
  buildLeame,
  dvdFilename,
  surnameFromFullName,
  writeDvdZip,
} from "../dvdExport.mjs";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "dvd-zip-test-"));
after(() => fs.rmSync(tempDir, { recursive: true, force: true }));

// Visor falso con la misma forma que devuelve getWeasisViewer().
function fakeViewer() {
  const dir = path.join(tempDir, "viewer");
  const files = [
    { path: "Weasis.exe", content: "MZ-exe-falso" },
    { path: "app/Weasis.cfg", content: "[Application]" },
    { path: "runtime/bin/java.dll", content: "dll" },
  ];
  for (const file of files) {
    fs.mkdirSync(path.dirname(path.join(dir, file.path)), { recursive: true });
    fs.writeFileSync(path.join(dir, file.path), file.content);
  }
  return {
    dir,
    version: "4.7.3",
    files: files.map((f) => ({ path: f.path, size: Buffer.byteLength(f.content) })),
  };
}

// ZIP como el de GET /studies/{id}/media de Orthanc: DICOMDIR en la raíz y
// las instancias en IMAGES/. `entries` = [{ name, source }].
function mockOrthancMedia(entries) {
  const archive = new ZipArchive({ zlib: { level: 1 } });
  for (const { name, source } of entries) archive.append(source, { name });
  archive.finalize();
  return archive;
}

const README_DATA = {
  clinicName: "Clínica Test",
  patientName: "Juan Andrés Pérez Soto",
  patientRut: "12345678-5",
  examDate: "2026-09-24T15:00:00Z",
  examTypes: ["Radiografía de tórax"],
  accessionNumber: "IMD000123",
};

class Collector extends Writable {
  chunks = [];
  _write(chunk, _encoding, callback) {
    this.chunks.push(chunk);
    callback();
  }
  get buffer() {
    return Buffer.concat(this.chunks);
  }
}

async function readZip(buffer) {
  const directory = await unzipper.Open.buffer(buffer);
  const files = new Map();
  for (const file of directory.files) {
    if (file.type === "File") files.set(file.path, await file.buffer());
  }
  return files;
}

test("nombre del archivo: DVD_<apellido>_<fecha>_<accession>.zip", () => {
  assert.equal(
    dvdFilename({ patientName: "Juan Andrés Pérez Soto", examDate: "2026-09-24T15:00:00Z", accessionNumber: "IMD000123" }),
    "DVD_Perez_2026-09-24_IMD000123.zip",
  );
  assert.equal(surnameFromFullName("María Núñez"), "Nunez");
  assert.equal(surnameFromFullName(""), "Paciente");
  // Hora de Chile: las 01:00 UTC del 25 todavía son el 24 en Santiago.
  assert.match(
    dvdFilename({ patientName: "Ana Díaz", examDate: "2026-09-25T01:00:00Z", accessionNumber: "IMD1" }),
    /^DVD_Diaz_2026-09-24_IMD1\.zip$/,
  );
});

test("estructura de la raíz, autorun.inf, lanzador y LEAME con los datos", async () => {
  const viewer = fakeViewer();
  const media = mockOrthancMedia([
    { name: "DICOMDIR", source: Buffer.from("DICM-directorio") },
    { name: "IMAGES/IM0", source: Buffer.alloc(200_000, 1) },
    { name: "IMAGES/IM1", source: Buffer.alloc(200_000, 2) },
    // No puede pisar el autorun.inf propio del disco:
    { name: "autorun.inf", source: Buffer.from("[autorun]\r\nopen=malo.exe") },
  ]);
  const output = new Collector();

  const result = await writeDvdZip({
    mediaZip: media,
    output,
    viewer,
    leame: buildLeame({ ...README_DATA, viewer }),
  });
  assert.equal(result.mediaEntries, 3);

  const files = await readZip(output.buffer);
  const roots = new Set([...files.keys()].map((name) => name.split("/")[0]));
  assert.deepEqual(
    [...roots].sort(),
    ["Abrir imagenes.cmd", "DICOMDIR", "IMAGES", "LEAME.txt", "autorun.inf", "viewer"],
  );
  assert.equal(files.get("DICOMDIR").toString(), "DICM-directorio");
  assert.equal(files.get("IMAGES/IM0").length, 200_000);
  assert.equal(files.get("viewer/Weasis.exe").toString(), "MZ-exe-falso");
  assert.ok(files.has("viewer/runtime/bin/java.dll"));

  const autorun = files.get("autorun.inf").toString();
  assert.match(autorun, /^\[autorun\]\r\n/);
  assert.match(autorun, /^open=viewer\\Weasis\.exe weasis:\/\/%24dicom%3Aget%20-l%20DICOMDIR\r$/m);
  assert.match(autorun, /^action=Abrir imagenes\r$/m);
  assert.match(autorun, /^icon=viewer\\Weasis\.exe,0\r$/m);

  const launcher = files.get("Abrir imagenes.cmd").toString();
  assert.match(launcher, /cd \/d "%~dp0"/);
  assert.match(launcher, /start "" "viewer\\Weasis\.exe" "weasis:\/\/%%24dicom%%3Aget%%20-l%%20DICOMDIR"/);

  const leame = files.get("LEAME.txt").toString("utf8");
  assert.ok(leame.startsWith("﻿"), "UTF-8 con BOM para el Bloc de notas");
  for (const expected of [
    "Clínica Test",
    "Juan Andrés Pérez Soto",
    "12345678-5",
    "24-09-2026",
    "Radiografía de tórax",
    "IMD000123",
    "Horos",
    "El visor incluido sirve para ver las imágenes; el diagnóstico oficial es el informe del radiólogo.",
    "Weasis 4.7.3",
  ]) {
    assert.ok(leame.includes(expected), `el LEAME debe incluir: ${expected}`);
  }
  assert.match(leame, /CÓMO ABRIR LAS IMÁGENES EN WINDOWS/);
  assert.match(leame, /CÓMO ABRIR LAS IMÁGENES EN MAC/);
});

test("sin visor: van las imágenes y el LEAME lo avisa; sin autorun ni lanzador", async () => {
  const media = mockOrthancMedia([
    { name: "DICOMDIR", source: Buffer.from("DICM") },
    { name: "IMAGES/IM0", source: Buffer.from("imagen") },
  ]);
  const output = new Collector();
  await writeDvdZip({ mediaZip: media, output, viewer: null, leame: buildLeame({ ...README_DATA, viewer: null }) });

  const files = await readZip(output.buffer);
  assert.deepEqual([...files.keys()].sort(), ["DICOMDIR", "IMAGES/IM0", "LEAME.txt"]);
  const leame = files.get("LEAME.txt").toString("utf8");
  assert.match(leame, /Este disco NO incluye un visor de imágenes\./);
  assert.ok(leame.includes("el diagnóstico oficial es el informe del radiólogo"));
});

test("un paquete de Orthanc vacío o corrupto hace fallar el armado", async () => {
  const empty = mockOrthancMedia([]);
  await assert.rejects(
    writeDvdZip({ mediaZip: empty, output: new Collector(), viewer: null, leame: "x" }),
    /vino vacío/,
  );
});

test("streaming: 256 MB de imágenes pasan sin cargarse en memoria", async () => {
  const ENTRY_BYTES = 16 * 1024 * 1024;
  const ENTRIES = 16;
  const CHUNK = 64 * 1024;
  let sourceFinished = 0;

  // Cada "instancia" se genera de a 64 KB a medida que se lee: el paquete
  // simulado nunca existe completo en memoria.
  function lazyInstance(seed) {
    let produced = 0;
    return new Readable({
      read() {
        if (produced >= ENTRY_BYTES) {
          sourceFinished += 1;
          this.push(null);
          return;
        }
        const chunk = Buffer.allocUnsafe(CHUNK);
        chunk.fill(seed + (produced / CHUNK) % 7);
        produced += CHUNK;
        this.push(chunk);
      },
    });
  }

  const media = mockOrthancMedia([
    { name: "DICOMDIR", source: Buffer.from("DICM") },
    ...Array.from({ length: ENTRIES }, (_, i) => ({ name: `IMAGES/IM${i}`, source: lazyInstance(i) })),
  ]);

  const memory = () => {
    const usage = process.memoryUsage();
    return usage.heapUsed + usage.arrayBuffers;
  };
  const baseline = memory();
  let peak = baseline;
  let outputBytes = 0;
  let instancesDoneAtFirstOutput = null;

  const sink = new Writable({
    write(chunk, _encoding, callback) {
      if (instancesDoneAtFirstOutput === null) instancesDoneAtFirstOutput = sourceFinished;
      outputBytes += chunk.length;
      peak = Math.max(peak, memory());
      callback();
    },
  });

  const result = await writeDvdZip({ mediaZip: media, output: sink, viewer: null, leame: "LEAME" });
  assert.equal(result.mediaEntries, ENTRIES + 1);
  assert.ok(outputBytes > 0);

  // El ZIP de salida empieza a salir antes de terminar de leer el de entrada.
  assert.equal(instancesDoneAtFirstOutput, 0);

  const growthMb = (peak - baseline) / (1024 * 1024);
  console.log(`memoria: +${growthMb.toFixed(1)} MB de pico, ${(outputBytes / 1048576).toFixed(1)} MB escritos`);
  const inputMb = (ENTRY_BYTES * ENTRIES) / (1024 * 1024);
  assert.ok(
    growthMb < 96,
    `la memoria creció ${growthMb.toFixed(1)} MB procesando ${inputMb} MB (máximo permitido 96 MB)`,
  );
});
