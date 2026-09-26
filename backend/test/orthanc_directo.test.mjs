// Fase 2A: imágenes servidas directo desde Orthanc. Vincular sin copiar ni
// borrar, URLs firmadas (/imaging-files/:id/dicom|preview), GET .../images con
// una vista previa por serie y DVD desde el estudio vinculado. Contra un
// Orthanc simulado (servidor HTTP local) y la base en memoria de
// test/support/supabase-mock.mjs. No toca Orthanc ni Supabase reales.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { ZipArchive } from "archiver";
import unzipper from "unzipper";

import { db, resetDb, storageFiles, users } from "./support/supabase-mock.mjs";
import { signImageToken, verifyImageToken } from "../imageTokens.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const TOKENS = { recepcion: "tok-recepcion", tecnico: "tok-tecnico", otraClinica: "tok-otra" };

// ---------------------------------------------------------------------------
// Orthanc simulado. Estudios "directos" con series e instancias fijas; POST
// /instances agrupa por el prefijo "estudio:<id>|" (rehidratación de filas
// antiguas, como en dvd_route.test.mjs).
// ---------------------------------------------------------------------------
const orthanc = { studies: new Map(), labels: [], deleted: [], requests: [], createMedia: [] };

function directStudy(studyId, series) {
  // series: [{ id, number, instances: [{ id, number }] }]
  const instances = new Map();
  for (const serie of series) {
    for (const instance of serie.instances) {
      instances.set(instance.id, { ...instance, series: serie.id, body: Buffer.from(`DICM ${instance.id}`) });
    }
  }
  orthanc.studies.set(studyId, { series, instances });
}

function readBody(request) {
  return new Promise((resolve) => {
    const chunks = [];
    request.on("data", (c) => chunks.push(c));
    request.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

function findInstance(instanceId) {
  for (const study of orthanc.studies.values()) {
    if (study.instances.has(instanceId)) return study.instances.get(instanceId);
  }
  return null;
}

function sendZip(response, parts) {
  response.writeHead(200, { "Content-Type": "application/zip" });
  const archive = new ZipArchive({ zlib: { level: 1 } });
  archive.pipe(response);
  archive.append(Buffer.from(`DICOMDIR de ${parts.map((p) => p.studyId).join("+")}`), { name: "DICOMDIR" });
  let i = 0;
  for (const { studyId } of parts) {
    for (const instance of orthanc.studies.get(studyId).instances.values()) {
      archive.append(instance.body, { name: `IMAGES/IM${i++}` });
    }
  }
  archive.finalize();
}

const json = (response, value) => {
  response.writeHead(200, { "Content-Type": "application/json" });
  response.end(JSON.stringify(value));
};

const fakeOrthanc = http.createServer(async (request, response) => {
  orthanc.requests.push(`${request.method} ${request.url}`);
  if (request.headers.authorization !== `Basic ${Buffer.from("orthanc:secreto").toString("base64")}`) {
    response.writeHead(401).end();
    return;
  }
  const body = await readBody(request);
  let match;

  if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)$/))) {
    const study = orthanc.studies.get(match[1]);
    return study ? json(response, { ID: match[1], Labels: [] }) : response.writeHead(404).end();
  }
  if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)\/instances$/))) {
    const study = orthanc.studies.get(match[1]);
    if (!study) return response.writeHead(404).end();
    // Orthanc no garantiza orden: se devuelven al revés a propósito.
    return json(
      response,
      [...study.instances.values()].reverse().map((instance) => ({
        ID: instance.id,
        ParentSeries: instance.series,
        MainDicomTags: instance.number == null ? {} : { InstanceNumber: String(instance.number) },
      })),
    );
  }
  if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)\/series$/))) {
    const study = orthanc.studies.get(match[1]);
    if (!study) return response.writeHead(404).end();
    return json(
      response,
      study.series.map((serie) => ({
        ID: serie.id,
        MainDicomTags: { SeriesNumber: String(serie.number) },
        Instances: serie.instances.map((instance) => instance.id),
      })),
    );
  }
  if (request.method === "GET" && (match = request.url.match(/^\/instances\/([\w-]+)\/(file|preview)$/))) {
    const instance = findInstance(match[1]);
    if (!instance) return response.writeHead(404).end();
    if (match[2] === "file") {
      response.writeHead(200, { "Content-Type": "application/dicom", "Content-Length": instance.body.length });
      return response.end(instance.body);
    }
    const png = Buffer.from(`PNG ${instance.id}`);
    response.writeHead(200, { "Content-Type": "image/png" });
    return response.end(png);
  }
  if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)\/media$/))) {
    if (!orthanc.studies.has(match[1])) return response.writeHead(404).end();
    return sendZip(response, [{ studyId: match[1] }]);
  }
  if (request.method === "POST" && request.url === "/tools/create-media") {
    const { Resources } = JSON.parse(body.toString());
    orthanc.createMedia.push(Resources);
    return sendZip(response, Resources.map((studyId) => ({ studyId })));
  }
  if (request.method === "POST" && request.url === "/instances") {
    const studyId = body.toString().match(/^estudio:([\w-]+)\|/)?.[1];
    if (!studyId) return response.writeHead(400).end();
    const instanceId = crypto.createHash("sha1").update(body).digest("hex");
    const study = orthanc.studies.get(studyId) ?? { series: [], instances: new Map() };
    const status = study.instances.has(instanceId) ? "AlreadyStored" : "Success";
    study.instances.set(instanceId, { id: instanceId, series: "s-rehidratada", body });
    orthanc.studies.set(studyId, study);
    return json(response, { ID: instanceId, ParentStudy: studyId, Status: status });
  }
  if (request.method === "PUT" && (match = request.url.match(/^\/studies\/([\w-]+)\/labels\/(.+)$/))) {
    orthanc.labels.push([match[1], match[2]]);
    return json(response, {});
  }
  if (request.method === "DELETE" && (match = request.url.match(/^\/studies\/([\w-]+)$/))) {
    orthanc.studies.delete(match[1]);
    orthanc.deleted.push(match[1]);
    return json(response, {});
  }
  response.writeHead(404).end();
});

// Visor falso ya "preparado" en la caché (manifest válido): no se descarga.
const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "orthanc-directo-test-"));
{
  const viewerDir = path.join(cacheDir, "weasis-4.7.3", "viewer");
  fs.mkdirSync(viewerDir, { recursive: true });
  fs.writeFileSync(path.join(viewerDir, "Weasis.exe"), "MZ");
  fs.writeFileSync(
    path.join(cacheDir, "weasis-4.7.3", "manifest.json"),
    JSON.stringify({ version: "4.7.3", totalBytes: 2, files: [{ path: "Weasis.exe", size: 2 }] }),
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
      { id: "io-directo", patient_id: 1, clinic_id: CLINIC, status: "ordenado", accession_number: "IMD000801", requested_at: "2026-09-26T12:00:00Z" },
      { id: "io-mixto", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000802", requested_at: "2026-09-26T12:00:00Z" },
      { id: "io-otra", patient_id: 2, clinic_id: OTHER_CLINIC, status: "realizado", accession_number: "IMD000900", requested_at: "2026-09-26T12:00:00Z" },
    ],
    orthanc_studies: [
      { orthanc_study_id: "st-directo", status: "unlinked", clinic_id: CLINIC },
      { orthanc_study_id: "st-mixto", status: "linked", linked_order_id: "io-mixto", clinic_id: CLINIC },
      // Copiado y borrado de Orthanc antes de la Fase 2A: su fila sigue 'linked'.
      { orthanc_study_id: "st-viejo", status: "linked", linked_order_id: "io-mixto", clinic_id: CLINIC },
      { orthanc_study_id: "st-otra", status: "linked", linked_order_id: "io-otra", clinic_id: OTHER_CLINIC },
    ],
    imaging_files: [
      // io-mixto: una fila antigua (Storage) + una de Orthanc.
      { id: "f-viejo", order_id: "io-mixto", dicom_path: "orders/io-mixto/a.dcm", png_path: "orders/io-mixto/a.png", orthanc_instance_id: "i-viejo", uploaded_at: "2026-09-20T10:00:00Z" },
      { id: "f-mixto", order_id: "io-mixto", dicom_path: null, png_path: null, orthanc_instance_id: "i-mixto-1", orthanc_series_id: "se-mixto", orthanc_series_number: 1, orthanc_instance_number: 1, uploaded_at: "2026-09-26T10:00:00Z" },
      { id: "f-otra", order_id: "io-otra", dicom_path: null, png_path: null, orthanc_instance_id: "i-otra", orthanc_series_id: "se-otra", uploaded_at: "2026-09-26T10:00:00Z" },
    ],
  });
  orthanc.studies.clear();
  directStudy("st-directo", [
    { id: "se-2", number: 2, instances: [{ id: "i-2-1", number: 1 }] },
    { id: "se-1", number: 1, instances: [{ id: "i-1-3", number: 3 }, { id: "i-1-1", number: 1 }, { id: "i-1-2", number: 2 }] },
  ]);
  directStudy("st-mixto", [{ id: "se-mixto", number: 1, instances: [{ id: "i-mixto-1", number: 1 }] }]);
  directStudy("st-otra", [{ id: "se-otra", number: 1, instances: [{ id: "i-otra", number: 1 }] }]);
  storageFiles["imaging/orders/io-mixto/a.dcm"] = Buffer.from("estudio:st-viejo|instancia antigua");
  users[TOKENS.recepcion] = { id: "u-recepcion", email: "recepcion@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
}

function get(pathname, as, headers = {}) {
  const url = pathname.startsWith("http") ? pathname : `${BASE}${pathname}`;
  return fetch(url, { headers: { ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}), ...headers } });
}

// Cambia un carácter del medio (el último de un base64url puede ser solo
// relleno y decodificar igual).
function tamper(text) {
  const i = Math.floor(text.length / 2);
  return text.slice(0, i) + (text[i] === "A" ? "B" : "A") + text.slice(i + 1);
}

async function images(orderId, as = "tecnico", headers) {
  const response = await get(`/patients/1/imaging-orders/${orderId}/images`, as, headers);
  assert.equal(response.status, 200);
  return (await response.json()).files;
}

async function zipEntries(response) {
  const directory = await unzipper.Open.buffer(Buffer.from(await response.arrayBuffer()));
  const files = new Map();
  for (const file of directory.files) if (file.type === "File") files.set(file.path, await file.buffer());
  return files;
}

async function linkDirectStudy() {
  const response = await fetch(`${BASE}/orthanc-studies/st-directo/link`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKENS.tecnico}`, "Content-Type": "application/json" },
    body: JSON.stringify({ orderId: "io-directo" }),
  });
  return response;
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
  delete process.env.PUBLIC_BACKEND_URL;
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

// ---------------------------------------------------------------------------
// Vincular
// ---------------------------------------------------------------------------

test("vincular registra una fila por instancia sin copiar a Storage ni borrar de Orthanc", async () => {
  orthanc.requests.length = 0;
  const response = await linkDirectStudy();
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { linked: true, orderId: "io-directo", totalInstances: 4, linkedNow: 4 });

  const rows = db.imaging_files.filter((row) => row.order_id === "io-directo");
  assert.equal(rows.length, 4);
  for (const row of rows) {
    assert.equal(row.dicom_path, null);
    assert.equal(row.png_path, null);
  }
  const byInstance = Object.fromEntries(rows.map((row) => [row.orthanc_instance_id, row]));
  assert.equal(byInstance["i-1-3"].orthanc_series_id, "se-1");
  assert.equal(byInstance["i-1-3"].orthanc_series_number, 1);
  assert.equal(byInstance["i-1-3"].orthanc_instance_number, 3);
  assert.equal(byInstance["i-2-1"].orthanc_series_id, "se-2");

  assert.ok(!orthanc.requests.some((r) => r.startsWith("DELETE")), "no debe borrar nada de Orthanc");
  assert.ok(!orthanc.requests.some((r) => /\/instances\/[\w-]+\/(file|preview)/.test(r)), "no debe descargar instancias");
  assert.equal(Object.keys(storageFiles).filter((k) => k.includes("io-directo")).length, 0, "no debe subir a Storage");
  assert.ok(orthanc.studies.has("st-directo"));

  const study = db.orthanc_studies.find((row) => row.orthanc_study_id === "st-directo");
  assert.equal(study.status, "linked");
  assert.equal(study.linked_order_id, "io-directo");
  assert.equal(db.imaging_orders.find((o) => o.id === "io-directo").status, "realizado");

  // Ya vinculado: la ruta responde 409 y no toca nada.
  assert.equal((await linkDirectStudy()).status, 409);
});

test("vincular dos veces el mismo estudio no duplica filas (idempotente por instancia)", async () => {
  const { linkOrthancStudyToOrder } = await import("../orthancStudies.mjs");
  const { createClient } = await import("@supabase/supabase-js");
  const result = await linkOrthancStudyToOrder(createClient(), { orthancStudyId: "st-directo", orderId: "io-directo" });
  assert.deepEqual(result, { totalInstances: 4, linkedNow: 0 });
  assert.equal(db.imaging_files.filter((row) => row.order_id === "io-directo").length, 4);
});

test("ni el vínculo ni el cron importan el borrado de Orthanc", () => {
  for (const file of ["orthancStudies.mjs", "syncOrthanc.mjs"]) {
    const source = fs.readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
    assert.ok(!source.includes("orthancDelete"), `${file} no debe usar orthancDelete`);
    assert.ok(!/storage\s*\.from/.test(source), `${file} no debe subir a Storage`);
  }
});

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

test("token de imagen: válido, vencido, manipulado, de otro archivo o de otro tipo", () => {
  const token = signImageToken({ fileId: "f-1", kind: "dicom" });
  assert.equal(verifyImageToken(token, { fileId: "f-1", kind: "dicom" }), true);
  assert.equal(verifyImageToken(token, { fileId: "f-2", kind: "dicom" }), false);
  assert.equal(verifyImageToken(token, { fileId: "f-1", kind: "preview" }), false);

  const expired = signImageToken({ fileId: "f-1", kind: "dicom" }, { now: Date.now() - 2 * 60 * 60 * 1000 });
  assert.equal(verifyImageToken(expired, { fileId: "f-1", kind: "dicom" }), false);
  // Vence a la hora.
  assert.equal(verifyImageToken(token, { fileId: "f-1", kind: "dicom" }, { now: Date.now() + 61 * 60 * 1000 }), false);

  const [body, signature] = token.split(".");
  const forgedBody = Buffer.from(
    JSON.stringify({ fileId: "f-1", kind: "dicom", exp: Date.now() + 10 * 365 * 24 * 3600 * 1000 }),
  ).toString("base64url");
  assert.equal(verifyImageToken(`${forgedBody}.${signature}`, { fileId: "f-1", kind: "dicom" }), false);
  assert.equal(verifyImageToken(`${body}.${tamper(signature)}`, { fileId: "f-1", kind: "dicom" }), false);
  for (const bad of [undefined, "", "abc", `${body}.`, `.${signature}`, `${body}.${signature}.x`]) {
    assert.equal(verifyImageToken(bad, { fileId: "f-1", kind: "dicom" }), false);
  }
});

// ---------------------------------------------------------------------------
// GET .../images y proxy firmado
// ---------------------------------------------------------------------------

test("/images: URLs del proxy en orden de serie e instancia, una vista previa por serie", async () => {
  const files = await images("io-directo");
  assert.equal(files.length, 4);
  const instanceOf = (file) => db.imaging_files.find((row) => row.id === file.id).orthanc_instance_id;
  assert.deepEqual(files.map(instanceOf), ["i-1-1", "i-1-2", "i-1-3", "i-2-1"]);
  assert.deepEqual(files.map((f) => Boolean(f.pngUrl)), [true, false, false, true]);
  assert.deepEqual(files.map((f) => f.seriesId), ["se-1", "se-1", "se-1", "se-2"]);
  for (const file of files) {
    assert.equal(file.source, "orthanc");
    assert.match(file.dicomUrl, new RegExp(`^http://localhost:3000/imaging-files/${file.id}/dicom\\?t=`));
    assert.ok(!file.dicomUrl.includes("storage.mock"));
  }
  assert.match(files[0].pngUrl, new RegExp(`/imaging-files/${files[0].id}/preview\\?t=`));

  const dicom = await get(files[0].dicomUrl);
  assert.equal(dicom.status, 200);
  assert.equal(dicom.headers.get("content-type"), "application/dicom");
  assert.match(dicom.headers.get("cache-control"), /^private/);
  assert.equal(Buffer.from(await dicom.arrayBuffer()).toString(), "DICM i-1-1");

  const preview = await get(files[0].pngUrl);
  assert.equal(preview.status, 200);
  assert.equal(preview.headers.get("content-type"), "image/png");
  assert.equal(Buffer.from(await preview.arrayBuffer()).toString(), "PNG i-1-1");
});

test("/images: la URL pública usa PUBLIC_BACKEND_URL o x-forwarded-proto/host", async () => {
  const forwarded = await images("io-directo", "tecnico", {
    "x-forwarded-proto": "https",
    "x-forwarded-host": "api.imagenda.cl",
  });
  assert.match(forwarded[0].dicomUrl, /^https:\/\/api\.imagenda\.cl\/imaging-files\//);

  process.env.PUBLIC_BACKEND_URL = "https://backend.imagenda.cl/";
  try {
    const configured = await images("io-directo");
    assert.match(configured[0].dicomUrl, /^https:\/\/backend\.imagenda\.cl\/imaging-files\//);
  } finally {
    delete process.env.PUBLIC_BACKEND_URL;
  }
});

test("/images: orden mixta devuelve la fila antigua con URLs de Storage", async () => {
  const files = await images("io-mixto");
  const legacy = files.find((f) => f.id === "f-viejo");
  const direct = files.find((f) => f.id === "f-mixto");
  assert.equal(legacy.source, "storage");
  assert.match(legacy.dicomUrl, /^http:\/\/storage\.mock\/imaging\/orders\/io-mixto\/a\.dcm/);
  assert.match(legacy.pngUrl, /storage\.mock/);
  assert.equal(direct.source, "orthanc");
  assert.match(direct.dicomUrl, /\/imaging-files\/f-mixto\/dicom\?t=/);
});

test("proxy: token vencido, manipulado o de otro tipo 403; fila inexistente o antigua 404", async () => {
  const [file] = await images("io-directo");
  const url = new URL(file.dicomUrl);

  assert.equal((await get(`/imaging-files/${file.id}/dicom`)).status, 403);
  const expired = signImageToken({ fileId: file.id, kind: "dicom" }, { now: Date.now() - 2 * 60 * 60 * 1000 });
  assert.equal((await get(`/imaging-files/${file.id}/dicom?t=${expired}`)).status, 403);
  const [tokenBody, tokenSignature] = url.searchParams.get("t").split(".");
  assert.equal((await get(`/imaging-files/${file.id}/dicom?t=${tokenBody}.${tamper(tokenSignature)}`)).status, 403);
  // Token de dicom usado en preview, y token de un archivo en otro.
  assert.equal((await get(`/imaging-files/${file.id}/preview?t=${url.searchParams.get("t")}`)).status, 403);
  assert.equal((await get(`/imaging-files/f-otra/dicom?t=${url.searchParams.get("t")}`)).status, 403);

  const missing = signImageToken({ fileId: "no-existe", kind: "dicom" });
  assert.equal((await get(`/imaging-files/no-existe/dicom?t=${missing}`)).status, 404);
  const legacy = signImageToken({ fileId: "f-viejo", kind: "dicom" });
  assert.equal((await get(`/imaging-files/f-viejo/dicom?t=${legacy}`)).status, 404);
});

test("proxy: CORS permite que la app web lea las imágenes", async () => {
  const [file] = await images("io-directo");
  const response = await get(file.dicomUrl, null, { Origin: "https://agenda.imagenda.cl" });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("access-control-allow-origin"), "https://agenda.imagenda.cl");
  await response.arrayBuffer();
});

test("/images: recepción puede ver; otra clínica recibe 404; sin sesión 401", async () => {
  const files = await images("io-directo", "recepcion");
  assert.equal(files.length, 4);
  assert.equal((await get(files[3].dicomUrl)).status, 200);

  assert.equal((await get("/patients/1/imaging-orders/io-directo/images", "otraClinica")).status, 404);
  assert.equal((await get("/patients/2/imaging-orders/io-otra/images", "recepcion")).status, 404);
  assert.equal((await get("/patients/1/imaging-orders/io-directo/images")).status, 401);
});

// ---------------------------------------------------------------------------
// DVD
// ---------------------------------------------------------------------------

test("DVD de una orden de Orthanc: /studies/{id}/media directo, sin subir ni borrar", async () => {
  orthanc.requests.length = 0;
  orthanc.deleted.length = 0;
  orthanc.labels.length = 0;

  const listing = await (await get("/patients/1/dvd-studies", "recepcion")).json();
  const study = listing.studies.find((s) => s.orderId === "io-directo");
  assert.equal(study.imageCount, 4);

  const response = await get("/patients/1/imaging-orders/io-directo/dvd", "recepcion");
  assert.equal(response.status, 200);
  const files = await zipEntries(response);
  assert.equal(files.get("DICOMDIR").toString(), "DICOMDIR de st-directo");
  assert.equal([...files.keys()].filter((name) => name.startsWith("IMAGES/")).length, 4);

  await new Promise((r) => setTimeout(r, 100));
  assert.ok(orthanc.requests.includes("GET /studies/st-directo/media"));
  assert.ok(!orthanc.requests.some((r) => r.startsWith("POST /instances")), "no debe re-subir");
  assert.deepEqual(orthanc.deleted, [], "no debe borrar");
  assert.deepEqual(orthanc.labels, []);
  assert.ok(orthanc.studies.has("st-directo"));
});

test("DVD de una orden mixta: un paquete con ambos; solo se borra lo rehidratado", async () => {
  orthanc.requests.length = 0;
  orthanc.deleted.length = 0;
  orthanc.createMedia.length = 0;

  const response = await get("/patients/1/imaging-orders/io-mixto/dvd", "tecnico");
  assert.equal(response.status, 200);
  const files = await zipEntries(response);
  assert.equal(files.get("DICOMDIR").toString(), "DICOMDIR de st-mixto+st-viejo");

  for (let i = 0; i < 50 && !orthanc.deleted.includes("st-viejo"); i++) await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(orthanc.createMedia, [["st-mixto", "st-viejo"]]);
  assert.deepEqual(orthanc.deleted, ["st-viejo"], "solo el estudio rehidratado");
  assert.ok(orthanc.studies.has("st-mixto"));
});

test("DVD mixto: una instancia antigua que cae en el estudio vinculado no lo hace borrar", async () => {
  orthanc.deleted.length = 0;
  storageFiles["imaging/orders/io-mixto/a.dcm"] = Buffer.from("estudio:st-mixto|instancia antigua");
  try {
    const response = await get("/patients/1/imaging-orders/io-mixto/dvd", "tecnico");
    assert.equal(response.status, 200);
    await response.arrayBuffer();
    await new Promise((r) => setTimeout(r, 150));
    assert.deepEqual(orthanc.deleted, []);
    assert.ok(orthanc.studies.has("st-mixto"));
  } finally {
    storageFiles["imaging/orders/io-mixto/a.dcm"] = Buffer.from("estudio:st-viejo|instancia antigua");
  }
});

test("DVD: la orden de otra clínica responde 404 y no toca Orthanc", async () => {
  orthanc.requests.length = 0;
  assert.equal((await get("/patients/2/imaging-orders/io-otra/dvd", "recepcion")).status, 404);
  assert.ok(!orthanc.requests.some((r) => r.includes("st-otra")));
});
