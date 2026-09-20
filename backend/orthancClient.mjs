// Cliente HTTP mínimo para la REST API de Orthanc. Lo usan tanto
// syncOrthanc.mjs (cron) como server.mjs (vínculo manual de un estudio).
//
// Las credenciales se leen de process.env recién en el primer uso (lazy),
// no al importar el módulo: tanto server.mjs como syncOrthanc.mjs llaman a
// dotenv.config() en su propio código, y el import de este archivo se
// resuelve antes de que esa llamada corra -- leer process.env a nivel de
// módulo aquí arriba daría siempre undefined en local.
let cachedConfig = null;

function getConfig() {
  if (cachedConfig) return cachedConfig;

  const { ORTHANC_URL, ORTHANC_USER, ORTHANC_PASSWORD } = process.env;
  if (!ORTHANC_URL || !ORTHANC_USER || !ORTHANC_PASSWORD) {
    throw new Error(
      "Faltan ORTHANC_URL, ORTHANC_USER o ORTHANC_PASSWORD en las variables de entorno.",
    );
  }

  cachedConfig = {
    baseUrl: ORTHANC_URL.replace(/\/+$/, ""),
    authHeader:
      "Basic " +
      Buffer.from(`${ORTHANC_USER}:${ORTHANC_PASSWORD}`).toString("base64"),
  };
  return cachedConfig;
}

async function orthancRequest(path, { method = "GET" } = {}) {
  const { baseUrl, authHeader } = getConfig();

  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { Authorization: authHeader },
  });

  if (response.status === 404) return null;

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Orthanc respondió ${response.status} en ${method} ${path}: ${detail}`,
    );
  }

  return response;
}

export async function orthancGetJson(path) {
  const response = await orthancRequest(path);
  return response ? response.json() : null;
}

export async function orthancGetBinary(path) {
  const response = await orthancRequest(path);
  if (!response) return null;
  return Buffer.from(await response.arrayBuffer());
}

export async function orthancDelete(path) {
  await orthancRequest(path, { method: "DELETE" });
}
