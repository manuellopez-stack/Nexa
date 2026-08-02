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
    },
    {
      id: 2,
      time: "08:45",
      name: "Juan Pérez",
      exam: "Mamografía",
      room: "Sala 2",
      status: "Esperando",
    },
    {
      id: 3,
      time: "09:00",
      name: "Ana Rojas",
      exam: "Rayos X de tórax",
      room: "Sala 3",
      status: "Programado",
    },
    {
      id: 4,
      time: "09:15",
      name: "Carlos Díaz",
      exam: "Ecografía Doppler",
      room: "Sala 1",
      status: "Programado",
    },
  ];

  response.json({
    fecha: new Date().toISOString().split("T")[0],
    total: patients.length,
    patients,
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
        "La cuenta no tiene saldo disponible o alcanzó un límite de uso.";
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
  console.log("========================================");
  console.log("");
});