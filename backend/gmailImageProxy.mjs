// ============================================
// PROXY DE IMÁGENES DE CORREOS (Gmail)
// ============================================
// Los correos de la campanita de notificaciones cargan imágenes desde CDNs de
// terceros (Mailjet, ESPs, etc.) que el navegador bloquea por CORS. Para que se
// vean igual que en Gmail, el backend las descarga server-to-server (ahí no
// aplica CORS) y las reenvía al frontend.
//
// SEGURIDAD: esto NO es un proxy abierto. El frontend nunca envía una URL.
// Cuando el backend prepara el HTML de un correo real, reemplaza cada `src`
// de imagen remota por una referencia opaca y aleatoria; esa referencia mapea
// de vuelta a la URL original, asociada al mensaje de Gmail que se está viendo.
// El endpoint de proxy solo acepta esas referencias.
//
// Defensa en profundidad contra SSRF: aunque las URLs provienen de correos
// reales, igual se resuelve el DNS y se bloquean IPs privadas/internas
// (loopback, 10/8, 172.16/12, 192.168/16, link-local, 169.254.169.254, CGNAT,
// multicast, IPv6 ULA/loopback...), con timeout y tope de tamaño de descarga.

import { randomBytes } from "node:crypto";
import dns from "node:dns/promises";
import net from "node:net";

const TTL_MS_DEFECTO = 30 * 60 * 1000; // 30 min
const MAX_ENTRADAS_DEFECTO = 5000;
export const MAX_BYTES_DEFECTO = 5 * 1024 * 1024; // 5 MB
export const TIMEOUT_MS_DEFECTO = 6000; // 6 s
const MAX_REDIRECCIONES_DEFECTO = 3;

// ---- Filtro de IPs privadas / internas -------------------------------------

/** Devuelve true si la IP (v4 o v6) apunta a una red privada, interna o
 *  reservada a la que el backend nunca debería conectarse. */
export function esIpPrivadaOInterna(ip) {
  if (typeof ip !== "string") return true;

  if (net.isIPv4(ip)) {
    const o = ip.split(".").map(Number);
    if (o.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return true;
    if (o[0] === 0) return true; // "this" network
    if (o[0] === 10) return true; // 10.0.0.0/8
    if (o[0] === 127) return true; // loopback
    if (o[0] === 169 && o[1] === 254) return true; // link-local (incluye 169.254.169.254)
    if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return true; // 172.16.0.0/12
    if (o[0] === 192 && o[1] === 168) return true; // 192.168.0.0/16
    if (o[0] === 192 && o[1] === 0 && o[2] === 0) return true; // IETF protocol assignments
    if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return true; // CGNAT 100.64.0.0/10
    if (o[0] >= 224) return true; // multicast + reservado (224+ y 240+)
    if (o[0] === 255 && o[1] === 255 && o[2] === 255 && o[3] === 255) return true; // broadcast
    return false;
  }

  if (net.isIPv6(ip)) {
    const bajo = ip.toLowerCase();
    if (bajo === "::" || bajo === "::1") return true; // no especificada / loopback
    if (bajo.startsWith("fe80:") || bajo.startsWith("fe8") || bajo.startsWith("fe9") ||
        bajo.startsWith("fea") || bajo.startsWith("feb")) return true; // link-local fe80::/10
    if (bajo.startsWith("fc") || bajo.startsWith("fd")) return true; // ULA fc00::/7
    if (bajo.startsWith("ff")) return true; // multicast
    // IPv4 mapeada/compatible: ::ffff:a.b.c.d  o  ::a.b.c.d
    const m = bajo.match(/(?:^|:)((?:\d{1,3}\.){3}\d{1,3})$/);
    if (m) return esIpPrivadaOInterna(m[1]);
    return false;
  }

  return true; // no es una IP válida -> bloquear
}

/** Valida que `urlStr` sea http(s), sin credenciales embebidas, y que ninguna
 *  de las IPs a las que resuelve su host sea privada/interna.
 *  Devuelve un objeto URL si es segura, o null si debe rechazarse. */
export async function validarDestinoSeguro(urlStr) {
  let u;
  try {
    u = new URL(urlStr);
  } catch {
    return null;
  }

  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (u.username || u.password) return null;

  const host = u.hostname.replace(/^\[|\]$/g, ""); // quita corchetes de IPv6

  if (net.isIP(host)) {
    return esIpPrivadaOInterna(host) ? null : u;
  }

  // Nombre de dominio: resolver TODAS las direcciones y validarlas.
  let direcciones;
  try {
    direcciones = await dns.lookup(host, { all: true });
  } catch {
    return null;
  }
  if (!Array.isArray(direcciones) || direcciones.length === 0) return null;
  for (const { address } of direcciones) {
    if (esIpPrivadaOInterna(address)) return null;
  }
  return u;
}

// ---- Descarga segura de una imagen ----------------------------------------

/** Descarga una imagen con validación anti-SSRF en cada salto de redirección,
 *  timeout y tope de tamaño. Devuelve { contentType, buffer } o null si algo
 *  falla (la fuente sigue bloqueando, error de red, no es una imagen, etc.). */
export async function descargarImagenSegura(urlInicial, opciones = {}) {
  const {
    timeoutMs = TIMEOUT_MS_DEFECTO,
    maxBytes = MAX_BYTES_DEFECTO,
    maxRedirecciones = MAX_REDIRECCIONES_DEFECTO,
  } = opciones;

  let urlActual = urlInicial;

  for (let salto = 0; salto <= maxRedirecciones; salto++) {
    const destino = await validarDestinoSeguro(urlActual);
    if (!destino) return null;

    const controlador = new AbortController();
    const temporizador = setTimeout(() => controlador.abort(), timeoutMs);

    try {
      const respuesta = await fetch(destino, {
        method: "GET",
        redirect: "manual",
        signal: controlador.signal,
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; NexaMailImageProxy/1.0)",
          Accept: "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        },
      });

      // Redirección: validar el destino y seguir manualmente.
      if (respuesta.status >= 300 && respuesta.status < 400) {
        const location = respuesta.headers.get("location");
        if (!location) return null;
        try {
          urlActual = new URL(location, destino).toString();
        } catch {
          return null;
        }
        continue;
      }

      if (!respuesta.ok || !respuesta.body) return null;

      const contentType = (respuesta.headers.get("content-type") || "")
        .split(";")[0]
        .trim()
        .toLowerCase();
      if (!contentType.startsWith("image/")) return null;

      const largoDeclarado = Number(respuesta.headers.get("content-length"));
      if (Number.isFinite(largoDeclarado) && largoDeclarado > maxBytes) return null;

      const trozos = [];
      let total = 0;
      for await (const trozo of respuesta.body) {
        total += trozo.length;
        if (total > maxBytes) return null;
        trozos.push(trozo);
      }
      return { contentType, buffer: Buffer.concat(trozos) };
    } catch {
      return null;
    } finally {
      clearTimeout(temporizador);
    }
  }

  return null; // demasiadas redirecciones
}

// ---- Registro (referencia opaca -> URL original) --------------------------

/** Crea un registro en memoria que asocia referencias aleatorias con las URLs
 *  de imágenes de un correo concreto. Con TTL y tope de entradas. */
export function crearRegistroImagenesProxy(opciones = {}) {
  const { ttlMs = TTL_MS_DEFECTO, maxEntradas = MAX_ENTRADAS_DEFECTO } = opciones;
  const mapa = new Map(); // ref -> { url, messageId, expiraEn }

  function purgar() {
    const ahora = Date.now();
    for (const [ref, dato] of mapa) {
      if (dato.expiraEn <= ahora) mapa.delete(ref);
    }
    // Map mantiene orden de inserción: las primeras son las más antiguas.
    while (mapa.size > maxEntradas) {
      const masAntigua = mapa.keys().next().value;
      if (masAntigua === undefined) break;
      mapa.delete(masAntigua);
    }
  }

  return {
    /** Registra una URL y devuelve la referencia opaca. */
    registrar(url, messageId) {
      purgar();
      const ref = randomBytes(18).toString("base64url"); // 24 chars, ~144 bits
      mapa.set(ref, { url, messageId, expiraEn: Date.now() + ttlMs });
      return ref;
    },
    /** Resuelve una referencia a { url, messageId } o null si no existe/expiró. */
    resolver(ref) {
      if (typeof ref !== "string" || !ref) return null;
      const dato = mapa.get(ref);
      if (!dato) return null;
      if (dato.expiraEn <= Date.now()) {
        mapa.delete(ref);
        return null;
      }
      return { url: dato.url, messageId: dato.messageId };
    },
    get tamano() {
      return mapa.size;
    },
  };
}

// ---- Reescritura del HTML del correo -------------------------------------

const RE_IMG_SRC = /(<img\b[^>]*?\bsrc\s*=\s*)(["'])\s*(https?:\/\/[^"'\s>]+)\s*\2/gi;

function decodificarEntidadesUrl(url) {
  return url
    .replace(/&amp;/gi, "&")
    .replace(/&#0*38;/g, "&")
    .replace(/&#x0*26;/gi, "&");
}

/** Reemplaza cada `src` de imagen remota (http/https) por una URL de nuestro
 *  proxy con una referencia opaca. Las imágenes que ya apuntan al backend, o
 *  que usan `cid:`/`data:`, se dejan intactas. */
export function reescribirImagenesRemotas(html, { registrar, messageId, urlBaseProxy }) {
  if (typeof html !== "string" || !html) return html;

  let hostProxy = "";
  try {
    hostProxy = new URL(urlBaseProxy).host;
  } catch {
    return html; // sin base válida no reescribimos (fallback: imágenes ocultas)
  }

  return html.replace(RE_IMG_SRC, (completo, prefijo, comilla, urlCruda) => {
    const url = decodificarEntidadesUrl(urlCruda);
    try {
      if (new URL(url).host === hostProxy) return completo;
    } catch {
      return completo;
    }
    const ref = registrar(url, messageId);
    return `${prefijo}${comilla}${urlBaseProxy}?ref=${encodeURIComponent(ref)}${comilla}`;
  });
}
