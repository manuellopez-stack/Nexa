// pacs-gate contra un Orthanc simulado (servidor HTTP local). Incluye un
// token firmado por backend/viewerTokens.mjs, para asegurar que ambos lados
// hablan el mismo formato.

import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import { after, before, beforeEach, test } from "node:test";

import { createGateServer, createKeyring, createStudyIndex, decide, verifyToken } from "../server.mjs";

const STUDY_A = "1.2.840.1";
const STUDY_B = "1.2.840.2";
const SERIES_A = "1.2.840.1.10";
const SERIES_B = "1.2.840.2.10";
const SOP_A1 = "1.2.840.1.10.1";
const SOP_B1 = "1.2.840.2.10.1";

// Orthanc simulado: dos estudios, una serie y una instancia cada uno.
const orthanc = {
  studies: {
    [STUDY_A]: { id: "oa", series: { [SERIES_A]: { id: "sa", sops: [SOP_A1] } } },
    [STUDY_B]: { id: "ob", series: { [SERIES_B]: { id: "sb", sops: [SOP_B1] } } },
  },
  calls: [],
  down: false,
};

const fakeOrthanc = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (c) => chunks.push(c));
  request.on("end", () => {
    orthanc.calls.push(`${request.method} ${request.url}`);
    if (orthanc.down) return response.writeHead(500).end();
    if (request.headers.authorization !== `Basic ${Buffer.from("orthanc:secreto").toString("base64")}`) {
      return response.writeHead(401).end();
    }
    const json = (value) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(value));
    };
    const byId = Object.values(orthanc.studies).find((s) => request.url.startsWith(`/studies/${s.id}/`));
    if (request.method === "POST" && request.url === "/tools/lookup") {
      const study = orthanc.studies[Buffer.concat(chunks).toString().trim()];
      return json(study ? [{ Type: "Study", ID: study.id }] : []);
    }
    if (request.method === "GET" && byId && request.url.endsWith("/series")) {
      return json(Object.entries(byId.series).map(([uid, s]) => ({ ID: s.id, MainDicomTags: { SeriesInstanceUID: uid } })));
    }
    if (request.method === "GET" && byId && request.url.endsWith("/instances")) {
      return json(
        Object.values(byId.series).flatMap((s) =>
          s.sops.map((sop) => ({ ParentSeries: s.id, MainDicomTags: { SOPInstanceUID: sop } })),
        ),
      );
    }
    response.writeHead(404).end();
  });
});

const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
const KID = "kid-de-prueba-01";
const keyring = createKeyring();
keyring.add({ kid: KID, publicKeyPem: publicKey.export({ format: "pem", type: "spki" }) });

function sign(payload, key = privateKey) {
  const body = Buffer.from(JSON.stringify({ v: 1, kid: KID, sub: "u", clinic: "c", order: "o", iat: Date.now(), exp: Date.now() + 3600e3, ...payload })).toString("base64url");
  return `${body}.${crypto.sign(null, Buffer.from(body), key).toString("base64url")}`;
}
const tokenA = () => sign({ studies: [STUDY_A] });

let belongs;
let gate;
let gateUrl;

before(async () => {
  await new Promise((resolve) => fakeOrthanc.listen(0, resolve));
  gate = createGateServer({ keyring, belongs: (...args) => belongs(...args) });
  await new Promise((resolve) => gate.listen(0, "127.0.0.1", resolve));
  gateUrl = `http://127.0.0.1:${gate.address().port}`;
});

beforeEach(() => {
  orthanc.calls.length = 0;
  orthanc.down = false;
  belongs = createStudyIndex({
    orthancUrl: `http://127.0.0.1:${fakeOrthanc.address().port}`,
    authHeader: `Basic ${Buffer.from("orthanc:secreto").toString("base64")}`,
  });
});

after(() => {
  fakeOrthanc.close();
  gate.close();
});

const check = (uri, { method = "GET", token = tokenA() } = {}) =>
  decide({ method, uri, authorization: token === null ? undefined : `Bearer ${token}` }, { keyring, belongs });
const status = async (uri, options) => (await check(uri, options)).status;

// ---------------------------------------------------------------------------
// /ohif: solo estáticos
// ---------------------------------------------------------------------------

test("/ohif: rutas de la app y archivos estáticos del bundle, sin token", async () => {
  for (const uri of [
    "/ohif",
    "/ohif/",
    "/ohif/viewer",
    `/ohif/viewer?StudyInstanceUIDs=${STUDY_A}&token=x`,
    "/ohif/app-config.js",
    "/ohif/index.html",
    "/ohif/app.bundle.5f3c2a.js",
    "/ohif/assets/styles.css",
    "/ohif/manifest.json",
    "/ohif/dicom-image-loader/decodeImageFrameWorker.js",
    "/ohif/codec.wasm",
    "/ohif/assets/fonts/inter.woff2",
    "/ohif/assets/logo.svg",
    "/ohif/favicon.ico",
  ]) {
    assert.equal(await status(uri, { token: null }), 204, uri);
  }
  assert.equal(await status("/ohif/app.js", { method: "HEAD", token: null }), 204);
});

test("/ohif: rutas de datos o desconocidas -> 403 (aunque traigan token)", async () => {
  for (const uri of [
    "/ohif/dicom-json/1.2.3",
    "/ohif/dicom-json/1.2.3.json",
    "/ohif/api/studies",
    "/ohif/viewer/extra",
    "/ohif/segmentation",
    "/ohif/something",
    "/ohif/script.php",
    "/ohif/../system",
    "/ohif/%2e%2e/system",
    "/ohif//etc/passwd.js",
    "/ohif/..%2fsystem.js",
  ]) {
    assert.equal(await status(uri, { token: null }), 403, uri);
    assert.equal(await status(uri), 403, `${uri} con token`);
  }
  assert.equal(await status("/ohif/app.js", { method: "POST", token: null }), 403);
  // La ruta dicom-json del plugin OHIF (fuera de /ohif) tampoco.
  assert.equal(await status("/studies/oa/ohif-dicom-json"), 403);
});

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

test("token: falta, manipulado, vencido, otra clave o kid desconocido -> 401", async () => {
  const uri = `/dicom-web/studies/${STUDY_A}/series`;
  assert.equal(await status(uri, { token: null }), 401);
  assert.equal(await status(uri, { token: "basura" }), 401);

  const [body, signature] = tokenA().split(".");
  const forged = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(body, "base64url")), studies: [STUDY_B] })).toString("base64url");
  assert.equal(await status(`/dicom-web/studies/${STUDY_B}/series`, { token: `${forged}.${signature}` }), 401);

  assert.equal(await status(uri, { token: sign({ studies: [STUDY_A], exp: Date.now() - 1 }) }), 401);
  const other = crypto.generateKeyPairSync("ed25519").privateKey;
  assert.equal(await status(uri, { token: sign({ studies: [STUDY_A] }, other) }), 401);
  const unknownKid = sign({ studies: [STUDY_A], kid: "otro-kid" });
  assert.equal(await status(uri, { token: unknownKid }), 401);
  // Basic (backend/cron) no es asunto del portero: Caddy no se lo manda.
  const basic = await decide({ method: "GET", uri, authorization: "Basic eDp5" }, { keyring, belongs });
  assert.equal(basic.status, 401);
});

test("token firmado por backend/viewerTokens.mjs se acepta con su clave pública", async () => {
  process.env.SUPABASE_SERVICE_ROLE_KEY = "clave-de-prueba";
  const { signViewerToken, viewerPublicKeyInfo } = await import("../../backend/viewerTokens.mjs");
  const backendKeys = createKeyring();
  backendKeys.add(viewerPublicKeyInfo());
  const { token } = signViewerToken({ studies: [STUDY_A], sub: "u", clinic: "c", order: "o" });
  assert.ok(verifyToken(token, backendKeys));
  const result = await decide(
    { method: "GET", uri: `/dicom-web/studies/${STUDY_A}/series`, authorization: `Bearer ${token}` },
    { keyring: backendKeys, belongs },
  );
  assert.equal(result.status, 204);
  assert.equal(verifyToken(token, keyring), null, "con otra clave no verifica");
});

// ---------------------------------------------------------------------------
// DICOMweb del estudio del token
// ---------------------------------------------------------------------------

test("QIDO: solo con StudyInstanceUID del token", async () => {
  assert.equal(await status(`/dicom-web/studies?StudyInstanceUID=${STUDY_A}&includefield=all`), 204);
  assert.equal(await status(`/dicom-web/studies?0020000D=${STUDY_A}`), 204);
  assert.equal(await status(`/dicom-web/studies?StudyInstanceUID=${STUDY_B}`), 403);
  assert.equal(await status(`/dicom-web/studies?StudyInstanceUID=${STUDY_A},${STUDY_B}`), 403);
  assert.equal(await status("/dicom-web/studies"), 403);
  assert.equal(await status("/dicom-web/studies?PatientName=*"), 403);
});

test("rutas del estudio del token: sí; de otro estudio: 403", async () => {
  for (const suffix of ["", "/metadata", "/series", "/instances"]) {
    assert.equal(await status(`/dicom-web/studies/${STUDY_A}${suffix}`), 204, suffix);
    assert.equal(await status(`/dicom-web/studies/${STUDY_B}${suffix}`), 403, `otro ${suffix}`);
  }
  assert.equal(await status(`/dicom-web/studies/${STUDY_A}/series?Modality=CT`), 204);
  assert.equal(await status(`/dicom-web/studies/${STUDY_A}/algo-raro`), 403);
});

test("serie e instancia: deben pertenecer al estudio (cruce de UIDs -> 403)", async () => {
  const base = `/dicom-web/studies/${STUDY_A}`;
  assert.equal(await status(`${base}/series/${SERIES_A}/metadata`), 204);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances`), 204);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_A1}/frames/1`), 204);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_A1}/frames/1,2`), 204);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_A1}/bulk/7fe00010`), 204);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_A1}`), 204);

  // Cruces: estudio permitido en la ruta, serie/instancia de otro estudio.
  assert.equal(await status(`${base}/series/${SERIES_B}/metadata`), 403);
  assert.equal(await status(`${base}/series/${SERIES_B}/instances/${SOP_B1}/frames/1`), 403);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_B1}/frames/1`), 403);
  assert.equal(await status(`${base}/series/${SERIES_A}/instances/${SOP_A1}/otra-cosa`), 403);
});

test("pertenencia con caché: un estudio se consulta una vez; una instancia nueva se relee", async () => {
  const base = `/dicom-web/studies/${STUDY_A}/series/${SERIES_A}`;
  for (let i = 0; i < 20; i++) assert.equal(await status(`${base}/instances/${SOP_A1}/frames/1`), 204);
  assert.equal(orthanc.calls.filter((c) => c.startsWith("POST /tools/lookup")).length, 1);

  // Llega una instancia nueva: el primer pedido la encuentra releyendo.
  orthanc.studies[STUDY_A].series[SERIES_A].sops.push("1.2.840.1.10.2");
  const index = createStudyIndex({
    orthancUrl: `http://127.0.0.1:${fakeOrthanc.address().port}`,
    authHeader: `Basic ${Buffer.from("orthanc:secreto").toString("base64")}`,
    refreshAfterMs: 0,
  });
  assert.equal(await index(STUDY_A, SERIES_A, SOP_A1), true);
  orthanc.studies[STUDY_A].series[SERIES_A].sops.push("1.2.840.1.10.3");
  assert.equal(await index(STUDY_A, SERIES_A, "1.2.840.1.10.3"), true);
  assert.equal(await index(STUDY_A, SERIES_A, "9.9.9"), false);
});

test("Orthanc caído: se niega (503), nunca se deja pasar", async () => {
  orthanc.down = true;
  const result = await check(`/dicom-web/studies/${STUDY_A}/series/${SERIES_A}/metadata`);
  assert.equal(result.status, 503);
});

test("fuera de DICOMweb del estudio: todo 403; solo GET", async () => {
  for (const uri of ["/system", "/instances", "/patients", "/changes", "/tools/find", "/studies/oa", "/dicom-web/series", "/dicom-web/instances", `/dicom-web/studies/${STUDY_A}/../../system`]) {
    assert.equal(await status(uri), 403, uri);
  }
  assert.equal(await status("/tools/find", { method: "POST" }), 403);
  assert.equal(await status(`/dicom-web/studies/${STUDY_A}/series`, { method: "POST" }), 403);
  assert.equal(await status(`/dicom-web/studies/${STUDY_A}`, { method: "DELETE" }), 403);
  assert.equal(await status(`/dicom-web/studies/${STUDY_A}%2F..%2Fsystem`), 403);
});

test("servidor HTTP: /check responde 204/401/403 según los headers de Caddy; /health", async () => {
  const call = (headers) => fetch(`${gateUrl}/check`, { headers });
  const ok = await call({ "X-Forwarded-Method": "GET", "X-Forwarded-Uri": `/dicom-web/studies/${STUDY_A}/series`, Authorization: `Bearer ${tokenA()}` });
  assert.equal(ok.status, 204);
  const noToken = await call({ "X-Forwarded-Method": "GET", "X-Forwarded-Uri": `/dicom-web/studies/${STUDY_A}/series` });
  assert.equal(noToken.status, 401);
  assert.match((await noToken.json()).error, /no es válido o ya venció/);
  const staticOk = await call({ "X-Forwarded-Method": "GET", "X-Forwarded-Uri": "/ohif/app.js" });
  assert.equal(staticOk.status, 204);
  const dataUnderOhif = await call({ "X-Forwarded-Method": "GET", "X-Forwarded-Uri": "/ohif/dicom-json/x" });
  assert.equal(dataUnderOhif.status, 403);
  assert.equal((await call({})).status, 403);

  const health = await fetch(`${gateUrl}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, keys: 1 });
  assert.equal((await fetch(`${gateUrl}/otra`)).status, 404);
});
