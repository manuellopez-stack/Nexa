// Correos de la reserva web (confirmación y cancelación). Solo arman
// { subject, html, text }; el envío lo hace mailer.mjs. Todo dato escrito por
// el paciente (nombre, tipo de atención) se escapa antes de ir al HTML.

const BRAND_GREEN = "#0F6D63";
const BOOKING_SITE = "https://reservar.imagenda.cl";

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function firstName(fullName) {
  return String(fullName ?? "").trim().split(/\s+/)[0] || "";
}

// "YYYY-MM-DD" -> "jueves 2 de octubre de 2026" (fecha de calendario, sin
// zona horaria de por medio).
export function formatLongSpanishDate(ymd) {
  const [y, m, d] = String(ymd).split("-").map(Number);
  if (!y || !m || !d) return String(ymd ?? "");
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("es-CL", {
      timeZone: "UTC",
      weekday: "long",
      day: "numeric",
      month: "long",
      year: "numeric",
    })
      .formatToParts(new Date(Date.UTC(y, m - 1, d, 12)))
      .map((part) => [part.type, part.value]),
  );
  return `${parts.weekday} ${parts.day} de ${parts.month} de ${parts.year}`;
}

function layout(bodyHtml) {
  return `<!doctype html>
<html lang="es">
<body style="margin:0;padding:0;background:#f4f6f5;font-family:Arial,Helvetica,sans-serif;color:#1f2a28;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f5;padding:24px 12px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:12px;overflow:hidden;">
        <tr><td style="background:${BRAND_GREEN};padding:18px 24px;color:#ffffff;font-size:18px;font-weight:bold;">Imagenda</td></tr>
        <tr><td style="padding:24px;font-size:15px;line-height:1.5;">
${bodyHtml}
        </td></tr>
        <tr><td style="padding:16px 24px;border-top:1px solid #e3e8e6;color:#6b7775;font-size:12px;">
          Reserva hecha en reservar.imagenda.cl · Imagenda
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

function detailRow(label, valueHtml) {
  return `<tr><td style="padding:4px 12px 4px 0;color:#6b7775;white-space:nowrap;vertical-align:top;">${label}</td><td style="padding:4px 0;font-weight:bold;">${valueHtml}</td></tr>`;
}

function button(href, label) {
  return `<a href="${escapeHtml(href)}" style="display:inline-block;background:${BRAND_GREEN};color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:bold;">${label}</a>`;
}

// { patientName, clinicName, clinicAddress?, tipo, fecha (YYYY-MM-DD), hora (HH:MM), cancelUrl }
export function bookingConfirmationEmail({
  patientName,
  clinicName,
  clinicAddress,
  tipo,
  fecha,
  hora,
  cancelUrl,
}) {
  const nombre = firstName(patientName);
  const fechaLarga = formatLongSpanishDate(fecha);
  const address = String(clinicAddress ?? "").trim();
  const subject = `Tu hora en ${clinicName} está reservada`;

  const html = layout(`
          <p style="margin:0 0 16px;">Hola, ${escapeHtml(nombre)}:</p>
          <p style="margin:0 0 16px;">Tu hora quedó reservada. Estos son los datos:</p>
          <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 16px;">
            ${detailRow("Centro", escapeHtml(clinicName))}
            ${address ? detailRow("Dirección", escapeHtml(address)) : ""}
            ${detailRow("Tipo de atención", escapeHtml(tipo))}
            ${detailRow("Fecha", escapeHtml(fechaLarga))}
            ${detailRow("Hora", escapeHtml(hora))}
          </table>
          <p style="margin:0 0 20px;">La sala y el profesional se asignan en el centro antes de tu atención.</p>
          <p style="margin:0 0 12px;">${button(cancelUrl, "Cancelar mi hora")}</p>
          <p style="margin:0;color:#6b7775;font-size:13px;">Puedes cancelar hasta 2 horas antes; después, comunícate directamente con el centro.</p>`);

  const text = [
    `Hola, ${nombre}:`,
    "",
    "Tu hora quedó reservada. Estos son los datos:",
    "",
    `Centro: ${clinicName}`,
    ...(address ? [`Dirección: ${address}`] : []),
    `Tipo de atención: ${tipo}`,
    `Fecha: ${fechaLarga}`,
    `Hora: ${hora}`,
    "",
    "La sala y el profesional se asignan en el centro antes de tu atención.",
    "",
    `Cancelar mi hora: ${cancelUrl}`,
    "Puedes cancelar hasta 2 horas antes; después, comunícate directamente con el centro.",
    "",
    "Reserva hecha en reservar.imagenda.cl · Imagenda",
  ].join("\n");

  return { subject, html, text };
}

// { patientName, clinicName, clinicSlug?, fecha (YYYY-MM-DD), hora (HH:MM) }
export function bookingCancellationEmail({ patientName, clinicName, clinicSlug, fecha, hora }) {
  const nombre = firstName(patientName);
  const fechaLarga = formatLongSpanishDate(fecha);
  const rebookUrl = clinicSlug ? `${BOOKING_SITE}/${encodeURIComponent(clinicSlug)}` : BOOKING_SITE;
  const subject = `Tu hora en ${clinicName} fue cancelada`;

  const html = layout(`
          <p style="margin:0 0 16px;">Hola, ${escapeHtml(nombre)}:</p>
          <p style="margin:0 0 16px;">Cancelamos tu hora en <strong>${escapeHtml(clinicName)}</strong>:</p>
          <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 20px;">
            ${detailRow("Fecha", escapeHtml(fechaLarga))}
            ${detailRow("Hora", escapeHtml(hora))}
          </table>
          <p style="margin:0;">${button(rebookUrl, "Reservar otra hora")}</p>`);

  const text = [
    `Hola, ${nombre}:`,
    "",
    `Cancelamos tu hora en ${clinicName}:`,
    "",
    `Fecha: ${fechaLarga}`,
    `Hora: ${hora}`,
    "",
    `Reservar otra hora: ${rebookUrl}`,
    "",
    "Reserva hecha en reservar.imagenda.cl · Imagenda",
  ].join("\n");

  return { subject, html, text };
}
