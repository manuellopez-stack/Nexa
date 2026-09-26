// PDF original de los documentos (bucket "clinical-documents") y lo que
// recepción puede ver de imagenología: GET /patients/:id/documents/:filename/pdf
// por rol y estado de validación, guardado del PDF al analizar e incorporar,
// lectura de imágenes para recepción y estado del informe en /dvd-studies.
// Base, Storage e IA en memoria (test/support); no toca Supabase ni OpenAI.
//
// Usa el puerto 3000 como los demás: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { queuedResponses } from "./support/openai-mock.mjs";
import { db, resetDb, storageFiles, users } from "./support/supabase-mock.mjs";

process.env.OPENAI_API_KEY = "test";
process.env.SUPABASE_URL = "http://supabase.mock";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test";
process.env.SUPABASE_PUBLISHABLE_KEY = "test";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const BUCKET = "clinical-documents";
const TOKENS = {
  medico: "tok-medico",
  tecnico: "tok-tecnico",
  recepcion: "tok-recepcion",
  otraClinica: "tok-otra",
};

const pdf = (text) => Buffer.from(`%PDF-1.4\n${text}\n%%EOF\n`);

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      { id: "u-medico", role: "medico", clinic_id: CLINIC, full_name: "Dra. Test" },
      { id: "u-tecnico", role: "tecnico", clinic_id: CLINIC, full_name: "Tec" },
      { id: "u-recepcion", role: "recepcion", clinic_id: CLINIC, full_name: "Recepción" },
      { id: "u-otra", role: "recepcion", clinic_id: OTHER_CLINIC, full_name: "Otra" },
    ],
    patients: [
      { id: 1, name: "Juan Pérez", rut: "12345678-5", clinic_id: CLINIC, status: "Programado" },
    ],
    documents: [
      {
        id: "doc-pend", patient_id: 1, filename: "pendiente.pdf", validation_status: "pendiente",
        incorporated_at: "2026-09-25T10:00:00Z", pdf_path: `${CLINIC}/1/pend.pdf`, imaging_order_id: "io-pend",
      },
      {
        id: "doc-apro", patient_id: 1, filename: "Informe Tórax.pdf", validation_status: "aprobado",
        incorporated_at: "2026-09-25T11:00:00Z", pdf_path: `${CLINIC}/1/apro.pdf`, imaging_order_id: "io-apro",
      },
      {
        id: "doc-sinpdf", patient_id: 1, filename: "antiguo.pdf", validation_status: "aprobado",
        incorporated_at: "2026-09-20T11:00:00Z", pdf_path: null,
      },
    ],
    imaging_orders: [
      { id: "io-apro", patient_id: 1, clinic_id: CLINIC, status: "validado", accession_number: "IMD1", requested_at: "2026-09-25T09:00:00Z" },
      { id: "io-pend", patient_id: 1, clinic_id: CLINIC, status: "informado", accession_number: "IMD2", requested_at: "2026-09-25T08:00:00Z" },
      { id: "io-sin", patient_id: 1, clinic_id: CLINIC, status: "realizado", accession_number: "IMD3", requested_at: "2026-09-25T07:00:00Z" },
    ],
    imaging_order_types: [],
    imaging_files: [
      { id: "f1", order_id: "io-apro", dicom_path: "orders/io-apro/a.dcm", png_path: "orders/io-apro/a.png", uploaded_at: "2026-09-25T09:30:00Z" },
      { id: "f2", order_id: "io-pend", dicom_path: "orders/io-pend/a.dcm", png_path: null, uploaded_at: "2026-09-25T08:30:00Z" },
      { id: "f3", order_id: "io-sin", dicom_path: "orders/io-sin/a.dcm", png_path: null, uploaded_at: "2026-09-25T07:30:00Z" },
    ],
  });
  storageFiles[`${BUCKET}/${CLINIC}/1/pend.pdf`] = pdf("pendiente");
  storageFiles[`${BUCKET}/${CLINIC}/1/apro.pdf`] = pdf("aprobado");
  for (const [role, token] of Object.entries(TOKENS)) {
    const id = role === "otraClinica" ? "u-otra" : `u-${role}`;
    users[token] = { id, email: `${role}@test.cl` };
  }
}

async function api(method, path, { as = "medico", body } = {}) {
  return fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

const pdfPath = (filename) => `/patients/1/documents/${encodeURIComponent(filename)}/pdf`;
const doc = (id) => db.documents.find((row) => row.id === id);
const docByName = (filename) => db.documents.find((row) => row.filename === filename);

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

after(() => {
  setTimeout(() => process.exit(), 50);
});

// ---------------------------------------------------------------------------
// GET /patients/:id/documents/:filename/pdf
// ---------------------------------------------------------------------------

test("/pdf: el personal clínico ve el PDF aunque no esté aprobado (inline)", async () => {
  for (const as of ["medico", "tecnico"]) {
    const response = await api("GET", pdfPath("pendiente.pdf"), { as });
    assert.equal(response.status, 200, as);
    assert.equal(response.headers.get("content-type"), "application/pdf");
    assert.match(response.headers.get("content-disposition"), /^inline; filename="pendiente\.pdf"/);
    assert.equal(Buffer.from(await response.arrayBuffer()).toString(), pdf("pendiente").toString());
  }
});

test("/pdf: recepción solo con el documento aprobado", async () => {
  const pending = await api("GET", pdfPath("pendiente.pdf"), { as: "recepcion" });
  assert.equal(pending.status, 403);
  assert.deepEqual(await pending.json(), { error: "El informe todavía no está aprobado por un médico." });

  const approved = await api("GET", pdfPath("Informe Tórax.pdf"), { as: "recepcion" });
  assert.equal(approved.status, 200);
  assert.equal(approved.headers.get("content-type"), "application/pdf");
  assert.match(approved.headers.get("content-disposition"), /filename\*=UTF-8''Informe%20T%C3%B3rax\.pdf/);
  assert.equal(Buffer.from(await approved.arrayBuffer()).toString(), pdf("aprobado").toString());

  // Si el documento vuelve a pendiente, recepción deja de verlo.
  doc("doc-apro").validation_status = "pendiente";
  assert.equal((await api("GET", pdfPath("Informe Tórax.pdf"), { as: "recepcion" })).status, 403);
  doc("doc-apro").validation_status = "aprobado";
});

test("/pdf: 404 sin pdf_path o sin documento; otra clínica 404; sin sesión 401", async () => {
  assert.equal((await api("GET", pdfPath("antiguo.pdf"))).status, 404);
  assert.equal((await api("GET", pdfPath("antiguo.pdf"), { as: "recepcion" })).status, 404);
  assert.equal((await api("GET", pdfPath("no-existe.pdf"))).status, 404);
  assert.equal((await api("GET", pdfPath("Informe Tórax.pdf"), { as: "otraClinica" })).status, 404);
  assert.equal((await api("GET", pdfPath("Informe Tórax.pdf"), { as: null })).status, 401);
});

test("el detalle y la lista de documentos dicen si hay PDF, sin exponer la ruta", async () => {
  const body = await (await api("GET", "/patients/1/documents", { as: "recepcion" })).json();
  const byName = Object.fromEntries(body.documents.map((d) => [d.filename, d]));
  assert.equal(byName["pendiente.pdf"].hasPdf, true);
  assert.equal(byName["antiguo.pdf"].hasPdf, false);
  assert.ok(!JSON.stringify(body).includes(CLINIC + "/"), "no debe salir la ruta de Storage");
});

// ---------------------------------------------------------------------------
// Guardado del PDF
// ---------------------------------------------------------------------------

test("incorporar con el PDF reenviado lo guarda en <clínica>/<paciente>/<uuid>.pdf", async () => {
  const response = await api("PATCH", "/patients/1/from-document", {
    body: {
      filename: "eco.pdf",
      documentData: { isClinical: true, exam: "Ecografía", patientRut: "12345678-5" },
      base64Data: pdf("eco").toString("base64"),
    },
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).pdfSaved, true);

  const saved = docByName("eco.pdf");
  assert.match(saved.pdf_path, new RegExp(`^${CLINIC}/1/[0-9a-f-]{36}\\.pdf$`));
  assert.equal(storageFiles[`${BUCKET}/${saved.pdf_path}`].toString(), pdf("eco").toString());

  // Guardarlo de nuevo con otro PDF reemplaza el archivo y borra el anterior.
  const firstPath = saved.pdf_path;
  const again = await api("PATCH", "/patients/1/from-document", {
    body: {
      filename: "eco.pdf",
      documentData: { isClinical: true, exam: "Ecografía" },
      base64Data: pdf("eco v2").toString("base64"),
    },
  });
  assert.equal(again.status, 200);
  assert.notEqual(docByName("eco.pdf").pdf_path, firstPath);
  assert.equal(storageFiles[`${BUCKET}/${firstPath}`], undefined);

  // Sin PDF reenviado se conserva el que ya estaba.
  const keptPath = docByName("eco.pdf").pdf_path;
  const noPdf = await api("PATCH", "/patients/1/from-document", {
    body: { filename: "eco.pdf", documentData: { isClinical: true, exam: "Ecografía" } },
  });
  assert.equal((await noPdf.json()).pdfSaved, null);
  assert.equal(docByName("eco.pdf").pdf_path, keptPath);

  // Eliminar el documento borra también su PDF.
  const deleted = await api("DELETE", "/patients/1/documents/eco.pdf");
  assert.equal(deleted.status, 200);
  assert.equal(storageFiles[`${BUCKET}/${keptPath}`], undefined);
});

test("incorporar rechaza un adjunto que no es PDF o supera 10 MB", async () => {
  const notPdf = await api("PATCH", "/patients/1/from-document", {
    body: {
      filename: "x.pdf",
      documentData: { isClinical: true },
      base64Data: Buffer.from("no soy un pdf").toString("base64"),
    },
  });
  assert.equal(notPdf.status, 400);

  const big = Buffer.concat([pdf("grande"), Buffer.alloc(10 * 1024 * 1024)]);
  const tooBig = await api("PATCH", "/patients/1/from-document", {
    body: { filename: "x.pdf", documentData: { isClinical: true }, base64Data: big.toString("base64") },
  });
  assert.equal(tooBig.status, 400);
  assert.equal(docByName("x.pdf"), undefined, "no debe guardar el documento");
});

test("analizar guarda el PDF cuando el documento queda guardado en la ficha", async () => {
  queuedResponses.push({
    output_text: JSON.stringify({
      documentType: "Informe", isClinical: true, patientName: "Juan Pérez",
      patientRut: "12.345.678-5", patientAge: null, exam: "Radiografía", summary: "Normal",
    }),
  });
  const response = await api("POST", "/patients/1/documents/analyze", {
    body: { filename: "rx-nueva.pdf", base64Data: pdf("rx nueva").toString("base64") },
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.documentSaved, true);
  assert.equal(body.pdfSaved, true);
  const saved = docByName("rx-nueva.pdf");
  assert.equal(storageFiles[`${BUCKET}/${saved.pdf_path}`].toString(), pdf("rx nueva").toString());
});

test("analizar un documento de otro RUT no guarda nada (el PDF se reenvía al incorporar)", async () => {
  queuedResponses.push({
    output_text: JSON.stringify({ documentType: "Informe", isClinical: true, patientRut: "11.111.111-1", exam: "TAC" }),
  });
  const body = await (
    await api("POST", "/patients/1/documents/analyze", {
      body: { filename: "otro.pdf", base64Data: pdf("otro").toString("base64") },
    })
  ).json();
  assert.equal(body.documentSaved, false);
  assert.equal(body.pdfSaved, false);
  assert.equal(docByName("otro.pdf"), undefined);
});

// ---------------------------------------------------------------------------
// Imagenología para recepción: solo lectura
// ---------------------------------------------------------------------------

test("recepción lista las imágenes de una orden (URLs firmadas) pero no puede escribir", async () => {
  const response = await api("GET", "/patients/1/imaging-orders/io-apro/images", { as: "recepcion" });
  assert.equal(response.status, 200);
  const { files } = await response.json();
  assert.equal(files.length, 1);
  assert.match(files[0].dicomUrl, /^http:\/\/storage\.mock\/imaging\/orders\/io-apro\/a\.dcm/);
  assert.match(files[0].pngUrl, /a\.png/);

  assert.equal((await api("GET", "/patients/1/imaging-orders/io-apro/images", { as: "otraClinica" })).status, 404);

  // Todo lo demás de la orden sigue cerrado para recepción.
  assert.equal(
    (await api("POST", "/patients/1/imaging-orders/io-apro/image", {
      as: "recepcion",
      body: { filename: "a.dcm", base64Data: "AAAA" },
    })).status,
    403,
  );
  assert.equal((await api("PATCH", "/patients/1/imaging-orders/io-sin/performed", { as: "recepcion" })).status, 403);
  assert.equal((await api("GET", "/patients/1/imaging-orders/io-apro", { as: "recepcion" })).status, 403);
  assert.equal((await api("GET", "/patients/1/imaging-orders", { as: "recepcion" })).status, 403);
  assert.equal((await api("GET", "/patients/1", { as: "recepcion" })).status, 403);
});

test("/dvd-studies trae el estado del informe de cada estudio", async () => {
  const { studies } = await (await api("GET", "/patients/1/dvd-studies", { as: "recepcion" })).json();
  const byOrder = Object.fromEntries(studies.map((s) => [s.orderId, s.report]));
  assert.deepEqual(byOrder["io-apro"], { status: "aprobado", filename: "Informe Tórax.pdf" });
  assert.deepEqual(byOrder["io-pend"], { status: "pendiente", filename: null });
  assert.equal(byOrder["io-sin"], null);
});
