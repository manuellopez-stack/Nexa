import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import OpenAI from "openai";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { randomUUID } from "crypto";

dotenv.config({ quiet: true });

const app = express();
const port = 3000;
const model = process.env.OPENAI_MODEL || "gpt-5-mini";
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const dataDirectory = path.join(__dirname, "data");
const patientsFile = path.join(dataDirectory, "patients.json");

app.use(cors());
app.use(express.json({ limit: "20mb" }));

if (!process.env.OPENAI_API_KEY) {
  console.error("");
  console.error("ERROR: No se encontró OPENAI_API_KEY en backend/.env");
  console.error("");
  process.exit(1);
}

const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
});

const defaultPatients = [
  {
    id: 1,
    time: "08:30",
    name: "María Soto",
    rut: "15.234.567-8",
    age: 46,
    doctor: "Dr. Juan Pérez",
    phone: "+56 9 9876 5432",
    observations: "Paciente diabética. Ayuno confirmado.",
    exam: "Ecografía abdominal",
    room: "Sala 1",
    status: "En atención",
    risk: "BAJO",
    documents: [
      "Orden médica.pdf",
      "Consentimiento.pdf",
      "Informe anterior.pdf",
    ],
    history: [
      { date: "15/07/2026", exam: "Ecografía abdominal" },
      { date: "12/03/2026", exam: "Control médico" },
      { date: "21/11/2025", exam: "Radiografía de tórax" },
    ],
    aiSummary: null,
  },
  {
    id: 2,
    time: "08:45",
    name: "Juan Pérez",
    rut: "12.345.678-5",
    age: 52,
    doctor: "Dra. Carolina Muñoz",
    phone: "+56 9 6543 2109",
    observations: "Control anual. Sin antecedentes relevantes registrados.",
    exam: "Mamografía",
    room: "Sala 2",
    status: "Esperando",
    risk: "BAJO",
    documents: [
      "Orden médica.pdf",
      "Consentimiento.pdf",
    ],
    history: [
      { date: "10/06/2026", exam: "Mamografía" },
      { date: "08/05/2025", exam: "Control médico" },
    ],
    aiSummary: null,
  },
  {
    id: 3,
    time: "09:00",
    name: "Ana Rojas",
    rut: "18.765.432-1",
    age: 39,
    doctor: "Dr. Felipe Morales",
    phone: "+56 9 7654 3210",
    observations: "Derivada por tos persistente.",
    exam: "Rayos X de tórax",
    room: "Sala 3",
    status: "Programado",
    risk: "BAJO",
    documents: [
      "Orden médica.pdf",
      "Consentimiento.pdf",
      "Informe anterior.pdf",
    ],
    history: [
      { date: "18/01/2026", exam: "Radiografía de tórax" },
      { date: "02/08/2025", exam: "Control respiratorio" },
    ],
    aiSummary: null,
  },
  {
    id: 4,
    time: "09:15",
    name: "Carlos Díaz",
    rut: "9.876.543-2",
    age: 61,
    doctor: "Dra. Paula Silva",
    phone: "+56 9 8765 4321",
    observations: "Dolor y edema en extremidad inferior derecha.",
    exam: "Ecografía Doppler",
    room: "Sala 1",
    status: "Programado",
    risk: "MEDIO",
    documents: [
      "Orden médica.pdf",
      "Consentimiento.pdf",
      "Informe vascular anterior.pdf",
    ],
    history: [
      { date: "22/04/2026", exam: "Ecografía Doppler venosa" },
      { date: "30/09/2025", exam: "Ecografía abdominal" },
    ],
    aiSummary: null,
  },
];


function cloneDefaultPatients() {
  return JSON.parse(JSON.stringify(defaultPatients));
}

function ensureDataDirectory() {
  if (!fs.existsSync(dataDirectory)) {
    fs.mkdirSync(dataDirectory, { recursive: true });
  }
}

function savePatients() {
  ensureDataDirectory();
  fs.writeFileSync(
    patientsFile,
    JSON.stringify(patients, null, 2),
    "utf8",
  );
}

function loadPatients() {
  ensureDataDirectory();

  if (!fs.existsSync(patientsFile)) {
    const initialPatients = cloneDefaultPatients();
    fs.writeFileSync(
      patientsFile,
      JSON.stringify(initialPatients, null, 2),
      "utf8",
    );
    return initialPatients;
  }

  try {
    const raw = fs.readFileSync(patientsFile, "utf8");
    const savedPatients = JSON.parse(raw);

    if (!Array.isArray(savedPatients)) {
      throw new Error("patients.json no contiene una lista válida.");
    }

    return savedPatients;
  } catch (error) {
    console.error("No fue posible leer patients.json:", error);
    console.error("Nexa continuará con los pacientes iniciales.");
    return cloneDefaultPatients();
  }
}

let patients = loadPatients();

function getPatientById(id) {
  return patients.find((patient) => patient.id === Number(id));
}

function normalizeRut(value) {
  return typeof value === "string" ? value.toUpperCase().replace(/[^0-9K]/g, "") : "";
}

function findPatientsByRut(rut, excludeId = null) {
  const normalized = normalizeRut(rut);
  if (!normalized) return [];
  return patients.filter(
    (patient) =>
      patient.id !== Number(excludeId) &&
      normalizeRut(patient.rut) === normalized,
  );
}

function findPatientByRut(rut, excludeId = null) {
  const matches = findPatientsByRut(rut, excludeId);
  return matches.length === 1 ? matches[0] : null;
}

function getDuplicateRutGroups() {
  const groups = new Map();

  for (const patient of patients) {
    const rut = normalizeRut(patient.rut);
    if (!rut) continue;

    if (!groups.has(rut)) groups.set(rut, []);
    groups.get(rut).push(patient);
  }

  return [...groups.entries()]
    .filter(([, group]) => group.length > 1)
    .map(([rut, group]) => ({
      rut,
      patients: group.map((patient) => ({
        id: patient.id,
        name: patient.name,
        time: patient.time,
      })),
    }));
}

function buildPatientContext(patient) {
  const historyText =
    patient.history.length === 0
      ? "Sin historial registrado."
      : patient.history
          .map((item) => `- ${item.date}: ${item.exam}`)
          .join("\n");

  return `
Nombre: ${patient.name}
RUT: ${patient.rut}
Edad: ${patient.age}
Médico: ${patient.doctor}
Teléfono: ${patient.phone}
Examen: ${patient.exam}
Sala: ${patient.room}
Estado: ${patient.status}
Observaciones: ${patient.observations}
Nivel de riesgo registrado: ${patient.risk}
Prioridad: ${patient.priority ?? "Sin información"}
Fecha del documento: ${patient.documentDate ?? "Sin información"}
Equipo: ${patient.equipment ?? "Sin información"}
Resumen del documento incorporado: ${patient.documentSummary ?? "Sin información"}

Historial:
${historyText}
  `.trim();
}

async function generatePatientSummary(patient) {
  const result = await openai.responses.create({
    model,
    instructions: `
Eres Nexa, un asistente de apoyo para equipos de salud.

Tu tarea es resumir únicamente la información entregada.
Reglas:
- Responde siempre en español.
- No inventes antecedentes, diagnósticos ni resultados.
- No entregues instrucciones médicas ni reemplaces el criterio profesional.
- Si faltan datos, indícalo claramente.
- Redacta un resumen breve de máximo 5 líneas.
- Destaca el motivo del examen, antecedentes registrados e historial relevante.
    `.trim(),
    input: buildPatientContext(patient),
  });

  const summary = result.output_text?.trim();

  if (!summary) {
    throw new Error("OpenAI no entregó un resumen de texto.");
  }

  return summary;
}

app.get("/", (_request, response) => {
  response.send("Nexa Backend funcionando");
});

app.get("/health", (_request, response) => {
  response.json({
    estado: "OK",
    servicio: "Nexa Backend",
    fecha: new Date().toISOString(),
    modelo: model,
  });
});

app.get("/patients/today", (_request, response) => {
  response.json({
    fecha: new Date().toISOString().split("T")[0],
    total: patients.length,
    patients,
  });
});

// Métricas reales del dashboard, calculadas a partir de los pacientes
// registrados. No se inventan cifras (como ingresos) para las que no
// existe una fuente de datos real todavía.
app.get("/dashboard/summary", (_request, response) => {
  const KNOWN_ROOMS = ["Sala 1", "Sala 2", "Sala 3"];

  const waiting = patients.filter((p) => p.status === "Esperando").length;
  const inAttention = patients.filter((p) => p.status === "En atención").length;
  const scheduled = patients.filter((p) => p.status === "Programado").length;
  const pendingValidation = patients.filter(
    (p) => p.status === "Pendiente de validación",
  ).length;

  const totalUploadedDocuments = patients.reduce(
    (sum, p) => sum + (Array.isArray(p.documents) ? p.documents.length : 0),
    0,
  );
  const totalAnalyzedDocuments = patients.reduce(
    (sum, p) =>
      sum + (Array.isArray(p.documentRecords) ? p.documentRecords.length : 0),
    0,
  );

  const roomsInUse = new Set(
    patients
      .map((p) => p.room)
      .filter((room) => KNOWN_ROOMS.includes(room)),
  ).size;

  response.json({
    fecha: new Date().toISOString().split("T")[0],
    patientsToday: patients.length,
    waiting,
    inAttention,
    scheduled,
    pendingValidation,
    totalUploadedDocuments,
    totalAnalyzedDocuments,
    documentsAwaitingAnalysis: Math.max(
      totalUploadedDocuments - totalAnalyzedDocuments,
      0,
    ),
    roomsInUse,
    totalKnownRooms: KNOWN_ROOMS.length,
  });
});

app.get("/patients/:id", async (request, response) => {
  const patient = getPatientById(request.params.id);

  if (!patient) {
    return response.status(404).json({
      error: "Paciente no encontrado",
    });
  }

  try {
    if (!patient.aiSummary) {
      patient.aiSummary = await generatePatientSummary(patient);
      savePatients();
    }

    return response.json(patient);
  } catch (error) {
    console.error("Error al generar resumen del paciente:", error);

    return response.json({
      ...patient,
      aiSummary:
        "No fue posible generar el resumen automático en este momento.",
      aiSummaryError: true,
    });
  }
});

app.post("/patients/:id/summary", async (request, response) => {
  const patient = getPatientById(request.params.id);

  if (!patient) {
    return response.status(404).json({
      error: "Paciente no encontrado",
    });
  }

  try {
    patient.aiSummary = await generatePatientSummary(patient);
    savePatients();

    return response.json({
      patientId: patient.id,
      aiSummary: patient.aiSummary,
    });
  } catch (error) {
    console.error("Error al regenerar resumen:", error);

    return response.status(500).json({
      error: "No fue posible generar el resumen automático.",
      detalle:
        typeof error?.message === "string"
          ? error.message
          : "Error desconocido.",
    });
  }
});


app.patch("/patients/:id/from-document", async (request, response) => {
  const sourcePatient = getPatientById(request.params.id);
  if (!sourcePatient) return response.status(404).json({ error: "Paciente de origen no encontrado" });
  const documentData = request.body?.documentData;
  const requestedTargetId = request.body?.targetPatientId;
  const filename =
    typeof request.body?.filename === "string"
      ? request.body.filename.trim()
      : "";
  if (!documentData || typeof documentData !== "object") return response.status(400).json({ error: "No se recibieron datos válidos del documento." });
  if (documentData.isClinical !== true) return response.status(400).json({ error: "Solo se pueden incorporar datos desde documentos clínicos." });
  const cleanValue = (value) => { if (typeof value !== "string") return null; const c=value.trim(); return !c || c.toLowerCase()==="sin información" ? null : c; };
  const parseAge = (value) => { if (Number.isInteger(value) && value>=0 && value<=130) return value; if (typeof value==="string") { const m=value.match(/\d{1,3}/); if(m){const n=Number(m[0]); if(n>=0&&n<=130)return n;} } return null; };
  const patientName=cleanValue(documentData.patientName), patientRut=cleanValue(documentData.patientRut), patientAge=parseAge(documentData.patientAge), exam=cleanValue(documentData.exam), doctor=cleanValue(documentData.doctor), reason=cleanValue(documentData.reason), priority=cleanValue(documentData.priority), date=cleanValue(documentData.date), equipment=cleanValue(documentData.equipment), summary=cleanValue(documentData.summary);
  const incomingRut=normalizeRut(patientRut), sourceRut=normalizeRut(sourcePatient.rut);
  const identityDiffers=incomingRut && sourceRut && incomingRut!==sourceRut;
  let targetPatient=sourcePatient; let routedToExistingPatient=false;
  if (identityDiffers) {
    const matches = findPatientsByRut(patientRut, sourcePatient.id);

    if (matches.length === 0) {
      return response.status(409).json({
        error:
          "El documento corresponde a otro RUT y no existe una ficha coincidente. Nexa no modificó la ficha original.",
      });
    }

    if (matches.length > 1) {
      return response.status(409).json({
        error:
          "Nexa encontró más de una ficha con el mismo RUT. Debes corregir los duplicados antes de incorporar el documento.",
      });
    }

    const existingPatient = matches[0];

    if (Number(requestedTargetId) !== existingPatient.id) {
      return response.status(409).json({
        error:
          "Este paciente ya existe. Debes confirmar la incorporación a su ficha existente.",
      });
    }

    targetPatient = existingPatient;
    routedToExistingPatient = true;
  }
  if(patientName)targetPatient.name=patientName; if(patientRut)targetPatient.rut=patientRut; if(patientAge!==null)targetPatient.age=patientAge; if(exam)targetPatient.exam=exam; if(doctor)targetPatient.doctor=doctor; if(reason)targetPatient.observations=reason; if(priority)targetPatient.priority=priority; if(date)targetPatient.documentDate=date; if(equipment)targetPatient.equipment=equipment; if(summary)targetPatient.documentSummary=summary;

  // V4.1: el PDF queda registrado únicamente en la ficha de destino.
  // Si una versión anterior lo dejó por error en la ficha de origen,
  // al volver a incorporarlo lo retiramos de allí.
  if (filename) {
    if (!Array.isArray(targetPatient.documents)) targetPatient.documents = [];

    const normalizeDocumentName = (value) =>
      typeof value === "string"
        ? value
            .trim()
            .toLowerCase()
            .replace(/\.pdf$/i, "")
            .replace(/[^a-z0-9áéíóúüñ]+/gi, "")
        : "";

    const normalizedFilename = normalizeDocumentName(filename);

    // V4.3: limpieza robusta. Compara el nombre ignorando espacios,
    // guiones, puntos, dobles espacios y mayúsculas/minúsculas.
    // Así también elimina asociaciones antiguas con pequeñas variaciones
    // del mismo nombre de archivo.
    for (const otherPatient of patients) {
      if (otherPatient.id === targetPatient.id) continue;
      if (!Array.isArray(otherPatient.documents)) continue;

      otherPatient.documents = otherPatient.documents.filter((documentName) => {
        if (typeof documentName !== "string") return true;
        return normalizeDocumentName(documentName) !== normalizedFilename;
      });
    }

    const alreadyInTarget = targetPatient.documents.some(
      (documentName) =>
        typeof documentName === "string" &&
        normalizeDocumentName(documentName) === normalizedFilename,
    );

    if (!alreadyInTarget) {
      targetPatient.documents.push(filename);
    }
  }

  if (!Array.isArray(targetPatient.documentRecords)) targetPatient.documentRecords = [];
  if (filename) {
    const normalizeStoredName = (value) => typeof value === "string"
      ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
      : "";
    const normalizedStoredFilename = normalizeStoredName(filename);
    const recordIndex = targetPatient.documentRecords.findIndex(
      (item) => item && normalizeStoredName(item.filename) === normalizedStoredFilename,
    );
    // V8: cada documento tiene una identidad propia (id) que no cambia aunque
    // se vuelva a analizar o reincorporar el mismo archivo.
    const existingId = recordIndex >= 0 ? targetPatient.documentRecords[recordIndex].id : null;
    const record = {
      id: existingId ?? randomUUID(),
      filename, incorporatedAt: new Date().toISOString(),
      isClinical: documentData.isClinical === true,
      documentType: cleanValue(documentData.documentType),
      patientName, patientRut, patientAge, exam, doctor, reason, priority, date, equipment, summary,
      // V11: cada documento requiere validación humana antes de darse por
      // definitivo. Se reinicia a "pendiente" cada vez que se (re)incorpora,
      // ya que una nueva extracción es información nueva que aún no ha sido
      // revisada por un profesional.
      validationStatus: "pendiente",
      validatedAt: null,
    };
    if (recordIndex >= 0) targetPatient.documentRecords[recordIndex] = record;
    else targetPatient.documentRecords.push(record);

    // V9: cada documento incorporado con un examen identificado genera (o
    // actualiza) un evento en el historial del paciente. Se usa el id del
    // propio documento para no duplicar el evento si se vuelve a incorporar.
    if (exam) {
      if (!Array.isArray(targetPatient.history)) targetPatient.history = [];

      const historyEntry = {
        date: date ?? new Date().toLocaleDateString("es-CL"),
        exam,
        summary: summary ?? null,
        sourceDocumentId: record.id,
      };

      const historyIndex = targetPatient.history.findIndex(
        (item) => item && item.sourceDocumentId === record.id,
      );

      if (historyIndex >= 0) targetPatient.history[historyIndex] = historyEntry;
      else targetPatient.history.unshift(historyEntry);
    }
  }

  targetPatient.aiSummary=null;
  try{targetPatient.aiSummary=await generatePatientSummary(targetPatient);}catch(error){console.error("No fue posible regenerar el resumen:",error);}
  savePatients();
  return response.json({ok:true,routedToExistingPatient,sourcePatientId:sourcePatient.id,targetPatientId:targetPatient.id,message:routedToExistingPatient?`Documento incorporado a la ficha existente de ${targetPatient.name}. La ficha original no fue modificada.`:"Información incorporada y guardada correctamente en la ficha.",patient:targetPatient});
});

app.get("/patients/:id/documents/:filename", (request, response) => {
  const patient = getPatientById(request.params.id);
  if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });
  const filename = decodeURIComponent(request.params.filename);
  const normalizeName = (value) => typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
  const normalized = normalizeName(filename);
  const records = Array.isArray(patient.documentRecords) ? patient.documentRecords : [];
  const record = records.find((item) => item && normalizeName(item.filename) === normalized);
  if (!record) return response.status(404).json({
    error: "Este documento todavía no tiene información detallada guardada. Vuelve a analizarlo e incorporarlo para habilitar su consulta.",
  });
  return response.json({ patientId: patient.id, patientName: patient.name, document: record });
});

// V11: validación humana por documento. Un profesional aprueba o rechaza
// la información que la IA extrajo antes de que se considere definitiva.
app.patch("/patients/:id/documents/:filename/validate", (request, response) => {
  const patient = getPatientById(request.params.id);
  if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

  const filename = decodeURIComponent(request.params.filename);
  const normalizeName = (value) => typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
  const normalized = normalizeName(filename);

  const validStatuses = ["pendiente", "aprobado", "rechazado"];
  const status = request.body?.status;

  if (!validStatuses.includes(status)) {
    return response.status(400).json({
      error: "Estado de validación inválido. Debe ser pendiente, aprobado o rechazado.",
    });
  }

  const records = Array.isArray(patient.documentRecords) ? patient.documentRecords : [];
  const record = records.find((item) => item && normalizeName(item.filename) === normalized);

  if (!record) {
    return response.status(404).json({
      error: "Este documento no tiene información detallada guardada todavía.",
    });
  }

  record.validationStatus = status;
  record.validatedAt = status === "pendiente" ? null : new Date().toISOString();

  savePatients();

  return response.json({
    patientId: patient.id,
    filename,
    document: record,
    patient,
  });
});

// V8: gestión real de documentos — permite retirar un documento de la ficha
// (tanto de la lista simple "documents" como de su registro estructurado).
app.delete("/patients/:id/documents/:filename", (request, response) => {
  const patient = getPatientById(request.params.id);
  if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

  const filename = decodeURIComponent(request.params.filename);
  const normalizeName = (value) => typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
  const normalized = normalizeName(filename);

  const hadDocument =
    Array.isArray(patient.documents) &&
    patient.documents.some((name) => normalizeName(name) === normalized);
  const matchingRecord = Array.isArray(patient.documentRecords)
    ? patient.documentRecords.find(
        (item) => item && normalizeName(item.filename) === normalized,
      )
    : null;
  const hadRecord = Boolean(matchingRecord);

  if (!hadDocument && !hadRecord) {
    return response.status(404).json({
      error: "Este documento no está registrado en la ficha del paciente.",
    });
  }

  if (Array.isArray(patient.documents)) {
    patient.documents = patient.documents.filter(
      (name) => normalizeName(name) !== normalized,
    );
  }

  if (Array.isArray(patient.documentRecords)) {
    patient.documentRecords = patient.documentRecords.filter(
      (item) => !(item && normalizeName(item.filename) === normalized),
    );
  }

  // V9: si el documento eliminado había generado un evento de historial,
  // lo retiramos también para no dejar historial huérfano.
  if (matchingRecord && Array.isArray(patient.history)) {
    patient.history = patient.history.filter(
      (item) => !(item && item.sourceDocumentId === matchingRecord.id),
    );
  }

  savePatients();

  return response.json({
    ok: true,
    patientId: patient.id,
    filename,
    patient,
  });
});

app.post("/patients/:id/documents/:filename/ask", async (request, response) => {
  const patient = getPatientById(request.params.id);
  if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

  const filename = decodeURIComponent(request.params.filename);
  const question = typeof request.body?.question === "string" ? request.body.question.trim() : "";
  if (!question) return response.status(400).json({ error: "Debes escribir una pregunta sobre el documento." });

  const normalizeName = (value) => typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
  const records = Array.isArray(patient.documentRecords) ? patient.documentRecords : [];
  const record = records.find((item) => item && normalizeName(item.filename) === normalizeName(filename));
  if (!record) return response.status(404).json({
    error: "Este documento todavía no tiene información detallada guardada. Vuelve a analizarlo e incorporarlo para poder consultarlo.",
  });

  const documentContext = JSON.stringify({
    filename: record.filename,
    documentType: record.documentType,
    patientName: record.patientName,
    patientRut: record.patientRut,
    patientAge: record.patientAge,
    exam: record.exam,
    doctor: record.doctor,
    reason: record.reason,
    priority: record.priority,
    date: record.date,
    equipment: record.equipment,
    summary: record.summary,
  }, null, 2);

  try {
    const result = await openai.responses.create({
      model,
      instructions: `
Eres Nexa, un asistente de apoyo para la consulta de documentos clínicos ya incorporados.

Reglas estrictas:
- Responde siempre en español.
- Responde ÚNICAMENTE con la información del documento guardado que se entrega como contexto.
- No uses otros antecedentes de la ficha del paciente ni conocimiento externo para completar datos.
- No inventes diagnósticos, resultados, fechas ni recomendaciones.
- Si la respuesta no está contenida en el documento guardado, dilo claramente.
- No reemplaces el criterio de un profesional de salud.
- Sé claro, breve y práctico.
      `.trim(),
      input: `DOCUMENTO GUARDADO:\n${documentContext}\n\nPREGUNTA DEL USUARIO:\n${question}`,
    });

    const answer = result.output_text?.trim();
    if (!answer) return response.status(502).json({ error: "OpenAI no entregó una respuesta de texto." });
    return response.json({ patientId: patient.id, filename: record.filename, respuesta: answer });
  } catch (error) {
    console.error("Error al consultar documento con Nexa:", error);
    const status = typeof error?.status === "number" ? error.status : 500;
    return response.status(status).json({
      error: "No fue posible consultar este documento con Nexa.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.post("/patients/:id/documents/analyze", async (request, response) => {
  const patient = getPatientById(request.params.id);

  if (!patient) {
    return response.status(404).json({
      error: "Paciente no encontrado",
    });
  }

  const filename = request.body?.filename;
  const base64Data = request.body?.base64Data;

  if (
    typeof filename !== "string" ||
    !filename.toLowerCase().endsWith(".pdf") ||
    typeof base64Data !== "string" ||
    base64Data.trim().length === 0
  ) {
    return response.status(400).json({
      error: "Debes enviar un archivo PDF válido.",
    });
  }

  if (base64Data.length > 14_000_000) {
    return response.status(413).json({
      error: "El PDF supera el tamaño máximo permitido de 10 MB.",
    });
  }

  try {
    const result = await openai.responses.create({
      model,
      instructions: `
Eres Nexa, un asistente para apoyar la revisión documental.

Analiza únicamente el PDF y la ficha entregada.
No inventes datos ni completes información ausente.
No emitas diagnósticos ni reemplaces el criterio profesional.

Devuelve SOLO un objeto JSON válido, sin Markdown ni texto adicional, con estas claves exactas:
{
  "documentType": "string",
  "isClinical": true,
  "patientName": "string o Sin información",
  "patientRut": "string o Sin información",
  "patientAge": 0,
  "exam": "string o Sin información",
  "doctor": "string o Sin información",
  "priority": "string o Sin información",
  "date": "string o Sin información",
  "reason": "string o Sin información",
  "equipment": "string o Sin información",
  "summary": "resumen breve del documento",
  "missingData": ["dato faltante 1", "dato faltante 2"],
  "differences": ["diferencia con la ficha 1"]
}

Para "patientAge", devuelve un número entero SOLO si la edad aparece explícitamente en el documento; si no aparece, usa null.
Si el documento no es clínico, usa isClinical=false y extrae igualmente la información útil disponible.
      `.trim(),
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: `FICHA ACTUAL DEL PACIENTE:\n${buildPatientContext(patient)}\n\nAnaliza el PDF adjunto y compáralo con esta ficha.`,
            },
            {
              type: "input_file",
              filename,
              file_data: `data:application/pdf;base64,${base64Data}`,
            },
          ],
        },
      ],
    });

    const raw = result.output_text?.trim();

    if (!raw) {
      return response.status(502).json({
        error: "OpenAI no entregó un análisis del documento.",
      });
    }

    let clean = raw;
    if (clean.startsWith("```")) {
      clean = clean
        .replace(/^```(?:json)?\s*/i, "")
        .replace(/\s*```$/, "");
    }

    let documentData;
    try {
      documentData = JSON.parse(clean);
    } catch (parseError) {
      console.error("Respuesta no JSON de OpenAI:", raw);
      return response.status(502).json({
        error: "Nexa recibió un análisis que no pudo estructurar.",
      });
    }

    const missing = Array.isArray(documentData.missingData)
      ? documentData.missingData
      : [];
    const differences = Array.isArray(documentData.differences)
      ? documentData.differences
      : [];

    const matchingPatients =
      documentData.isClinical === true
        ? findPatientsByRut(documentData.patientRut, patient.id)
        : [];

    const existingPatientMatch =
      matchingPatients.length === 1 ? matchingPatients[0] : null;

    const analysisLines = [
      `Tipo de documento: ${documentData.documentType ?? "Sin información"}`,
      `Documento clínico: ${documentData.isClinical === true ? "Sí" : "No"}`,
      `Paciente: ${documentData.patientName ?? "Sin información"}`,
      `RUT: ${documentData.patientRut ?? "Sin información"}`,
      `Edad: ${documentData.patientAge ?? "Sin información"}`,
      `Examen: ${documentData.exam ?? "Sin información"}`,
      `Médico: ${documentData.doctor ?? "Sin información"}`,
      `Prioridad: ${documentData.priority ?? "Sin información"}`,
      `Fecha: ${documentData.date ?? "Sin información"}`,
      `Motivo: ${documentData.reason ?? "Sin información"}`,
      `Equipo: ${documentData.equipment ?? "Sin información"}`,
      "",
      `Resumen: ${documentData.summary ?? "Sin información"}`,
      "",
      `Datos faltantes: ${missing.length ? missing.join(", ") : "Ninguno informado"}`,
      `Diferencias con la ficha: ${differences.length ? differences.join(" | ") : "No se informaron diferencias"}`,
    ];

    // El análisis por sí solo no asocia el archivo a ninguna ficha.
    // La asociación se realiza únicamente al confirmar "Incorporar datos a la ficha".
    return response.json({
      patientId: patient.id,
      filename,
      analysis: analysisLines.join("\n"),
      documentData,
      existingPatient: existingPatientMatch
        ? {
            id: existingPatientMatch.id,
            name: existingPatientMatch.name,
            rut: existingPatientMatch.rut,
          }
        : null,
      duplicateRutCount: matchingPatients.length > 1 ? matchingPatients.length : 0,
    });
  } catch (error) {
    console.error("Error al analizar PDF:", error);

    const status =
      typeof error?.status === "number"
        ? error.status
        : 500;

    return response.status(status).json({
      error: "No fue posible analizar el documento.",
      detalle:
        typeof error?.message === "string"
          ? error.message
          : "Error desconocido.",
    });
  }
});

app.post("/chat", async (request, response) => {
  try {
    const message = request.body?.message;

    if (typeof message !== "string" || message.trim().length === 0) {
      return response.status(400).json({
        error: "Debes enviar un mensaje válido.",
      });
    }

    const result = await openai.responses.create({
      model,
      instructions: `
Eres Nexa, un asistente de inteligencia artificial para empresas y equipos de salud.

Reglas:
- Responde siempre en español.
- Utiliza un tono claro, profesional y práctico.
- No inventes datos.
- Indica cuando falte información.
- No reemplaces la evaluación de un profesional de salud.
- Organiza las respuestas extensas con títulos.
      `.trim(),
      input: message.trim(),
    });

    const answer = result.output_text?.trim();

    if (!answer) {
      return response.status(502).json({
        error: "OpenAI no entregó una respuesta de texto.",
      });
    }

    return response.json({
      respuesta: answer,
    });
  } catch (error) {
    console.error("");
    console.error("Error al consultar OpenAI:");
    console.error(error);
    console.error("");

    const status =
      typeof error?.status === "number"
        ? error.status
        : 500;

    let publicMessage =
      "No fue posible consultar la inteligencia artificial.";

    if (status === 401) {
      publicMessage =
        "La API Key no es válida, fue revocada o no está siendo leída.";
    } else if (status === 403) {
      publicMessage =
        "La cuenta o el proyecto no tiene permiso para utilizar este recurso.";
    } else if (status === 429) {
      publicMessage =
        "La cuenta alcanzó un límite de uso o no tiene saldo disponible.";
    }

    return response.status(status).json({
      error: publicMessage,
      detalle:
        typeof error?.message === "string"
          ? error.message
          : "Error desconocido.",
    });
  }
});

app.listen(port, () => {
  const duplicateRutGroups = getDuplicateRutGroups();

  if (duplicateRutGroups.length > 0) {
    console.warn("");
    console.warn("ADVERTENCIA: se detectaron RUT duplicados en patients.json:");
    console.warn(JSON.stringify(duplicateRutGroups, null, 2));
    console.warn("");
  }

  console.log("");
  console.log("========================================");
  console.log("Nexa Backend iniciado correctamente");
  console.log(`Servidor: http://localhost:${port}`);
  console.log(`Estado:   http://localhost:${port}/health`);
  console.log(`Modelo:   ${model}`);
  console.log("========================================");
  console.log("");
});
