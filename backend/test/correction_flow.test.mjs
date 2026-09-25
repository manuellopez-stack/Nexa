// Flujo "Pedir corrección" contra las rutas reales de server.mjs, con una
// base en memoria (test/support/supabase-mock.mjs) y datos simulados. No toca
// Supabase ni OpenAI.
//
// Correr desde backend/ (el servidor usa el puerto 3000, que debe estar libre):
//   node --import ./test/support/register-mocks.mjs --test "test/*.test.mjs"

import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { db, resetDb, users } from "./support/supabase-mock.mjs";

// Variables que server.mjs exige al arrancar (valores falsos: todo va al mock).
process.env.OPENAI_API_KEY = "test";
process.env.SUPABASE_URL = "http://supabase.mock";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test";
process.env.SUPABASE_PUBLISHABLE_KEY = "test";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const HOUR = 60 * 60 * 1000;
const ago = (ms) => new Date(Date.now() - ms).toISOString();

const TOKENS = { medico: "tok-medico", tecnico: "tok-tecnico", otraClinica: "tok-otra" };

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      { id: "u-medico", role: "medico", clinic_id: CLINIC, full_name: "Dra. Test" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec Test" },
      { id: "u-otra", role: "medico", clinic_id: OTHER_CLINIC, full_name: "Otro" },
    ],
    patients: [
      { id: 1, name: "Juan Pérez", rut: "12345678-5", clinic_id: CLINIC, status: "Programado" },
    ],
    documents: [
      {
        id: "doc-1", patient_id: 1, filename: "informe.pdf", exam: "Ecografía abdominal",
        validation_status: "pendiente", incorporated_at: ago(5 * HOUR), imaging_order_id: null,
      },
      {
        id: "doc-rx", patient_id: 1, filename: "rx.pdf", exam: "Radiografía de tórax",
        doctor: "Dr. Rayos", validation_status: "pendiente", incorporated_at: ago(3 * HOUR),
        imaging_order_id: "io-1",
      },
    ],
    imaging_orders: [
      { id: "io-1", patient_id: 1, clinic_id: CLINIC, status: "informado", requested_at: ago(9 * HOUR), informed_at: ago(3 * HOUR) },
    ],
    imaging_order_types: [{ order_id: "io-1", imaging_type_id: "it-1" }],
    imaging_types: [{ id: "it-1", name: "Radiografía de tórax", category: "RX" }],
    lab_orders: [
      { id: "lo-1", patient_id: 1, clinic_id: CLINIC, status: "completado", requested_at: ago(8 * HOUR), completed_at: ago(2 * HOUR) },
    ],
    lab_order_panels: [{ order_id: "lo-1", panel_id: "p-1" }],
    lab_panels: [{ id: "p-1", name: "Hemograma" }],
    lab_parameters: [{ id: "par-1", panel_id: "p-1", name: "Hemoglobina", unit: "g/dL", ref_min: 12, ref_max: 16 }],
    lab_results: [{ id: "lr-1", order_id: "lo-1", parameter_id: "par-1", value_numeric: 11 }],
    dental_orders: [
      { id: "do-1", patient_id: 1, clinic_id: CLINIC, status: "realizado", requested_at: ago(7 * HOUR), performed_at: ago(1 * HOUR) },
    ],
    dental_order_procedures: [{ order_id: "do-1", procedure_id: "dp-1" }],
    dental_procedures: [{ id: "dp-1", name: "Exodoncia simple" }],
  });
  users[TOKENS.medico] = { id: "u-medico", email: "medica@test.cl" };
  users[TOKENS.tecnico] = { id: "u-tecnico", email: "tecnico@test.cl" };
  users[TOKENS.otraClinica] = { id: "u-otra", email: "otra@test.cl" };
}

async function api(method, path, { as = "medico", body } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKENS[as]}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: response.status, body: await response.json() };
}

const row = (tableName, id) => db[tableName].find((r) => r.id === id);
const queue = async () => (await api("GET", "/validation-queue")).body;
const summary = async (as = "medico") => (await api("GET", "/dashboard/summary", { as })).body;

before(async () => {
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

// El servidor no se puede cerrar desde acá (server.mjs no exporta el
// listener): se sale al terminar, respetando el código de salida del runner.
after(() => {
  setTimeout(() => process.exit(), 50);
});

test("punto de partida: 4 informes por validar, ninguno devuelto", async () => {
  const q = await queue();
  assert.deepEqual(q.conteos, { total: 4, documento: 1, laboratorio: 1, imagenologia: 1, dental: 1 });
  const s = await summary();
  assert.equal(s.pendingValidation, 4);
  assert.equal(s.returnedForCorrection, 0);
});

test("reglas: solo validadores, motivo obligatorio de al menos 5 caracteres", async () => {
  const path = "/patients/1/documents/informe.pdf/validate";
  assert.equal((await api("PATCH", path, { as: "tecnico", body: { status: "rechazado", reason: "Falta la firma" } })).status, 403);
  assert.equal((await api("PATCH", path, { body: { status: "rechazado" } })).status, 400);
  assert.equal((await api("PATCH", path, { body: { status: "rechazado", reason: "  mal " } })).status, 400);
  assert.equal((await api("PATCH", "/patients/1/lab-orders/lo-1/request-correction", { as: "tecnico", body: { reason: "Revisar Hb" } })).status, 403);
  assert.equal((await api("PATCH", "/patients/1/lab-orders/lo-1/request-correction", { body: { reason: "Hb" } })).status, 400);
  assert.equal((await api("PATCH", "/patients/1/dental-orders/do-1/request-correction", { body: {} })).status, 400);
  // Otra clínica no ve la orden.
  assert.equal((await api("PATCH", "/patients/1/lab-orders/lo-1/request-correction", { as: "otraClinica", body: { reason: "Revisar Hb" } })).status, 404);
  // Nada cambió.
  assert.equal(row("documents", "doc-1").validation_status, "pendiente");
  assert.equal(row("lab_orders", "lo-1").status, "completado");
});

test("pedir corrección: queda devuelto y sale de Por validar", async () => {
  const doc = await api("PATCH", "/patients/1/documents/informe.pdf/validate", {
    body: { status: "rechazado", reason: "El examen no corresponde al paciente" },
  });
  assert.equal(doc.status, 200);
  assert.equal(doc.body.document.validationStatus, "rechazado");
  assert.equal(doc.body.document.correctionReason, "El examen no corresponde al paciente");
  assert.equal(doc.body.document.correctionRequestedBy, "medica@test.cl");
  assert.ok(doc.body.document.correctionRequestedAt);

  const rx = await api("PATCH", "/patients/1/documents/rx.pdf/validate", {
    body: { status: "rechazado", reason: "Informe sin conclusión" },
  });
  assert.equal(rx.status, 200);
  assert.equal(row("imaging_orders", "io-1").status, "realizado", "la orden de imagen vuelve a 'realizado'");

  const lab = await api("PATCH", "/patients/1/lab-orders/lo-1/request-correction", {
    body: { reason: "Hemoglobina fuera de rango, repetir" },
  });
  assert.equal(lab.status, 200);
  assert.equal(lab.body.order.status, "en_proceso");
  assert.equal(lab.body.order.correctionReason, "Hemoglobina fuera de rango, repetir");
  // Ya no está en 'completado': no se puede pedir de nuevo.
  assert.equal((await api("PATCH", "/patients/1/lab-orders/lo-1/request-correction", { body: { reason: "Otra vez" } })).status, 409);

  const dental = await api("PATCH", "/patients/1/dental-orders/do-1/request-correction", {
    body: { reason: "Falta indicar la pieza" },
  });
  assert.equal(dental.status, 200);
  assert.equal(dental.body.order.status, "ordenado");
  assert.equal(dental.body.order.correctionRequestedBy, "medica@test.cl");

  const q = await queue();
  assert.equal(q.conteos.total, 0);
  assert.deepEqual(q.items, []);
  const s = await summary();
  assert.equal(s.pendingValidation, 0);
  assert.equal(s.returnedForCorrection, 4, "2 documentos + 1 laboratorio + 1 dental");

  // La orden de imagen muestra la corrección de su informe devuelto.
  const imaging = await api("GET", "/patients/1/imaging-orders", { as: "tecnico" });
  assert.equal(imaging.body.orders[0].correctionReason, "Informe sin conclusión");
  const labList = await api("GET", "/patients/1/lab-orders", { as: "tecnico" });
  assert.equal(labList.body.orders[0].correctionReason, "Hemoglobina fuera de rango, repetir");
});

test("se corrige: vuelve a Por validar sin aviso", async () => {
  const documentData = {
    isClinical: true, patientName: "Juan Pérez", patientRut: "12345678-5",
    exam: "Ecografía abdominal", documentType: "Informe", summary: "Corregido",
  };

  // Documento: se vuelve a guardar con el mismo nombre.
  const redo = await api("PATCH", "/patients/1/from-document", {
    as: "tecnico",
    body: { documentData, filename: "informe.pdf" },
  });
  assert.equal(redo.status, 200, JSON.stringify(redo.body));
  assert.equal(row("documents", "doc-1").validation_status, "pendiente");
  assert.equal(row("documents", "doc-1").correction_reason, null);

  // Imagenología: el tecnólogo vincula un informe corregido con otro nombre.
  const newReport = await api("PATCH", "/patients/1/from-document", {
    as: "tecnico",
    body: { documentData: { ...documentData, exam: "Radiografía de tórax" }, filename: "rx-corregido.pdf", imagingOrderId: "io-1" },
  });
  assert.equal(newReport.status, 200, JSON.stringify(newReport.body));
  assert.equal(row("imaging_orders", "io-1").status, "informado");
  const oldReport = row("documents", "doc-rx");
  assert.equal(oldReport.validation_status, "rechazado", "el informe anterior queda como historia");
  assert.equal(oldReport.correction_reason, null, "pero sin corrección pendiente");

  // Laboratorio: se vuelven a cargar los resultados completos.
  const labResults = await api("PATCH", "/patients/1/lab-orders/lo-1/results", {
    as: "tecnico",
    body: { results: [{ parameterId: "par-1", valueNumeric: 13.2 }] },
  });
  assert.equal(labResults.status, 200);
  assert.equal(labResults.body.order.status, "completado");
  assert.equal(labResults.body.order.correctionReason, null);

  // Dental: se corrige el resultado y se marca realizada de nuevo.
  const dentalResults = await api("PATCH", "/patients/1/dental-orders/do-1/results", {
    as: "tecnico",
    body: { results: [{ procedureId: "dp-1", tooth: "3.6", diagnosis: "Caries", professional: "Dr. Diente" }] },
  });
  assert.equal(dentalResults.status, 200);
  const performed = await api("PATCH", "/patients/1/dental-orders/do-1/performed", { as: "tecnico" });
  assert.equal(performed.status, 200);
  assert.equal(performed.body.order.status, "realizado");
  assert.equal(performed.body.order.correctionReason, null);

  const q = await queue();
  assert.deepEqual(q.conteos, { total: 4, documento: 1, laboratorio: 1, imagenologia: 1, dental: 1 });
  const imagingItem = q.items.find((item) => item.tipo === "imagenologia");
  assert.equal(imagingItem.archivo, "rx-corregido.pdf", "Revisar abre el informe nuevo");
  const s = await summary();
  assert.equal(s.pendingValidation, 4);
  assert.equal(s.returnedForCorrection, 0);

  // Sin aviso: ningún documento ni orden trae corrección pendiente.
  const docs = await api("GET", "/patients/1/documents", { as: "tecnico" });
  const pendingDocs = docs.body.documents.filter((d) => d.validationStatus === "pendiente");
  assert.equal(pendingDocs.length, 2);
  assert.ok(pendingDocs.every((d) => d.correctionReason === null));
  const labList = await api("GET", "/patients/1/lab-orders", { as: "tecnico" });
  assert.equal(labList.body.orders[0].correctionReason, null);
  const imaging = await api("GET", "/patients/1/imaging-orders", { as: "tecnico" });
  assert.equal(imaging.body.orders[0].correctionReason, null);
});

test("aprobar después de una corrección no deja aviso", async () => {
  const approved = await api("PATCH", "/patients/1/documents/informe.pdf/validate", { body: { status: "aprobado" } });
  assert.equal(approved.status, 200);
  assert.equal(approved.body.document.correctionReason, null);
  const approvedRx = await api("PATCH", "/patients/1/documents/rx-corregido.pdf/validate", { body: { status: "aprobado" } });
  assert.equal(approvedRx.status, 200);
  assert.equal(row("imaging_orders", "io-1").status, "validado");
  const s = await summary();
  assert.equal(s.pendingValidation, 2);
  assert.equal(s.returnedForCorrection, 0);
});
