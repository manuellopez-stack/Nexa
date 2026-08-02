import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import OpenAI from "openai";

dotenv.config({ quiet: true });

const app = express();
const port = 3000;

app.use(cors());
app.use(express.json({ limit: "1mb" }));

if (!process.env.OPENAI_API_KEY) {
  console.error("");
  console.error("ERROR: No se encontró OPENAI_API_KEY en el archivo .env");
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
    history: [
      { date: "15/07/2026", exam: "Ecografía abdominal" },
      { date: "12/03/2026", exam: "Control médico" },
      { date: "21/11/2025", exam: "Radiografía de tórax" },
    ],
  },
  {
    id: 2,
    time: "08:45",
    name: "Juan Pérez",
    rut: "12.345.678-5",
    age: 52,
    doctor: "Dra. Camila Torres",
    phone: "+56 9 8765 4321",
    observations: "Control anual. Sin observaciones relevantes.",
    exam: "Mamografía",
    room: "Sala 2",
    status: "Esperando",
    history: [
      { date: "03/06/2026", exam: "Mamografía bilateral" },
      { date: "10/06/2025", exam: "Ecografía mamaria" },
    ],
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
    history: [
      { date: "14/01/2026", exam: "Rayos X de tórax" },
      { date: "18/08/2024", exam: "Radiografía de columna" },
    ],
  },
  {
    id: 4,
    time: "09:15",
    name: "Carlos Díaz",
    rut: "9.876.543-2",
    age: 61,
    doctor: "Dra. Paula Herrera",
    phone: "+56 9 6543 2109",
    observations: "Evaluación vascular de extremidad inferior.",
    exam: "Ecografía Doppler",
    room: "Sala 1",
    status: "Programado",
    history: [
      { date: "22/04/2026", exam: "Ecografía Doppler venosa" },
      { date: "30/09/2025", exam: "Ecografía abdominal" },
    ],
  },
];

app.get("/", (_request, response) => {
  response.send("Nexa Backend funcionando");
});

app.get("/health", (_request, response) => {
  response.json({
    estado: "OK",
    servicio: "Nexa Backend",
    fecha: new Date().toISOString(),
  });
});

app.get("/patients/today", (_request, response) => {
  response.json({
    fecha: new Date().toISOString().split("T")[0],
    total: patients.length,
    patients,
  });
});

app.get("/patients/:id", (request, response) => {
  const patient = patients.find(
    (item) => item.id === Number(request.params.id),
  );

  if (!patient) {
    return response.status(404).json({
      error: "Paciente no encontrado",
    });
  }

  response.json({
    ...patient,
    risk: patient.risk ?? "BAJO",
    aiSummary:
      patient.aiSummary ??
      "No existe todavía un resumen generado por Nexa AI.",
    documents:
      patient.documents ?? [
        "Orden médica.pdf",
        "Consentimiento.pdf",
        "Informe anterior.pdf",
      ],
  });
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
      model: "gpt-5-mini",
      instructions: `
Eres Nexa, un asistente de inteligencia artificial para empresas.

Reglas:
- Responde siempre en español.
- Utiliza un tono claro, profesional y práctico.
- No inventes datos.
- Indica cuando falte información.
- Organiza las respuestas extensas con títulos.
- Ayuda especialmente con contratos, documentos, informes,
  correos, reuniones, planillas y tareas administrativas.
- Cuando el usuario pida analizar información que no ha proporcionado,
  solicita los datos o el archivo necesario.
      `.trim(),
      input: message.trim(),
    });

    const answer = result.output_text?.trim();

    if (!answer) {
      return response.status(502).json({
        error: "OpenAI no entregó una respuesta de texto.",
      });
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
      publicMessage = "La cuenta no tiene saldo disponible o alcanzó un límite de uso.";
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
  console.log(`Servidor: http://localhost:${port}`);
  console.log(`Estado:   http://localhost:${port}/health`);
  console.log("========================================");
  console.log("");
});
