// Envío de correos transaccionales (confirmación / cancelación de reservas
// web) por SMTP de Zoho: smtp.zoho.com, puerto 587 con STARTTLS, desde
// contacto@imagenda.cl (mismo remitente que usa Supabase; el dominio ya tiene
// SPF/DKIM).
//
// Se configura con SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS y MAIL_FROM
// (opcional). Si falta alguna, sendMail NO lanza: avisa una sola vez por
// consola y devuelve { sent: false, reason: "smtp-no-configurado" }, para que
// una reserva nunca falle por no tener correo configurado.
//
// Nunca se imprime SMTP_PASS en logs.
import nodemailer from "nodemailer";

const DEFAULT_FROM = "Imagenda <contacto@imagenda.cl>";
const TIMEOUT_MS = 10_000;

let transporter = null;
let warnedMissingConfig = false;

function smtpConfig() {
  const host = process.env.SMTP_HOST?.trim();
  const port = Number(process.env.SMTP_PORT);
  const user = process.env.SMTP_USER?.trim();
  const pass = process.env.SMTP_PASS;
  if (!host || !port || !user || !pass) return null;
  return { host, port, user, pass };
}

function getTransporter() {
  if (transporter) return transporter;
  const config = smtpConfig();
  if (!config) return null;
  transporter = nodemailer.createTransport({
    host: config.host,
    port: config.port,
    // 465 = TLS directo; cualquier otro puerto (587) sube a TLS con STARTTLS.
    secure: config.port === 465,
    requireTLS: config.port !== 465,
    auth: { user: config.user, pass: config.pass },
    connectionTimeout: TIMEOUT_MS,
    greetingTimeout: TIMEOUT_MS,
    socketTimeout: TIMEOUT_MS,
  });
  return transporter;
}

// sendMail({ to, subject, html, text }) -> { sent: true, messageId }
//                                        | { sent: false, reason }
// Solo "no configurado" se resuelve sin lanzar; un error real de envío
// (credenciales, red, timeout) sí lanza para que quien llama decida.
export async function sendMail({ to, subject, html, text }) {
  const transport = getTransporter();
  if (!transport) {
    if (!warnedMissingConfig) {
      warnedMissingConfig = true;
      console.warn(
        "SMTP no configurado (faltan SMTP_HOST, SMTP_PORT, SMTP_USER o SMTP_PASS): no se envían correos.",
      );
    }
    return { sent: false, reason: "smtp-no-configurado" };
  }

  const from = process.env.MAIL_FROM?.trim() || DEFAULT_FROM;
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("Tiempo de envío de correo agotado")), TIMEOUT_MS);
  });
  try {
    const info = await Promise.race([
      transport.sendMail({ from, to, subject, html, text }),
      timeout,
    ]);
    return { sent: true, messageId: info?.messageId ?? null };
  } finally {
    clearTimeout(timer);
  }
}
