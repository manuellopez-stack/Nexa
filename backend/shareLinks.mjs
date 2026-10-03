// Enlace del QR del informe firmado para que el paciente vea sus imágenes
// (rutas /ver/:token y /public/study/:token/*, server.mjs).
//
// - Token del enlace: 32 bytes aleatorios en base64url. Va en la URL del QR;
//   en study_share_links solo se guarda su SHA-256 (token_hash).
// - Clave: los 4 primeros dígitos del RUT del paciente (patients.rut).
// - Sesión: después de la clave, un token corto (2 h) atado al id del enlace,
//   que la página manda en X-Viewer-Session (o ?s= para el PDF y el logo).
//   Formato <payload base64url>.<HMAC-SHA256 base64url>, payload
//   { v: 1, link, iat, exp } con iat/exp en milisegundos. La clave HMAC se
//   deriva de SUPABASE_SERVICE_ROLE_KEY con HKDF (como viewerTokens.mjs) y se
//   lee en cada uso: server.mjs llama a dotenv.config() después de los imports.
import crypto from "node:crypto";

export const SHARE_LINK_TTL_MS = 365 * 24 * 60 * 60 * 1000;
export const SHARE_SESSION_TTL_MS = 2 * 60 * 60 * 1000;
export const SHARE_MAX_FAILED_ATTEMPTS = 5;
export const SHARE_LOCK_MS = 15 * 60 * 1000;

const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

let cachedKey = null;

function sessionKey() {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret) throw new Error("Falta SUPABASE_SERVICE_ROLE_KEY para firmar sesiones del visor del paciente.");
  if (cachedKey?.secret === secret) return cachedKey.key;
  const key = Buffer.from(crypto.hkdfSync("sha256", secret, "imagenda", "imagenda-share-session-hmac", 32));
  cachedKey = { secret, key };
  return key;
}

function sign(body) {
  return crypto.createHmac("sha256", sessionKey()).update(body).digest();
}

// Token nuevo para un enlace: el token va en la URL, el hash a la base.
export function createShareToken() {
  const token = crypto.randomBytes(32).toString("base64url");
  return { token, tokenHash: hashShareToken(token) };
}

export function hashShareToken(token) {
  return crypto.createHash("sha256").update(String(token)).digest("hex");
}

// Un token de enlace bien formado (antes de ir a la base).
export function isShareTokenFormat(token) {
  return typeof token === "string" && TOKEN_RE.test(token);
}

export function shareLinkUrl(base, token) {
  return `${String(base).replace(/\/+$/, "")}/ver/${encodeURIComponent(token)}`;
}

// Estado de una fila de study_share_links: "activo", "vencido" o "revocado".
export function shareLinkStatus(link, { now = Date.now() } = {}) {
  if (link.revoked_at) return "revocado";
  if (new Date(link.expires_at).getTime() <= now) return "vencido";
  return "activo";
}

export function isShareLinkLocked(link, { now = Date.now() } = {}) {
  return Boolean(link.locked_until) && new Date(link.locked_until).getTime() > now;
}

// Los 4 primeros dígitos del RUT ("12345678-5" -> "1234"), o null si el RUT
// no alcanza.
export function rutPin(rut) {
  const body = String(rut ?? "").toUpperCase().replace(/[^0-9K]/g, "").slice(0, -1);
  return /^\d{4,}$/.test(body) ? body.slice(0, 4) : null;
}

export function pinMatchesRut(pin, rut) {
  const expected = rutPin(rut);
  if (!expected || typeof pin !== "string" || !/^\d{4}$/.test(pin)) return false;
  return crypto.timingSafeEqual(Buffer.from(pin), Buffer.from(expected));
}

export function signShareSession(linkId, { now = Date.now(), ttlMs = SHARE_SESSION_TTL_MS } = {}) {
  const payload = { v: 1, link: String(linkId), iat: now, exp: now + ttlMs };
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return { session: `${body}.${sign(body).toString("base64url")}`, expiresAt: new Date(payload.exp).toISOString() };
}

// Payload si la firma es válida, no venció y es de ese enlace; si no, null.
export function verifyShareSession(session, linkId, { now = Date.now() } = {}) {
  const parts = String(session ?? "").split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
  const [body, signature] = parts;

  const expected = sign(body);
  const received = Buffer.from(signature, "base64url");
  if (received.length !== expected.length || !crypto.timingSafeEqual(received, expected)) return null;

  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  return payload?.link === String(linkId) && typeof payload?.exp === "number" && payload.exp > now
    ? payload
    : null;
}
