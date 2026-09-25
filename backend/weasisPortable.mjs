// Visor Weasis portable para Windows que va dentro del ZIP "Descargar para
// DVD" (ver dvdExport.mjs).
//
// Weasis 4.x ya no publica en sus releases de GitHub un zip "portable": la
// copia que el propio Weasis incrusta en sus CD (exportación "CD/DVD Image",
// solo Windows x86-64) es la carpeta instalada de la app (Weasis.exe + app/ +
// runtime/, sin Java aparte). Esa misma carpeta viene dentro del instalador
// oficial Weasis-<versión>-x86-64.msi, así que la primera vez que se pide un
// DVD el servidor:
//   1. descarga el MSI oficial de https://github.com/nroduit/Weasis/releases
//      y verifica su tamaño y su SHA-256 (fijados abajo);
//   2. saca el gabinete (Data.cab) del MSI y lo descomprime con 7za
//      (paquete 7zip-bin), que deja cada archivo con su clave interna;
//   3. lee las tablas File / Component / Directory del MSI para devolverle a
//      cada archivo su nombre y carpeta reales, y verifica cada uno contra
//      el tamaño de la tabla File y el MD5 de la tabla MsiFileHash;
//   4. deja el resultado en la caché (WEASIS_CACHE_DIR, por defecto
//      backend/.cache/weasis) junto a un manifest.json con tamaño por archivo.
// Los pedidos siguientes solo comprueban el manifest contra el disco.
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import CFB from "cfb";
import sevenZip from "7zip-bin";

const execFileAsync = promisify(execFile);

export const WEASIS_VERSION = "4.7.3";
const WEASIS_MSI = {
  url: `https://github.com/nroduit/Weasis/releases/download/v${WEASIS_VERSION}/Weasis-${WEASIS_VERSION}-x86-64.msi`,
  size: 54636544,
  sha256: "c15358f95b79d936dd908ebd9afeebbce90bd463a9ba97aeda5edcfb78712f1c",
};

// Si la preparación falla (GitHub caído, disco lleno...), no se reintenta en
// cada pedido: el DVD sale sin visor hasta que pase este tiempo.
const RETRY_AFTER_MS = 5 * 60 * 1000;

const backendDir = path.dirname(fileURLToPath(import.meta.url));

function cacheRoot() {
  return process.env.WEASIS_CACHE_DIR || path.join(backendDir, ".cache", "weasis");
}

function versionDir() {
  return path.join(cacheRoot(), `weasis-${WEASIS_VERSION}`);
}

// ----------------------------------------------------------------------------
// Lectura de tablas de un MSI (base de datos de Windows Installer dentro de
// un archivo OLE / Compound File)
// ----------------------------------------------------------------------------

// Los nombres de los streams del MSI vienen comprimidos: cada carácter entre
// 0x3800 y 0x4840 codifica uno o dos caracteres de este alfabeto, y 0x4840
// marca las tablas (se devuelve como prefijo "!").
const MSI_NAME_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._";

function decodeMsiStreamName(name) {
  let out = "";
  for (const char of name) {
    const code = char.charCodeAt(0);
    if (code === 0x4840) {
      out += "!";
    } else if (code >= 0x3800 && code < 0x4800) {
      const value = code - 0x3800;
      out += MSI_NAME_ALPHABET[value & 0x3f] + MSI_NAME_ALPHABET[(value >> 6) & 0x3f];
    } else if (code >= 0x4800 && code < 0x4840) {
      out += MSI_NAME_ALPHABET[code - 0x4800];
    } else {
      out += char;
    }
  }
  return out;
}

export function readMsiDatabase(msiBuffer) {
  const container = CFB.read(msiBuffer, { type: "buffer" });
  const streams = new Map();
  for (const entry of container.FileIndex) {
    if (entry.type === 2 && entry.content) {
      streams.set(decodeMsiStreamName(entry.name), Buffer.from(entry.content));
    }
  }

  const pool = streams.get("!_StringPool");
  const data = streams.get("!_StringData");
  if (!pool || !data) throw new Error("El MSI no tiene tabla de strings.");

  const longRefs = (pool.readUInt32LE(0) & 0x80000000) !== 0;
  const refSize = longRefs ? 3 : 2;
  const strings = [null];
  let offset = 0;
  for (let i = 4; i + 4 <= pool.length; ) {
    let length = pool.readUInt16LE(i);
    const refs = pool.readUInt16LE(i + 2);
    if (length === 0 && refs === 0) {
      strings.push("");
      i += 4;
      continue;
    }
    // Un string de más de 64 KB ocupa dos entradas: la primera va en cero y
    // la segunda trae la palabra alta del largo.
    if (length === 0) {
      length = (pool.readUInt16LE(i + 6) << 16) + pool.readUInt16LE(i + 4);
      i += 8;
    } else {
      i += 4;
    }
    strings.push(data.toString("utf8", offset, offset + length));
    offset += length;
  }

  // Las filas se guardan por columna: todos los valores de la columna 1,
  // luego los de la 2, etc. Los enteros llevan un sesgo (0x8000 / 0x80000000)
  // y el cero significa null.
  function readRows(tableName, columns) {
    const buffer = streams.get(`!${tableName}`);
    if (!buffer) return [];
    const sizes = columns.map((c) => (c.isString ? refSize : c.size));
    const rowSize = sizes.reduce((a, b) => a + b, 0);
    const rowCount = Math.floor(buffer.length / rowSize);
    const rows = Array.from({ length: rowCount }, () => ({}));
    let position = 0;
    columns.forEach((column, index) => {
      for (let r = 0; r < rowCount; r++) {
        let value;
        if (column.isString) {
          const ref = refSize === 3 ? buffer.readUIntLE(position, 3) : buffer.readUInt16LE(position);
          value = strings[ref] ?? null;
        } else if (column.size === 2) {
          const raw = buffer.readUInt16LE(position);
          value = raw ? raw - 0x8000 : null;
        } else {
          const raw = buffer.readUInt32LE(position);
          value = raw ? raw - 0x80000000 : null;
        }
        rows[r][column.name] = value;
        position += sizes[index];
      }
    });
    return rows;
  }

  const columnRows = readRows("_Columns", [
    { name: "Table", isString: true },
    { name: "Number", size: 2 },
    { name: "Name", isString: true },
    { name: "Type", size: 2 },
  ]);

  function readTable(tableName) {
    const columns = columnRows
      .filter((row) => row.Table === tableName)
      .sort((a, b) => a.Number - b.Number)
      .map((row) => {
        const type = row.Type & 0xffff;
        const isString = (type & 0x0800) !== 0;
        return { name: row.Name, isString, size: isString ? refSize : (type & 0xff) === 4 ? 4 : 2 };
      });
    return readRows(tableName, columns);
  }

  const cabinet = [...streams.entries()].find(
    ([, buffer]) => buffer.subarray(0, 4).toString("latin1") === "MSCF",
  );

  return {
    readTable,
    cabinetName: cabinet?.[0] ?? null,
    cabinet: cabinet?.[1] ?? null,
  };
}

// "corto|largo" -> largo; "destino:origen" -> destino.
function msiLongName(value) {
  const target = String(value).split(":")[0];
  return target.includes("|") ? target.split("|")[1] : target;
}

// Ruta relativa a INSTALLDIR de cada archivo del MSI, más su tamaño y MD5
// esperados (el MD5 solo existe para archivos sin versión, como en todo MSI).
export function planMsiInstallTree(database) {
  const directories = new Map(database.readTable("Directory").map((d) => [d.Directory, d]));
  const components = new Map(database.readTable("Component").map((c) => [c.Component, c]));
  const hashes = new Map(database.readTable("MsiFileHash").map((h) => [h.File_, h]));

  function directorySegments(directoryId) {
    const segments = [];
    let current = directoryId;
    while (current && current !== "INSTALLDIR") {
      const directory = directories.get(current);
      if (!directory) return null;
      const name = msiLongName(directory.DefaultDir);
      if (name !== ".") segments.unshift(name);
      current = directory.Directory_Parent;
    }
    return current === "INSTALLDIR" ? segments : null;
  }

  const files = [];
  for (const file of database.readTable("File")) {
    const component = components.get(file.Component_);
    const segments = component ? directorySegments(component.Directory_) : null;
    if (!segments) continue; // fuera de la carpeta de la app (accesos directos, etc.)

    const hash = hashes.get(file.File);
    let md5 = null;
    if (hash) {
      md5 = Buffer.alloc(16);
      [hash.HashPart1, hash.HashPart2, hash.HashPart3, hash.HashPart4].forEach((part, i) =>
        md5.writeInt32LE(part ?? 0, i * 4),
      );
    }

    files.push({
      key: file.File,
      relativePath: [...segments, msiLongName(file.FileName)].join("/"),
      size: file.FileSize,
      md5,
    });
  }
  return files;
}

// ----------------------------------------------------------------------------
// Descarga + armado de la caché
// ----------------------------------------------------------------------------

async function downloadVerified(url, destination, { size, sha256 }) {
  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok || !response.body) {
    throw new Error(`No se pudo descargar ${url} (HTTP ${response.status}).`);
  }
  const hash = crypto.createHash("sha256");
  let bytes = 0;
  const source = Readable.fromWeb(response.body);
  source.on("data", (chunk) => {
    hash.update(chunk);
    bytes += chunk.length;
  });
  await pipeline(source, fs.createWriteStream(destination));

  if (bytes !== size) {
    throw new Error(`El MSI de Weasis pesa ${bytes} bytes; se esperaban ${size}.`);
  }
  const digest = hash.digest("hex");
  if (digest !== sha256) {
    throw new Error(`El SHA-256 del MSI de Weasis no coincide (${digest}).`);
  }
}

async function md5OfFile(filePath) {
  const hash = crypto.createHash("md5");
  await pipeline(fs.createReadStream(filePath), hash);
  return hash.digest();
}

async function sevenZipBinary() {
  const binary = sevenZip.path7za;
  // npm no siempre conserva el bit de ejecución del binario incluido.
  try {
    await fsp.access(binary, fs.constants.X_OK);
  } catch {
    await fsp.chmod(binary, 0o755);
  }
  return binary;
}

// Arma la carpeta del visor a partir de un MSI ya descargado. Exportada para
// poder probarla con otro MSI; en producción solo la llama prepareWeasis.
export async function buildViewerFromMsi(msiPath, workDir) {
  const database = readMsiDatabase(await fsp.readFile(msiPath));
  if (!database.cabinet) throw new Error("El MSI no trae un gabinete (.cab) interno.");

  const plan = planMsiInstallTree(database);
  const cabPath = path.join(workDir, "Data.cab");
  await fsp.writeFile(cabPath, database.cabinet);

  const extractedDir = path.join(workDir, "cab");
  await execFileAsync(await sevenZipBinary(), ["x", "-y", `-o${extractedDir}`, cabPath], {
    maxBuffer: 16 * 1024 * 1024,
  });
  await fsp.rm(cabPath, { force: true });

  const viewerDir = path.join(workDir, "viewer");
  const manifestFiles = [];
  let totalBytes = 0;

  for (const file of plan) {
    const source = path.join(extractedDir, file.key);
    const destination = path.join(viewerDir, ...file.relativePath.split("/"));
    await fsp.mkdir(path.dirname(destination), { recursive: true });
    await fsp.rename(source, destination);

    const { size } = await fsp.stat(destination);
    if (size !== file.size) {
      throw new Error(`${file.relativePath}: ${size} bytes, el MSI dice ${file.size}.`);
    }
    if (file.md5 && !(await md5OfFile(destination)).equals(file.md5)) {
      throw new Error(`${file.relativePath}: el MD5 no coincide con el del MSI.`);
    }

    manifestFiles.push({ path: file.relativePath, size });
    totalBytes += size;
  }
  await fsp.rm(extractedDir, { recursive: true, force: true });

  if (!manifestFiles.some((f) => f.path === "Weasis.exe")) {
    throw new Error("El MSI no trae Weasis.exe en la raíz de la app.");
  }

  return { viewerDir, files: manifestFiles, totalBytes };
}

async function prepareWeasis() {
  const root = cacheRoot();
  await fsp.mkdir(root, { recursive: true });
  const workDir = await fsp.mkdtemp(path.join(root, ".preparando-"));

  try {
    const msiPath = path.join(workDir, "weasis.msi");
    console.log(`[DVD] Descargando Weasis ${WEASIS_VERSION} (primera vez) desde ${WEASIS_MSI.url}`);
    await downloadVerified(WEASIS_MSI.url, msiPath, WEASIS_MSI);

    const outDir = path.join(workDir, "salida");
    await fsp.mkdir(outDir);
    const { files, totalBytes } = await buildViewerFromMsi(msiPath, outDir);
    await fsp.rm(msiPath, { force: true });

    const manifest = {
      version: WEASIS_VERSION,
      source: WEASIS_MSI.url,
      msiSha256: WEASIS_MSI.sha256,
      preparedAt: new Date().toISOString(),
      fileCount: files.length,
      totalBytes,
      files,
    };
    await fsp.writeFile(path.join(outDir, "manifest.json"), JSON.stringify(manifest));

    await fsp.rm(versionDir(), { recursive: true, force: true });
    await fsp.rename(outDir, versionDir());
    console.log(`[DVD] Weasis ${WEASIS_VERSION} listo en caché: ${files.length} archivos, ${totalBytes} bytes.`);
  } finally {
    await fsp.rm(workDir, { recursive: true, force: true });
  }
}

// Comprueba la caché contra su manifest (existencia y tamaño de cada archivo).
// Devuelve el visor o null si falta algo.
async function loadCachedViewer() {
  let manifest;
  try {
    manifest = JSON.parse(await fsp.readFile(path.join(versionDir(), "manifest.json"), "utf8"));
  } catch {
    return null;
  }
  if (manifest.version !== WEASIS_VERSION || !Array.isArray(manifest.files)) return null;

  const viewerDir = path.join(versionDir(), "viewer");
  try {
    for (const file of manifest.files) {
      const { size } = await fsp.stat(path.join(viewerDir, ...file.path.split("/")));
      if (size !== file.size) return null;
    }
  } catch {
    return null;
  }

  return {
    dir: viewerDir,
    version: manifest.version,
    files: manifest.files,
    totalBytes: manifest.totalBytes,
  };
}

let preparing = null;
let lastFailureAt = 0;
let lastFailureMessage = null;

/**
 * Devuelve { dir, version, files, totalBytes } del visor en caché,
 * preparándolo si hace falta. Nunca lanza: si no hay visor devuelve
 * { viewer: null, error } y el DVD sale sin él.
 *
 * waitMs: cuánto esperar una preparación en curso. Si se agota, la
 * preparación sigue en segundo plano para el próximo pedido.
 */
export async function getWeasisViewer({ waitMs = 4 * 60 * 1000 } = {}) {
  const cached = await loadCachedViewer();
  if (cached) return { viewer: cached, error: null };

  if (!preparing) {
    if (Date.now() - lastFailureAt < RETRY_AFTER_MS) {
      return { viewer: null, error: lastFailureMessage };
    }
    preparing = prepareWeasis()
      .catch((error) => {
        lastFailureAt = Date.now();
        lastFailureMessage = error?.message ?? String(error);
        console.error("[DVD] No se pudo preparar el visor Weasis:", error);
      })
      .finally(() => {
        preparing = null;
      });
  }

  let timer;
  const timedOut = await Promise.race([
    preparing.then(() => false),
    new Promise((resolve) => {
      timer = setTimeout(() => resolve(true), waitMs);
    }),
  ]);
  clearTimeout(timer);

  if (timedOut) {
    const message = "El visor Weasis todavía se está preparando.";
    console.error(`[DVD] ${message}`);
    return { viewer: null, error: message };
  }

  const ready = await loadCachedViewer();
  return ready
    ? { viewer: ready, error: null }
    : { viewer: null, error: lastFailureMessage ?? "No se pudo preparar el visor Weasis." };
}
