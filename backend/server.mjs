import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import OpenAI from "openai";
import { createClient } from "@supabase/supabase-js";
import dicomParser from "dicom-parser";
import sharp from "sharp";
dotenv.config({ quiet: true });

const app = express();
const port = 3000;
const model = process.env.OPENAI_MODEL || "gpt-5-mini";

app.use(cors());
app.use(express.json({ limit: "50mb" }));

if (!process.env.OPENAI_API_KEY) {
  console.error("");
  console.error("ERROR: No se encontró OPENAI_API_KEY en backend/.env");
  console.error("");
  process.exit(1);
}

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  console.error("");
  console.error("ERROR: Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY en backend/.env");
  console.error("");
  process.exit(1);
}

if (!process.env.SUPABASE_PUBLISHABLE_KEY) {
  console.error("");
  console.error("ERROR: Falta SUPABASE_PUBLISHABLE_KEY en backend/.env (la clave 'anon'/'publishable' de Supabase, necesaria para el login).");
  console.error("");
  process.exit(1);
}

const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
});

// Cliente con clave de administrador: para leer/escribir datos sin
// restricciones (usado en toda la lógica de pacientes/documentos).
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
);

// Cliente con la clave pública: solo se usa para validar inicios de sesión
// de usuarios reales (nunca para leer datos de pacientes directamente).
const supabaseAuth = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_PUBLISHABLE_KEY,
);

// V13: exige una sesión válida (token entregado por /auth/login) para
// acceder a cualquier dato de pacientes.
async function requireAuth(request, response, next) {
  const authHeader = request.headers.authorization || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;

  if (!token) {
    return response.status(401).json({ error: "No has iniciado sesión." });
  }

  const { data, error } = await supabaseAuth.auth.getUser(token);

  if (error || !data?.user) {
    return response.status(401).json({ error: "Tu sesión expiró o no es válida. Vuelve a iniciar sesión." });
  }

  request.user = data.user;
  next();
}

function normalizeRut(value) {
  return typeof value === "string" ? value.toUpperCase().replace(/[^0-9K]/g, "") : "";
}

function normalizeDocumentName(value) {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
}

// ---- Helpers para transformar filas de Supabase (snake_case) al formato
// que la app Flutter ya espera (camelCase). Esto es lo que permite que el
// frontend no necesite ningún cambio con esta migración.

function shapePatientRow(row) {
  return {
    id: row.id,
    time: row.time,
    name: row.name,
    rut: row.rut,
    age: row.age,
    doctor: row.doctor,
    phone: row.phone,
    exam: row.exam,
    room: row.room,
    status: row.status,
    observations: row.observations,
    priority: row.priority,
    risk: row.risk,
    sexo: row.sexo,
    aiSummary: row.ai_summary,
  };
}

function shapeDocumentRecord(row) {
  return {
    id: row.id,
    filename: row.filename,
    documentType: row.document_type,
    exam: row.exam,
    patientName: row.patient_name,
    patientRut: row.patient_rut,
    patientAge: row.patient_age,
    reason: row.reason,
    priority: row.priority,
    isClinical: row.is_clinical,
    date: row.date,
    summary: row.summary,
    equipment: row.equipment,
    doctor: row.doctor,
    validationStatus: row.validation_status,
    validatedAt: row.validated_at,
    incorporatedAt: row.incorporated_at,
  };
}

function shapeHistoryEvent(row) {
  return {
    date: row.date,
    exam: row.exam,
    summary: row.summary,
  };
}

async function getPatientFull(id) {
  const patientId = Number(id);
  if (!Number.isInteger(patientId)) return null;

  const { data: patientRow, error: patientError } = await supabase
    .from("patients")
    .select("*")
    .eq("id", patientId)
    .maybeSingle();

  if (patientError) throw patientError;
  if (!patientRow) return null;

  const { data: documentRows, error: documentsError } = await supabase
    .from("documents")
    .select("*")
    .eq("patient_id", patientId)
    .order("incorporated_at", { ascending: true });

  if (documentsError) throw documentsError;

  const { data: historyRows, error: historyError } = await supabase
    .from("history_events")
    .select("*")
    .eq("patient_id", patientId)
    .order("id", { ascending: false });

  if (historyError) throw historyError;

  return {
    ...shapePatientRow(patientRow),
    documents: (documentRows ?? []).map((row) => row.filename).filter(Boolean),
    documentRecords: (documentRows ?? []).map(shapeDocumentRecord),
    history: (historyRows ?? []).map(shapeHistoryEvent),
  };
}

async function findPatientsByRutDb(rut, excludeId = null) {
  const normalized = normalizeRut(rut);
  if (!normalized) return [];

  const { data, error } = await supabase.from("patients").select("id, name, rut");
  if (error) throw error;

  return (data ?? []).filter(
    (patient) =>
      patient.id !== Number(excludeId) && normalizeRut(patient.rut) === normalized,
  );
}

async function getDuplicateRutGroupsDb() {
  const { data, error } = await supabase.from("patients").select("id, name, time, rut");
  if (error) {
    console.error("No fue posible verificar RUT duplicados:", error.message);
    return [];
  }

  const groups = new Map();
  for (const patient of data ?? []) {
    const rut = normalizeRut(patient.rut);
    if (!rut) continue;
    if (!groups.has(rut)) groups.set(rut, []);
    groups.get(rut).push(patient);
  }

  return [...groups.entries()]
    .filter(([, group]) => group.length > 1)
    .map(([rut, group]) => ({
      rut,
      patients: group.map((patient) => ({ id: patient.id, name: patient.name, time: patient.time })),
    }));
}

function buildPatientContext(patient) {
  const history = Array.isArray(patient.history) ? patient.history : [];
  const historyText =
    history.length === 0
      ? "Sin historial registrado."
      : history
          .map((item) => {
            const summaryPart = item.summary ? ` — ${item.summary}` : "";
            return `- ${item.date ?? "Sin fecha"}: ${item.exam ?? "Sin examen"}${summaryPart}`;
          })
          .join("\n");

  const documentRecords = Array.isArray(patient.documentRecords) ? patient.documentRecords : [];
  const documentsText =
    documentRecords.length === 0
      ? "Sin documentos incorporados todavía."
      : documentRecords
          .map((doc) => {
            const summaryPart = doc.summary ? `\n  ${doc.summary}` : "";
            return `- [${doc.date ?? "Sin fecha"}] ${doc.documentType ?? doc.exam ?? "Documento"}${summaryPart}`;
          })
          .join("\n");

  const latestDocument = documentRecords[documentRecords.length - 1] ?? null;

  return `
Nombre: ${patient.name ?? "Sin información"}
RUT: ${patient.rut ?? "Sin información"}
Edad: ${patient.age ?? "Sin información"}
Médico: ${patient.doctor ?? "Sin información"}
Teléfono: ${patient.phone ?? "Sin información"}
Examen: ${patient.exam ?? "Sin información"}
Sala: ${patient.room ?? "Sin información"}
Estado: ${patient.status ?? "Sin información"}
Observaciones: ${patient.observations ?? "Sin información"}
Nivel de riesgo registrado: ${patient.risk ?? "Sin información"}
Prioridad: ${patient.priority ?? "Sin información"}
Fecha del último documento: ${latestDocument?.date ?? "Sin información"}
Equipo del último documento: ${latestDocument?.equipment ?? "Sin información"}
Resumen del último documento incorporado: ${latestDocument?.summary ?? "Sin información"}

Historial:
${historyText}

Documentos incorporados (con su resumen clínico):
${documentsText}
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

app.post("/auth/login", async (request, response) => {
  const email = typeof request.body?.email === "string" ? request.body.email.trim() : "";
  const password = typeof request.body?.password === "string" ? request.body.password : "";

  if (!email || !password) {
    return response.status(400).json({ error: "Debes ingresar tu email y tu contraseña." });
  }

  const { data, error } = await supabaseAuth.auth.signInWithPassword({ email, password });

  if (error || !data?.session) {
    return response.status(401).json({ error: "Email o contraseña incorrectos." });
  }

  return response.json({
    accessToken: data.session.access_token,
    user: {
      id: data.user.id,
      email: data.user.email,
    },
  });
});

// A partir de aquí, todas las rutas requieren haber iniciado sesión.
app.use("/patients", requireAuth);
app.use("/dashboard", requireAuth);
app.use("/chat", requireAuth);

app.get("/patients/today", async (_request, response) => {
  try {
    const { data, error } = await supabase
      .from("patients")
      .select("*")
      .order("time", { ascending: true });

    if (error) throw error;

    const patients = (data ?? []).map(shapePatientRow);

    return response.json({
      fecha: new Date().toISOString().split("T")[0],
      total: patients.length,
      patients,
    });
  } catch (error) {
    console.error("Error al obtener pacientes de hoy:", error);
    return response.status(500).json({ error: "No fue posible obtener los pacientes." });
  }
});

// Métricas reales del dashboard, calculadas desde la base de datos.
app.get("/dashboard/summary", async (_request, response) => {
  try {
    const KNOWN_ROOMS = ["Sala 1", "Sala 2", "Sala 3"];

    const { data: patientRows, error: patientsError } = await supabase
      .from("patients")
      .select("id, status, room");
    if (patientsError) throw patientsError;

    const patients = patientRows ?? [];
    const waiting = patients.filter((p) => p.status === "Esperando").length;
    const inAttention = patients.filter((p) => p.status === "En atención").length;
    const scheduled = patients.filter((p) => p.status === "Programado").length;
    const pendingValidation = patients.filter(
      (p) => p.status === "Pendiente de validación",
    ).length;
    const roomsInUse = new Set(
      patients.map((p) => p.room).filter((room) => KNOWN_ROOMS.includes(room)),
    ).size;

    const { count: documentsCount, error: docsCountError } = await supabase
      .from("documents")
      .select("id", { count: "exact", head: true });
    if (docsCountError) throw docsCountError;

    const totalDocuments = documentsCount ?? 0;

    return response.json({
      fecha: new Date().toISOString().split("T")[0],
      patientsToday: patients.length,
      waiting,
      inAttention,
      scheduled,
      pendingValidation,
      totalUploadedDocuments: totalDocuments,
      totalAnalyzedDocuments: totalDocuments,
      documentsAwaitingAnalysis: 0,
      roomsInUse,
      totalKnownRooms: KNOWN_ROOMS.length,
    });
  } catch (error) {
    console.error("Error al calcular el resumen del dashboard:", error);
    return response.status(500).json({ error: "No fue posible calcular el resumen." });
  }
});

app.get("/patients/:id", async (request, response) => {
  try {
    const patient = await getPatientFull(request.params.id);
    if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

    if (!patient.aiSummary) {
      try {
        const aiSummary = await generatePatientSummary(patient);
        const { error: updateError } = await supabase
          .from("patients")
          .update({ ai_summary: aiSummary })
          .eq("id", patient.id);
        if (updateError) throw updateError;
        patient.aiSummary = aiSummary;
      } catch (summaryError) {
        console.error("Error al generar resumen del paciente:", summaryError);
        return response.json({
          ...patient,
          aiSummary: "No fue posible generar el resumen automático en este momento.",
          aiSummaryError: true,
        });
      }
    }

    return response.json(patient);
  } catch (error) {
    console.error("Error al obtener paciente:", error);
    return response.status(500).json({ error: "No fue posible obtener el paciente." });
  }
});

app.post("/patients/:id/summary", async (request, response) => {
  try {
    const patient = await getPatientFull(request.params.id);
    if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

    const aiSummary = await generatePatientSummary(patient);
    const { error: updateError } = await supabase
      .from("patients")
      .update({ ai_summary: aiSummary })
      .eq("id", patient.id);
    if (updateError) throw updateError;

    return response.json({ patientId: patient.id, aiSummary });
  } catch (error) {
    console.error("Error al regenerar resumen:", error);
    return response.status(500).json({
      error: "No fue posible generar el resumen automático.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.patch("/patients/:id/from-document", async (request, response) => {
  try {
    const sourcePatient = await getPatientFull(request.params.id);
    if (!sourcePatient) return response.status(404).json({ error: "Paciente de origen no encontrado" });

    const documentData = request.body?.documentData;
    const requestedTargetId = request.body?.targetPatientId;
        const imagingOrderId = request.body?.imagingOrderId;
    const filename =
      typeof request.body?.filename === "string" ? request.body.filename.trim() : "";

    if (!documentData || typeof documentData !== "object") {
      return response.status(400).json({ error: "No se recibieron datos válidos del documento." });
    }
    if (documentData.isClinical !== true) {
      return response.status(400).json({ error: "Solo se pueden incorporar datos desde documentos clínicos." });
    }

    const cleanValue = (value) => {
      if (typeof value !== "string") return null;
      const c = value.trim();
      return !c || c.toLowerCase() === "sin información" ? null : c;
    };
    const parseAge = (value) => {
      if (Number.isInteger(value) && value >= 0 && value <= 130) return value;
      if (typeof value === "string") {
        const m = value.match(/\d{1,3}/);
        if (m) {
          const n = Number(m[0]);
          if (n >= 0 && n <= 130) return n;
        }
      }
      return null;
    };

    const patientName = cleanValue(documentData.patientName);
    const patientRut = cleanValue(documentData.patientRut);
    const patientAge = parseAge(documentData.patientAge);
    const exam = cleanValue(documentData.exam);
    const doctor = cleanValue(documentData.doctor);
    const reason = cleanValue(documentData.reason);
    const priority = cleanValue(documentData.priority);
    const date = cleanValue(documentData.date);
    const equipment = cleanValue(documentData.equipment);
    const summary = cleanValue(documentData.summary);
    const documentType = cleanValue(documentData.documentType);

    const incomingRut = normalizeRut(patientRut);
    const sourceRut = normalizeRut(sourcePatient.rut);
    const identityDiffers = incomingRut && sourceRut && incomingRut !== sourceRut;

    let targetPatient = sourcePatient;
    let routedToExistingPatient = false;

    if (identityDiffers) {
      const matches = await findPatientsByRutDb(patientRut, sourcePatient.id);

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

      const existingPatientId = matches[0].id;
      if (Number(requestedTargetId) !== existingPatientId) {
        return response.status(409).json({
          error: "Este paciente ya existe. Debes confirmar la incorporación a su ficha existente.",
        });
      }

      targetPatient = await getPatientFull(existingPatientId);
      routedToExistingPatient = true;
    }

    const patientUpdate = {};
    if (patientName) patientUpdate.name = patientName;
    if (patientRut) patientUpdate.rut = patientRut;
    if (patientAge !== null) patientUpdate.age = patientAge;
    if (exam) patientUpdate.exam = exam;
    if (doctor) patientUpdate.doctor = doctor;
    if (reason) patientUpdate.observations = reason;
    if (priority) patientUpdate.priority = priority;

    if (Object.keys(patientUpdate).length > 0) {
      const { error: patientUpdateError } = await supabase
        .from("patients")
        .update(patientUpdate)
        .eq("id", targetPatient.id);
      if (patientUpdateError) throw patientUpdateError;
    }

    if (filename) {
      const normalizedFilename = normalizeDocumentName(filename);

      // Si el mismo archivo quedó por error asociado a otra ficha, lo
      // retiramos de ahí (equivalente a la limpieza cruzada de antes).
      const { data: otherDocs, error: otherDocsError } = await supabase
        .from("documents")
        .select("id, filename")
        .neq("patient_id", targetPatient.id);
      if (otherDocsError) throw otherDocsError;

      const crossedDocs = (otherDocs ?? []).filter(
        (doc) => normalizeDocumentName(doc.filename) === normalizedFilename,
      );
      for (const doc of crossedDocs) {
        await supabase.from("history_events").delete().eq("document_id", doc.id);
        await supabase.from("documents").delete().eq("id", doc.id);
      }

      const { data: existingDocs, error: existingDocsError } = await supabase
        .from("documents")
        .select("id, filename")
        .eq("patient_id", targetPatient.id);
      if (existingDocsError) throw existingDocsError;

      const existingDoc = (existingDocs ?? []).find(
        (doc) => normalizeDocumentName(doc.filename) === normalizedFilename,
      );

      const documentRow = {
        patient_id: targetPatient.id,
        filename,
        document_type: documentType,
        exam,
        patient_name: patientName,
        patient_rut: patientRut,
        patient_age: patientAge,
        reason,
        priority,
        is_clinical: true,
        date,
        summary,
        equipment,
        doctor,
        // Cada vez que se (re)incorpora un documento, su validación humana
        // vuelve a quedar pendiente: es información nueva que todavía no
        // ha sido revisada por un profesional.
        validation_status: "pendiente",
        validated_at: null,
        incorporated_at: new Date().toISOString(),
      };

      let savedDocId;
      if (existingDoc) {
        const { data, error } = await supabase
          .from("documents")
          .update(documentRow)
          .eq("id", existingDoc.id)
          .select()
          .single();
        if (error) throw error;
        savedDocId = data.id;
      } else {
        const { data, error } = await supabase
          .from("documents")
          .insert(documentRow)
          .select()
          .single();
        if (error) throw error;
        savedDocId = data.id;
      }

      if (exam) {
        const historyEntry = {
          patient_id: targetPatient.id,
          document_id: savedDocId,
          date: date ?? new Date().toLocaleDateString("es-CL"),
          exam,
          summary,
        };

        const { data: existingHistory, error: existingHistoryError } = await supabase
          .from("history_events")
          .select("id")
          .eq("document_id", savedDocId)
          .maybeSingle();
        if (existingHistoryError) throw existingHistoryError;

        if (existingHistory) {
          const { error } = await supabase
            .from("history_events")
            .update(historyEntry)
            .eq("id", existingHistory.id);
          if (error) throw error;
        } else {
          const { error } = await supabase.from("history_events").insert(historyEntry);
          if (error) throw error;
               }
      }

      if (imagingOrderId) {
        const { error: linkError } = await supabase
          .from("documents")
          .update({ imaging_order_id: imagingOrderId })
          .eq("id", savedDocId);
        if (linkError) throw linkError;

        const { error: orderUpdateError } = await supabase
          .from("imaging_orders")
          .update({ status: "informado", informed_at: new Date().toISOString() })
          .eq("id", imagingOrderId)
          .eq("patient_id", targetPatient.id);
        if (orderUpdateError) throw orderUpdateError;
      }
    }

    const refreshedPatient = await getPatientFull(targetPatient.id);

    try {
      const aiSummary = await generatePatientSummary(refreshedPatient);
      await supabase.from("patients").update({ ai_summary: aiSummary }).eq("id", targetPatient.id);
      refreshedPatient.aiSummary = aiSummary;
    } catch (error) {
      console.error("No fue posible regenerar el resumen:", error);
    }

    return response.json({
      ok: true,
      routedToExistingPatient,
      sourcePatientId: sourcePatient.id,
      targetPatientId: targetPatient.id,
      message: routedToExistingPatient
        ? `Documento incorporado a la ficha existente de ${refreshedPatient.name}. La ficha original no fue modificada.`
        : "Información incorporada y guardada correctamente en la ficha.",
      patient: refreshedPatient,
    });
  } catch (error) {
    console.error("Error al incorporar documento:", error);
    return response.status(500).json({
      error: "No fue posible incorporar el documento a la ficha.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.get("/patients/:id/documents/:filename", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const normalized = normalizeDocumentName(filename);

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, name")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: docs, error: docsError } = await supabase
      .from("documents")
      .select("*")
      .eq("patient_id", patientId);
    if (docsError) throw docsError;

    const record = (docs ?? []).find((doc) => normalizeDocumentName(doc.filename) === normalized);
    if (!record) {
      return response.status(404).json({
        error:
          "Este documento todavía no tiene información detallada guardada. Vuelve a analizarlo e incorporarlo para habilitar su consulta.",
      });
    }

    return response.json({
      patientId: patientRow.id,
      patientName: patientRow.name,
      document: shapeDocumentRecord(record),
    });
  } catch (error) {
    console.error("Error al obtener documento:", error);
    return response.status(500).json({ error: "No fue posible obtener el documento." });
  }
});

// V11: validación humana por documento.
app.patch("/patients/:id/documents/:filename/validate", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const normalized = normalizeDocumentName(filename);

    const validStatuses = ["pendiente", "aprobado", "rechazado"];
    const status = request.body?.status;
    if (!validStatuses.includes(status)) {
      return response.status(400).json({
        error: "Estado de validación inválido. Debe ser pendiente, aprobado o rechazado.",
      });
    }

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: docs, error: docsError } = await supabase
      .from("documents")
      .select("id, filename")
      .eq("patient_id", patientId);
    if (docsError) throw docsError;

    const match = (docs ?? []).find((doc) => normalizeDocumentName(doc.filename) === normalized);
    if (!match) {
      return response.status(404).json({ error: "Este documento no tiene información detallada guardada todavía." });
    }

    const validatedAt = status === "pendiente" ? null : new Date().toISOString();

    const { data: updatedDoc, error: updateError } = await supabase
      .from("documents")
      .update({ validation_status: status, validated_at: validatedAt })
      .eq("id", match.id)
      .select()
      .single();
    if (updateError) throw updateError;

        if (updatedDoc.imaging_order_id) {
      if (status === "aprobado") {
        await supabase
          .from("imaging_orders")
          .update({ status: "validado", validated_at: new Date().toISOString() })
          .eq("id", updatedDoc.imaging_order_id);
      } else {
        await supabase
          .from("imaging_orders")
          .update({ status: "informado", validated_at: null })
          .eq("id", updatedDoc.imaging_order_id)
          .eq("status", "validado");
      }
    }

    const refreshedPatient = await getPatientFull(patientId);

    return response.json({
      patientId,
      filename,
      document: shapeDocumentRecord(updatedDoc),
      patient: refreshedPatient,
    });
  } catch (error) {
    console.error("Error al validar documento:", error);
    return response.status(500).json({ error: "No fue posible actualizar la validación del documento." });
  }
});

// V8: gestión real de documentos.
app.delete("/patients/:id/documents/:filename", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const normalized = normalizeDocumentName(filename);

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: docs, error: docsError } = await supabase
      .from("documents")
      .select("id, filename")
      .eq("patient_id", patientId);
    if (docsError) throw docsError;

    const match = (docs ?? []).find((doc) => normalizeDocumentName(doc.filename) === normalized);
    if (!match) {
      return response.status(404).json({ error: "Este documento no está registrado en la ficha del paciente." });
    }

    const { error: historyDeleteError } = await supabase
      .from("history_events")
      .delete()
      .eq("document_id", match.id);
    if (historyDeleteError) throw historyDeleteError;

    const { error: docDeleteError } = await supabase
      .from("documents")
      .delete()
      .eq("id", match.id);
    if (docDeleteError) throw docDeleteError;

    const refreshedPatient = await getPatientFull(patientId);

    return response.json({ ok: true, patientId, filename, patient: refreshedPatient });
  } catch (error) {
    console.error("Error al eliminar documento:", error);
    return response.status(500).json({ error: "No fue posible eliminar el documento." });
  }
});

app.post("/patients/:id/documents/:filename/ask", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const question = typeof request.body?.question === "string" ? request.body.question.trim() : "";
    if (!question) return response.status(400).json({ error: "Debes escribir una pregunta sobre el documento." });

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: docs, error: docsError } = await supabase
      .from("documents")
      .select("*")
      .eq("patient_id", patientId);
    if (docsError) throw docsError;

    const record = (docs ?? []).find(
      (doc) => normalizeDocumentName(doc.filename) === normalizeDocumentName(filename),
    );
    if (!record) {
      return response.status(404).json({
        error:
          "Este documento todavía no tiene información detallada guardada. Vuelve a analizarlo e incorporarlo para poder consultarlo.",
      });
    }

    const documentContext = JSON.stringify(
      {
        filename: record.filename,
        documentType: record.document_type,
        patientName: record.patient_name,
        patientRut: record.patient_rut,
        patientAge: record.patient_age,
        exam: record.exam,
        doctor: record.doctor,
        reason: record.reason,
        priority: record.priority,
        date: record.date,
        equipment: record.equipment,
        summary: record.summary,
      },
      null,
      2,
    );

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
    return response.json({ patientId, filename: record.filename, respuesta: answer });
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
  try {
    const patient = await getPatientFull(request.params.id);
    if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

    const filename = request.body?.filename;
    const base64Data = request.body?.base64Data;

    if (
      typeof filename !== "string" ||
      !filename.toLowerCase().endsWith(".pdf") ||
      typeof base64Data !== "string" ||
      base64Data.trim().length === 0
    ) {
      return response.status(400).json({ error: "Debes enviar un archivo PDF válido." });
    }

    if (base64Data.length > 14_000_000) {
      return response.status(413).json({ error: "El PDF supera el tamaño máximo permitido de 10 MB." });
    }

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
      return response.status(502).json({ error: "OpenAI no entregó un análisis del documento." });
    }

    let clean = raw;
    if (clean.startsWith("```")) {
      clean = clean.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    }

    let documentData;
    try {
      documentData = JSON.parse(clean);
    } catch (parseError) {
      console.error("Respuesta no JSON de OpenAI:", raw);
      return response.status(502).json({ error: "Nexa recibió un análisis que no pudo estructurar." });
    }

    const missing = Array.isArray(documentData.missingData) ? documentData.missingData : [];
    const differences = Array.isArray(documentData.differences) ? documentData.differences : [];

    const matchingPatients =
      documentData.isClinical === true
        ? await findPatientsByRutDb(documentData.patientRut, patient.id)
        : [];

    const existingPatientMatch = matchingPatients.length === 1 ? matchingPatients[0] : null;

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

    return response.json({
      patientId: patient.id,
      filename,
      analysis: analysisLines.join("\n"),
      documentData,
      existingPatient: existingPatientMatch
        ? { id: existingPatientMatch.id, name: existingPatientMatch.name, rut: existingPatientMatch.rut }
        : null,
      duplicateRutCount: matchingPatients.length > 1 ? matchingPatients.length : 0,
    });
  } catch (error) {
    console.error("Error al analizar PDF:", error);
    const status = typeof error?.status === "number" ? error.status : 500;
    return response.status(status).json({
      error: "No fue posible analizar el documento.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});
// ============================================
// MÓDULO DE LABORATORIO
// ============================================

function shapeLabPanelRow(row) {
  return { id: row.id, fonasaCode: row.fonasa_code, name: row.name };
}

function shapeLabParameterRow(row) {
  return {
    id: row.id,
    panelId: row.panel_id,
    fonasaCode: row.fonasa_code,
    name: row.name,
    unit: row.unit,
    refMin: row.ref_min,
    refMax: row.ref_max,
    refMinMale: row.ref_min_male,
    refMaxMale: row.ref_max_male,
    refMinFemale: row.ref_min_female,
    refMaxFemale: row.ref_max_female,
    refText: row.ref_text,
    displayOrder: row.display_order,
  };
}

function shapeLabOrderRow(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    status: row.status,
    requestedAt: row.requested_at,
    sampleTakenAt: row.sample_taken_at,
    completedAt: row.completed_at,
    validatedAt: row.validated_at,
    validatedBy: row.validated_by,
  };
}

function shapeLabResultRow(row) {
  return {
    id: row.id,
    orderId: row.order_id,
    parameterId: row.parameter_id,
    valueNumeric: row.value_numeric,
    valueText: row.value_text,
    isOutOfRange: row.is_out_of_range,
  };
}

function isNumericOutOfRange(parameter, value, sexo) {
  let min = parameter.ref_min;
  let max = parameter.ref_max;
  if (sexo === "M" && (parameter.ref_min_male !== null || parameter.ref_max_male !== null)) {
    min = parameter.ref_min_male;
    max = parameter.ref_max_male;
  } else if (sexo === "F" && (parameter.ref_min_female !== null || parameter.ref_max_female !== null)) {
    min = parameter.ref_min_female;
    max = parameter.ref_max_female;
  }
  if (min === null && max === null) return null;
  if (min !== null && value < min) return true;
  if (max !== null && value > max) return true;
  return false;
}

app.use("/lab", requireAuth);

app.get("/lab/panels", async (_request, response) => {
  try {
    const { data: panelRows, error: panelsError } = await supabase
      .from("lab_panels")
      .select("*")
      .order("name", { ascending: true });
    if (panelsError) throw panelsError;

    const { data: parameterRows, error: parametersError } = await supabase
      .from("lab_parameters")
      .select("*")
      .order("display_order", { ascending: true });
    if (parametersError) throw parametersError;

    const panels = (panelRows ?? []).map((panel) => ({
      ...shapeLabPanelRow(panel),
      parameters: (parameterRows ?? [])
        .filter((param) => param.panel_id === panel.id)
        .map(shapeLabParameterRow),
    }));

    return response.json({ panels });
  } catch (error) {
    console.error("Error al obtener catálogo de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible obtener el catálogo de exámenes de laboratorio." });
  }
});

app.post("/patients/:id/lab-orders", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const panelIds = Array.isArray(request.body?.panelIds) ? request.body.panelIds : [];

    if (panelIds.length === 0) {
      return response.status(400).json({ error: "Debes seleccionar al menos un examen." });
    }

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: orderRow, error: orderError } = await supabase
      .from("lab_orders")
      .insert({ patient_id: patientId, status: "ordenado" })
      .select()
      .single();
    if (orderError) throw orderError;

    const orderPanelsRows = panelIds.map((panelId) => ({ order_id: orderRow.id, panel_id: panelId }));
    const { error: orderPanelsError } = await supabase.from("lab_order_panels").insert(orderPanelsRows);
    if (orderPanelsError) throw orderPanelsError;

    return response.json({ order: shapeLabOrderRow(orderRow) });
  } catch (error) {
    console.error("Error al crear orden de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible crear la orden de laboratorio." });
  }
});

app.get("/patients/:id/lab-orders", async (request, response) => {
  try {
    const patientId = Number(request.params.id);

    const { data: orderRows, error: ordersError } = await supabase
      .from("lab_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("requested_at", { ascending: false });
    if (ordersError) throw ordersError;

    const orderIds = (orderRows ?? []).map((o) => o.id);

    const { data: orderPanelRows, error: orderPanelsError } = orderIds.length
      ? await supabase.from("lab_order_panels").select("*, lab_panels(name, fonasa_code)").in("order_id", orderIds)
      : { data: [], error: null };
    if (orderPanelsError) throw orderPanelsError;

    const orders = (orderRows ?? []).map((order) => ({
      ...shapeLabOrderRow(order),
      panels: (orderPanelRows ?? [])
        .filter((op) => op.order_id === order.id)
        .map((op) => ({ id: op.panel_id, name: op.lab_panels?.name, fonasaCode: op.lab_panels?.fonasa_code })),
    }));

    return response.json({ orders });
  } catch (error) {
    console.error("Error al obtener órdenes de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible obtener las órdenes de laboratorio." });
  }
});

app.get("/patients/:id/lab-orders/:orderId", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    const { data: orderRow, error: orderError } = await supabase
      .from("lab_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!orderRow) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    const { data: orderPanelRows, error: orderPanelsError } = await supabase
      .from("lab_order_panels")
      .select("panel_id, lab_panels(id, name, fonasa_code)")
      .eq("order_id", orderId);
    if (orderPanelsError) throw orderPanelsError;

    const panelIds = (orderPanelRows ?? []).map((op) => op.panel_id);

    const { data: parameterRows, error: parametersError } = panelIds.length
      ? await supabase.from("lab_parameters").select("*").in("panel_id", panelIds).order("display_order", { ascending: true })
      : { data: [], error: null };
    if (parametersError) throw parametersError;

    const { data: resultRows, error: resultsError } = await supabase
      .from("lab_results")
      .select("*")
      .eq("order_id", orderId);
    if (resultsError) throw resultsError;

    const panels = (orderPanelRows ?? []).map((op) => ({
      id: op.panel_id,
      name: op.lab_panels?.name,
      fonasaCode: op.lab_panels?.fonasa_code,
      parameters: (parameterRows ?? [])
        .filter((param) => param.panel_id === op.panel_id)
        .map((param) => {
          const result = (resultRows ?? []).find((r) => r.parameter_id === param.id);
          return {
            ...shapeLabParameterRow(param),
            result: result ? shapeLabResultRow(result) : null,
          };
        }),
    }));

    return response.json({ order: shapeLabOrderRow(orderRow), panels });
  } catch (error) {
    console.error("Error al obtener detalle de orden de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible obtener el detalle de la orden." });
  }
});

app.patch("/patients/:id/lab-orders/:orderId/sample-taken", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    const { data: updatedOrder, error } = await supabase
      .from("lab_orders")
      .update({ status: "muestra_tomada", sample_taken_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .select()
      .single();
    if (error) throw error;
    if (!updatedOrder) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    return response.json({ order: shapeLabOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al marcar toma de muestra:", error);
    return response.status(500).json({ error: "No fue posible marcar la toma de muestra." });
  }
});

app.patch("/patients/:id/lab-orders/:orderId/results", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;
    const results = Array.isArray(request.body?.results) ? request.body.results : [];

    if (results.length === 0) {
      return response.status(400).json({ error: "Debes enviar al menos un resultado." });
    }

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, sexo")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: orderRow, error: orderError } = await supabase
      .from("lab_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!orderRow) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    for (const item of results) {
      const parameterId = item.parameterId;
      const valueNumeric = typeof item.valueNumeric === "number" ? item.valueNumeric : null;
      const valueText = typeof item.valueText === "string" ? item.valueText.trim() : null;

      const { data: parameterRow, error: parameterError } = await supabase
        .from("lab_parameters")
        .select("*")
        .eq("id", parameterId)
        .maybeSingle();
      if (parameterError) throw parameterError;
      if (!parameterRow) continue;

      let isOutOfRange = null;
      if (valueNumeric !== null) {
        isOutOfRange = isNumericOutOfRange(parameterRow, valueNumeric, patientRow.sexo);
      } else if (valueText !== null && parameterRow.ref_text) {
        isOutOfRange = valueText.toLowerCase() !== parameterRow.ref_text.trim().toLowerCase();
      }

      const { data: existingResult, error: existingError } = await supabase
        .from("lab_results")
        .select("id")
        .eq("order_id", orderId)
        .eq("parameter_id", parameterId)
        .maybeSingle();
      if (existingError) throw existingError;

      const resultRow = {
        order_id: orderId,
        parameter_id: parameterId,
        value_numeric: valueNumeric,
        value_text: valueText,
        is_out_of_range: isOutOfRange,
      };

      if (existingResult) {
        const { error } = await supabase.from("lab_results").update(resultRow).eq("id", existingResult.id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("lab_results").insert(resultRow);
        if (error) throw error;
      }
    }

    const { data: orderPanelRows } = await supabase.from("lab_order_panels").select("panel_id").eq("order_id", orderId);
    const panelIds = (orderPanelRows ?? []).map((op) => op.panel_id);
    const { data: allParameters } = panelIds.length
      ? await supabase.from("lab_parameters").select("id").in("panel_id", panelIds)
      : { data: [] };
    const { data: allResults } = await supabase.from("lab_results").select("parameter_id").eq("order_id", orderId);

    const totalParams = (allParameters ?? []).length;
    const filledParams = new Set((allResults ?? []).map((r) => r.parameter_id)).size;

    const newStatus = filledParams >= totalParams && totalParams > 0 ? "completado" : "en_proceso";

    const { data: updatedOrder, error: updateOrderError } = await supabase
      .from("lab_orders")
      .update({
        status: newStatus,
        completed_at: newStatus === "completado" ? new Date().toISOString() : null,
      })
      .eq("id", orderId)
      .select()
      .single();
    if (updateOrderError) throw updateOrderError;

    return response.json({ order: shapeLabOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al guardar resultados de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible guardar los resultados." });
  }
});

app.patch("/patients/:id/lab-orders/:orderId/validate", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    const { data: updatedOrder, error } = await supabase
      .from("lab_orders")
      .update({
        status: "validado",
        validated_at: new Date().toISOString(),
        validated_by: request.user?.email ?? null,
      })
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .select()
      .single();
    if (error) throw error;
    if (!updatedOrder) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    return response.json({ order: shapeLabOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al validar orden de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible validar la orden de laboratorio." });
  }
});
// ============================================
// MÓDULO DE IMAGENOLOGÍA
// ============================================

function shapeImagingTypeRow(row) {
  return {
    id: row.id,
    fonasaCode: row.fonasa_code,
    category: row.category,
    name: row.name,
  };
}

function shapeImagingOrderRow(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    status: row.status,
    requestedAt: row.requested_at,
    performedAt: row.performed_at,
    informedAt: row.informed_at,
    validatedAt: row.validated_at,
  };
}

app.use("/imaging", requireAuth);

app.get("/imaging/types", async (_request, response) => {
  try {
    const { data, error } = await supabase
      .from("imaging_types")
      .select("*")
      .order("category", { ascending: true })
      .order("name", { ascending: true });
    if (error) throw error;

    return response.json({ types: (data ?? []).map(shapeImagingTypeRow) });
  } catch (error) {
    console.error("Error al obtener catálogo de imagenología:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener el catálogo de imagenología." });
  }
});

app.post("/patients/:id/imaging-orders", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const typeIds = Array.isArray(request.body?.typeIds)
      ? request.body.typeIds
      : [];

    if (typeIds.length === 0) {
      return response
        .status(400)
        .json({ error: "Debes seleccionar al menos un tipo de estudio." });
    }

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow)
      return response.status(404).json({ error: "Paciente no encontrado" });

    const { data: orderRow, error: orderError } = await supabase
      .from("imaging_orders")
      .insert({ patient_id: patientId, status: "ordenado" })
      .select()
      .single();
    if (orderError) throw orderError;

    const orderTypeRows = typeIds.map((typeId) => ({
      order_id: orderRow.id,
      imaging_type_id: typeId,
    }));
    const { error: orderTypesError } = await supabase
      .from("imaging_order_types")
      .insert(orderTypeRows);
    if (orderTypesError) throw orderTypesError;

    return response.json({ order: shapeImagingOrderRow(orderRow) });
  } catch (error) {
    console.error("Error al crear orden de imagenología:", error);
    return response
      .status(500)
      .json({ error: "No fue posible crear la orden de imagenología." });
  }
});

app.get("/patients/:id/imaging-orders", async (request, response) => {
  try {
    const patientId = Number(request.params.id);

    const { data: orderRows, error: ordersError } = await supabase
      .from("imaging_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("requested_at", { ascending: false });
    if (ordersError) throw ordersError;

    const orderIds = (orderRows ?? []).map((o) => o.id);

    const { data: orderTypeRows, error: orderTypesError } = orderIds.length
      ? await supabase
          .from("imaging_order_types")
          .select("*, imaging_types(name, category, fonasa_code)")
          .in("order_id", orderIds)
      : { data: [], error: null };
    if (orderTypesError) throw orderTypesError;

    const orders = (orderRows ?? []).map((order) => ({
      ...shapeImagingOrderRow(order),
      types: (orderTypeRows ?? [])
        .filter((ot) => ot.order_id === order.id)
        .map((ot) => ({
          id: ot.imaging_type_id,
          name: ot.imaging_types?.name,
          category: ot.imaging_types?.category,
          fonasaCode: ot.imaging_types?.fonasa_code,
        })),
    }));

    return response.json({ orders });
  } catch (error) {
    console.error("Error al obtener órdenes de imagenología:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener las órdenes de imagenología." });
  }
});

app.get("/patients/:id/imaging-orders/:orderId", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    const { data: orderRow, error: orderError } = await supabase
      .from("imaging_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!orderRow)
      return response
        .status(404)
        .json({ error: "Orden de imagenología no encontrada." });

    const { data: orderTypeRows, error: orderTypesError } = await supabase
      .from("imaging_order_types")
      .select("imaging_type_id, imaging_types(id, name, category, fonasa_code)")
      .eq("order_id", orderId);
    if (orderTypesError) throw orderTypesError;

    const { data: linkedDocs, error: docsError } = await supabase
      .from("documents")
      .select("*")
      .eq("imaging_order_id", orderId);
    if (docsError) throw docsError;

    return response.json({
      order: shapeImagingOrderRow(orderRow),
      types: (orderTypeRows ?? []).map((ot) => ({
        id: ot.imaging_type_id,
        name: ot.imaging_types?.name,
        category: ot.imaging_types?.category,
        fonasaCode: ot.imaging_types?.fonasa_code,
      })),
      documents: (linkedDocs ?? []).map(shapeDocumentRecord),
    });
  } catch (error) {
    console.error("Error al obtener detalle de orden de imagenología:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener el detalle de la orden." });
  }
});

app.patch(
  "/patients/:id/imaging-orders/:orderId/performed",
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;

      const { data: updatedOrder, error } = await supabase
        .from("imaging_orders")
        .update({ status: "realizado", performed_at: new Date().toISOString() })
        .eq("id", orderId)
        .eq("patient_id", patientId)
        .select()
        .single();
      if (error) throw error;
      if (!updatedOrder)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });

      return response.json({ order: shapeImagingOrderRow(updatedOrder) });
    } catch (error) {
      console.error("Error al marcar estudio realizado:", error);
      return response
        .status(500)
        .json({ error: "No fue posible marcar el estudio como realizado." });
    }
  },
);
// ============================================
// IMAGENOLOGÍA — ETAPA B: imágenes DICOM
// ============================================

async function convertDicomToPng(dicomBuffer) {
  const byteArray = new Uint8Array(dicomBuffer);
  const dataSet = dicomParser.parseDicom(byteArray);

  const pixelDataElement = dataSet.elements.x7fe00010;
  if (!pixelDataElement) {
    throw new Error(
      "El archivo DICOM no contiene datos de imagen (pixel data).",
    );
  }

  if (pixelDataElement.encapsulatedPixelData) {
    throw new Error(
      "Este archivo DICOM usa un formato comprimido que Nexa todavía no puede convertir a imagen.",
    );
  }

  const rows = dataSet.uint16("x00280010");
  const columns = dataSet.uint16("x00280011");
  const bitsAllocated = dataSet.uint16("x00280100") || 16;
  const pixelRepresentation = dataSet.uint16("x00280103") || 0;
  const samplesPerPixel = dataSet.uint16("x00280002") || 1;
  const photometricInterpretation = (
    dataSet.string("x00280004") || "MONOCHROME2"
  ).trim();

  if (!rows || !columns) {
    throw new Error(
      "No fue posible leer las dimensiones de la imagen DICOM.",
    );
  }

  const numPixels = rows * columns * samplesPerPixel;

  if (samplesPerPixel === 3) {
    const rgbValues = new Uint8Array(
      dataSet.byteArray.buffer,
      pixelDataElement.dataOffset,
      numPixels,
    );
    return sharp(Buffer.from(rgbValues), {
      raw: { width: columns, height: rows, channels: 3 },
    })
      .png()
      .toBuffer();
  }

  const rescaleSlopeRaw = dataSet.floatString("x00281053");
  const rescaleInterceptRaw = dataSet.floatString("x00281052");
  const slope = rescaleSlopeRaw !== undefined ? rescaleSlopeRaw : 1;
  const intercept = rescaleInterceptRaw !== undefined ? rescaleInterceptRaw : 0;

  let rawValues;
  if (bitsAllocated === 16) {
    rawValues =
      pixelRepresentation === 1
        ? new Int16Array(
            dataSet.byteArray.buffer,
            pixelDataElement.dataOffset,
            numPixels,
          )
        : new Uint16Array(
            dataSet.byteArray.buffer,
            pixelDataElement.dataOffset,
            numPixels,
          );
  } else {
    rawValues = new Uint8Array(
      dataSet.byteArray.buffer,
      pixelDataElement.dataOffset,
      numPixels,
    );
  }

  const rescaled = new Float64Array(numPixels);
  let min = Infinity;
  let max = -Infinity;
  for (let i = 0; i < numPixels; i++) {
    const value = rawValues[i] * slope + intercept;
    rescaled[i] = value;
    if (value < min) min = value;
    if (value > max) max = value;
  }

  const windowCenterRaw = dataSet.string("x00281050");
  const windowWidthRaw = dataSet.string("x00281051");
  let windowCenter = windowCenterRaw
    ? parseFloat(windowCenterRaw.split("\\")[0])
    : NaN;
  let windowWidth = windowWidthRaw
    ? parseFloat(windowWidthRaw.split("\\")[0])
    : NaN;

  if (Number.isNaN(windowCenter) || Number.isNaN(windowWidth)) {
    windowCenter = (max + min) / 2;
    windowWidth = max - min || 1;
  }

  const low = windowCenter - windowWidth / 2;
  const high = windowCenter + windowWidth / 2;
  const range = high - low || 1;
  const invert = photometricInterpretation === "MONOCHROME1";

  const output = new Uint8Array(numPixels);
  for (let i = 0; i < numPixels; i++) {
    let normalized = ((rescaled[i] - low) / range) * 255;
    normalized = Math.max(0, Math.min(255, normalized));
    output[i] = invert ? 255 - normalized : normalized;
  }

  return sharp(Buffer.from(output), {
    raw: { width: columns, height: rows, channels: 1 },
  })
    .png()
    .toBuffer();
}

function shapeImagingFileRow(row) {
  return {
    id: row.id,
    orderId: row.order_id,
    dicomPath: row.dicom_path,
    pngPath: row.png_path,
    uploadedAt: row.uploaded_at,
  };
}

app.post(
  "/patients/:id/imaging-orders/:orderId/image",
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;
      const filename = request.body?.filename;
      const base64Data = request.body?.base64Data;

      if (
        typeof filename !== "string" ||
        typeof base64Data !== "string" ||
        base64Data.trim().length === 0
      ) {
        return response
          .status(400)
          .json({ error: "Debes enviar un archivo DICOM válido." });
      }

      const { data: orderRow, error: orderError } = await supabase
        .from("imaging_orders")
        .select("id")
        .eq("id", orderId)
        .eq("patient_id", patientId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });

      const dicomBuffer = Buffer.from(base64Data, "base64");
      const timestamp = Date.now();
      const safeFilename = filename.replace(/[^a-zA-Z0-9._-]/g, "_");
      const dicomPath = `orders/${orderId}/${timestamp}-${safeFilename}`;

      const { error: dicomUploadError } = await supabase.storage
        .from("imaging")
        .upload(dicomPath, dicomBuffer, {
          contentType: "application/dicom",
        });
      if (dicomUploadError) throw dicomUploadError;

      let pngPath = null;
      let conversionError = null;

      try {
        const pngBuffer = await convertDicomToPng(dicomBuffer);
        pngPath = `orders/${orderId}/${timestamp}-preview.png`;
        const { error: pngUploadError } = await supabase.storage
          .from("imaging")
          .upload(pngPath, pngBuffer, { contentType: "image/png" });
        if (pngUploadError) throw pngUploadError;
      } catch (error) {
        console.error("Error al convertir DICOM a PNG:", error);
        conversionError =
          typeof error?.message === "string"
            ? error.message
            : "No fue posible generar una vista previa de la imagen.";
        pngPath = null;
      }

      const { data: fileRow, error: fileInsertError } = await supabase
        .from("imaging_files")
        .insert({
          order_id: orderId,
          dicom_path: dicomPath,
          png_path: pngPath,
        })
        .select()
        .single();
      if (fileInsertError) throw fileInsertError;

      return response.json({
        file: shapeImagingFileRow(fileRow),
        conversionError,
      });
    } catch (error) {
      console.error("Error al subir la imagen DICOM:", error);
      return response.status(500).json({
        error: "No fue posible subir la imagen DICOM.",
        detalle:
          typeof error?.message === "string"
            ? error.message
            : "Error desconocido.",
      });
    }
  },
);

app.get(
  "/patients/:id/imaging-orders/:orderId/images",
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;

      const { data: orderRow, error: orderError } = await supabase
        .from("imaging_orders")
        .select("id")
        .eq("id", orderId)
        .eq("patient_id", patientId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });

      const { data: fileRows, error: filesError } = await supabase
        .from("imaging_files")
        .select("*")
        .eq("order_id", orderId)
        .order("uploaded_at", { ascending: false });
      if (filesError) throw filesError;

      const files = await Promise.all(
        (fileRows ?? []).map(async (row) => {
          let pngUrl = null;
          let dicomUrl = null;

          if (row.png_path) {
            const { data: pngSigned } = await supabase.storage
              .from("imaging")
              .createSignedUrl(row.png_path, 3600);
            pngUrl = pngSigned?.signedUrl ?? null;
          }

          if (row.dicom_path) {
            const { data: dicomSigned } = await supabase.storage
              .from("imaging")
              .createSignedUrl(row.dicom_path, 3600);
            dicomUrl = dicomSigned?.signedUrl ?? null;
          }

          return {
            ...shapeImagingFileRow(row),
            pngUrl,
            dicomUrl,
          };
        }),
      );

      return response.json({ files });
    } catch (error) {
      console.error("Error al obtener imágenes de la orden:", error);
      return response
        .status(500)
        .json({ error: "No fue posible obtener las imágenes de la orden." });
    }
  },
);
app.post("/chat", async (request, response) => {
  try {
    const message = request.body?.message;

    if (typeof message !== "string" || message.trim().length === 0) {
      return response.status(400).json({ error: "Debes enviar un mensaje válido." });
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
      return response.status(502).json({ error: "OpenAI no entregó una respuesta de texto." });
    }

    return response.json({ respuesta: answer });
  } catch (error) {
    console.error("");
    console.error("Error al consultar OpenAI:");
    console.error(error);
    console.error("");

    const status = typeof error?.status === "number" ? error.status : 500;

    let publicMessage = "No fue posible consultar la inteligencia artificial.";

    if (status === 401) {
      publicMessage = "La API Key no es válida, fue revocada o no está siendo leída.";
    } else if (status === 403) {
      publicMessage = "La cuenta o el proyecto no tiene permiso para utilizar este recurso.";
    } else if (status === 429) {
      publicMessage = "La cuenta alcanzó un límite de uso o no tiene saldo disponible.";
    }

    return response.status(status).json({
      error: publicMessage,
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.listen(port, () => {
  console.log("");
  console.log("========================================");
  console.log("Nexa Backend iniciado correctamente");
  console.log(`Servidor:      http://localhost:${port}`);
  console.log(`Estado:        http://localhost:${port}/health`);
  console.log(`Modelo:        ${model}`);
  console.log(`Base de datos: Supabase (${process.env.SUPABASE_URL})`);
  console.log("========================================");
  console.log("");

  getDuplicateRutGroupsDb().then((duplicateRutGroups) => {
    if (duplicateRutGroups.length > 0) {
      console.warn("");
      console.warn("ADVERTENCIA: se detectaron RUT duplicados en la base de datos:");
      console.warn(JSON.stringify(duplicateRutGroups, null, 2));
      console.warn("");
    }
  });
});
