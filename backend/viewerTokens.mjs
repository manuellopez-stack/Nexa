// Tokens del visor OHIF (Fase 3). El backend los firma con Ed25519 y el
// portero del droplet (pacs-gate) los verifica solo con la clave pública: el
// droplet nunca tiene nada con qué firmar.
//
// El par de claves se deriva de SUPABASE_SERVICE_ROLE_KEY con HKDF (no hay
// variable nueva): la semilla privada de 32 bytes sale de
// HKDF-SHA256(ikm = SUPABASE_SERVICE_ROLE_KEY, salt = "imagenda",
// info = "imagenda-viewer-token-ed25519"). Si esa clave de Supabase rota, el
// par cambia con ella; pacs-gate vuelve a leer la pública de
// GET /viewer-tokens/public-key.
//
// Formato: <payload base64url>.<firma Ed25519 base64url>, firmado sobre el
// texto del payload en base64url. Payload:
//   { v: 1, kid, studies: [StudyInstanceUID…], sub, clinic, order, iat, exp }
// con iat/exp en milisegundos. pacs-gate/server.mjs repite la verificación
// (sin dependencias compartidas).
import crypto from "node:crypto";

export const VIEWER_TOKEN_TTL_MS = 2 * 60 * 60 * 1000;

// Prefijo DER PKCS#8 de una clave privada Ed25519 (RFC 8410) antes de la
// semilla de 32 bytes.
const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

let cached = null;

function keyPair() {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret) throw new Error("Falta SUPABASE_SERVICE_ROLE_KEY para firmar tokens del visor.");
  if (cached?.secret === secret) return cached;

  const seed = Buffer.from(crypto.hkdfSync("sha256", secret, "imagenda", "imagenda-viewer-token-ed25519", 32));
  const privateKey = crypto.createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  });
  const publicKey = crypto.createPublicKey(privateKey);
  const publicDer = publicKey.export({ format: "der", type: "spki" });
  const kid = crypto.createHash("sha256").update(publicDer).digest("base64url").slice(0, 16);
  cached = {
    secret,
    privateKey,
    publicKey,
    kid,
    publicKeyPem: publicKey.export({ format: "pem", type: "spki" }).toString(),
  };
  return cached;
}

// Lo que publica GET /viewer-tokens/public-key (nada secreto).
export function viewerPublicKeyInfo() {
  const { kid, publicKeyPem } = keyPair();
  return { alg: "Ed25519", kid, publicKeyPem };
}

export function signViewerToken(
  { studies, sub, clinic, order },
  { now = Date.now(), ttlMs = VIEWER_TOKEN_TTL_MS } = {},
) {
  if (!Array.isArray(studies) || studies.length === 0) throw new Error("El token del visor necesita al menos un estudio.");
  const { privateKey, kid } = keyPair();
  const payload = { v: 1, kid, studies: studies.map(String), sub, clinic, order, iat: now, exp: now + ttlMs };
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = crypto.sign(null, Buffer.from(body), privateKey).toString("base64url");
  return { token: `${body}.${signature}`, expiresAt: new Date(payload.exp).toISOString() };
}

// Payload si la firma es válida y no venció; si no, null. (La usa el backend
// en los tests; pacs-gate tiene su propia copia.)
export function verifyViewerToken(token, { now = Date.now() } = {}) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
  const [body, signature] = parts;
  const { publicKey } = keyPair();
  let valid = false;
  try {
    valid = crypto.verify(null, Buffer.from(body), publicKey, Buffer.from(signature, "base64url"));
  } catch {
    return null;
  }
  if (!valid) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    return typeof payload.exp === "number" && payload.exp > now && Array.isArray(payload.studies) ? payload : null;
  } catch {
    return null;
  }
}
