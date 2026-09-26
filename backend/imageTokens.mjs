// Tokens para las URLs firmadas de imágenes que viven en Orthanc
// (GET /imaging-files/:fileId/dicom?t=... y .../preview?t=..., server.mjs).
//
// El visor DICOM y las miniaturas cargan esas URLs directo desde el
// navegador, sin poder poner el header Authorization, así que la ruta es
// pública y la autorización es el token: se entrega solo a quien ya pasó los
// chequeos de rol y clínica de GET .../imaging-orders/:orderId/images, está
// atado a una fila de imaging_files y a un tipo ("dicom" o "preview") y vence
// en 1 hora (lo mismo que las signed URLs de Storage de las filas antiguas).
//
// Formato: <payload base64url>.<HMAC-SHA256 base64url>, payload
// { fileId, kind, exp } con exp en milisegundos. La clave se deriva de
// SUPABASE_SERVICE_ROLE_KEY y se lee en cada uso (no al importar: server.mjs
// llama a dotenv.config() después de resolver los imports).
import crypto from "node:crypto";

export const IMAGE_TOKEN_TTL_MS = 60 * 60 * 1000;
export const IMAGE_TOKEN_KINDS = ["dicom", "preview"];

function tokenKey() {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret) throw new Error("Falta SUPABASE_SERVICE_ROLE_KEY para firmar URLs de imágenes.");
  return crypto.createHash("sha256").update(`imagenda-image-token:${secret}`).digest();
}

function sign(body) {
  return crypto.createHmac("sha256", tokenKey()).update(body).digest();
}

export function signImageToken({ fileId, kind }, { now = Date.now(), ttlMs = IMAGE_TOKEN_TTL_MS } = {}) {
  if (!IMAGE_TOKEN_KINDS.includes(kind)) throw new Error(`Tipo de token de imagen desconocido: ${kind}`);
  const body = Buffer.from(JSON.stringify({ fileId: String(fileId), kind, exp: now + ttlMs })).toString("base64url");
  return `${body}.${sign(body).toString("base64url")}`;
}

// true solo si la firma es válida, no venció y es para ese archivo y tipo.
export function verifyImageToken(token, { fileId, kind }, { now = Date.now() } = {}) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return false;
  const [body, signature] = parts;

  const expected = sign(body);
  const received = Buffer.from(signature, "base64url");
  if (received.length !== expected.length || !crypto.timingSafeEqual(received, expected)) return false;

  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    return false;
  }
  return (
    payload?.fileId === String(fileId) &&
    payload?.kind === kind &&
    typeof payload?.exp === "number" &&
    payload.exp > now
  );
}
