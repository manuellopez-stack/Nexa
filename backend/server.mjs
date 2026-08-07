import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import OpenAI from "openai";

dotenv.config({ quiet: true });

const app = express();
const port = 3000;
const model = process.env.OPENAI_MODEL || "gpt-5-mini";

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

const patients = [
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

function getPatientById(id) {
  return patients.find((patient) => patient.id === Number(id));
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

    const analysisLines = [
      `Tipo de documento: ${documentData.documentType ?? "Sin información"}`,
      `Documento clínico: ${documentData.isClinical === true ? "Sí" : "No"}`,
      `Paciente: ${documentData.patientName ?? "Sin información"}`,
      `RUT: ${documentData.patientRut ?? "Sin información"}`,
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

    if (!patient.documents.includes(filename)) {
      patient.documents.push(filename);
    }

    return response.json({
      patientId: patient.id,
      filename,
      analysis: analysisLines.join("\n"),
      documentData,
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
  console.log("");
  console.log("========================================");
  console.log("Nexa Backend iniciado correctamente");
  console.log(`Servidor: http://localhost:${port}`);
  console.log(`Estado:   http://localhost:${port}/health`);
  console.log(`Modelo:   ${model}`);
  console.log("========================================");
  console.log("");
});
