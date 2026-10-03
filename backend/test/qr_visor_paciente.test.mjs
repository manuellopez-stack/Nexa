// QR del visor del paciente: enlace creado al firmar, clave (4 primeros
// dígitos del RUT), bloqueo, vencido/revocado, sesión atada al enlace y rutas
// internas de estado y revocación. Contra la base en memoria de
// test/support/supabase-mock.mjs y un Orthanc simulado (solo para OHIF).
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import http from "node:http";
import { after, before, beforeEach, test } from "node:test";

import { db, resetDb, storageFiles, users } from "./support/supabase-mock.mjs";
import { readQrFromPdf } from "./support/pdf-qr.mjs";
import { buildReportPdf } from "../reportPdf.mjs";
import {
  createShareToken,
  hashShareToken,
  patientViewerBase,
  pinMatchesRut,
  rutPin,
  signShareSession,
  verifyShareSession,
} from "../shareLinks.mjs";
import { verifyViewerToken } from "../viewerTokens.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const TOKENS = {
  medico: "tok-medico",
  admin: "tok-admin",
  tecnico: "tok-tecnico",
  recepcion: "tok-recepcion",
  otraClinica: "tok-otra",
};
const DAY = 24 * 3600 * 1000;
const ago = (ms) => new Date(Date.now() - ms).toISOString();
const fromNow = (ms) => new Date(Date.now() + ms).toISOString();
const TEXT = {
  clinicalHistory: "Dolor abdominal.",
  technique: "TAC multicorte.",
  findings: "Sin lesiones focales.",
  impression: "Sin hallazgos agudos.",
};
const NOT_FOUND = "Este enlace no es válido o ya venció. Pide uno nuevo en tu centro médico.";

const fakeOrthanc = http.createServer((request, response) => {
  if (request.method === "GET" && request.url === "/studies/st-a") {
    response.writeHead(200, { "Content-Type": "application/json" });
    return response.end(JSON.stringify({ ID: "st-a", MainDicomTags: { StudyInstanceUID: "1.2.826.0.1.9" } }));
  }
  response.writeHead(404).end();
});

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      {
        id: "u-medico", role: "medico", clinic_id: CLINIC, full_name: "Dra. Ana Soto",
        rut: "11111111-1", specialty: "Radiología",
      },
      { id: "u-admin", role: "administrador", clinic_id: CLINIC, full_name: "Admin" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec" },
      { id: "u-recepcion", role: "recepcion", clinic_id: CLINIC, full_name: "Recepción" },
      {
        id: "u-otra", role: "medico", clinic_id: OTHER_CLINIC, full_name: "Dr. Otro",
        rut: "22222222-2", specialty: "Radiología",
      },
    ],
    patients: [
      { id: 1, name: "Juan Pérez", rut: "12345678-5", age: 54, clinic_id: CLINIC },
      { id: 2, name: "María Rojas", rut: "9876543-3", age: 40, clinic_id: CLINIC },
    ],
    imaging_orders: [
      {
        id: "io-a", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000201",
        requested_at: ago(DAY), performed_at: ago(DAY / 2),
      },
      {
        id: "io-b", patient_id: 2, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000202",
        requested_at: ago(DAY), performed_at: ago(DAY / 2),
      },
    ],
    imaging_order_types: [
      { order_id: "io-a", imaging_type_id: "it-tac" },
      { order_id: "io-b", imaging_type_id: "it-rx" },
    ],
    imaging_types: [
      { id: "it-tac", name: "TAC de abdomen", category: "TAC", fonasa_code: "0403014" },
      { id: "it-rx", name: "Radiografía de tórax", category: "RX", fonasa_code: "0401070" },
    ],
    imaging_files: [
      // io-a: dos series en Orthanc, desordenadas a propósito.
      { id: "f-a2-1", order_id: "io-a", orthanc_instance_id: "i-21", orthanc_series_id: "s-2", orthanc_series_number: 2, orthanc_instance_number: 1, uploaded_at: ago(3000) },
      { id: "f-a1-2", order_id: "io-a", orthanc_instance_id: "i-12", orthanc_series_id: "s-1", orthanc_series_number: 1, orthanc_instance_number: 2, uploaded_at: ago(2000) },
      { id: "f-a1-1", order_id: "io-a", orthanc_instance_id: "i-11", orthanc_series_id: "s-1", orthanc_series_number: 1, orthanc_instance_number: 1, uploaded_at: ago(1000) },
      // io-b: una imagen antigua en Storage.
      { id: "f-b-1", order_id: "io-b", dicom_path: "orders/io-b/x.dcm", png_path: "orders/io-b/x.png", uploaded_at: ago(1000) },
    ],
    orthanc_studies: [
      { orthanc_study_id: "st-a", status: "linked", linked_order_id: "io-a", clinic_id: CLINIC },
    ],
  });
  users[TOKENS.medico] = { id: "u-medico", email: "medica@test.cl" };
  users[TOKENS.admin] = { id: "u-admin", email: "admin@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.recepcion] = { id: "u-recepcion", email: "recepcion@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
}

async function api(method, path, { as, body, headers = {} } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const type = response.headers.get("content-type") ?? "";
  return {
    status: response.status,
    headers: response.headers,
    body: type.includes("json") ? await response.json() : Buffer.from(await response.arrayBuffer()),
  };
}

// Enlace con token conocido, directo en la base.
function makeLink(orderId = "io-a", overrides = {}) {
  const { token, tokenHash } = createShareToken();
  const row = {
    id: `link-${Math.random().toString(16).slice(2)}`,
    clinic_id: CLINIC,
    imaging_order_id: orderId,
    imaging_report_id: null,
    token_hash: tokenHash,
    expires_at: fromNow(300 * DAY),
    revoked_at: null,
    revoked_by: null,
    created_by: "u-medico",
    created_at: new Date().toISOString(),
    failed_attempts: 0,
    locked_until: null,
    last_access_at: null,
    access_count: 0,
    ...overrides,
  };
  (db.study_share_links ??= []).push(row);
  return { token, row };
}

const unlock = (token, pin) => api("POST", `/public/study/${token}/unlock`, { body: { pin } });
const data = (token, session) =>
  api("GET", `/public/study/${token}/data`, { headers: session ? { "X-Viewer-Session": session } : {} });

async function sign(orderId = "io-a") {
  const reportPath = `/patients/1/imaging-orders/${orderId}/report`;
  assert.equal((await api("PUT", reportPath, { as: "medico", body: TEXT })).status, 200);
  const signed = await api("POST", `${reportPath}/sign`, { as: "medico" });
  assert.equal(signed.status, 200, JSON.stringify(signed.body));
  return signed;
}

// El enlace activo de la orden, con un token conocido (en la base solo está
// el hash del que fue al PDF).
function takeOverActiveLink(orderId) {
  const link = db.study_share_links.find((row) => row.imaging_order_id === orderId && !row.revoked_at);
  const { token, tokenHash } = createShareToken();
  link.token_hash = tokenHash;
  return { token, link };
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
  process.env.PACS_PUBLIC_URL = "https://pacs.test";
  delete process.env.OHIF_VIEWER_ENABLED;
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

beforeEach(() => {
  seed();
  delete process.env.OHIF_VIEWER_ENABLED;
  delete process.env.PATIENT_VIEWER_URL;
  delete process.env.PUBLIC_BACKEND_URL;
});

after(() => {
  fakeOrthanc.close();
  setTimeout(() => process.exit(), 50);
});

test("clave: 4 primeros dígitos del RUT", () => {
  assert.equal(rutPin("12345678-5"), "1234");
  assert.equal(rutPin("12.345.678-5"), "1234");
  assert.equal(rutPin("9876543-K"), "9876");
  assert.equal(rutPin("123-4"), null);
  assert.equal(rutPin(null), null);
  assert.ok(pinMatchesRut("1234", "12345678-5"));
  assert.ok(!pinMatchesRut("1235", "12345678-5"));
  assert.ok(!pinMatchesRut("12345", "12345678-5"));
  assert.ok(!pinMatchesRut("1234", null));
});

test("sesión: atada al enlace y con vencimiento", () => {
  const now = Date.now();
  const { session } = signShareSession("link-1", { now });
  assert.ok(verifyShareSession(session, "link-1", { now }));
  assert.equal(verifyShareSession(session, "link-2", { now }), null);
  assert.equal(verifyShareSession(session, "link-1", { now: now + 2 * 3600 * 1000 + 1 }), null);
  const [body, signature] = session.split(".");
  const tampered = Buffer.from(JSON.stringify({ v: 1, link: "link-2", iat: now, exp: now + 1e9 })).toString("base64url");
  assert.equal(verifyShareSession(`${tampered}.${signature}`, "link-2", { now }), null);
  assert.equal(verifyShareSession(`${body}.`, "link-1", { now }), null);
});

test("PDF: el firmado lleva el QR y el borrador no", async () => {
  const base = {
    clinicName: "Clínica Test",
    logo: null,
    examTitle: "TAC de abdomen",
    patient: { name: "Juan Pérez", rut: "12345678-5", age: 54 },
    accessionNumber: "IMD000201",
    examDate: "1 de octubre de 2026",
    fonasaCodes: [],
    sections: TEXT,
    signature: { name: "Dra. Ana Soto", rut: "11111111-1", specialty: "Radiología", signedAtText: "hoy" },
  };
  const countImages = (pdf) => (pdf.toString("latin1").match(/\/Subtype \/Image/g) ?? []).length;
  const withQr = await buildReportPdf({ ...base, viewerUrl: "https://ver.test/ver/abc" });
  const draft = await buildReportPdf({ ...base, signature: null, draft: true, viewerUrl: "https://ver.test/ver/abc" });
  const plain = await buildReportPdf(base);
  assert.ok(countImages(withQr) > 0);
  assert.equal(countImages(draft), 0);
  assert.equal(countImages(plain), 0);
});

test("base del enlace: PATIENT_VIEWER_URL, luego PUBLIC_BACKEND_URL, luego el origen de la petición", () => {
  const origin = "http://localhost:3000";
  assert.equal(patientViewerBase({}, origin), origin);
  assert.equal(patientViewerBase({ PATIENT_VIEWER_URL: "  ", PUBLIC_BACKEND_URL: "" }, origin), origin);
  assert.equal(patientViewerBase({ PUBLIC_BACKEND_URL: "https://api.test/" }, origin), "https://api.test");
  assert.equal(
    patientViewerBase({ PATIENT_VIEWER_URL: "https://ver.test/", PUBLIC_BACKEND_URL: "https://api.test" }, origin),
    "https://ver.test",
  );
});

test("el QR del PDF firmado apunta al origen del backend si no hay PATIENT_VIEWER_URL", async () => {
  // QR que quedó en el PDF guardado del informe firmado vigente de io-a.
  const qrOfSignedPdf = () => {
    const report = db.imaging_reports.find((row) => row.imaging_order_id === "io-a" && row.status === "firmado");
    const document = db.documents.find((row) => row.id === report.document_id);
    return readQrFromPdf(storageFiles[`clinical-documents/${document.pdf_path}`]);
  };
  const activeLink = () => db.study_share_links.find((row) => !row.revoked_at);
  const newVersion = async () => {
    const path = "/patients/1/imaging-orders/io-a/report";
    assert.equal((await api("POST", `${path}/new-version`, { as: "medico" })).status, 200);
    assert.equal((await api("POST", `${path}/sign`, { as: "medico" })).status, 200);
  };

  // Sin ninguna variable: el origen por el que llegó la firma.
  await sign();
  const url = qrOfSignedPdf();
  const match = url?.match(/^http:\/\/localhost:3000\/ver\/([A-Za-z0-9_-]{43})$/);
  assert.ok(match, `QR inesperado: ${url}`);
  assert.equal(hashShareToken(match[1]), activeLink().token_hash);
  assert.ok(!url.includes("imagenda.cl"));

  // Con PUBLIC_BACKEND_URL.
  process.env.PUBLIC_BACKEND_URL = "https://api.test/";
  await newVersion();
  assert.match(qrOfSignedPdf(), /^https:\/\/api\.test\/ver\/[A-Za-z0-9_-]{43}$/);

  // PATIENT_VIEWER_URL manda sobre PUBLIC_BACKEND_URL.
  process.env.PATIENT_VIEWER_URL = "https://ver.test";
  await newVersion();
  const last = qrOfSignedPdf();
  assert.match(last, /^https:\/\/ver\.test\/ver\/[A-Za-z0-9_-]{43}$/);
  assert.equal(hashShareToken(last.split("/ver/")[1]), activeLink().token_hash);
});

test("firmar crea un enlace de 365 días; solo se guarda el hash del token", async () => {
  await sign();
  assert.equal(db.study_share_links.length, 1);
  const link = db.study_share_links[0];
  assert.equal(link.imaging_order_id, "io-a");
  assert.equal(link.clinic_id, CLINIC);
  assert.equal(link.created_by, "u-medico");
  assert.equal(link.imaging_report_id, db.imaging_reports[0].id);
  assert.match(link.token_hash, /^[0-9a-f]{64}$/);
  assert.equal(link.revoked_at ?? null, null);
  const days = (new Date(link.expires_at).getTime() - Date.now()) / DAY;
  assert.ok(days > 364.9 && days <= 365, `vence en ${days} días`);
});

test("firmar una nueva versión revoca el enlace anterior", async () => {
  await sign();
  const { token: oldToken } = takeOverActiveLink("io-a");
  const first = db.study_share_links[0];

  assert.equal((await api("POST", "/patients/1/imaging-orders/io-a/report/new-version", { as: "medico" })).status, 200);
  const signed = await api("POST", "/patients/1/imaging-orders/io-a/report/sign", { as: "medico" });
  assert.equal(signed.status, 200);

  assert.equal(db.study_share_links.length, 2);
  assert.ok(first.revoked_at);
  assert.equal(first.revoked_by, "u-medico");
  const second = db.study_share_links.find((row) => row !== first);
  assert.equal(second.revoked_at ?? null, null);
  const v2 = db.imaging_reports.find((row) => row.version === 2);
  assert.equal(second.imaging_report_id, v2.id);

  const old = await unlock(oldToken, "1234");
  assert.equal(old.status, 404);
  assert.equal(old.body.error, NOT_FOUND);
});

test("clave correcta entrega sesión; incorrecta responde 401 con intentos restantes", async () => {
  const { token, row } = makeLink();
  const wrong = await unlock(token, "9999");
  assert.equal(wrong.status, 401);
  assert.equal(wrong.body.code, "wrong_pin");
  assert.equal(wrong.body.remainingAttempts, 4);
  assert.equal(row.failed_attempts, 1);
  assert.equal(wrong.body.session, undefined);

  const bad = await unlock(token, "12a4");
  assert.equal(bad.status, 400);
  assert.equal(row.failed_attempts, 1); // mal formada no cuenta

  const ok = await unlock(token, "1234");
  assert.equal(ok.status, 200);
  assert.ok(verifyShareSession(ok.body.session, row.id));
  assert.equal(row.failed_attempts, 0);
  assert.equal(ok.headers.get("cache-control"), "no-store");
  assert.equal(ok.headers.get("referrer-policy"), "no-referrer");
  assert.match(ok.headers.get("x-robots-tag"), /noindex/);

  const log = db.study_share_access_log.map((entry) => [entry.action, entry.ok, entry.link_id]);
  assert.deepEqual(log, [
    ["unlock_fail", false, row.id],
    ["unlock_ok", true, row.id],
  ]);
});

test("5 claves erradas seguidas bloquean el enlace 15 minutos", async () => {
  const { token, row } = makeLink();
  for (let i = 1; i <= 4; i++) assert.equal((await unlock(token, "0000")).status, 401, `intento ${i}`);
  const fifth = await unlock(token, "0000");
  assert.equal(fifth.status, 423);
  assert.equal(fifth.body.code, "locked");
  const minutes = (new Date(row.locked_until).getTime() - Date.now()) / 60000;
  assert.ok(minutes > 14.9 && minutes <= 15, `bloqueado ${minutes} min`);

  // Bloqueado: ni la clave correcta entra.
  const locked = await unlock(token, "1234");
  assert.equal(locked.status, 423);

  // Pasado el bloqueo, la clave correcta funciona.
  row.locked_until = ago(1000);
  assert.equal((await unlock(token, "1234")).status, 200);
});

test("vencido, revocado o inexistente: el mismo 404", async () => {
  const { token: expired } = makeLink("io-a", { expires_at: ago(1000) });
  const { token: revoked } = makeLink("io-a", { revoked_at: ago(1000) });
  const { token: unknown } = createShareToken();
  for (const token of [expired, revoked, unknown, "corto"]) {
    const response = await unlock(token, "1234");
    assert.equal(response.status, 404, token);
    assert.equal(response.body.error, NOT_FOUND);
  }
  // Una sesión emitida antes de revocar tampoco sirve.
  const { token, row } = makeLink();
  const { session } = signShareSession(row.id);
  row.revoked_at = new Date().toISOString();
  assert.equal((await data(token, session)).status, 404);
});

test("/data sin sesión (o con una inválida) responde 401", async () => {
  const { token, row } = makeLink();
  assert.equal((await data(token)).status, 401);
  assert.equal((await data(token, "basura.firma")).status, 401);
  const expired = signShareSession(row.id, { now: Date.now() - 3 * 3600 * 1000 }).session;
  assert.equal((await data(token, expired)).status, 401);
  assert.equal(row.access_count, 0);
});

test("/data entrega solo el examen de ESA orden, sin datos de la ficha", async () => {
  process.env.OHIF_VIEWER_ENABLED = "true";
  await sign();
  const { token, link } = takeOverActiveLink("io-a");
  const { session } = (await unlock(token, "1234")).body;

  const response = await data(token, session);
  assert.equal(response.status, 200, JSON.stringify(response.body));
  const body = response.body;
  assert.equal(body.clinic.name, "Clínica Test");
  assert.equal(body.clinic.logoUrl, null);
  assert.equal(body.exam.title, "TAC de abdomen");
  assert.ok(body.exam.date);

  // Mismo orden que GET .../images: serie 1 (instancias 1, 2) y serie 2.
  assert.deepEqual(body.series.map((s) => [s.title, s.count]), [["Serie 1", 2], ["Serie 2", 1]]);
  assert.equal(body.totalImages, 3);
  const firstImage = body.series[0].images[0];
  assert.match(firstImage.preview, /\/imaging-files\/f-a1-1\/preview\?t=/);
  assert.match(firstImage.dicom, /\/imaging-files\/f-a1-1\/dicom\?t=/);
  assert.match(body.series[0].images[1].preview, /f-a1-2/);

  const ohif = new URL(body.ohifUrl);
  assert.equal(ohif.origin, "https://pacs.test");
  const viewerToken = verifyViewerToken(ohif.searchParams.get("token"));
  assert.equal(viewerToken.sub, `share:${link.id}`);
  assert.deepEqual(viewerToken.studies, ["1.2.826.0.1.9"]);
  assert.equal(viewerToken.order, "io-a");

  // Nada de la ficha: ni RUT, ni nombre, ni otras órdenes.
  const text = JSON.stringify(body);
  for (const forbidden of ["12345678", "Juan", "io-b", "f-b-1", "María"]) {
    assert.ok(!text.includes(forbidden), `la respuesta incluye ${forbidden}`);
  }

  assert.equal(link.access_count, 1);
  assert.ok(link.last_access_at);
  assert.ok(db.study_share_access_log.some((entry) => entry.action === "view" && entry.link_id === link.id));

  // El informe firmado se descarga con la sesión (?s=).
  const pdf = await api("GET", new URL(body.reportUrl).pathname + new URL(body.reportUrl).search);
  assert.equal(pdf.status, 200);
  assert.equal(pdf.body.subarray(0, 5).toString(), "%PDF-");
  assert.equal(pdf.headers.get("cache-control"), "no-store");
  assert.equal((await api("GET", `/public/study/${token}/report.pdf`)).status, 401);
});

test("un token no da acceso a otra orden", async () => {
  const { token: tokenA, row: linkA } = makeLink("io-a");
  const { token: tokenB } = makeLink("io-b");

  // El PIN de la paciente de io-a no abre io-b.
  assert.equal((await unlock(tokenB, "1234")).status, 401);
  // La sesión de A no sirve en B.
  const { session } = (await unlock(tokenA, "1234")).body;
  assert.equal((await data(tokenB, session)).status, 401);
  assert.equal((await api("GET", `/public/study/${tokenB}/report.pdf?s=${session}`)).status, 401);

  // Con su propia clave, B solo ve lo suyo.
  const sessionB = (await unlock(tokenB, "9876")).body.session;
  const bodyB = (await data(tokenB, sessionB)).body;
  assert.equal(bodyB.totalImages, 1);
  assert.match(bodyB.series[0].images[0].preview, /orders\/io-b\/x\.png/);
  assert.ok(!JSON.stringify(bodyB).includes("f-a1"));

  // Un enlace cuya orden ya no es de esa clínica no muestra nada.
  linkA.clinic_id = OTHER_CLINIC;
  assert.equal((await data(tokenA, session)).status, 404);
});

test("GET /ver/:token sirve la página sin datos y con headers privados", async () => {
  const { token } = makeLink();
  const response = await fetch(`${BASE}/ver/${token}`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/html/);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("referrer-policy"), "no-referrer");
  assert.match(response.headers.get("x-robots-tag"), /noindex/);
  const html = await response.text();
  assert.match(html, /<meta name="robots" content="noindex/);
  assert.ok(!html.includes("Clínica Test"));
});

test("rutas internas: estado y revocación, solo médico y administrador de la clínica", async () => {
  const path = "/patients/1/imaging-orders/io-a/share-link";
  assert.deepEqual((await api("GET", path, { as: "medico" })).body, { link: null });

  await sign();
  const { token, link } = takeOverActiveLink("io-a");
  link.access_count = 3;
  link.last_access_at = ago(1000);

  const state = await api("GET", path, { as: "admin" });
  assert.equal(state.status, 200);
  assert.equal(state.body.link.status, "activo");
  assert.equal(state.body.link.accessCount, 3);
  assert.equal(state.body.link.lastAccessAt, link.last_access_at);
  assert.equal(state.body.link.expiresAt, link.expires_at);
  assert.ok(!JSON.stringify(state.body).includes(link.token_hash));

  for (const as of ["tecnico", "recepcion"]) {
    assert.equal((await api("GET", path, { as })).status, 403, as);
    assert.equal((await api("POST", `${path}/revoke`, { as })).status, 403, as);
  }
  assert.equal((await api("GET", path, { as: "otraClinica" })).status, 404);
  assert.equal((await api("POST", `${path}/revoke`, { as: "otraClinica" })).status, 404);
  assert.equal(link.revoked_at ?? null, null);

  const revoked = await api("POST", `${path}/revoke`, { as: "admin" });
  assert.equal(revoked.status, 200);
  assert.equal(revoked.body.link.status, "revocado");
  assert.equal(link.revoked_by, "u-admin");
  assert.equal((await unlock(token, "1234")).status, 404);

  link.revoked_at = null;
  link.expires_at = ago(1000);
  assert.equal((await api("GET", path, { as: "medico" })).body.link.status, "vencido");
});
