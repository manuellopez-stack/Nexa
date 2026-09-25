// Rutas "Descargar para DVD" de server.mjs contra un Orthanc simulado (un
// servidor HTTP local), la base en memoria de test/support/supabase-mock.mjs
// y un visor Weasis falso en una caché temporal. No toca Orthanc, Supabase
// ni GitHub reales.
//
// Usa el puerto 3000 como correction_flow.test.mjs: npm test corre los
// archivos de a uno (--test-concurrency=1).

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { ZipArchive } from "archiver";
import unzipper from "unzipper";

import { resetDb, storageFiles, users } from "./support/supabase-mock.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const TOKENS = { recepcion: "tok-recepcion", tecnico: "tok-tecnico", otraClinica: "tok-otra" };

// ---------------------------------------------------------------------------
// Orthanc simulado: guarda instancias en memoria agrupadas por estudio (el
// estudio sale del prefijo "estudio:<id>|" del archivo DICOM simulado).
// ---------------------------------------------------------------------------
const orthanc = { studies: new Map(), labels: [], deleted: [], requests: [] };

function readBody(request) {
  return new Promise((resolve) => {
    const chunks = [];
    request.on("data", (c) => chunks.push(c));
    request.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

const fakeOrthanc = http.createServer(async (request, response) => {
  orthanc.requests.push(`${request.method} ${request.url}`);
  if (request.headers.authorization !== `Basic ${Buffer.from("orthanc:secreto").toString("base64")}`) {
    response.writeHead(401).end();
    return;
  }
  const body = await readBody(request);
  let match;

  if (request.method === "POST" && request.url === "/instances") {
    const studyId = body.toString().match(/^estudio:([\w-]+)\|/)?.[1];
    if (!studyId) {
      response.writeHead(400).end();
      return;
    }
    const instanceId = crypto.createHash("sha1").update(body).digest("hex");
    const study = orthanc.studies.get(studyId) ?? new Map();
    const status = study.has(instanceId) ? "AlreadyStored" : "Success";
    study.set(instanceId, body);
    orthanc.studies.set(studyId, study);
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ID: instanceId, ParentStudy: studyId, Status: status }));
  } else if (request.method === "PUT" && (match = request.url.match(/^\/studies\/([\w-]+)\/labels\/(.+)$/))) {
    orthanc.labels.push([match[1], match[2]]);
    response.writeHead(200).end("{}");
  } else if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)\/media$/))) {
    const study = orthanc.studies.get(match[1]);
    if (!study) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "Content-Type": "application/zip" });
    const archive = new ZipArchive({ zlib: { level: 1 } });
    archive.pipe(response);
    archive.append(Buffer.from(`DICOMDIR de ${match[1]}`), { name: "DICOMDIR" });
    [...study.values()].forEach((instance, i) => archive.append(instance, { name: `IMAGES/IM${i}` }));
    archive.finalize();
  } else if (request.method === "DELETE" && (match = request.url.match(/^\/studies\/([\w-]+)$/))) {
    orthanc.studies.delete(match[1]);
    orthanc.deleted.push(match[1]);
    response.writeHead(200).end("{}");
  } else {
    response.writeHead(404).end();
  }
});

// ---------------------------------------------------------------------------
// Visor falso ya "preparado" en la caché (manifest válido): no se descarga.
// ---------------------------------------------------------------------------
const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "dvd-route-test-"));
{
  const viewerDir = path.join(cacheDir, "weasis-4.7.3", "viewer");
  fs.mkdirSync(path.join(viewerDir, "app"), { recursive: true });
  fs.writeFileSync(path.join(viewerDir, "Weasis.exe"), "MZ");
  fs.writeFileSync(path.join(viewerDir, "app", "Weasis.cfg"), "cfg");
  fs.writeFileSync(
    path.join(cacheDir, "weasis-4.7.3", "manifest.json"),
    JSON.stringify({
      version: "4.7.3",
      totalBytes: 5,
      files: [
        { path: "Weasis.exe", size: 2 },
        { path: "app/Weasis.cfg", size: 3 },
      ],
    }),
  );
}

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      { id: "u-recepcion", role: "recepcion", clinic_id: CLINIC, full_name: "Recepción" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec" },
      { id: "u-otra", role: "medico", clinic_id: OTHER_CLINIC, full_name: "Otro" },
    ],
    patients: [
      { id: 1, name: "Juan Andrés Pérez Soto", rut: "12.345.678-5", clinic_id: CLINIC },
      { id: 2, name: "Otra Persona", rut: "11111111-1", clinic_id: OTHER_CLINIC },
    ],
    imaging_orders: [
      {
        id: "io-1", patient_id: 1, clinic_id: CLINIC, status: "realizado",
        accession_number: "IMD000777", requested_at: "2026-09-24T12:00:00Z", performed_at: "2026-09-24T15:00:00Z",
      },
      { id: "io-vacia", patient_id: 1, clinic_id: CLINIC, status: "ordenado", accession_number: "IMD000778", requested_at: "2026-09-24T12:00:00Z" },
      { id: "io-previo", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000779", requested_at: "2026-09-24T12:00:00Z" },
      { id: "io-otra", patient_id: 2, clinic_id: OTHER_CLINIC, status: "realizado", accession_number: "IMD000900", requested_at: "2026-09-24T12:00:00Z" },
    ],
    imaging_order_types: [{ order_id: "io-1", imaging_type_id: "it-1" }],
    imaging_types: [{ id: "it-1", name: "Radiografía de tórax", category: "RX" }],
    imaging_files: [
      { id: "f1", order_id: "io-1", dicom_path: "orders/io-1/a.dcm", uploaded_at: "2026-09-24T15:01:00Z" },
      { id: "f2", order_id: "io-1", dicom_path: "orders/io-1/b.dcm", uploaded_at: "2026-09-24T15:02:00Z" },
      { id: "f3", order_id: "io-previo", dicom_path: "orders/io-previo/a.dcm", uploaded_at: "2026-09-24T15:01:00Z" },
      { id: "f4", order_id: "io-otra", dicom_path: "orders/io-otra/a.dcm", uploaded_at: "2026-09-24T15:01:00Z" },
    ],
  });
  storageFiles["imaging/orders/io-1/a.dcm"] = Buffer.from("estudio:st-1|instancia A");
  storageFiles["imaging/orders/io-1/b.dcm"] = Buffer.from("estudio:st-1|instancia B");
  storageFiles["imaging/orders/io-previo/a.dcm"] = Buffer.from("estudio:st-previo|instancia A");
  storageFiles["imaging/orders/io-otra/a.dcm"] = Buffer.from("estudio:st-otra|instancia A");
  users[TOKENS.recepcion] = { id: "u-recepcion", email: "recepcion@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
}

function get(pathname, as) {
  return fetch(`${BASE}${pathname}`, { headers: as ? { Authorization: `Bearer ${TOKENS[as]}` } : {} });
}

async function zipEntries(response) {
  const directory = await unzipper.Open.buffer(Buffer.from(await response.arrayBuffer()));
  const files = new Map();
  for (const file of directory.files) if (file.type === "File") files.set(file.path, await file.buffer());
  return files;
}

// La limpieza en Orthanc corre justo después de cerrar la respuesta.
async function waitFor(condition) {
  for (let i = 0; i < 50 && !condition(); i++) await new Promise((r) => setTimeout(r, 20));
  return condition();
}

before(async () => {
  await new Promise((resolve) => fakeOrthanc.listen(0, resolve));
  process.env.OPENAI_API_KEY = "test";
  process.env.SUPABASE_URL = "http://supabase.mock";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test";
  process.env.ORTHANC_URL = `http://127.0.0.1:${fakeOrthanc.address().port}`;
  process.env.ORTHANC_USER = "orthanc";
  process.env.ORTHANC_PASSWORD = "secreto";
  process.env.WEASIS_CACHE_DIR = cacheDir;
  seed();

  await import("../server.mjs");
  for (let i = 0; i < 50; i++) {
    try {
      await fetch(`${BASE}/health`);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("El servidor de prueba no arrancó en el puerto 3000.");
});

after(() => {
  fs.rmSync(cacheDir, { recursive: true, force: true });
  setTimeout(() => process.exit(), 50);
});

test("recepción descarga el ZIP; el estudio temporal se etiqueta y se borra de Orthanc", async () => {
  const response = await get("/patients/1/imaging-orders/io-1/dvd", "recepcion");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "application/zip");
  assert.match(
    response.headers.get("content-disposition"),
    /filename="DVD_Perez_2026-09-24_IMD000777\.zip"/,
  );

  const files = await zipEntries(response);
  assert.deepEqual(
    [...files.keys()].sort(),
    [
      "Abrir imagenes.cmd",
      "DICOMDIR",
      "IMAGES/IM0",
      "IMAGES/IM1",
      "LEAME.txt",
      "autorun.inf",
      "viewer/Weasis.exe",
      "viewer/app/Weasis.cfg",
    ],
  );
  assert.equal(files.get("DICOMDIR").toString(), "DICOMDIR de st-1");
  const leame = files.get("LEAME.txt").toString("utf8");
  for (const expected of ["Clínica Test", "Juan Andrés Pérez Soto", "12345678-5", "24-09-2026", "Radiografía de tórax", "IMD000777"]) {
    assert.ok(leame.includes(expected), `el LEAME debe incluir: ${expected}`);
  }

  assert.deepEqual(orthanc.labels, [["st-1", "imagenda-dvd-temporal"]]);
  assert.ok(await waitFor(() => orthanc.deleted.includes("st-1")), "debe borrar el estudio temporal");
  assert.equal(orthanc.studies.has("st-1"), false);
});

test("un estudio que ya estaba en Orthanc no se borra al terminar", async () => {
  storageFiles["imaging/orders/io-previo/a.dcm"] = Buffer.from("estudio:st-previo|instancia A");
  orthanc.studies.set(
    "st-previo",
    new Map([[crypto.createHash("sha1").update("estudio:st-previo|instancia A").digest("hex"), Buffer.from("estudio:st-previo|instancia A")]]),
  );
  const response = await get("/patients/1/imaging-orders/io-previo/dvd", "tecnico");
  assert.equal(response.status, 200);
  await response.arrayBuffer();
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(orthanc.studies.has("st-previo"), true);
  assert.ok(!orthanc.deleted.includes("st-previo"));
  assert.ok(!orthanc.labels.some(([study]) => study === "st-previo"));
});

test("enlace firmado para la app web: sirve sin header y un token alterado no", async () => {
  const linkResponse = await fetch(`${BASE}/patients/1/imaging-orders/io-1/dvd-link`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKENS.recepcion}` },
  });
  assert.equal(linkResponse.status, 200);
  const link = await linkResponse.json();
  assert.equal(link.filename, "DVD_Perez_2026-09-24_IMD000777.zip");
  assert.equal(link.viewerIncluded, true);
  assert.match(link.url, /^\/dvd-downloads\/[\w-]+\.[\w-]+$/);

  const download = await get(link.url);
  assert.equal(download.status, 200);
  assert.ok((await zipEntries(download)).has("autorun.inf"));

  const tampered = link.url.replace(/.$/, (c) => (c === "A" ? "B" : "A"));
  assert.equal((await get(tampered)).status, 401);
});

test("aislamiento por clínica: la orden de otra clínica responde 404", async () => {
  // Alguien de otra clínica pidiendo una orden de esta clínica.
  assert.equal((await get("/patients/1/imaging-orders/io-1/dvd", "otraClinica")).status, 404);
  const link = await fetch(`${BASE}/patients/1/imaging-orders/io-1/dvd-link`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKENS.otraClinica}` },
  });
  assert.equal(link.status, 404);
  // Y al revés: esta clínica pidiendo una orden de la otra.
  assert.equal((await get("/patients/2/imaging-orders/io-otra/dvd", "recepcion")).status, 404);
  assert.ok(!orthanc.requests.some((r) => r.includes("st-otra")), "no debe tocar Orthanc");
});

test("sin sesión 401; orden sin imágenes DICOM 409", async () => {
  assert.equal((await get("/patients/1/imaging-orders/io-1/dvd")).status, 401);
  assert.equal((await get("/patients/1/imaging-orders/io-vacia/dvd", "recepcion")).status, 409);
});

test("listado para DVD: solo órdenes con imágenes y de la propia clínica", async () => {
  const response = await get("/patients/1/dvd-studies", "recepcion");
  assert.equal(response.status, 200);
  const { studies } = await response.json();
  assert.deepEqual(studies.map((s) => s.orderId).sort(), ["io-1", "io-previo"]);
  const study = studies.find((s) => s.orderId === "io-1");
  assert.equal(study.accessionNumber, "IMD000777");
  assert.deepEqual(study.examTypes, ["Radiografía de tórax"]);
  assert.equal(study.imageCount, 2);

  const other = await (await get("/patients/1/dvd-studies", "otraClinica")).json();
  assert.deepEqual(other.studies, []);
  assert.equal((await get("/patients/1/dvd-studies")).status, 401);
});
