// pacs-gate: portero del visor OHIF en el droplet (Fase 3). Node puro, sin
// dependencias. Caddy le pregunta por cada petición a /ohif/* y por cada
// petición con "Authorization: Bearer" (forward_auth, GET /check con
// X-Forwarded-Method y X-Forwarded-Uri). Si responde 2xx, Caddy reenvía a
// Orthanc reemplazando el header por el Basic de admin; si no, su respuesta
// vuelve al navegador. Escucha solo en 127.0.0.1:9100 (lo publica así el
// compose).
//
// Reglas:
//   /ohif, /ohif/*  -> solo archivos estáticos del visor (GET/HEAD): las rutas
//                     de la app (/ohif/, /ohif/viewer) y archivos con extensión
//                     de la lista. Cualquier otra ruta bajo /ohif -> 403. No
//                     pide token (el bundle no tiene datos).
//   resto           -> token Ed25519 del backend (viewerTokens.mjs) válido y
//                     vigente (si no, 401), solo GET, y solo DICOMweb de los
//                     StudyInstanceUID del token:
//                       /dicom-web/studies?StudyInstanceUID=<uid>
//                       /dicom-web/studies/<uid>[/metadata|/series|/instances|...]
//                       /dicom-web/studies/<uid>/series/<serie>/...
//                       /dicom-web/studies/<uid>/series/<serie>/instances/<sop>/...
//                     La serie y la instancia deben pertenecer a ese estudio:
//                     se comprueba contra Orthanc (con caché por estudio), así
//                     un UID permitido en la ruta no abre series de otro.
//                     Todo lo demás -> 403.
//
// Variables: PORT (9100), GATE_ORTHANC_URL (http://orthanc:8042),
// GATE_ORTHANC_USER (orthanc), ORTHANC_PASSWORD, KEY_FILE (clave pública,
// {kid, publicKeyPem}), PUBLIC_KEY_URL (opcional: GET /viewer-tokens/public-key
// del backend, se relee cada 10 min).
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import { pathToFileURL } from "node:url";

const UID = "[0-9]+(?:\\.[0-9]+)*";
const STATIC_APP_ROUTES = new Set(["/ohif", "/ohif/", "/ohif/viewer", "/ohif/viewer/"]);
const STATIC_FILE_RE =
  /^\/ohif\/[A-Za-z0-9_.\-/]+\.(?:js|mjs|css|html|json|wasm|woff2?|ttf|otf|eot|png|jpe?g|gif|svg|ico|webp|map|txt|webmanifest)$/;
const STUDY_LEVEL_SUFFIXES = new Set(["", "/metadata", "/series", "/instances", "/rendered", "/thumbnail"]);
const SERIES_RE = new RegExp(`^/series/(${UID})(/metadata|/instances|/rendered|/thumbnail)?$`);
const INSTANCE_RE = new RegExp(
  `^/series/(${UID})/instances/(${UID})(/metadata|/rendered|/thumbnail|/frames/[0-9,]+(?:/rendered)?|/bulk/[A-Za-z0-9_.\\-/]+)?$`,
);
const STUDY_RE = new RegExp(`^/dicom-web/studies/(${UID})(/.*)?$`);

// ----------------------------------------------------------------------------
// Tokens
// ----------------------------------------------------------------------------

export function createKeyring() {
  const keys = new Map(); // kid -> KeyObject
  return {
    add({ kid, publicKeyPem }) {
      if (typeof kid !== "string" || typeof publicKeyPem !== "string") throw new Error("clave pública inválida");
      const key = crypto.createPublicKey(publicKeyPem);
      if (key.asymmetricKeyType !== "ed25519") throw new Error("la clave pública no es Ed25519");
      const isNew = !keys.has(kid);
      keys.set(kid, key);
      return isNew;
    },
    get: (kid) => keys.get(kid),
    get size() {
      return keys.size;
    },
  };
}

export function verifyToken(token, keyring, now = Date.now()) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
  const [body, signature] = parts;
  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  const key = keyring.get(payload?.kid);
  if (!key) return null;
  let valid = false;
  try {
    valid = crypto.verify(null, Buffer.from(body), key, Buffer.from(signature, "base64url"));
  } catch {
    return null;
  }
  if (!valid) return null;
  if (typeof payload.exp !== "number" || payload.exp <= now) return null;
  if (!Array.isArray(payload.studies) || payload.studies.length === 0) return null;
  return payload;
}

// ----------------------------------------------------------------------------
// Pertenencia serie/instancia -> estudio (consulta a Orthanc, con caché)
// ----------------------------------------------------------------------------

export function createStudyIndex({ orthancUrl, authHeader, ttlMs = 5 * 60 * 1000, refreshAfterMs = 30 * 1000, now = Date.now }) {
  const cache = new Map(); // studyUid -> { at, series: Map<seriesUid, Set<sopUid>> } | Promise

  async function orthanc(path, init = {}) {
    const response = await fetch(`${orthancUrl}${path}`, {
      ...init,
      headers: { Authorization: authHeader, ...(init.headers ?? {}) },
      signal: AbortSignal.timeout(15000),
    });
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`Orthanc respondió ${response.status} en ${path}`);
    return response.json();
  }

  async function load(studyUid) {
    const found = (await orthanc("/tools/lookup", { method: "POST", body: studyUid })) ?? [];
    const study = found.find((item) => item.Type === "Study");
    const series = new Map();
    if (study) {
      const [seriesList, instances] = await Promise.all([
        orthanc(`/studies/${study.ID}/series`),
        orthanc(`/studies/${study.ID}/instances`),
      ]);
      const uidById = new Map();
      for (const serie of seriesList ?? []) {
        const uid = serie.MainDicomTags?.SeriesInstanceUID;
        if (uid) {
          uidById.set(serie.ID, uid);
          series.set(uid, new Set());
        }
      }
      for (const instance of instances ?? []) {
        const seriesUid = uidById.get(instance.ParentSeries);
        const sop = instance.MainDicomTags?.SOPInstanceUID;
        if (seriesUid && sop) series.get(seriesUid).add(sop);
      }
    }
    return { at: now(), series };
  }

  async function get(studyUid, { fresh = false } = {}) {
    const entry = cache.get(studyUid);
    if (entry instanceof Promise) return entry;
    if (entry && !fresh && now() - entry.at < ttlMs) return entry;
    if (entry && fresh && now() - entry.at < refreshAfterMs) return entry;
    const pending = load(studyUid).then(
      (value) => {
        cache.set(studyUid, value);
        return value;
      },
      (error) => {
        cache.delete(studyUid);
        throw error;
      },
    );
    cache.set(studyUid, pending);
    return pending;
  }

  // ¿La serie (y la instancia, si viene) pertenecen al estudio? Si no aparece,
  // se relee una vez (una instancia recién llegada) antes de negar.
  return async function belongs(studyUid, seriesUid, sopUid = null) {
    const check = (entry) => {
      const sops = entry.series.get(seriesUid);
      return Boolean(sops) && (sopUid === null || sops.has(sopUid));
    };
    if (check(await get(studyUid))) return true;
    return check(await get(studyUid, { fresh: true }));
  };
}

// ----------------------------------------------------------------------------
// Decisión
// ----------------------------------------------------------------------------

function isStaticAllowed(pathname) {
  if (pathname.includes("..") || pathname.includes("//")) return false;
  if (/(^|\/)dicom-json(\/|$)/i.test(pathname)) return false;
  return STATIC_APP_ROUTES.has(pathname) || STATIC_FILE_RE.test(pathname);
}

// Devuelve { status, reason }. status 204 = permitido.
export async function decide({ method, uri, authorization }, { keyring, belongs, now = Date.now() }) {
  if (typeof uri !== "string" || !uri.startsWith("/")) return { status: 403, reason: "sin URI" };
  const queryIndex = uri.indexOf("?");
  const pathname = queryIndex >= 0 ? uri.slice(0, queryIndex) : uri;
  const query = new URLSearchParams(queryIndex >= 0 ? uri.slice(queryIndex + 1) : "");
  // Sin codificaciones en la ruta: nada de %2e%2e ni similares.
  if (pathname.includes("%") || pathname.includes("\\")) return { status: 403, reason: "ruta codificada" };

  if (pathname === "/ohif" || pathname.startsWith("/ohif/")) {
    if (method !== "GET" && method !== "HEAD") return { status: 403, reason: "método no permitido en /ohif" };
    return isStaticAllowed(pathname) ? { status: 204, reason: "estático" } : { status: 403, reason: "ruta de /ohif no estática" };
  }

  const match = /^Bearer\s+(\S+)$/.exec(authorization ?? "");
  const token = match ? verifyToken(match[1], keyring, now) : null;
  if (!token) return { status: 401, reason: "token inválido o vencido" };
  if (method !== "GET") return { status: 403, reason: "solo GET" };
  const allowed = new Set(token.studies);

  if (pathname === "/dicom-web/studies") {
    const requested = [];
    for (const [key, value] of query) {
      if (key.toLowerCase() === "studyinstanceuid" || key.toLowerCase() === "0020000d") {
        requested.push(...value.split(",").map((v) => v.trim()).filter(Boolean));
      }
    }
    if (requested.length === 0) return { status: 403, reason: "búsqueda sin StudyInstanceUID" };
    return requested.every((uid) => allowed.has(uid))
      ? { status: 204, reason: "qido del estudio" }
      : { status: 403, reason: "estudio fuera del token" };
  }

  const study = STUDY_RE.exec(pathname);
  if (!study) return { status: 403, reason: "ruta no permitida" };
  const [, studyUid, rest = ""] = study;
  if (!allowed.has(studyUid)) return { status: 403, reason: "estudio fuera del token" };
  if (STUDY_LEVEL_SUFFIXES.has(rest)) return { status: 204, reason: "estudio" };

  const instance = INSTANCE_RE.exec(rest);
  const series = instance ? null : SERIES_RE.exec(rest);
  if (!instance && !series) return { status: 403, reason: "ruta no permitida" };
  const seriesUid = (instance ?? series)[1];
  const sopUid = instance ? instance[2] : null;
  try {
    return (await belongs(studyUid, seriesUid, sopUid))
      ? { status: 204, reason: instance ? "instancia del estudio" : "serie del estudio" }
      : { status: 403, reason: "serie o instancia de otro estudio" };
  } catch (error) {
    return { status: 503, reason: `no se pudo consultar Orthanc: ${error.message}` };
  }
}

// ----------------------------------------------------------------------------
// Servidor
// ----------------------------------------------------------------------------

export function createGateServer({ keyring, belongs, log = () => {} }) {
  return http.createServer(async (request, response) => {
    const path = request.url.split("?")[0];
    if (path === "/health") {
      response.writeHead(keyring.size > 0 ? 200 : 503, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ ok: keyring.size > 0, keys: keyring.size }));
    }
    if (path !== "/check") return response.writeHead(404).end();

    const method = String(request.headers["x-forwarded-method"] ?? "").toUpperCase();
    const uri = request.headers["x-forwarded-uri"];
    const { status, reason } = await decide(
      { method, uri, authorization: request.headers.authorization },
      { keyring, belongs },
    );
    if (status !== 204) log(`${status} ${method} ${String(uri ?? "").split("?")[0]} (${reason})`);
    if (status === 204) return response.writeHead(204).end();
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify({ error: status === 401 ? "El enlace del visor no es válido o ya venció." : "Acceso no permitido." }));
  });
}

async function main() {
  const log = (line) => console.log(`[pacs-gate] ${new Date().toISOString()} ${line}`);
  const port = Number(process.env.PORT || 9100);
  const orthancUrl = (process.env.GATE_ORTHANC_URL || "http://orthanc:8042").replace(/\/+$/, "");
  const user = process.env.GATE_ORTHANC_USER || "orthanc";
  const password = process.env.ORTHANC_PASSWORD;
  if (!password) throw new Error("Falta ORTHANC_PASSWORD");
  const keyFile = process.env.KEY_FILE || "/data/viewer-public-key.json";
  const publicKeyUrl = process.env.PUBLIC_KEY_URL || "";

  const keyring = createKeyring();
  if (fs.existsSync(keyFile)) {
    const info = JSON.parse(fs.readFileSync(keyFile, "utf8"));
    keyring.add(info);
    log(`clave pública cargada de ${keyFile} (kid ${info.kid})`);
  }

  async function refreshKey() {
    if (!publicKeyUrl) return;
    try {
      const response = await fetch(publicKeyUrl, { signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const info = await response.json();
      if (keyring.add(info)) {
        fs.writeFileSync(keyFile, JSON.stringify({ kid: info.kid, publicKeyPem: info.publicKeyPem }));
        log(`clave pública nueva desde el backend (kid ${info.kid})`);
      }
    } catch (error) {
      log(`no se pudo leer la clave pública del backend: ${error.message}`);
    }
  }
  await refreshKey();
  setInterval(refreshKey, 10 * 60 * 1000).unref();

  const belongs = createStudyIndex({
    orthancUrl,
    authHeader: "Basic " + Buffer.from(`${user}:${password}`).toString("base64"),
  });
  createGateServer({ keyring, belongs, log }).listen(port, "0.0.0.0", () => log(`escuchando en :${port}`));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[pacs-gate] ERROR: ${error.message}`);
    process.exit(1);
  });
}
