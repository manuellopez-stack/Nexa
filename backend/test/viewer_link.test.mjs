// Fase 3: enlace al visor OHIF (POST .../viewer-link) y clave pública
// (GET /viewer-tokens/public-key), contra un Orthanc simulado y la base en
// memoria de test/support/supabase-mock.mjs. No toca Orthanc ni Supabase.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import { after, before, beforeEach, test } from "node:test";

import { resetDb, users } from "./support/supabase-mock.mjs";
import { signViewerToken, verifyViewerToken } from "../viewerTokens.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const TOKENS = { recepcion: "tok-recepcion", tecnico: "tok-tecnico", otraClinica: "tok-otra" };

const STUDY_UIDS = { "st-1": "1.2.826.0.1.1", "st-2": "1.2.826.0.1.2" };

const fakeOrthanc = http.createServer((request, response) => {
  const match = request.url.match(/^\/studies\/([\w-]+)$/);
  if (request.method === "GET" && match && STUDY_UIDS[match[1]]) {
    response.writeHead(200, { "Content-Type": "application/json" });
    return response.end(JSON.stringify({ ID: match[1], MainDicomTags: { StudyInstanceUID: STUDY_UIDS[match[1]] } }));
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
      { id: "u-recepcion", role: "recepcion", clinic_id: CLINIC, full_name: "Recepción" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec" },
      { id: "u-otra", role: "medico", clinic_id: OTHER_CLINIC, full_name: "Otro" },
    ],
    patients: [
      { id: 1, name: "Paciente Uno", clinic_id: CLINIC },
      { id: 2, name: "Paciente Dos", clinic_id: OTHER_CLINIC },
    ],
    imaging_orders: [
      { id: "io-1", patient_id: 1, clinic_id: CLINIC, status: "realizado" },
      { id: "io-2", patient_id: 1, clinic_id: CLINIC, status: "realizado" },
      { id: "io-sin", patient_id: 1, clinic_id: CLINIC, status: "ordenado" },
      { id: "io-borrado", patient_id: 1, clinic_id: CLINIC, status: "realizado" },
      { id: "io-otra", patient_id: 2, clinic_id: OTHER_CLINIC, status: "realizado" },
    ],
    orthanc_studies: [
      { orthanc_study_id: "st-1", status: "linked", linked_order_id: "io-1", clinic_id: CLINIC },
      { orthanc_study_id: "st-1", status: "linked", linked_order_id: "io-2", clinic_id: CLINIC },
      { orthanc_study_id: "st-2", status: "linked", linked_order_id: "io-2", clinic_id: CLINIC },
      { orthanc_study_id: "st-unlinked", status: "unlinked", linked_order_id: null, clinic_id: CLINIC },
      // Vinculado pero ya no está en Orthanc.
      { orthanc_study_id: "st-borrado", status: "linked", linked_order_id: "io-borrado", clinic_id: CLINIC },
      { orthanc_study_id: "st-1", status: "linked", linked_order_id: "io-otra", clinic_id: OTHER_CLINIC },
    ],
  });
  users[TOKENS.recepcion] = { id: "u-recepcion", email: "recepcion@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
}

function link(patientId, orderId, as) {
  return fetch(`${BASE}/patients/${patientId}/imaging-orders/${orderId}/viewer-link`, {
    method: "POST",
    headers: as ? { Authorization: `Bearer ${TOKENS[as]}` } : {},
  });
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
  delete process.env.PACS_PUBLIC_URL;
  delete process.env.OHIF_VIEWER_ENABLED;

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
  process.env.OHIF_VIEWER_ENABLED = "true";
  process.env.PACS_PUBLIC_URL = "https://pacs.test";
});

after(() => {
  fakeOrthanc.close();
  setTimeout(() => process.exit(), 50);
});

test("clave pública: pública y verifica los tokens que firma el backend", async () => {
  const response = await fetch(`${BASE}/viewer-tokens/public-key`);
  assert.equal(response.status, 200);
  const info = await response.json();
  assert.equal(info.alg, "Ed25519");
  assert.match(info.kid, /^[\w-]{16}$/);
  assert.match(info.publicKeyPem, /^-----BEGIN PUBLIC KEY-----/);
  assert.ok(!JSON.stringify(info).includes("PRIVATE"));

  const { token } = signViewerToken({ studies: ["1.2.3"], sub: "u", clinic: CLINIC, order: "io-1" });
  const [body, signature] = token.split(".");
  const publicKey = crypto.createPublicKey(info.publicKeyPem);
  assert.equal(crypto.verify(null, Buffer.from(body), publicKey, Buffer.from(signature, "base64url")), true);
  assert.equal(JSON.parse(Buffer.from(body, "base64url")).kid, info.kid);
});

test("viewer-link: URL de OHIF con los StudyInstanceUID y un token de 2 h atado a la persona y la clínica", async () => {
  const response = await link(1, "io-2", "tecnico");
  assert.equal(response.status, 200);
  const result = await response.json();
  const url = new URL(result.url);
  assert.equal(url.origin, "https://pacs.test");
  assert.equal(url.pathname, "/ohif/viewer");
  assert.equal(url.searchParams.get("StudyInstanceUIDs"), "1.2.826.0.1.1,1.2.826.0.1.2");
  assert.equal(result.studies, 2);

  const payload = verifyViewerToken(url.searchParams.get("token"));
  assert.ok(payload, "el token debe verificar");
  assert.deepEqual(payload.studies, ["1.2.826.0.1.1", "1.2.826.0.1.2"]);
  assert.equal(payload.sub, "u-tecnico");
  assert.equal(payload.clinic, CLINIC);
  assert.equal(payload.order, "io-2");
  const ttl = payload.exp - payload.iat;
  assert.equal(ttl, 2 * 60 * 60 * 1000);
  assert.equal(new Date(result.expiresAt).getTime(), payload.exp);
});

test("viewer-link: sin PACS_PUBLIC_URL usa el origen de ORTHANC_URL", async () => {
  delete process.env.PACS_PUBLIC_URL;
  const result = await (await link(1, "io-1", "tecnico")).json();
  assert.equal(new URL(result.url).origin, new URL(process.env.ORTHANC_URL).origin);
});

test("viewer-link: recepción puede; otra clínica 404; sin sesión 401", async () => {
  assert.equal((await link(1, "io-1", "recepcion")).status, 200);
  assert.equal((await link(1, "io-1", "otraClinica")).status, 404);
  assert.equal((await link(2, "io-otra", "recepcion")).status, 404);
  assert.equal((await link(1, "io-1")).status, 401);
  // La orden existe pero es de otro paciente.
  assert.equal((await link(2, "io-1", "tecnico")).status, 404);
});

test("viewer-link: orden sin estudios en el PACS responde 409", async () => {
  assert.equal((await link(1, "io-sin", "tecnico")).status, 409);
  assert.equal((await link(1, "io-borrado", "tecnico")).status, 409);
});

test("viewer-link: apagado por defecto (sin OHIF_VIEWER_ENABLED) responde 404", async () => {
  delete process.env.OHIF_VIEWER_ENABLED;
  assert.equal((await link(1, "io-1", "tecnico")).status, 404);
  process.env.OHIF_VIEWER_ENABLED = "false";
  assert.equal((await link(1, "io-1", "tecnico")).status, 404);
  // La clave pública se publica igual.
  assert.equal((await fetch(`${BASE}/viewer-tokens/public-key`)).status, 200);
});

test("token del visor: vencido, manipulado o mal formado no verifica", () => {
  const { token } = signViewerToken({ studies: ["1.2.3"], sub: "u", clinic: CLINIC, order: "o" });
  assert.ok(verifyViewerToken(token));
  assert.equal(verifyViewerToken(token, { now: Date.now() + 2 * 60 * 60 * 1000 + 1 }), null);

  const [body, signature] = token.split(".");
  const payload = JSON.parse(Buffer.from(body, "base64url"));
  const forged = Buffer.from(JSON.stringify({ ...payload, studies: ["9.9.9"] })).toString("base64url");
  assert.equal(verifyViewerToken(`${forged}.${signature}`), null);
  for (const bad of [undefined, "", "abc", `${body}.`, `${body}.${signature}.x`]) {
    assert.equal(verifyViewerToken(bad), null);
  }
  assert.throws(() => signViewerToken({ studies: [], sub: "u" }));
});
