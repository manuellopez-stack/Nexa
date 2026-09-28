// Informe radiológico escrito y firmado en Imagenda (rutas .../report), contra
// la base en memoria de test/support/supabase-mock.mjs. Lo central: un
// informe firmado deja la orden y el documento EXACTAMENTE como un informe
// subido en PDF y aprobado por un médico, y no aparece en Por validar.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";

import { db, resetDb, storageFiles, users } from "./support/supabase-mock.mjs";
import { templateForExams } from "../reportTemplates.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const BUCKET = "clinical-documents";
const TOKENS = {
  medico: "tok-medico",
  medicoSinFirma: "tok-medico-sin-firma",
  admin: "tok-admin",
  tecnico: "tok-tecnico",
  recepcion: "tok-recepcion",
  otraClinica: "tok-otra",
  equipoTodas: "tok-equipo-todas",
};

const HOUR = 3600 * 1000;
const ago = (ms) => new Date(Date.now() - ms).toISOString();

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      {
        id: "u-medico", role: "medico", clinic_id: CLINIC, full_name: "Dra. Ana Soto",
        rut: "11111111-1", specialty: "Radiología",
      },
      { id: "u-medico-sin", role: "medico", clinic_id: CLINIC, full_name: "Dr. Sin Firma" },
      { id: "u-admin", role: "administrador", clinic_id: CLINIC, full_name: "Admin" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec" },
      { id: "u-recepcion", role: "recepcion", clinic_id: CLINIC, full_name: "Recepción" },
      {
        id: "u-otra", role: "medico", clinic_id: OTHER_CLINIC, full_name: "Dr. Otro",
        rut: "22222222-2", specialty: "Radiología",
      },
      {
        id: "u-equipo", role: "administrador", clinic_id: null, full_name: "Equipo",
        is_platform_admin: true, platform_role: "admin", all_clinics: true,
      },
    ],
    patients: [
      { id: 1, name: "Juan Pérez", rut: "12345678-5", age: 54, clinic_id: CLINIC, status: "Programado" },
    ],
    imaging_orders: [
      // Estudio realizado, sin informe.
      {
        id: "io-tac", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000101",
        requested_at: ago(9 * HOUR), performed_at: ago(8 * HOUR),
      },
      // Otro estudio realizado, para el camino "subir PDF y aprobar".
      {
        id: "io-rx", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD000102",
        requested_at: ago(9 * HOUR), performed_at: ago(8 * HOUR),
      },
      // Todavía no realizado.
      { id: "io-ordenado", patient_id: 1, clinic_id: CLINIC, status: "ordenado", requested_at: ago(1 * HOUR) },
      // Con un informe subido que sigue pendiente.
      {
        id: "io-pend", patient_id: 1, clinic_id: CLINIC, status: "informado", accession_number: "IMD000103",
        requested_at: ago(9 * HOUR), performed_at: ago(8 * HOUR), informed_at: ago(2 * HOUR),
      },
    ],
    imaging_order_types: [
      { order_id: "io-tac", imaging_type_id: "it-tac" },
      { order_id: "io-rx", imaging_type_id: "it-rx" },
      { order_id: "io-ordenado", imaging_type_id: "it-rx" },
      { order_id: "io-pend", imaging_type_id: "it-rx" },
    ],
    imaging_types: [
      { id: "it-tac", name: "TAC de abdomen", category: "TAC", fonasa_code: "0403014" },
      { id: "it-rx", name: "Radiografía de tórax", category: "RX", fonasa_code: "0401070" },
    ],
    documents: [
      {
        id: "doc-subido", patient_id: 1, filename: "rx subido.pdf", exam: "Radiografía de tórax",
        validation_status: "pendiente", incorporated_at: ago(2 * HOUR), imaging_order_id: "io-pend",
        pdf_path: `${CLINIC}/1/subido.pdf`,
      },
    ],
  });
  users[TOKENS.medico] = { id: "u-medico", email: "medica@test.cl" };
  users[TOKENS.medicoSinFirma] = { id: "u-medico-sin", email: "sinfirma@test.cl" };
  users[TOKENS.admin] = { id: "u-admin", email: "admin@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.recepcion] = { id: "u-recepcion", email: "recepcion@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
  users[TOKENS.equipoTodas] = { id: "u-equipo", email: "equipo@imagenda.cl" };
}

async function raw(method, path, { as = "medico", body, headers = {} } = {}) {
  return fetch(`${BASE}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKENS[as]}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function api(method, path, options) {
  const response = await raw(method, path, options);
  const type = response.headers.get("content-type") ?? "";
  return {
    status: response.status,
    body: type.includes("json") ? await response.json() : Buffer.from(await response.arrayBuffer()),
  };
}

const reportPath = (orderId = "io-tac") => `/patients/1/imaging-orders/${orderId}/report`;
const TEXT = {
  clinicalHistory: "Dolor abdominal de 3 días.",
  technique: "TAC multicorte con contraste endovenoso.",
  findings: "Hígado de tamaño normal, sin lesiones focales.",
  impression: "Sin hallazgos agudos.",
};
const row = (table, id) => db[table].find((r) => r.id === id);
const docsOf = (orderId) => db.documents.filter((doc) => doc.imaging_order_id === orderId);
const queueCount = async () => (await api("GET", "/validation-queue")).body.conteos.total;

async function writeAndSign(orderId = "io-tac", as = "medico") {
  const put = await api("PUT", reportPath(orderId), { as, body: TEXT });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  return api("POST", `${reportPath(orderId)}/sign`, { as });
}

before(async () => {
  process.env.OPENAI_API_KEY = "test";
  process.env.SUPABASE_URL = "http://supabase.mock";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test";
  seed();
  await import("../server.mjs");
  for (let i = 0; i < 50; i++) {
    try {
      await fetch(`${BASE}/health`);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("El servidor de prueba no arrancó en el puerto 3000.");
});

beforeEach(() => seed());

after(() => {
  setTimeout(() => process.exit(), 50);
});

test("plantillas: se eligen por categoría o nombre del examen, genérica si no calza", () => {
  assert.equal(templateForExams([{ category: "TAC", name: "TAC de abdomen" }]).key, "tac");
  assert.equal(templateForExams([{ category: "Resonancia magnética", name: "RM de rodilla" }]).key, "rm");
  assert.equal(templateForExams([{ category: "Ecotomografía", name: "Eco abdominal" }]).key, "eco");
  assert.equal(templateForExams([{ category: "RX", name: "Mamografía bilateral" }]).key, "mamografia");
  assert.equal(templateForExams([{ category: "RX", name: "Radiografía de tórax" }]).key, "rx");
  assert.equal(templateForExams([{ category: "Otros", name: "Densitometría ósea" }]).key, "generica");
  // "rm"/"ct" como palabra completa, no dentro de otra.
  assert.equal(templateForExams([{ category: "Otros", name: "Forma de abdomen" }]).key, "generica");
});

test("GET sin informe: plantilla según el examen y datos para el encabezado", async () => {
  const { status, body } = await api("GET", reportPath());
  assert.equal(status, 200);
  assert.equal(body.report, null);
  assert.equal(body.template.key, "tac");
  assert.ok(body.template.technique.length > 0);
  assert.equal(body.exam.title, "TAC de abdomen");
  assert.equal(body.order.accessionNumber, "IMD000101");
  assert.equal(body.patient.name, "Juan Pérez");
  assert.deepEqual(body.permissions, { canWrite: true, canSign: true, canDraft: true, canCreateNewVersion: false });
  assert.equal(body.mySignature.complete, true);
});

test("borrador: solo médico y administrador; la orden debe estar realizada", async () => {
  for (const as of ["tecnico", "recepcion"]) {
    assert.equal((await api("PUT", reportPath(), { as, body: TEXT })).status, 403, as);
  }
  const put = await api("PUT", reportPath(), { as: "admin", body: TEXT });
  assert.equal(put.status, 200);
  assert.equal(put.body.report.status, "borrador");
  assert.equal(put.body.report.version, 1);
  assert.equal(put.body.report.findings, TEXT.findings);

  // Guardar de nuevo actualiza el mismo borrador.
  const again = await api("PUT", reportPath(), { body: { findings: "Cambio." } });
  assert.equal(again.body.report.id, put.body.report.id);
  assert.equal(again.body.report.findings, "Cambio.");
  assert.equal(again.body.report.impression, TEXT.impression);
  assert.equal(db.imaging_reports.length, 1);

  const notDone = await api("PUT", reportPath("io-ordenado"), { body: TEXT });
  assert.equal(notDone.status, 400);
  assert.match(notDone.body.error, /realizado/);
});

test("quien no escribe informes no ve borradores", async () => {
  await api("PUT", reportPath(), { body: TEXT });
  for (const as of ["recepcion", "tecnico"]) {
    const { status, body } = await api("GET", reportPath(), { as });
    assert.equal(status, 200, as);
    assert.equal(body.report, null, as);
    assert.equal(body.template, null, as);
    assert.equal(body.permissions.canWrite, false, as);
  }
});

test("firmar: técnico, recepción y administrador reciben 403", async () => {
  await api("PUT", reportPath(), { body: TEXT });
  for (const as of ["tecnico", "recepcion", "admin"]) {
    assert.equal((await api("POST", `${reportPath()}/sign`, { as })).status, 403, as);
  }
  assert.equal(row("imaging_orders", "io-tac").status, "realizado");
});

test("no se firma sin datos de firma; PATCH /me/signature valida el RUT", async () => {
  await api("PUT", reportPath(), { as: "medicoSinFirma", body: TEXT });
  const noData = await api("POST", `${reportPath()}/sign`, { as: "medicoSinFirma" });
  assert.equal(noData.status, 400);
  assert.equal(noData.body.code, "signature_incomplete");
  assert.match(noData.body.error, /Completa tus datos de firma/);
  assert.equal(noData.body.mySignature.complete, false);

  const badRut = await api("PATCH", "/me/signature", {
    as: "medicoSinFirma",
    body: { fullName: "Dr. Sin Firma", rut: "12.345.678-9", specialty: "Radiología" },
  });
  assert.equal(badRut.status, 400);
  assert.match(badRut.body.error, /dígito verificador/);

  const missing = await api("PATCH", "/me/signature", {
    as: "medicoSinFirma",
    body: { fullName: "Dr. Sin Firma", rut: "12.345.678-5" },
  });
  assert.equal(missing.status, 400);

  const ok = await api("PATCH", "/me/signature", {
    as: "medicoSinFirma",
    body: { fullName: "Dr. Sin Firma", rut: "12.345.678-5", specialty: "Radiología" },
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.signature, {
    fullName: "Dr. Sin Firma",
    rut: "12345678-5",
    specialty: "Radiología",
    complete: true,
  });

  const signed = await api("POST", `${reportPath()}/sign`, { as: "medicoSinFirma" });
  assert.equal(signed.status, 200);
  assert.equal(signed.body.report.signerRut, "12345678-5");
});

test("no se firma con Hallazgos o Impresión vacíos", async () => {
  await api("PUT", reportPath(), { body: { ...TEXT, findings: "   " } });
  const noFindings = await api("POST", `${reportPath()}/sign`);
  assert.equal(noFindings.status, 400);
  assert.match(noFindings.body.error, /Hallazgos e Impresión/);

  const noImpression = await api("POST", `${reportPath()}/sign`, {
    body: { findings: "Algo.", impression: "" },
  });
  assert.equal(noImpression.status, 400);
  assert.equal(row("imaging_orders", "io-tac").status, "realizado");
  assert.equal(docsOf("io-tac").length, 0);
});

test("firmar deja orden y documento EXACTAMENTE como un informe subido y aprobado", async () => {
  // Camino de siempre en io-rx: subir el PDF vinculado a la orden y aprobarlo.
  const upload = await api("PATCH", "/patients/1/from-document", {
    body: {
      filename: "informe rx.pdf",
      imagingOrderId: "io-rx",
      documentData: { isClinical: true, exam: "Radiografía de tórax", patientRut: "12345678-5" },
      base64Data: Buffer.from("%PDF-1.4 subido").toString("base64"),
    },
  });
  assert.equal(upload.status, 200);
  const approve = await api("PATCH", `/patients/1/documents/${encodeURIComponent("informe rx.pdf")}/validate`, {
    body: { status: "aprobado" },
  });
  assert.equal(approve.status, 200);

  // Camino nuevo en io-tac: escribir y firmar.
  const signed = await writeAndSign();
  assert.equal(signed.status, 200, JSON.stringify(signed.body));

  const uploadedDoc = docsOf("io-rx")[0];
  const signedDoc = docsOf("io-tac")[0];
  const orderRx = row("imaging_orders", "io-rx");
  const orderTac = row("imaging_orders", "io-tac");

  // Mismo estado de la orden.
  assert.equal(orderTac.status, "validado");
  for (const key of ["status"]) assert.equal(orderTac[key], orderRx[key], key);
  for (const key of ["informed_at", "validated_at"]) {
    assert.ok(orderTac[key], `orden firmada sin ${key}`);
    assert.ok(orderRx[key], `orden subida sin ${key}`);
  }

  // Mismo estado del documento (salvo datos propios de cada informe).
  const stateKeys = [
    "validation_status", "is_clinical", "correction_reason", "correction_requested_at",
    "correction_requested_by", "validated_by", "validation_note",
  ];
  for (const key of stateKeys) assert.equal(signedDoc[key] ?? null, uploadedDoc[key] ?? null, key);
  assert.equal(signedDoc.validation_status, "aprobado");
  assert.equal(signedDoc.validated_by, "medica@test.cl");
  assert.ok(signedDoc.validated_at);
  assert.ok(signedDoc.incorporated_at);
  assert.equal(signedDoc.doctor, "Dra. Ana Soto");
  assert.equal(signedDoc.summary, TEXT.impression);
  // Mismas columnas presentes en ambos documentos.
  assert.deepEqual(
    Object.keys(signedDoc).filter((key) => !(key in uploadedDoc)),
    [],
    "el documento firmado tiene columnas que el subido no",
  );
  // Historia clínica igual que el informe subido.
  assert.ok(db.history_events.some((event) => event.document_id === signedDoc.id));

  // El PDF quedó en el mismo bucket y ruta que los documentos clínicos.
  assert.match(signedDoc.pdf_path, new RegExp(`^${CLINIC}/1/[0-9a-f-]{36}\\.pdf$`));
  assert.equal(storageFiles[`${BUCKET}/${signedDoc.pdf_path}`].subarray(0, 5).toString(), "%PDF-");

  // El informe queda firmado con copia de los datos de firma.
  const report = db.imaging_reports.find((r) => r.imaging_order_id === "io-tac");
  assert.equal(report.status, "firmado");
  assert.equal(report.signed_by, "u-medico");
  assert.ok(report.signed_at);
  assert.equal(report.signer_name, "Dra. Ana Soto");
  assert.equal(report.signer_rut, "11111111-1");
  assert.equal(report.signer_specialty, "Radiología");
  assert.equal(report.document_id, signedDoc.id);

  // No aparece en Por validar.
  assert.equal(await queueCount(), 1); // solo el informe subido pendiente de io-pend
  const queue = (await api("GET", "/validation-queue")).body;
  assert.ok(!JSON.stringify(queue).includes("io-tac"));
});

test("recepción descarga el PDF firmado y ve el informe firmado", async () => {
  const signed = await writeAndSign();
  const filename = signed.body.report.documentFilename;
  assert.ok(filename);

  const pdf = await api("GET", `/patients/1/documents/${encodeURIComponent(filename)}/pdf`, { as: "recepcion" });
  assert.equal(pdf.status, 200);
  assert.equal(pdf.body.subarray(0, 5).toString(), "%PDF-");

  const view = await api("GET", reportPath(), { as: "recepcion" });
  assert.equal(view.body.report.status, "firmado");
  assert.equal(view.body.report.impression, TEXT.impression);
});

test("un informe firmado no se edita", async () => {
  await writeAndSign();
  const before = { ...db.imaging_reports[0] };

  const put = await api("PUT", reportPath(), { body: { findings: "Cambiado." } });
  assert.equal(put.status, 409);
  assert.match(put.body.error, /nueva versión/);
  const resign = await api("POST", `${reportPath()}/sign`, { body: { findings: "Cambiado." } });
  assert.equal(resign.status, 409);
  assert.deepEqual(db.imaging_reports[0], before);
  assert.equal(db.imaging_reports.length, 1);
});

test("nueva versión: copia el texto y al firmarla reemplaza a la anterior", async () => {
  const first = await writeAndSign();
  const firstDocId = docsOf("io-tac")[0].id;

  const created = await api("POST", `${reportPath()}/new-version`);
  assert.equal(created.status, 200);
  assert.equal(created.body.report.status, "borrador");
  assert.equal(created.body.report.version, 2);
  assert.equal(created.body.report.findings, TEXT.findings);
  assert.equal(created.body.versions[0].status, "firmado");
  // Una sola a la vez.
  assert.equal((await api("POST", `${reportPath()}/new-version`)).status, 409);

  const signed = await api("POST", `${reportPath()}/sign`, {
    body: { impression: "Sin hallazgos agudos. Se corrige lateralidad." },
  });
  assert.equal(signed.status, 200);
  assert.equal(signed.body.report.version, 2);
  assert.equal(signed.body.report.status, "firmado");
  assert.notEqual(signed.body.report.documentFilename, first.body.report.documentFilename);

  const [v2, v1] = [...db.imaging_reports].sort((a, b) => b.version - a.version);
  assert.equal(v1.status, "reemplazado");
  assert.equal(v2.status, "firmado");

  const oldDoc = row("documents", firstDocId);
  assert.equal(oldDoc.validation_status, "rechazado");
  assert.equal(oldDoc.validation_note, "Reemplazado por versión corregida");
  assert.equal(oldDoc.correction_reason, null); // sin corrección pendiente
  const newDoc = row("documents", v2.document_id);
  assert.equal(newDoc.validation_status, "aprobado");
  assert.equal(row("imaging_orders", "io-tac").status, "validado");

  // No cuenta como devuelto ni vuelve a Por validar.
  assert.equal((await api("GET", "/dashboard/summary")).body.returnedForCorrection, 0);
  assert.equal(await queueCount(), 1);
});

test("firmar sobre un informe subido pendiente lo saca de Por validar", async () => {
  assert.equal(await queueCount(), 1);
  const signed = await writeAndSign("io-pend");
  assert.equal(signed.status, 200);

  const uploaded = row("documents", "doc-subido");
  assert.equal(uploaded.validation_status, "rechazado");
  assert.equal(uploaded.validation_note, "Reemplazado por informe firmado en Imagenda");
  assert.equal(uploaded.correction_reason ?? null, null);
  assert.equal(row("imaging_orders", "io-pend").status, "validado");
  assert.equal(await queueCount(), 0);
});

test("vista previa: PDF del borrador, sin guardar nada", async () => {
  assert.equal((await api("GET", `${reportPath()}/preview`)).status, 404);
  await api("PUT", reportPath(), { body: TEXT });
  const documentsBefore = db.documents.length;

  const preview = await api("GET", `${reportPath()}/preview`);
  assert.equal(preview.status, 200);
  assert.equal(preview.body.subarray(0, 5).toString(), "%PDF-");
  assert.equal(db.documents.length, documentsBefore);
  assert.equal(db.imaging_reports[0].status, "borrador");

  assert.equal((await api("GET", `${reportPath()}/preview`, { as: "recepcion" })).status, 403);
});

test("otra clínica recibe 404 en todas las rutas del informe", async () => {
  await api("PUT", reportPath(), { body: TEXT });
  const calls = [
    ["GET", reportPath()],
    ["PUT", reportPath(), TEXT],
    ["POST", `${reportPath()}/sign`],
    ["POST", `${reportPath()}/new-version`],
    ["GET", `${reportPath()}/preview`],
  ];
  for (const [method, path, body] of calls) {
    assert.equal((await api(method, path, { as: "otraClinica", body })).status, 404, `${method} ${path}`);
  }
  assert.equal(db.imaging_reports[0].findings, TEXT.findings);
});

test("respeta la clínica activa del selector del equipo Imagenda", async () => {
  const own = await api("GET", reportPath(), { as: "equipoTodas", headers: { "X-Clinic-Id": CLINIC } });
  assert.equal(own.status, 200);
  const other = await api("GET", reportPath(), { as: "equipoTodas", headers: { "X-Clinic-Id": OTHER_CLINIC } });
  assert.equal(other.status, 404);
});

test("gestión de personal: el administrador edita RUT y especialidad", async () => {
  const bad = await api("PATCH", "/staff/u-medico-sin/signature", { as: "admin", body: { rut: "1-1" } });
  assert.equal(bad.status, 400);

  const ok = await api("PATCH", "/staff/u-medico-sin/signature", {
    as: "admin",
    body: { rut: "12.345.678-5", specialty: "Radiología" },
  });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.staff.rut, "12345678-5");
  assert.equal(ok.body.staff.specialty, "Radiología");
  assert.equal(row("staff_profiles", "u-medico-sin").full_name, "Dr. Sin Firma");

  const list = await api("GET", "/staff", { as: "admin" });
  const member = list.body.staff.find((staff) => staff.id === "u-medico-sin");
  assert.equal(member.specialty, "Radiología");

  // Un médico no gestiona personal; otra clínica no existe para este admin.
  assert.equal((await api("PATCH", "/staff/u-medico-sin/signature", { body: { specialty: "X" } })).status, 403);
  assert.equal(
    (await api("PATCH", "/staff/u-otra/signature", { as: "admin", body: { specialty: "X" } })).status,
    404,
  );
});
