import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import OpenAI from "openai";
import { createClient } from "@supabase/supabase-js";
import { google } from "googleapis";
import MailComposer from "nodemailer/lib/mail-composer/index.js";
import {
  crearRegistroImagenesProxy,
  descargarImagenSegura,
  reescribirImagenesRemotas,
  MAX_BYTES_DEFECTO,
  TIMEOUT_MS_DEFECTO,
} from "./gmailImageProxy.mjs";
import { convertDicomToPng } from "./dicomPreview.mjs";
import { linkOrthancStudyToOrder } from "./orthancStudies.mjs";
dotenv.config({ quiet: true });

const app = express();
const port = 3000;
const model = process.env.OPENAI_MODEL || "gpt-5-mini";

// CORS. Comportamiento histórico: si no se configura FRONTEND_ORIGIN, se
// acepta cualquier origen (como hacía el `cors()` sin opciones de antes) —
// no es un agujero de seguridad nuevo: la app Flutter no usa cookies, se
// autentica con Bearer token, así que un origen abierto no expone la sesión
// de nadie (un sitio malicioso no puede leer ni forjar el token de otra
// pestaña). Si se define FRONTEND_ORIGIN (uno o más orígenes separados por
// coma) se restringe a esa lista, para asegurar producción cuando se quiera.
//
// Siempre se aceptan, además, los orígenes de desarrollo local: localhost/
// 127.0.0.1 en cualquier puerto y los `*.app.github.dev` que asigna GitHub
// Codespaces al reenviar un puerto — cambian de URL en cada preview y de
// puerto en cada reinicio de `flutter run`, por eso no se pueden listar a
// mano vía FRONTEND_ORIGIN.
const configuredOrigins = (process.env.FRONTEND_ORIGIN || "")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

const LOCALHOST_ORIGIN_RE = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i;
const CODESPACES_ORIGIN_RE = /^https:\/\/[a-z0-9-]+\.app\.github\.dev$/i;

function isOriginAllowed(origin) {
  // Sin header Origin (apps nativas, curl, healthchecks): no es una llamada
  // de navegador, CORS no aplica.
  if (!origin) return true;
  if (LOCALHOST_ORIGIN_RE.test(origin) || CODESPACES_ORIGIN_RE.test(origin)) return true;
  // Sin FRONTEND_ORIGIN configurado: mismo comportamiento abierto de antes.
  if (configuredOrigins.length === 0) return true;
  return configuredOrigins.includes(origin);
}

// DEBUG TEMPORAL: diagnóstico del login que no llega o falla en silencio.
app.use((request, _response, next) => {
  console.log(`[DEBUG] ${new Date().toISOString()} ${request.method} ${request.originalUrl} origin=${request.headers.origin ?? "(sin origin)"}`);
  next();
});
app.use(
  cors({
    origin(origin, callback) {
      callback(null, isOriginAllowed(origin));
    },
  }),
);
app.use(express.json({ limit: "50mb" }));
// Página pública de autoagendamiento (Etapa 2 del plan de autoagendamiento
// web). Es HTML/CSS/JS estático, sin build: no lleva login, ni menú, ni
// acceso a datos de otros pacientes -- solo llama a los endpoints públicos
// /public/booking/* definidos más abajo. Vive en /reservar porque es la URL
// que el plan usa como ejemplo (claude/plan-autoagendamiento-web.md).
const __dirname = path.dirname(fileURLToPath(import.meta.url));
app.use(express.static(path.join(__dirname, "public")));
app.get("/reservar", (request, response) => {
  response.sendFile(path.join(__dirname, "public", "reservar.html"));
});

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

// ============================================
// PERMISOS POR ROL
// ============================================

const ALL_ROLES = ["administrador", "medico", "tecnico", "recepcion"];
const CLINICAL_STAFF = ["administrador", "medico", "tecnico"];
const VALIDATORS = ["administrador", "medico"];
// Quienes pueden usar la IA (chat y "preguntar sobre un documento"). A
// diferencia de VALIDATORS, incluye a los 4 roles: abrir la IA no debe
// aflojar quién puede validar resultados clínicos, así que se mantiene como
// un grupo aparte.
const AI_STAFF = ["administrador", "medico", "tecnico", "recepcion"];
const ADMIN_ONLY = ["administrador"];
// Quienes manejan dinero: registran pagos y editan datos de facturación.
const BILLING_STAFF = ["administrador", "recepcion"];
// Quienes pueden usar el módulo de Correo (leer y responder desde Gmail).
const MAIL_STAFF = ["administrador", "recepcion"];
// Quienes gestionan la agenda de citas: el personal clínico + recepción, que
// es quien agenda, recibe y reprograma pacientes en el mesón.
const AGENDA_STAFF = ["administrador", "medico", "tecnico", "recepcion"];

// V13: exige una sesión válida (token entregado por /auth/login).
// Ahora además exige que la cuenta tenga un rol asignado en staff_profiles;
// si no lo tiene, la cuenta no puede usar Imagenda (aunque el login sea válido).
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

  const { data: profileRow, error: profileError } = await supabase
    .from("staff_profiles")
    .select("*")
    .eq("id", data.user.id)
    .maybeSingle();

  if (profileError) {
    console.error("Error al obtener el perfil de personal:", profileError);
    return response.status(500).json({ error: "No fue posible verificar tu perfil de usuario." });
  }

  if (!profileRow) {
    return response.status(403).json({
      error: "Tu cuenta no tiene un rol asignado en Imagenda. Contacta a un administrador.",
    });
  }

  request.user = data.user;
  request.staffRole = profileRow.role;
  request.staffProfile = profileRow;
  next();
}

// Middleware adicional: exige que el rol de la persona esté dentro de los
// roles permitidos para esa ruta específica. Se usa después de requireAuth.
function requireRole(allowedRoles) {
  return (request, response, next) => {
    if (!allowedRoles.includes(request.staffRole)) {
      return response.status(403).json({
        error: "No tienes permiso para realizar esta acción.",
      });
    }
    next();
  };
}

function normalizeRut(value) {
  return typeof value === "string" ? value.toUpperCase().replace(/[^0-9K]/g, "") : "";
}

// Valida un RUT chileno completo: cuerpo numérico + dígito verificador
// (módulo 11). Acepta cualquier formato de entrada ("12.345.678-5",
// "123456785", "12345678-K"); normalizeRut se encarga de limpiarlo.
function isValidRut(value) {
  const clean = normalizeRut(value);
  if (clean.length < 2) return false;
  const body = clean.slice(0, -1);
  const dv = clean.slice(-1);
  if (!/^\d+$/.test(body)) return false;
  let sum = 0;
  let multiplier = 2;
  for (let i = body.length - 1; i >= 0; i--) {
    sum += Number(body[i]) * multiplier;
    multiplier = multiplier === 7 ? 2 : multiplier + 1;
  }
  const remainder = 11 - (sum % 11);
  const expected =
    remainder === 11 ? "0" : remainder === 10 ? "K" : String(remainder);
  return dv === expected;
}

// Valida y normaliza los campos de IDENTIDAD de una ficha de paciente
// (nombre, rut, edad, sexo, teléfono, observaciones). Compartida entre el alta
// (POST /patients) y la edición (PATCH /patients/:id).
//
//   - partial: false (alta) -> exige nombre y rut.
//   - partial: true  (edición) -> solo revisa las claves presentes en el body;
//     una clave con null o "" limpia el campo (salvo nombre y rut, que no
//     pueden quedar vacíos).
//
// Devuelve `{ values }` con solo las claves a escribir, o `{ error }` con el
// mensaje 400 correspondiente.
function parsePatientIdentityInput(body, { partial }) {
  const source = body ?? {};
  const has = (key) => Object.prototype.hasOwnProperty.call(source, key);
  const values = {};

  if (!partial || has("name")) {
    const name = typeof source.name === "string" ? source.name.trim() : "";
    if (!name) return { error: "El nombre del paciente es obligatorio." };
    values.name = name;
  }

  if (!partial || has("rut")) {
    const rut =
      typeof source.rut === "string"
        ? source.rut.trim().replace(/\s+/g, "").toUpperCase()
        : "";
    if (!rut) return { error: "El RUT del paciente es obligatorio." };
    if (!isValidRut(rut)) {
      return { error: "El RUT no es válido: revisa el dígito verificador." };
    }
    values.rut = rut;
  }

  if (has("age")) {
    if (source.age === null || `${source.age}`.trim() === "") {
      values.age = null;
    } else {
      const parsed = Number(source.age);
      if (!Number.isInteger(parsed) || parsed < 0 || parsed > 130) {
        return { error: "La edad debe ser un número entero entre 0 y 130." };
      }
      values.age = parsed;
    }
  }

  if (has("sexo")) {
    if (source.sexo === null || `${source.sexo}`.trim() === "") {
      values.sexo = null;
    } else {
      // Codificación 'M'/'F' (una letra), la misma que usa el módulo de
      // Laboratorio para los rangos de referencia por sexo (isNumericOutOfRange).
      const s = `${source.sexo}`.trim().toUpperCase();
      if (s !== "M" && s !== "F") {
        return { error: 'El sexo debe ser "M" o "F".' };
      }
      values.sexo = s;
    }
  }

  if (has("phone")) {
    values.phone =
      typeof source.phone === "string" && source.phone.trim() ? source.phone.trim() : null;
  }

  if (has("observations")) {
    values.observations =
      typeof source.observations === "string" && source.observations.trim()
        ? source.observations.trim()
        : null;
  }

  return { values };
}

function normalizeDocumentName(value) {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/\.pdf$/i, "").replace(/[^a-z0-9áéíóúüñ]+/gi, "")
    : "";
}

// Registro best-effort de una operación de IA, para las métricas del dashboard
// ("Documentos analizados por IA"). Cuenta documentos/fichas distintos, no cada
// re-análisis: la deduplicación (patient_id + doc_key) la hace la consulta.
// Nunca hace fallar la respuesta al usuario: si el insert falla (por ejemplo,
// la tabla ai_analyses todavía no existe), solo deja un warning en el log.
async function logAiAnalysis({ patientId, filename = null, kind, staffEmail = null }) {
  try {
    const numericId = Number(patientId);
    const { error } = await supabase.from("ai_analyses").insert({
      patient_id: Number.isFinite(numericId) ? numericId : null,
      filename: filename || null,
      doc_key: filename ? normalizeDocumentName(filename) || null : null,
      kind,
      staff_email: staffEmail || null,
    });
    if (error) {
      console.warn("No fue posible registrar el análisis de IA:", error.message);
    }
  } catch (error) {
    console.warn("No fue posible registrar el análisis de IA:", error?.message ?? error);
  }
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

// Versión reducida de la ficha, sin datos clínicos, para el rol Recepción.
function shapePatientRowBasic(row) {
  return {
    id: row.id,
    time: row.time,
    name: row.name,
    rut: row.rut,
    doctor: row.doctor,
    phone: row.phone,
    room: row.room,
    status: row.status,
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

function shapeRoomRow(row) {
  return {
    id: row.id,
    name: row.name,
    kind: row.kind,
    capacity: row.capacity,
    active: row.active,
    sortOrder: row.sort_order,
  };
}

// Estados de cita (tabla appointments) <-> etiqueta que la app ya sabe pintar
// en el badge de "Pacientes del día". Mantener alineado con el CHECK de
// appointments.status en backend/sql/appointments.sql.
const APPOINTMENT_STATUSES = [
  "programada",
  "en_espera",
  "en_atencion",
  "atendida",
  "cancelada",
  "no_asistio",
];

const APPOINTMENT_STATUS_LABEL = {
  programada: "Programado",
  en_espera: "Esperando",
  en_atencion: "En atención",
  atendida: "Atendido",
  cancelada: "Cancelada",
  no_asistio: "No asistió",
};

function shapeAppointmentRow(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    roomId: row.room_id,
    roomName: row.room?.name ?? null,
    patientName: row.patient?.name ?? null,
    scheduledAt: row.scheduled_at,
    // Hora "HH:MM" y día "YYYY-MM-DD" ya resueltos en zona de la clínica, para
    // que la app no tenga que repetir la conversión de zona horaria.
    clock: formatClinicClock(row.scheduled_at),
    scheduledDate: formatClinicDate(row.scheduled_at),
    durationMin: row.duration_min,
    status: row.status,
    statusLabel: APPOINTMENT_STATUS_LABEL[row.status] ?? row.status,
    professional: row.professional,
    reason: row.reason,
    notes: row.notes,
    // 'staff' (creada por el personal) o 'web' (reservada por el paciente,
    // sin sala/profesional asignado todavía). Ver sql/public_booking.sql.
    origin: row.origin ?? "staff",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

// Zona horaria de la clínica. El resto del backend trabaja en UTC, pero la
// agenda de citas ("hoy" y la hora que se muestra) tiene que seguir el día
// local de Chile: una cita de las 21:00 en Chile no puede quedar clasificada
// como del día siguiente por el desfase con UTC.
const CLINIC_TIME_ZONE = "America/Santiago";

// Offset en minutos de la zona de la clínica respecto de UTC en un instante
// concreto (negativo para Chile). Se evalúa sobre la fecha real, así que
// maneja el cambio de horario de verano.
function clinicOffsetMinutes(at) {
  const local = new Date(at.toLocaleString("en-US", { timeZone: CLINIC_TIME_ZONE }));
  const utc = new Date(at.toLocaleString("en-US", { timeZone: "UTC" }));
  return Math.round((local.getTime() - utc.getTime()) / 60000);
}

// Rango [startUtc, endUtc) en UTC que cubre un día local completo de la clínica.
// `ymd` opcional (YYYY-MM-DD); por defecto, el día de hoy en Chile.
function clinicDayRangeUtc(ymd) {
  const day =
    ymd ||
    new Intl.DateTimeFormat("en-CA", {
      timeZone: CLINIC_TIME_ZONE,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date());
  const [y, m, d] = day.split("-").map(Number);
  // Offset calculado a mediodía para no caer justo sobre el salto de horario.
  const offsetMin = clinicOffsetMinutes(new Date(Date.UTC(y, m - 1, d, 12)));
  const startUtc = new Date(Date.UTC(y, m - 1, d, 0, 0, 0) - offsetMin * 60000);
  const endUtc = new Date(startUtc.getTime() + 24 * 60 * 60 * 1000);
  return { day, startUtc, endUtc };
}

// "HH:MM" de una cita, en hora de Chile (no UTC).
function formatClinicClock(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: CLINIC_TIME_ZONE,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

// "YYYY-MM-DD" de una cita, en día local de Chile (no UTC).
function formatClinicDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: CLINIC_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

// ---- Puente cita -> ficha del paciente -----------------------------------
// El estado del paciente (patients.status) alimenta el dashboard y la vista
// "Pacientes del día". Cuando una cita pasa a 'en_atencion' o 'atendida', ese
// estado tiene que moverse con ella, o el tablero queda desincronizado desde
// el primer uso de la agenda. Best-effort: si el update falla, solo se deja un
// warning y la operación sobre la cita no se cae.
const APPOINTMENT_STATUS_TO_PATIENT_STATUS = {
  en_atencion: "En atención",
  atendida: "Atendido",
};

async function syncPatientStatusFromAppointment(patientId, appointmentStatus) {
  const target = APPOINTMENT_STATUS_TO_PATIENT_STATUS[appointmentStatus];
  if (!target) return;
  const numericId = Number(patientId);
  if (!Number.isInteger(numericId)) return;
  const { error } = await supabase
    .from("patients")
    .update({ status: target })
    .eq("id", numericId);
  if (error) {
    console.warn(
      "No fue posible sincronizar el estado del paciente con la cita:",
      error.message,
    );
  }
}

// ---- Choque de agenda ----------------------------------------------------
// Dos citas activas no pueden solaparse en el tiempo si comparten sala o
// profesional. Devuelve { appointment, reason } de la primera cita en
// conflicto, o null. La hora de término se calcula acá (no hay columna end_at:
// depende de duration_min), así que se trae una ventana amplia y el solape
// exacto se filtra en memoria.
async function findAppointmentConflict({
  scheduledAt,
  durationMin,
  roomId,
  professional,
  excludeId,
}) {
  const start = scheduledAt.getTime();
  const end = start + (Number(durationMin) || 30) * 60000;
  const prof = (professional ?? "").trim();
  // Sin sala ni profesional no hay nada con qué chocar.
  if (!roomId && !prof) return null;

  const windowStart = new Date(start - 12 * 60 * 60 * 1000).toISOString();
  const windowEnd = new Date(end + 12 * 60 * 60 * 1000).toISOString();

  const { data, error } = await supabase
    .from("appointments")
    .select(
      "id, scheduled_at, duration_min, room_id, professional, status, patient:patients(name), room:rooms(name)",
    )
    .gte("scheduled_at", windowStart)
    .lt("scheduled_at", windowEnd)
    .not("status", "in", "(cancelada,no_asistio)");
  if (error) throw error;

  for (const row of data ?? []) {
    if (excludeId && row.id === excludeId) continue;
    const sameRoom = Boolean(roomId) && row.room_id === roomId;
    const sameProf =
      prof.length > 0 &&
      (row.professional ?? "").trim().toLowerCase() === prof.toLowerCase();
    if (!sameRoom && !sameProf) continue;

    const rowStart = new Date(row.scheduled_at).getTime();
    const rowEnd = rowStart + (Number(row.duration_min) || 30) * 60000;
    if (rowStart < end && rowEnd > start) {
      return { appointment: row, reason: sameRoom ? "sala" : "profesional" };
    }
  }
  return null;
}

function appointmentConflictMessage({ appointment, reason }) {
  const clock = formatClinicClock(appointment.scheduled_at);
  const patientName = appointment.patient?.name;
  const detail = patientName ? ` con ${patientName}` : "";
  if (reason === "sala") {
    const roomName = appointment.room?.name ?? "asignada";
    return `La sala "${roomName}" ya tiene una cita a las ${clock}${detail}.`;
  }
  return `El profesional ya tiene una cita a las ${clock}${detail}.`;
}

function shapeStaffRow(row) {
  return {
    id: row.id,
    email: row.email,
    fullName: row.full_name,
    role: row.role,
    createdAt: row.created_at,
  };
}

function shapeClinicRow(row) {
  return {
    id: row.id,
    name: row.name,
    address: row.address,
    status: row.status,
    dicomAeTitle: row.dicom_ae_title,
    dicomPort: row.dicom_port,
    createdAt: row.created_at,
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

// Etapa 3 (paso 3a) del plan multi-clínica: true si el paciente puede verse/
// editarse desde la sesión actual. Si el paciente o quien hace la petición
// todavía no tienen clinic_id asignado (dato no migrado / rollout gradual),
// no bloquea -- solo compara cuando ambos lados tienen clínica asignada.
async function patientBelongsToRequesterClinic(patientId, request) {
  const requesterClinicId = request.staffProfile?.clinic_id ?? null;
  if (!requesterClinicId) return true;

  const { data, error } = await supabase
    .from("patients")
    .select("clinic_id")
    .eq("id", Number(patientId))
    .maybeSingle();
  if (error) throw error;
  if (!data) return true; // no encontrado: que lo reporte el fetch principal

  const patientClinicId = data.clinic_id ?? null;
  return !patientClinicId || patientClinicId === requesterClinicId;
}

// Etapa 3 (paso 3a): clinicId es opcional -- cuando se pasa, la búsqueda de
// RUT duplicado se limita a esa clínica. Los llamadores sin sesión (booking
// público) o todavía no revisados (documentos) siguen sin pasarlo, sin
// cambio de comportamiento ahí.
async function findPatientsByRutDb(rut, excludeId = null, clinicId = null) {
  const normalized = normalizeRut(rut);
  if (!normalized) return [];

  let query = supabase.from("patients").select("id, name, rut");
  if (clinicId) {
    query = query.eq("clinic_id", clinicId);
  }
  const { data, error } = await query;
  if (error) throw error;

  return (data ?? []).filter(
    (patient) =>
      patient.id !== Number(excludeId) && normalizeRut(patient.rut) === normalized,
  );
}

// Guarda (o actualiza) la fila de `documents` y su `history_events` asociado
// para un documento ya analizado por IA. Compartido entre el guardado
// automático al analizar (POST /documents/analyze) y la incorporación manual
// (PATCH /from-document), para que ambos caminos dejen el documento en el
// mismo estado y no se dupliquen filas.
async function saveDocumentRecord({ targetPatientId, documentData, filename, imagingOrderId = null }) {
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

  const documentType = cleanValue(documentData.documentType);
  const exam = cleanValue(documentData.exam);
  const patientName = cleanValue(documentData.patientName);
  const patientRut = cleanValue(documentData.patientRut);
  const patientAge = parseAge(documentData.patientAge);
  const reason = cleanValue(documentData.reason);
  const priority = cleanValue(documentData.priority);
  const date = cleanValue(documentData.date);
  const equipment = cleanValue(documentData.equipment);
  const summary = cleanValue(documentData.summary);
  const doctor = cleanValue(documentData.doctor);

  const normalizedFilename = normalizeDocumentName(filename);

  // Si el mismo archivo quedó por error asociado a otra ficha, lo retiramos
  // de ahí (evita que un mismo PDF quede "pegado" a dos pacientes).
  const { data: otherDocs, error: otherDocsError } = await supabase
    .from("documents")
    .select("id, filename")
    .neq("patient_id", targetPatientId);
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
    .eq("patient_id", targetPatientId);
  if (existingDocsError) throw existingDocsError;

  const existingDoc = (existingDocs ?? []).find(
    (doc) => normalizeDocumentName(doc.filename) === normalizedFilename,
  );

  const documentRow = {
    patient_id: targetPatientId,
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
    // Cada vez que se (re)guarda un documento, su validación humana vuelve a
    // quedar pendiente: es información nueva que todavía no ha sido
    // revisada por un profesional.
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
      patient_id: targetPatientId,
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
      .eq("patient_id", targetPatientId);
    if (orderUpdateError) throw orderUpdateError;
  }

  return savedDocId;
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
Eres Imagenda, un asistente de apoyo para equipos de salud.

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
  response.send("Imagenda Backend funcionando");
});

app.get("/health", (_request, response) => {
  response.json({
    estado: "OK",
    servicio: "Imagenda Backend",
    fecha: new Date().toISOString(),
    modelo: model,
  });
});

app.post("/auth/login", async (request, response) => {
  try {
    const email = typeof request.body?.email === "string" ? request.body.email.trim() : "";
    const password = typeof request.body?.password === "string" ? request.body.password : "";

    if (!email || !password) {
      return response.status(400).json({ error: "Debes ingresar tu email y tu contraseña." });
    }

    const { data, error } = await supabaseAuth.auth.signInWithPassword({ email, password });

    if (error || !data?.session) {
      return response.status(401).json({ error: "Email o contraseña incorrectos." });
    }

    const { data: profileRow } = await supabase
      .from("staff_profiles")
      .select("*")
      .eq("id", data.user.id)
      .maybeSingle();

    return response.json({
      accessToken: data.session.access_token,
      user: {
        id: data.user.id,
        email: data.user.email,
        role: profileRow?.role ?? null,
        fullName: profileRow?.full_name ?? null,
        clinicId: profileRow?.clinic_id ?? null,
      },
    });
  } catch (error) {
    console.error("Error al iniciar sesión:", error);
    return response.status(500).json({ error: "No fue posible iniciar sesión. Intenta de nuevo." });
  }
});

// A partir de aquí, todas las rutas requieren haber iniciado sesión y
// tener un rol asignado. Algunas rutas además exigen un rol específico.
app.use("/patients", requireAuth);
app.use("/dashboard", requireAuth);
app.use("/rooms", requireAuth);
app.use("/appointments", requireAuth);
app.use("/chat", requireAuth, requireRole(AI_STAFF));
app.use("/lab", requireAuth);
app.use("/imaging", requireAuth);
app.use("/orthanc-studies", requireAuth);
app.use("/dental", requireAuth);
app.use("/billing", requireAuth);
app.use("/staff", requireAuth, requireRole(ADMIN_ONLY));
app.use("/clinics", requireAuth, requireRole(ADMIN_ONLY));
app.use("/notifications", requireAuth);
app.use("/mail", requireAuth, requireRole(MAIL_STAFF));

// Agenda del día leída desde la tabla appointments. Devuelve filas con la MISMA
// forma que /patients/today esperaba (id = id del paciente, para abrir la
// ficha), sobrescribiendo hora / sala / estado / examen con los datos de la
// cita. Devuelve null si la tabla appointments todavía no existe (SQL no
// corrido) o si no hay citas para hoy: en ese caso el endpoint cae al
// comportamiento anterior (leer patients.time) y la vista no se rompe.
async function loadTodayAgendaFromAppointments(canSeeClinicalData, clinicId = null) {
  // Ventana "de hoy" = día local completo de la clínica (Chile), convertido a
  // límites UTC. El backfill del SQL fecha las citas con el mismo criterio
  // (timezone('America/Santiago', now())).
  const { startUtc, endUtc } = clinicDayRangeUtc();

  let query = supabase
    .from("appointments")
    .select("*, patient:patients(*), room:rooms(name)")
    .gte("scheduled_at", startUtc.toISOString())
    .lt("scheduled_at", endUtc.toISOString())
    .neq("status", "cancelada")
    .order("scheduled_at", { ascending: true });

  // Etapa 3 (paso 3a): solo /patients/today pasa clinicId -- /dashboard/summary
  // sigue llamando esta función sin él, sin cambios de comportamiento ahí.
  if (clinicId) {
    query = query.eq("clinic_id", clinicId);
  }

  const { data, error } = await query;

  if (error) {
    console.warn("No fue posible leer la agenda de citas:", error.message);
    return null;
  }
  if (!data || data.length === 0) return null;

  const shapePatient = canSeeClinicalData ? shapePatientRow : shapePatientRowBasic;

  return data
    .filter((row) => row.patient)
    .map((row) => {
      const base = shapePatient(row.patient);
      return {
        ...base,
        // id se mantiene = id del paciente (lo usa la app para abrir la ficha).
        appointmentId: row.id,
        appointmentStatus: row.status,
        scheduledAt: row.scheduled_at,
        durationMin: row.duration_min,
        roomId: row.room_id,
        time: formatClinicClock(row.scheduled_at),
        room: row.room?.name ?? base.room ?? "",
        status: APPOINTMENT_STATUS_LABEL[row.status] ?? base.status,
        exam: row.reason ?? base.exam ?? "",
        doctor: row.professional ?? base.doctor ?? "",
      };
    });
}

// Lista liviana de pacientes para selectores (por ejemplo, "nueva cita" en la
// agenda). Solo identificación, sin datos clínicos. Disponible para el
// personal de agenda, que incluye recepción.
app.get("/patients", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    // ilike con comodines: se limpian los caracteres que rompen el filtro .or()
    // de PostgREST (comas y paréntesis) y el propio patrón (%).
    const search = (request.query.search ?? "")
      .toString()
      .trim()
      .replace(/[,()%*]/g, "")
      .slice(0, 80);

    let query = supabase
      .from("patients")
      .select("id, name, rut, phone")
      .order("name", { ascending: true })
      .limit(500);

    // Etapa 3 (paso 3a): solo filtra si quien pide tiene clínica asignada.
    if (request.staffProfile?.clinic_id) {
      query = query.eq("clinic_id", request.staffProfile.clinic_id);
    }

    if (search) {
      query = query.or(`name.ilike.%${search}%,rut.ilike.%${search}%`);
    }

    const { data, error } = await query;
    if (error) throw error;

    return response.json({
      patients: (data ?? []).map((row) => ({
        id: row.id,
        name: row.name,
        rut: row.rut,
        phone: row.phone,
      })),
    });
  } catch (error) {
    console.error("Error al obtener la lista de pacientes:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener la lista de pacientes." });
  }
});

// Alta de un paciente nuevo. Solo captura la IDENTIDAD (nombre, rut, edad,
// sexo, teléfono, observaciones); los campos de "cita" heredados de patients
// (time, room, exam, status, doctor) los llena la cita, no esto. Disponible
// para el personal de agenda (incluye recepción, que registra pacientes en el
// mesón). La corrección posterior se hace vía PATCH /patients/:id.
app.post("/patients", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const { values, error: validationError } = parsePatientIdentityInput(request.body, {
      partial: false,
    });
    if (validationError) {
      return response.status(400).json({ error: validationError });
    }

    // Deduplicación por RUT: no se crea una ficha si ya existe otra con el
    // mismo RUT. Se devuelven las coincidencias para que la UI ofrezca usar
    // la ficha existente.
    const duplicates = await findPatientsByRutDb(
      values.rut,
      null,
      request.staffProfile?.clinic_id ?? null,
    );
    if (duplicates.length > 0) {
      return response.status(409).json({
        error: "Ya existe una ficha con este RUT.",
        matches: duplicates.map((p) => ({ id: p.id, name: p.name, rut: p.rut })),
      });
    }

    // Solo columnas de identidad: el resto queda con el default de la tabla.
    // Los campos opcionales ausentes se insertan como null (comportamiento
    // histórico), luego `values` sobreescribe lo que llegó en el body.
    const { data, error } = await supabase
      .from("patients")
      // Etapa 3 (paso 3a): clinic_id va al final para que nunca lo sobrescriba
      // el body -- siempre es el de quien crea la ficha, no algo enviado por
      // el cliente.
      .insert({
        age: null,
        sexo: null,
        phone: null,
        observations: null,
        ...values,
        clinic_id: request.staffProfile?.clinic_id ?? null,
      })
      .select("id, name, rut, phone")
      .single();
    if (error) throw error;

    return response.status(201).json({
      patient: { id: data.id, name: data.name, rut: data.rut, phone: data.phone },
    });
  } catch (error) {
    console.error("Error al crear el paciente:", error);
    return response.status(500).json({ error: "No fue posible crear el paciente." });
  }
});

// Ficha de identidad para editar. A diferencia de GET /patients/:id, es de
// solo lectura pura: no dispara la generación del resumen IA ni carga
// documentos/historial. Mismo rol que el alta (AGENDA_STAFF).
app.get("/patients/:id/identity", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    if (!Number.isInteger(patientId)) {
      return response.status(400).json({ error: "Identificador de paciente inválido." });
    }

    const { data, error } = await supabase
      .from("patients")
      .select("id, name, rut, age, sexo, phone, observations, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (error) throw error;
    if (!data) return response.status(404).json({ error: "Paciente no encontrado" });

    // Etapa 3 (paso 3a): si el paciente es de otra clínica, se responde igual
    // que "no encontrado" (no se confirma su existencia a quien no debería verla).
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;
    if (requesterClinicId && data.clinic_id && data.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    const { clinic_id, ...patient } = data;
    return response.json({ patient });
  } catch (error) {
    console.error("Error al obtener la identidad del paciente:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener la ficha del paciente." });
  }
});

// Edición de la ficha de identidad. Body PARCIAL: solo se actualizan las
// claves presentes; un valor null/"" limpia el campo (salvo nombre y rut).
// Los campos de "cita" (time, room, exam, status, doctor) y los derivados
// clínicos/IA (priority, risk, ai_summary) no se tocan desde acá.
app.patch("/patients/:id", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    if (!Number.isInteger(patientId)) {
      return response.status(400).json({ error: "Identificador de paciente inválido." });
    }

    const { data: existing, error: lookupError } = await supabase
      .from("patients")
      .select("id, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (lookupError) throw lookupError;
    if (!existing) return response.status(404).json({ error: "Paciente no encontrado" });

    // Etapa 3 (paso 3a): mismo criterio que GET /patients/:id/identity.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;
    if (requesterClinicId && existing.clinic_id && existing.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    const { values, error: validationError } = parsePatientIdentityInput(request.body, {
      partial: true,
    });
    if (validationError) {
      return response.status(400).json({ error: validationError });
    }
    if (Object.keys(values).length === 0) {
      return response.status(400).json({ error: "No se recibieron campos para actualizar." });
    }

    // Si cambia el RUT, misma deduplicación que el alta, excluyendo la propia
    // ficha.
    if (values.rut !== undefined) {
      const duplicates = await findPatientsByRutDb(
        values.rut,
        patientId,
        request.staffProfile?.clinic_id ?? null,
      );
      if (duplicates.length > 0) {
        return response.status(409).json({
          error: "Ya existe otra ficha con este RUT.",
          matches: duplicates.map((p) => ({ id: p.id, name: p.name, rut: p.rut })),
        });
      }
    }

    const { data, error } = await supabase
      .from("patients")
      .update(values)
      .eq("id", patientId)
      .select("id, name, rut, phone")
      .single();
    if (error) throw error;

    return response.json({
      patient: { id: data.id, name: data.name, rut: data.rut, phone: data.phone },
    });
  } catch (error) {
    console.error("Error al actualizar el paciente:", error);
    return response.status(500).json({ error: "No fue posible actualizar el paciente." });
  }
});

app.get("/patients/today", async (request, response) => {
  try {
    // Por seguridad, solo el personal clínico (administrador, medico, tecnico)
    // recibe la ficha completa. Cualquier otro rol (recepcion o un rol no
    // reconocido) recibe la versión reducida, sin datos clínicos.
    const canSeeClinicalData = CLINICAL_STAFF.includes(request.staffRole);
    const { day } = clinicDayRangeUtc();
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;

    const agenda = await loadTodayAgendaFromAppointments(canSeeClinicalData, requesterClinicId);
    if (agenda) {
      return response.json({
        fecha: day,
        total: agenda.length,
        patients: agenda,
        source: "appointments",
      });
    }

    // Fallback: agenda derivada de patients.time (comportamiento previo a Citas).
    let fallbackQuery = supabase
      .from("patients")
      .select("*")
      .order("time", { ascending: true });

    if (requesterClinicId) {
      fallbackQuery = fallbackQuery.eq("clinic_id", requesterClinicId);
    }

    const { data, error } = await fallbackQuery;

    if (error) throw error;

    const patients = (data ?? []).map(
      canSeeClinicalData ? shapePatientRow : shapePatientRowBasic,
    );

    return response.json({
      fecha: day,
      total: patients.length,
      patients,
      source: "patients",
    });
  } catch (error) {
    console.error("Error al obtener pacientes de hoy:", error);
    return response.status(500).json({ error: "No fue posible obtener los pacientes." });
  }
});

// Métricas reales del dashboard, calculadas desde la base de datos.
// Solo personal clínico: el rol recepcion no ve indicadores agregados.
app.get("/dashboard/summary", requireRole(CLINICAL_STAFF), async (_request, response) => {
  try {
    // Total de salas: catálogo real (rooms activas). Si la tabla todavía no
    // existe o está vacía, se cae al valor histórico para no romper la métrica.
    const FALLBACK_ROOM_COUNT = 3;
    let totalKnownRooms = FALLBACK_ROOM_COUNT;
    const { count: activeRoomCount, error: roomsError } = await supabase
      .from("rooms")
      .select("id", { count: "exact", head: true })
      .eq("active", true);
    if (!roomsError && typeof activeRoomCount === "number" && activeRoomCount > 0) {
      totalKnownRooms = activeRoomCount;
    }

    // Pacientes de hoy / estados / salas en uso: se derivan de la agenda real
    // (tabla appointments), igual que /patients/today — así ambas vistas
    // siempre coinciden. `appointmentStatus` es el enum crudo de la cita
    // ('en_espera', 'en_atencion', 'programada', ...), no la etiqueta en
    // español. "Pacientes hoy" incluye no_asistio (seguían siendo la agenda
    // del día), solo excluye cancelada (ya lo hace loadTodayAgendaFromAppointments).
    //
    // Fallback si la tabla todavía no existe o no hay citas para hoy:
    // comportamiento histórico (todos los pacientes de la tabla patients),
    // para no romper el dashboard entre el deploy y el Run del SQL.
    const todayAgenda = await loadTodayAgendaFromAppointments(true);

    let patientsToday;
    let waiting;
    let inAttention;
    let scheduled;
    let roomsInUse;

    if (todayAgenda) {
      patientsToday = todayAgenda.length;
      waiting = todayAgenda.filter((p) => p.appointmentStatus === "en_espera").length;
      inAttention = todayAgenda.filter((p) => p.appointmentStatus === "en_atencion").length;
      scheduled = todayAgenda.filter((p) => p.appointmentStatus === "programada").length;
      // Salas en uso: catálogo real (appointments.room_id -> rooms), no el
      // string libre patients.room, acotado a las citas de HOY en atención.
      roomsInUse = new Set(
        todayAgenda
          .filter((p) => p.appointmentStatus === "en_atencion" && p.roomId)
          .map((p) => p.roomId),
      ).size;
    } else {
      const { data: patientRows, error: patientsError } = await supabase
        .from("patients")
        .select("id, status, room");
      if (patientsError) throw patientsError;

      const patients = patientRows ?? [];
      patientsToday = patients.length;
      waiting = patients.filter((p) => p.status === "Esperando").length;
      inAttention = patients.filter((p) => p.status === "En atención").length;
      scheduled = patients.filter((p) => p.status === "Programado").length;
      roomsInUse = new Set(
        patients
          .filter((p) => p.status === "En atención")
          .map((p) => (typeof p.room === "string" ? p.room.trim() : ""))
          .filter((room) => room.length > 0),
      ).size;
    }

    const { count: documentsCount, error: docsCountError } = await supabase
      .from("documents")
      .select("id", { count: "exact", head: true });
    if (docsCountError) throw docsCountError;

    const totalDocuments = documentsCount ?? 0;

    // Análisis de IA (histórico, sin backfill). Cuenta documentos/fichas
    // distintos, no cada re-análisis. Mientras la función ai_analysis_metrics
    // no exista (SQL no corrido), se mantiene el comportamiento anterior para
    // no regresar la UI: analizados = total, sin analizar = 0.
    let documentsAnalyzedByAi = totalDocuments;
    let documentsAwaitingAnalysis = 0;
    let patientsWithAiSummary = 0;
    let aiAnalysesTotal = totalDocuments;
    const { data: aiMetrics, error: aiMetricsError } = await supabase.rpc("ai_analysis_metrics");
    if (aiMetricsError) {
      console.warn("No fue posible obtener métricas de análisis de IA:", aiMetricsError.message);
    } else if (aiMetrics && typeof aiMetrics === "object") {
      documentsAnalyzedByAi = Number(aiMetrics.documentsAnalyzed) || 0;
      documentsAwaitingAnalysis = Number(aiMetrics.documentsAwaiting) || 0;
      patientsWithAiSummary = Number(aiMetrics.patientSummaries) || 0;
      aiAnalysesTotal = Number(aiMetrics.total) || 0;
    }

    // "Pendientes de validación" = todo lo que un profesional todavía tiene
    // que revisar/aprobar: documentos sin validar + órdenes clínicas ya
    // listas (con resultado/informe) pero aún no validadas.
    const countPending = async (table, column, value) => {
      const { count, error } = await supabase
        .from(table)
        .select("id", { count: "exact", head: true })
        .eq(column, value);
      if (error) throw error;
      return count ?? 0;
    };

    const [
      pendingDocuments,
      pendingLabOrders,
      pendingImagingOrders,
      pendingDentalOrders,
    ] = await Promise.all([
      countPending("documents", "validation_status", "pendiente"),
      countPending("lab_orders", "status", "completado"),
      countPending("imaging_orders", "status", "informado"),
      countPending("dental_orders", "status", "realizado"),
    ]);

    const pendingValidation =
      pendingDocuments +
      pendingLabOrders +
      pendingImagingOrders +
      pendingDentalOrders;

    return response.json({
      fecha: new Date().toISOString().split("T")[0],
      patientsToday,
      waiting,
      inAttention,
      scheduled,
      pendingValidation,
      pendingValidationBreakdown: {
        documents: pendingDocuments,
        labOrders: pendingLabOrders,
        imagingOrders: pendingImagingOrders,
        dentalOrders: pendingDentalOrders,
      },
      documentsToValidate: pendingDocuments,
      totalUploadedDocuments: totalDocuments,
      totalAnalyzedDocuments: documentsAnalyzedByAi,
      documentsAwaitingAnalysis,
      patientsWithAiSummary,
      aiAnalysesTotal,
      roomsInUse,
      totalKnownRooms,
    });
  } catch (error) {
    console.error("Error al calcular el resumen del dashboard:", error);
    return response.status(500).json({ error: "No fue posible calcular el resumen." });
  }
});

// Catálogo de salas. Lo consume el dashboard (Fase 2) y, más adelante, el
// selector de sala de Citas. Por defecto solo salas activas; ?all=1 devuelve
// también las inactivas.
app.get("/rooms", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    let query = supabase
      .from("rooms")
      .select("id, name, kind, capacity, active, sort_order")
      .order("sort_order", { ascending: true })
      .order("name", { ascending: true });

    if (request.query.all !== "1" && request.query.all !== "true") {
      query = query.eq("active", true);
    }

    // Mismo criterio que /patients: solo filtra si quien pide tiene clínica
    // asignada.
    if (request.staffProfile?.clinic_id) {
      query = query.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data, error } = await query;
    if (error) throw error;

    return response.json({ rooms: (data ?? []).map(shapeRoomRow) });
  } catch (error) {
    console.error("Error al obtener las salas:", error);
    return response.status(500).json({ error: "No fue posible obtener las salas." });
  }
});

// ---- Agenda de citas (tabla appointments). Personal clínico + recepción.

// GET /appointments?date=YYYY-MM-DD&from=&to=&status=&roomId=&patientId=
// Sin filtros de fecha devuelve la agenda del día local de la clínica (Chile).
app.get("/appointments", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const { date, from, to, status, roomId, patientId } = request.query;

    let rangeStart;
    let rangeEnd;
    if (from || to) {
      // Instantes ISO explícitos: se usan tal cual.
      if (from) rangeStart = new Date(from);
      if (to) rangeEnd = new Date(to);
      if ((from && Number.isNaN(rangeStart.getTime())) || (to && Number.isNaN(rangeEnd.getTime()))) {
        return response.status(400).json({ error: "El rango de fechas indicado no es válido." });
      }
    } else {
      // `date` (o el día de hoy): día local completo de la clínica -> límites UTC.
      if (date && !/^\d{4}-\d{2}-\d{2}$/.test(String(date))) {
        return response.status(400).json({ error: "La fecha debe tener el formato YYYY-MM-DD." });
      }
      const { startUtc, endUtc } = clinicDayRangeUtc(date || undefined);
      rangeStart = startUtc;
      rangeEnd = endUtc;
    }

    let query = supabase
      .from("appointments")
      .select("*, patient:patients(name), room:rooms(name)")
      .order("scheduled_at", { ascending: true });

    if (rangeStart) query = query.gte("scheduled_at", rangeStart.toISOString());
    if (rangeEnd) query = query.lt("scheduled_at", rangeEnd.toISOString());
    if (status) {
      const wanted = String(status).split(",").map((s) => s.trim()).filter(Boolean);
      const invalid = wanted.filter((s) => !APPOINTMENT_STATUSES.includes(s));
      if (invalid.length) {
        return response.status(400).json({ error: `Estado no válido: ${invalid.join(", ")}` });
      }
      query = wanted.length === 1 ? query.eq("status", wanted[0]) : query.in("status", wanted);
    }
    if (roomId) query = query.eq("room_id", roomId);
    if (patientId) query = query.eq("patient_id", Number(patientId));

    // Mismo criterio que /patients: solo filtra si quien pide tiene clínica
    // asignada.
    if (request.staffProfile?.clinic_id) {
      query = query.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data, error } = await query;
    if (error) throw error;

    return response.json({ appointments: (data ?? []).map(shapeAppointmentRow) });
  } catch (error) {
    console.error("Error al obtener la agenda de citas:", error);
    return response.status(500).json({ error: "No fue posible obtener la agenda de citas." });
  }
});

// POST /appointments
// { patientId, scheduledAt, roomId?, durationMin?, professional?, reason?, notes?, status? }
app.post("/appointments", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const body = request.body ?? {};
    const patientId = Number(body.patientId);
    if (!Number.isInteger(patientId)) {
      return response.status(400).json({ error: "Debes indicar el paciente de la cita." });
    }

    const scheduledAt = body.scheduledAt ? new Date(body.scheduledAt) : null;
    if (!scheduledAt || Number.isNaN(scheduledAt.getTime())) {
      return response.status(400).json({ error: "Debes indicar una fecha y hora válidas para la cita." });
    }

    const status = body.status ?? "programada";
    if (!APPOINTMENT_STATUSES.includes(status)) {
      return response.status(400).json({ error: "El estado de la cita no es válido." });
    }

    let durationMin = 30;
    if (body.durationMin !== undefined && body.durationMin !== null) {
      durationMin = Number(body.durationMin);
      if (!Number.isFinite(durationMin) || durationMin <= 0) {
        return response.status(400).json({ error: "La duración debe ser un número de minutos mayor que cero." });
      }
    }

    // Etapa 5: mismo criterio que /patients -- el paciente y la sala (si se
    // indica) tienen que pertenecer a la misma clínica de quien crea la cita,
    // no solo existir.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });
    if (requesterClinicId && patientRow.clinic_id && patientRow.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    if (body.roomId) {
      const { data: roomRow, error: roomError } = await supabase
        .from("rooms")
        .select("id, clinic_id")
        .eq("id", body.roomId)
        .maybeSingle();
      if (roomError) throw roomError;
      if (!roomRow) return response.status(404).json({ error: "La sala indicada no existe." });
      if (requesterClinicId && roomRow.clinic_id && roomRow.clinic_id !== requesterClinicId) {
        return response.status(404).json({ error: "La sala indicada no existe." });
      }
    }

    // Choque de agenda: misma sala o mismo profesional a una hora que se
    // solapa. Los estados cancelada/no_asistio no bloquean.
    if (!["cancelada", "no_asistio"].includes(status)) {
      const conflict = await findAppointmentConflict({
        scheduledAt,
        durationMin,
        roomId: body.roomId || null,
        professional: body.professional,
      });
      if (conflict) {
        return response.status(409).json({ error: appointmentConflictMessage(conflict) });
      }
    }

    const { data, error } = await supabase
      .from("appointments")
      .insert({
        patient_id: patientId,
        room_id: body.roomId || null,
        scheduled_at: scheduledAt.toISOString(),
        duration_min: durationMin,
        status,
        professional: body.professional?.trim() || null,
        reason: body.reason?.trim() || null,
        notes: body.notes?.trim() || null,
        // clinic_id va al final para que nunca lo sobrescriba un campo del
        // body (mismo criterio que POST /patients, Etapa 3).
        clinic_id: requesterClinicId,
      })
      .select("*, patient:patients(name), room:rooms(name)")
      .single();
    if (error) throw error;

    // Si la cita nace ya "en atención" o "atendida", arrastra el estado del
    // paciente para no dejar el dashboard desincronizado.
    await syncPatientStatusFromAppointment(patientId, status);

    return response.status(201).json({ appointment: shapeAppointmentRow(data) });
  } catch (error) {
    console.error("Error al crear la cita:", error);
    return response.status(500).json({ error: "No fue posible crear la cita." });
  }
});

// PATCH /appointments/:id
// Reprograma, reasigna sala, cambia estado (incluye 'cancelada') o edita datos.
app.patch("/appointments/:id", requireRole(AGENDA_STAFF), async (request, response) => {
  try {
    const body = request.body ?? {};
    const patch = {};

    if (body.scheduledAt !== undefined) {
      const scheduledAt = body.scheduledAt ? new Date(body.scheduledAt) : null;
      if (!scheduledAt || Number.isNaN(scheduledAt.getTime())) {
        return response.status(400).json({ error: "La fecha y hora de la cita no son válidas." });
      }
      patch.scheduled_at = scheduledAt.toISOString();
    }

    if (body.status !== undefined) {
      if (!APPOINTMENT_STATUSES.includes(body.status)) {
        return response.status(400).json({ error: "El estado de la cita no es válido." });
      }
      patch.status = body.status;
    }

    if (body.durationMin !== undefined) {
      const durationMin = Number(body.durationMin);
      if (!Number.isFinite(durationMin) || durationMin <= 0) {
        return response.status(400).json({ error: "La duración debe ser un número de minutos mayor que cero." });
      }
      patch.duration_min = durationMin;
    }

    if (body.roomId !== undefined) {
      if (body.roomId) {
        const { data: roomRow, error: roomError } = await supabase
          .from("rooms")
          .select("id")
          .eq("id", body.roomId)
          .maybeSingle();
        if (roomError) throw roomError;
        if (!roomRow) return response.status(404).json({ error: "La sala indicada no existe." });
        patch.room_id = body.roomId;
      } else {
        patch.room_id = null;
      }
    }

    if (body.professional !== undefined) patch.professional = body.professional?.trim() || null;
    if (body.reason !== undefined) patch.reason = body.reason?.trim() || null;
    if (body.notes !== undefined) patch.notes = body.notes?.trim() || null;

    if (Object.keys(patch).length === 0) {
      return response.status(400).json({ error: "No se recibieron cambios para la cita." });
    }

    const { data: existing, error: existingError } = await supabase
      .from("appointments")
      .select("*")
      .eq("id", request.params.id)
      .maybeSingle();
    if (existingError) throw existingError;
    if (!existing) return response.status(404).json({ error: "Cita no encontrada" });

    // Etapa 5: mismo criterio que /patients -- la fila ya se cargó completa
    // arriba, solo falta comparar su clínica contra la de quien pide el
    // cambio.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;
    if (requesterClinicId && existing.clinic_id && existing.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Cita no encontrada" });
    }

    // Revalida el choque de agenda si cambió algo que afecta el solape (hora,
    // duración, sala o profesional). Los estados cancelada/no_asistio liberan
    // el bloque, así que en ese caso no se valida.
    const effectiveStatus = patch.status ?? existing.status;
    const touchesOverlap =
      patch.scheduled_at !== undefined ||
      patch.duration_min !== undefined ||
      patch.room_id !== undefined ||
      patch.professional !== undefined;
    if (touchesOverlap && !["cancelada", "no_asistio"].includes(effectiveStatus)) {
      const conflict = await findAppointmentConflict({
        scheduledAt: new Date(patch.scheduled_at ?? existing.scheduled_at),
        durationMin: patch.duration_min ?? existing.duration_min ?? 30,
        roomId: patch.room_id !== undefined ? patch.room_id : existing.room_id,
        professional:
          patch.professional !== undefined ? patch.professional : existing.professional,
        excludeId: existing.id,
      });
      if (conflict) {
        return response.status(409).json({ error: appointmentConflictMessage(conflict) });
      }
    }

    patch.updated_at = new Date().toISOString();

    const { data, error } = await supabase
      .from("appointments")
      .update(patch)
      .eq("id", request.params.id)
      .select("*, patient:patients(name), room:rooms(name)")
      .maybeSingle();
    if (error) throw error;
    if (!data) return response.status(404).json({ error: "Cita no encontrada" });

    // Puente hacia la ficha: si la cita pasó a 'en_atencion' o 'atendida',
    // mueve también patients.status.
    if (patch.status) {
      await syncPatientStatusFromAppointment(data.patient_id, patch.status);
    }

    return response.json({ appointment: shapeAppointmentRow(data) });
  } catch (error) {
    console.error("Error al actualizar la cita:", error);
    return response.status(500).json({ error: "No fue posible actualizar la cita." });
  }
});

// ============================================================================
// AUTOAGENDAMIENTO WEB (RESERVA PÚBLICA) — Etapa 1
// ----------------------------------------------------------------------------
// El paciente reserva hora sin iniciar sesión y SIN elegir sala ni
// profesional (eso lo asigna después el personal, desde Agendamiento). La
// cita nace con origin = 'web' y room_id = null.
// Requiere haber corrido sql/public_booking.sql (agrega la columna `origin`
// a appointments).
//
// Reglas de partida (ajustables, ver claude/plan-autoagendamiento-web.md):
//   - Horario de atención: 08:00 a 18:00, hora de Chile.
//   - Bloques de 30 minutos.
//   - Cupo por bloque = cantidad de salas activas (mismo criterio que
//     "Salas en uso" del dashboard) -- no distingue sala ni profesional a
//     propósito, porque el paciente todavía no elige ninguno de los dos.
//   - Anticipación mínima: 2 horas. Anticipación máxima: 30 días.
// Estas rutas son públicas (sin requireAuth/requireRole): cualquiera en
// internet puede llamarlas, por eso llevan su propio límite de intentos.
// ============================================================================

const BOOKING_START_HOUR = 8;
const BOOKING_END_HOUR = 18;
const BOOKING_SLOT_MINUTES = 30;
const BOOKING_MIN_LEAD_MINUTES = 120;
const BOOKING_MAX_DAYS_AHEAD = 30;

// Límite de intentos por IP, en memoria. Alcanza para partir; si el backend
// llega a correr en más de una instancia a la vez habría que moverlo a algo
// compartido (ej. Redis) en vez de una variable en memoria del proceso.
const publicBookingHits = new Map(); // ip -> [timestamps en ms]
function isRateLimited(ip, { max, windowMs }) {
  const now = Date.now();
  const hits = (publicBookingHits.get(ip) ?? []).filter((t) => now - t < windowMs);
  hits.push(now);
  publicBookingHits.set(ip, hits);
  return hits.length > max;
}

function bookingSlotLabel(hour, minute) {
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

// Todos los horarios posibles del día, independiente de disponibilidad.
function allBookingSlots() {
  const slots = [];
  let totalMinutes = BOOKING_START_HOUR * 60;
  const endMinutes = BOOKING_END_HOUR * 60;
  while (totalMinutes < endMinutes) {
    slots.push(bookingSlotLabel(Math.floor(totalMinutes / 60), totalMinutes % 60));
    totalMinutes += BOOKING_SLOT_MINUTES;
  }
  return slots;
}

// Convierte fecha (YYYY-MM-DD) + hora (HH:MM), interpretadas en hora de
// Chile, al instante UTC real. Mismo criterio que clinicDayRangeUtc.
function chileLocalToUtc(ymd, hour, minute) {
  const [y, m, d] = ymd.split("-").map(Number);
  const offsetMin = clinicOffsetMinutes(new Date(Date.UTC(y, m - 1, d, 12)));
  return new Date(Date.UTC(y, m - 1, d, hour, minute, 0) - offsetMin * 60000);
}

// "YYYY-MM-DD" que queda a N días desde hoy, en día local de Chile.
function chileDateLabelDaysFromNow(days) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: CLINIC_TIME_ZONE }).format(
    new Date(Date.now() + days * 24 * 60 * 60 * 1000),
  );
}

async function getActiveRoomCount() {
  const { count, error } = await supabase
    .from("rooms")
    .select("id", { count: "exact", head: true })
    .eq("active", true);
  if (error) throw error;
  return count ?? 0;
}

// Cuenta, para un día completo, cuántas citas activas hay en cada bloque de
// BOOKING_SLOT_MINUTES (agrupando cada cita por el bloque en el que cae su
// hora de inicio). Es un cupo global del centro, no por sala ni profesional.
async function countAppointmentsPerBookingSlot(ymd) {
  const { startUtc, endUtc } = clinicDayRangeUtc(ymd);
  const { data, error } = await supabase
    .from("appointments")
    .select("scheduled_at")
    .gte("scheduled_at", startUtc.toISOString())
    .lt("scheduled_at", endUtc.toISOString())
    .not("status", "in", "(cancelada,no_asistio)");
  if (error) throw error;

  const counts = new Map(); // "HH:MM" -> cantidad de citas en ese bloque
  for (const row of data ?? []) {
    const [hh, mm] = formatClinicClock(row.scheduled_at).split(":").map(Number);
    if (Number.isNaN(hh) || Number.isNaN(mm)) continue;
    const totalMinutes = hh * 60 + mm;
    const bucketStart =
      BOOKING_START_HOUR * 60 +
      Math.floor((totalMinutes - BOOKING_START_HOUR * 60) / BOOKING_SLOT_MINUTES) *
        BOOKING_SLOT_MINUTES;
    const label = bookingSlotLabel(Math.floor(bucketStart / 60), bucketStart % 60);
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  return counts;
}

// GET /public/booking/availability?fecha=YYYY-MM-DD
// Devuelve los horarios del día y si cada uno tiene cupo disponible.
app.get("/public/booking/availability", async (request, response) => {
  try {
    if (isRateLimited(request.ip, { max: 60, windowMs: 10 * 60 * 1000 })) {
      return response
        .status(429)
        .json({ error: "Demasiadas solicitudes, intenta de nuevo en unos minutos." });
    }

    const fecha = String(request.query.fecha ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
      return response.status(400).json({ error: "Debes indicar una fecha con formato YYYY-MM-DD." });
    }

    const todayLabel = clinicDayRangeUtc().day;
    if (fecha < todayLabel) {
      return response.status(400).json({ error: "No se puede reservar en una fecha pasada." });
    }
    if (fecha > chileDateLabelDaysFromNow(BOOKING_MAX_DAYS_AHEAD)) {
      return response.status(400).json({
        error: `No se puede reservar con más de ${BOOKING_MAX_DAYS_AHEAD} días de anticipación.`,
      });
    }

    const [roomCount, perSlotCounts] = await Promise.all([
      getActiveRoomCount(),
      countAppointmentsPerBookingSlot(fecha),
    ]);

    const isToday = fecha === todayLabel;
    const now = Date.now();

    const slots = allBookingSlots().map((label) => {
      const [hh, mm] = label.split(":").map(Number);
      const slotUtc = chileLocalToUtc(fecha, hh, mm);
      const meetsLeadTime = slotUtc.getTime() - now >= BOOKING_MIN_LEAD_MINUTES * 60000;
      const used = perSlotCounts.get(label) ?? 0;
      const hasCapacity = roomCount > 0 && used < roomCount;
      return {
        hora: label,
        disponible: hasCapacity && (!isToday || meetsLeadTime),
      };
    });

    return response.json({ fecha, slots });
  } catch (error) {
    console.error("Error al calcular disponibilidad de reserva web:", error);
    return response.status(500).json({ error: "No fue posible calcular los horarios disponibles." });
  }
});

// Correo del paciente en la reserva web: SIEMPRE opcional (ver
// sql/patient_email.sql -- patients.email no existía antes de la Etapa 4 del
// plan de autoagendamiento). Solo se valida el formato cuando se escribió
// algo; en blanco no es un error.
const BOOKING_EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
function parseOptionalBookingEmail(value) {
  if (typeof value !== "string") return { email: null };
  const trimmed = value.trim();
  if (!trimmed) return { email: null };
  if (!BOOKING_EMAIL_RE.test(trimmed)) {
    return { error: "El correo no es válido." };
  }
  return { email: trimmed.toLowerCase() };
}

// POST /public/booking
// { nombre, rut, telefono?, tipo, fecha, hora }
app.post("/public/booking", async (request, response) => {
  try {
    if (isRateLimited(request.ip, { max: 10, windowMs: 10 * 60 * 1000 })) {
      return response
        .status(429)
        .json({ error: "Demasiados intentos, intenta de nuevo en unos minutos." });
    }

    const body = request.body ?? {};

    const { values, error: identityError } = parsePatientIdentityInput(
      { name: body.nombre, rut: body.rut, phone: body.telefono },
      { partial: false },
    );
    if (identityError) {
      return response.status(400).json({ error: identityError });
    }

    const { email: patientEmail, error: emailError } = parseOptionalBookingEmail(body.email);
    if (emailError) {
      return response.status(400).json({ error: emailError });
    }

    const tipo = typeof body.tipo === "string" ? body.tipo.trim() : "";
    if (!tipo) {
      return response.status(400).json({ error: "Debes indicar el tipo de atención." });
    }

    const fecha = String(body.fecha ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
      return response.status(400).json({ error: "La fecha no es válida." });
    }
    const hora = String(body.hora ?? "");
    if (!/^\d{2}:\d{2}$/.test(hora) || !allBookingSlots().includes(hora)) {
      return response.status(400).json({ error: "La hora no es válida." });
    }

    const todayLabel = clinicDayRangeUtc().day;
    if (fecha < todayLabel) {
      return response.status(400).json({ error: "No se puede reservar en una fecha pasada." });
    }
    if (fecha > chileDateLabelDaysFromNow(BOOKING_MAX_DAYS_AHEAD)) {
      return response.status(400).json({
        error: `No se puede reservar con más de ${BOOKING_MAX_DAYS_AHEAD} días de anticipación.`,
      });
    }

    const [hh, mm] = hora.split(":").map(Number);
    const scheduledAt = chileLocalToUtc(fecha, hh, mm);
    if (scheduledAt.getTime() - Date.now() < BOOKING_MIN_LEAD_MINUTES * 60000) {
      return response
        .status(400)
        .json({ error: "Esa hora ya no tiene la anticipación mínima requerida." });
    }

    // Vuelve a chequear cupo al momento de escribir (evita que dos personas
    // tomen el último cupo del mismo bloque al mismo tiempo; no es 100%
    // infalible sin un lock, pero reduce mucho el riesgo).
    const [roomCount, perSlotCounts] = await Promise.all([
      getActiveRoomCount(),
      countAppointmentsPerBookingSlot(fecha),
    ]);
    const used = perSlotCounts.get(hora) ?? 0;
    if (roomCount === 0 || used >= roomCount) {
      return response.status(409).json({ error: "Ese horario ya no tiene cupo disponible. Elige otro." });
    }

    // Encuentra al paciente por RUT o lo crea (a diferencia del alta interna,
    // acá SÍ se reutiliza la ficha existente en vez de rechazar por RUT
    // duplicado -- un paciente que ya existe debe poder reservar igual).
    const existingPatients = await findPatientsByRutDb(values.rut);
    let patientId;
    if (existingPatients.length > 0) {
      patientId = existingPatients[0].id;
      const patientUpdates = {};
      if (values.phone) patientUpdates.phone = values.phone;
      if (patientEmail) patientUpdates.email = patientEmail;
      if (Object.keys(patientUpdates).length > 0) {
        await supabase.from("patients").update(patientUpdates).eq("id", patientId);
      }
    } else {
      const { data: newPatient, error: insertPatientError } = await supabase
        .from("patients")
        .insert({
          name: values.name,
          rut: values.rut,
          age: null,
          sexo: null,
          phone: values.phone ?? null,
          email: patientEmail,
          observations: null,
        })
        .select("id")
        .single();
      if (insertPatientError) throw insertPatientError;
      patientId = newPatient.id;
    }

    const { data: appointment, error: insertAppointmentError } = await supabase
      .from("appointments")
      .insert({
        patient_id: patientId,
        room_id: null,
        scheduled_at: scheduledAt.toISOString(),
        duration_min: BOOKING_SLOT_MINUTES,
        status: "programada",
        professional: null,
        reason: tipo,
        notes: "Reservado por el paciente vía web.",
        origin: "web",
      })
      .select("id, scheduled_at")
      .single();
    if (insertAppointmentError) throw insertAppointmentError;

    // Confirmación por correo, solo si el paciente dejó uno y Gmail está
    // configurado. Nunca bloquea ni revierte la reserva: si el envío falla,
    // la cita ya quedó guardada de todas formas, solo se pierde el aviso.
    if (patientEmail && gmailConfigured) {
      try {
        await sendBookingConfirmationEmail({
          to: patientEmail,
          name: values.name,
          fecha,
          hora,
          tipo,
        });
      } catch (emailSendError) {
        console.error("No fue posible enviar el correo de confirmación de reserva:", emailSendError);
      }
    }

    return response.status(201).json({
      reserva: { id: appointment.id, fecha, hora, tipo },
    });
  } catch (error) {
    console.error("Error al crear la reserva web:", error);
    return response.status(500).json({ error: "No fue posible confirmar la reserva. Intenta de nuevo." });
  }
});

app.get("/patients/:id", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    // Etapa 3 (paso 3a): mismo criterio que las rutas anteriores.
    if (!(await patientBelongsToRequesterClinic(request.params.id, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

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
        await logAiAnalysis({
          patientId: patient.id,
          kind: "patient_summary",
          staffEmail: request.user?.email,
        });
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

app.post("/patients/:id/summary", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    // Etapa 3 (paso 3a): mismo criterio que las rutas anteriores.
    if (!(await patientBelongsToRequesterClinic(request.params.id, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    const patient = await getPatientFull(request.params.id);
    if (!patient) return response.status(404).json({ error: "Paciente no encontrado" });

    const aiSummary = await generatePatientSummary(patient);
    const { error: updateError } = await supabase
      .from("patients")
      .update({ ai_summary: aiSummary })
      .eq("id", patient.id);
    if (updateError) throw updateError;

    await logAiAnalysis({
      patientId: patient.id,
      kind: "patient_summary",
      staffEmail: request.user?.email,
    });

    return response.json({ patientId: patient.id, aiSummary });
  } catch (error) {
    console.error("Error al regenerar resumen:", error);
    return response.status(500).json({
      error: "No fue posible generar el resumen automático.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.patch("/patients/:id/from-document", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    // Etapa 3 (paso 3a): mismo criterio que las rutas anteriores. La búsqueda
    // de un paciente destino por RUT (más abajo, cuando el documento trae un
    // RUT distinto) también queda limitada a la misma clínica.
    if (!(await patientBelongsToRequesterClinic(request.params.id, request))) {
      return response.status(404).json({ error: "Paciente de origen no encontrado" });
    }

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
    if (!filename) {
      // Antes de este chequeo, un filename vacío hacía que el bloque de más
      // abajo se saltara el insert/update de `documents` en silencio y el
      // endpoint igual respondía éxito -- el paciente quedaba actualizado
      // pero el documento nunca se guardaba.
      return response.status(400).json({ error: "Falta el nombre del archivo del documento a incorporar." });
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
      const matches = await findPatientsByRutDb(
        patientRut,
        sourcePatient.id,
        request.staffProfile?.clinic_id ?? null,
      );

      if (matches.length === 0) {
        return response.status(409).json({
          error:
            "El documento corresponde a otro RUT y no existe una ficha coincidente. Imagenda no modificó la ficha original.",
        });
      }
      if (matches.length > 1) {
        return response.status(409).json({
          error:
            "Imagenda encontró más de una ficha con el mismo RUT. Debes corregir los duplicados antes de incorporar el documento.",
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

    // El guardado del documento en sí (insert/update en `documents` +
    // `history_events` + link a la orden de imagenología) vive en
    // saveDocumentRecord, compartido con el guardado automático que ocurre
    // apenas se analiza el PDF (ver /documents/analyze). Llamarlo de nuevo
    // acá es idempotente: si el documento ya se guardó al analizar, esto
    // solo lo actualiza con los mismos datos.
    await saveDocumentRecord({
      targetPatientId: targetPatient.id,
      documentData,
      filename,
      imagingOrderId,
    });

    const refreshedPatient = await getPatientFull(targetPatient.id);

    try {
      const aiSummary = await generatePatientSummary(refreshedPatient);
      await supabase.from("patients").update({ ai_summary: aiSummary }).eq("id", targetPatient.id);
      refreshedPatient.aiSummary = aiSummary;
      await logAiAnalysis({
        patientId: targetPatient.id,
        kind: "patient_summary",
        staffEmail: request.user?.email,
      });
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

app.get("/patients/:id/documents/:filename", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const normalized = normalizeDocumentName(filename);

    // Etapa 3 (paso 3b): mismo criterio que las rutas de ficha del paciente.
    if (!(await patientBelongsToRequesterClinic(patientId, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

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
app.patch("/patients/:id/documents/:filename/validate", requireRole(VALIDATORS), async (request, response) => {
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

    // Etapa 3 (paso 3b): mismo criterio que las rutas de ficha del paciente.
    if (!(await patientBelongsToRequesterClinic(patientId, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
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
app.delete("/patients/:id/documents/:filename", requireRole(VALIDATORS), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const normalized = normalizeDocumentName(filename);

    // Etapa 3 (paso 3b): mismo criterio que las rutas de ficha del paciente.
    if (!(await patientBelongsToRequesterClinic(patientId, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
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

app.post("/patients/:id/documents/:filename/ask", requireRole(AI_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const filename = decodeURIComponent(request.params.filename);
    const question = typeof request.body?.question === "string" ? request.body.question.trim() : "";
    if (!question) return response.status(400).json({ error: "Debes escribir una pregunta sobre el documento." });

    // Etapa 3 (paso 3b): mismo criterio que las rutas de ficha del paciente.
    if (!(await patientBelongsToRequesterClinic(patientId, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
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
Eres Imagenda, un asistente de apoyo para la consulta de documentos clínicos ya incorporados.

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

    await logAiAnalysis({
      patientId,
      filename: record.filename,
      kind: "document_ask",
      staffEmail: request.user?.email,
    });

    return response.json({ patientId, filename: record.filename, respuesta: answer });
  } catch (error) {
    console.error("Error al consultar documento con Imagenda:", error);
    const status = typeof error?.status === "number" ? error.status : 500;
    return response.status(status).json({
      error: "No fue posible consultar este documento con Imagenda.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.post("/patients/:id/documents/analyze", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    // Etapa 3 (paso 3b): mismo criterio que las rutas de ficha del paciente.
    if (!(await patientBelongsToRequesterClinic(request.params.id, request))) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

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
Eres Imagenda, un asistente para apoyar la revisión documental.

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
      return response.status(502).json({ error: "Imagenda recibió un análisis que no pudo estructurar." });
    }

    const missing = Array.isArray(documentData.missingData) ? documentData.missingData : [];
    const differences = Array.isArray(documentData.differences) ? documentData.differences : [];

    const matchingPatients =
      documentData.isClinical === true
        ? await findPatientsByRutDb(documentData.patientRut, patient.id)
        : [];

    const existingPatientMatch = matchingPatients.length === 1 ? matchingPatients[0] : null;

    // Guardado automático: si el documento es clínico y su RUT no entra en
    // conflicto con el de esta ficha (coincide, o el documento simplemente
    // no trae RUT), lo guardamos altiro en `documents` para que aparezca en
    // "Documentos disponibles" sin depender de que alguien presione
    // "Incorporar datos a la ficha". Si el RUT del documento apunta a otro
    // paciente, no se guarda acá -- sigue siendo una decisión humana (ver
    // PATCH /from-document), porque ahí también se decide a qué ficha va.
    const incomingRutForAutoSave = normalizeRut(documentData.patientRut);
    const sourceRutForAutoSave = normalizeRut(patient.rut);
    const identityDiffersForAutoSave =
      Boolean(incomingRutForAutoSave) &&
      Boolean(sourceRutForAutoSave) &&
      incomingRutForAutoSave !== sourceRutForAutoSave;

    let documentSaved = false;
    let refreshedPatient = null;
    if (documentData.isClinical === true && !identityDiffersForAutoSave) {
      try {
        await saveDocumentRecord({ targetPatientId: patient.id, documentData, filename });
        documentSaved = true;
        refreshedPatient = await getPatientFull(patient.id);
      } catch (saveError) {
        // No bloqueamos la respuesta del análisis por esto: el usuario
        // todavía puede guardar el documento manualmente con "Incorporar
        // datos a la ficha", que vuelve a intentar el mismo guardado.
        console.error("No fue posible guardar automáticamente el documento analizado:", saveError);
      }
    }

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

    await logAiAnalysis({
      patientId: patient.id,
      filename,
      kind: "document_analysis",
      staffEmail: request.user?.email,
    });

    return response.json({
      patientId: patient.id,
      filename,
      analysis: analysisLines.join("\n"),
      documentData,
      existingPatient: existingPatientMatch
        ? { id: existingPatientMatch.id, name: existingPatientMatch.name, rut: existingPatientMatch.rut }
        : null,
      duplicateRutCount: matchingPatients.length > 1 ? matchingPatients.length : 0,
      documentSaved,
      patient: refreshedPatient,
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

app.get("/lab/panels", requireRole(CLINICAL_STAFF), async (_request, response) => {
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

app.post("/patients/:id/lab-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const panelIds = Array.isArray(request.body?.panelIds) ? request.body.panelIds : [];

    if (panelIds.length === 0) {
      return response.status(400).json({ error: "Debes seleccionar al menos un examen." });
    }

    // Etapa 5: mismo criterio que POST /appointments -- el paciente tiene
    // que pertenecer a la clínica de quien pide el alta, no solo existir.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });
    if (requesterClinicId && patientRow.clinic_id && patientRow.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    const { data: orderRow, error: orderError } = await supabase
      .from("lab_orders")
      .insert({ patient_id: patientId, status: "ordenado", clinic_id: requesterClinicId })
      .select()
      .single();
    if (orderError) throw orderError;

    const orderPanelsRows = panelIds.map((panelId) => ({ order_id: orderRow.id, panel_id: panelId }));
    const { error: orderPanelsError } = await supabase.from("lab_order_panels").insert(orderPanelsRows);
    if (orderPanelsError) throw orderPanelsError;

    // Cobro automático: se crea el billing_order sumando el precio de cada
    // panel pedido. Si algo falla aquí no se cancela la orden clínica.
    const billing = await createBillingOrderForSource({
      patientId,
      sourceType: "lab_order",
      sourceOrderId: orderRow.id,
      category: "laboratorio",
      itemIds: panelIds,
    });

    return response.json({
      order: shapeLabOrderRow(orderRow),
      billing: billing.order ? shapeBillingOrderRow(billing.order) : null,
      billingWarning: billing.warning,
    });
  } catch (error) {
    console.error("Error al crear orden de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible crear la orden de laboratorio." });
  }
});

app.get("/patients/:id/lab-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);

    let ordersQuery = supabase
      .from("lab_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("requested_at", { ascending: false });

    // Mismo criterio que /patients: solo filtra si quien pide tiene clínica
    // asignada.
    if (request.staffProfile?.clinic_id) {
      ordersQuery = ordersQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data: orderRows, error: ordersError } = await ordersQuery;
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

app.get("/patients/:id/lab-orders/:orderId", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let orderQuery = supabase
      .from("lab_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      orderQuery = orderQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: orderRow, error: orderError } = await orderQuery.maybeSingle();
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

app.patch("/patients/:id/lab-orders/:orderId/sample-taken", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let sampleTakenQuery = supabase
      .from("lab_orders")
      .update({ status: "muestra_tomada", sample_taken_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      sampleTakenQuery = sampleTakenQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: updatedOrder, error } = await sampleTakenQuery.select().maybeSingle();
    if (error) throw error;
    if (!updatedOrder) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    return response.json({ order: shapeLabOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al marcar toma de muestra:", error);
    return response.status(500).json({ error: "No fue posible marcar la toma de muestra." });
  }
});

app.patch("/patients/:id/lab-orders/:orderId/results", requireRole(CLINICAL_STAFF), async (request, response) => {
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
    // Etapa 5: la orden ya se cargó completa arriba, solo falta comparar su
    // clínica contra la de quien pide guardar los resultados.
    if (
      request.staffProfile?.clinic_id &&
      orderRow.clinic_id &&
      orderRow.clinic_id !== request.staffProfile.clinic_id
    ) {
      return response.status(404).json({ error: "Orden de laboratorio no encontrada." });
    }

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

app.patch("/patients/:id/lab-orders/:orderId/validate", requireRole(VALIDATORS), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let validateQuery = supabase
      .from("lab_orders")
      .update({
        status: "validado",
        validated_at: new Date().toISOString(),
        validated_by: request.user?.email ?? null,
      })
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      validateQuery = validateQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: updatedOrder, error } = await validateQuery.select().maybeSingle();
    if (error) throw error;
    if (!updatedOrder) return response.status(404).json({ error: "Orden de laboratorio no encontrada." });

    return response.json({ order: shapeLabOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al validar orden de laboratorio:", error);
    return response.status(500).json({ error: "No fue posible validar la orden de laboratorio." });
  }
});
// ============================================
// MÓDULO DENTAL
// ============================================

function shapeDentalProcedureRow(row) {
  return { id: row.id, fonasaCode: row.fonasa_code, name: row.name };
}

function shapeDentalOrderRow(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    status: row.status,
    requestedAt: row.requested_at,
    performedAt: row.performed_at,
    validatedAt: row.validated_at,
    validatedBy: row.validated_by,
  };
}

function shapeDentalResultRow(row) {
  return {
    id: row.id,
    orderId: row.order_id,
    procedureId: row.procedure_id,
    tooth: row.tooth,
    diagnosis: row.diagnosis,
    professional: row.professional,
  };
}

app.get("/dental/procedures", requireRole(CLINICAL_STAFF), async (_request, response) => {
  try {
    const { data, error } = await supabase
      .from("dental_procedures")
      .select("*")
      .order("name", { ascending: true });
    if (error) throw error;

    return response.json({ procedures: (data ?? []).map(shapeDentalProcedureRow) });
  } catch (error) {
    console.error("Error al obtener catálogo dental:", error);
    return response.status(500).json({ error: "No fue posible obtener el catálogo de prestaciones dentales." });
  }
});

app.post("/patients/:id/dental-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const procedureIds = Array.isArray(request.body?.procedureIds) ? request.body.procedureIds : [];

    if (procedureIds.length === 0) {
      return response.status(400).json({ error: "Debes seleccionar al menos una prestación." });
    }

    // Etapa 5: mismo criterio que POST /patients/:id/lab-orders -- el
    // paciente tiene que pertenecer a la clínica de quien pide el alta.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow) return response.status(404).json({ error: "Paciente no encontrado" });
    if (requesterClinicId && patientRow.clinic_id && patientRow.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    const { data: orderRow, error: orderError } = await supabase
      .from("dental_orders")
      .insert({ patient_id: patientId, status: "ordenado", clinic_id: requesterClinicId })
      .select()
      .single();
    if (orderError) throw orderError;

    const orderProcedureRows = procedureIds.map((procedureId) => ({
      order_id: orderRow.id,
      procedure_id: procedureId,
    }));
    const { error: orderProceduresError } = await supabase
      .from("dental_order_procedures")
      .insert(orderProcedureRows);
    if (orderProceduresError) throw orderProceduresError;

    return response.json({ order: shapeDentalOrderRow(orderRow) });
  } catch (error) {
    console.error("Error al crear orden dental:", error);
    return response.status(500).json({ error: "No fue posible crear la orden dental." });
  }
});

app.get("/patients/:id/dental-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);

    let ordersQuery = supabase
      .from("dental_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("requested_at", { ascending: false });

    // Mismo criterio que /patients: solo filtra si quien pide tiene clínica
    // asignada.
    if (request.staffProfile?.clinic_id) {
      ordersQuery = ordersQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data: orderRows, error: ordersError } = await ordersQuery;
    if (ordersError) throw ordersError;

    const orderIds = (orderRows ?? []).map((o) => o.id);

    const { data: orderProcedureRows, error: orderProceduresError } = orderIds.length
      ? await supabase
          .from("dental_order_procedures")
          .select("*, dental_procedures(name, fonasa_code)")
          .in("order_id", orderIds)
      : { data: [], error: null };
    if (orderProceduresError) throw orderProceduresError;

    const orders = (orderRows ?? []).map((order) => ({
      ...shapeDentalOrderRow(order),
      procedures: (orderProcedureRows ?? [])
        .filter((op) => op.order_id === order.id)
        .map((op) => ({
          id: op.procedure_id,
          name: op.dental_procedures?.name,
          fonasaCode: op.dental_procedures?.fonasa_code,
        })),
    }));

    return response.json({ orders });
  } catch (error) {
    console.error("Error al obtener órdenes dentales:", error);
    return response.status(500).json({ error: "No fue posible obtener las órdenes dentales." });
  }
});

app.get("/patients/:id/dental-orders/:orderId", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let orderQuery = supabase
      .from("dental_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      orderQuery = orderQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: orderRow, error: orderError } = await orderQuery.maybeSingle();
    if (orderError) throw orderError;
    if (!orderRow) return response.status(404).json({ error: "Orden dental no encontrada." });

    const { data: orderProcedureRows, error: orderProceduresError } = await supabase
      .from("dental_order_procedures")
      .select("procedure_id, dental_procedures(id, name, fonasa_code)")
      .eq("order_id", orderId);
    if (orderProceduresError) throw orderProceduresError;

    const { data: resultRows, error: resultsError } = await supabase
      .from("dental_results")
      .select("*")
      .eq("order_id", orderId);
    if (resultsError) throw resultsError;

    const procedures = (orderProcedureRows ?? []).map((op) => {
      const result = (resultRows ?? []).find((r) => r.procedure_id === op.procedure_id);
      return {
        id: op.procedure_id,
        name: op.dental_procedures?.name,
        fonasaCode: op.dental_procedures?.fonasa_code,
        result: result ? shapeDentalResultRow(result) : null,
      };
    });

    return response.json({ order: shapeDentalOrderRow(orderRow), procedures });
  } catch (error) {
    console.error("Error al obtener detalle de orden dental:", error);
    return response.status(500).json({ error: "No fue posible obtener el detalle de la orden." });
  }
});

app.patch(
  "/patients/:id/dental-orders/:orderId/performed",
  requireRole(CLINICAL_STAFF),
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;

      let performedQuery = supabase
        .from("dental_orders")
        .update({ status: "realizado", performed_at: new Date().toISOString() })
        .eq("id", orderId)
        .eq("patient_id", patientId);
      if (request.staffProfile?.clinic_id) {
        performedQuery = performedQuery.eq("clinic_id", request.staffProfile.clinic_id);
      }
      const { data: updatedOrder, error } = await performedQuery.select().maybeSingle();
      if (error) throw error;
      if (!updatedOrder) return response.status(404).json({ error: "Orden dental no encontrada." });

      return response.json({ order: shapeDentalOrderRow(updatedOrder) });
    } catch (error) {
      console.error("Error al marcar atención dental como realizada:", error);
      return response.status(500).json({ error: "No fue posible marcar la orden como realizada." });
    }
  },
);

app.patch("/patients/:id/dental-orders/:orderId/results", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;
    const results = Array.isArray(request.body?.results) ? request.body.results : [];

    if (results.length === 0) {
      return response.status(400).json({ error: "Debes enviar al menos un resultado." });
    }

    const { data: orderRow, error: orderError } = await supabase
      .from("dental_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!orderRow) return response.status(404).json({ error: "Orden dental no encontrada." });
    // Etapa 5: la orden ya se cargó completa arriba, solo falta comparar su
    // clínica contra la de quien pide guardar los resultados.
    if (
      request.staffProfile?.clinic_id &&
      orderRow.clinic_id &&
      orderRow.clinic_id !== request.staffProfile.clinic_id
    ) {
      return response.status(404).json({ error: "Orden dental no encontrada." });
    }

    for (const item of results) {
      const procedureId = item.procedureId;
      if (!procedureId) continue;

      const tooth = typeof item.tooth === "string" ? item.tooth.trim() || null : null;
      const diagnosis = typeof item.diagnosis === "string" ? item.diagnosis.trim() || null : null;
      const professional = typeof item.professional === "string" ? item.professional.trim() || null : null;

      const { data: existingResult, error: existingError } = await supabase
        .from("dental_results")
        .select("id")
        .eq("order_id", orderId)
        .eq("procedure_id", procedureId)
        .maybeSingle();
      if (existingError) throw existingError;

      const resultRow = {
        order_id: orderId,
        procedure_id: procedureId,
        tooth,
        diagnosis,
        professional,
        updated_at: new Date().toISOString(),
      };

      if (existingResult) {
        const { error } = await supabase.from("dental_results").update(resultRow).eq("id", existingResult.id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("dental_results").insert(resultRow);
        if (error) throw error;
      }
    }

    return response.json({ order: shapeDentalOrderRow(orderRow) });
  } catch (error) {
    console.error("Error al guardar resultados dentales:", error);
    return response.status(500).json({ error: "No fue posible guardar los resultados." });
  }
});

app.patch("/patients/:id/dental-orders/:orderId/validate", requireRole(VALIDATORS), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let validateQuery = supabase
      .from("dental_orders")
      .update({
        status: "validado",
        validated_at: new Date().toISOString(),
        validated_by: request.user?.email ?? null,
      })
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      validateQuery = validateQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: updatedOrder, error } = await validateQuery.select().maybeSingle();
    if (error) throw error;
    if (!updatedOrder) return response.status(404).json({ error: "Orden dental no encontrada." });

    return response.json({ order: shapeDentalOrderRow(updatedOrder) });
  } catch (error) {
    console.error("Error al validar orden dental:", error);
    return response.status(500).json({ error: "No fue posible validar la orden dental." });
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
    accessionNumber: row.accession_number,
  };
}

app.get("/imaging/types", requireRole(CLINICAL_STAFF), async (_request, response) => {
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

app.post("/patients/:id/imaging-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
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

    // Etapa 5: mismo criterio que laboratorio/dental -- el paciente tiene
    // que pertenecer a la clínica de quien pide el alta.
    const requesterClinicId = request.staffProfile?.clinic_id ?? null;

    const { data: patientRow, error: patientError } = await supabase
      .from("patients")
      .select("id, clinic_id")
      .eq("id", patientId)
      .maybeSingle();
    if (patientError) throw patientError;
    if (!patientRow)
      return response.status(404).json({ error: "Paciente no encontrado" });
    if (requesterClinicId && patientRow.clinic_id && patientRow.clinic_id !== requesterClinicId) {
      return response.status(404).json({ error: "Paciente no encontrado" });
    }

    // accession_number lo genera solo la base de datos (default de la
    // columna sobre imaging_accession_seq, ver dicom_pacs_stage1.sql).
    const { data: orderRow, error: orderError } = await supabase
      .from("imaging_orders")
      .insert({ patient_id: patientId, status: "ordenado", clinic_id: requesterClinicId })
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

    // Cobro automático: se crea el billing_order sumando el precio de cada
    // estudio pedido. Si algo falla aquí no se cancela la orden clínica.
    const billing = await createBillingOrderForSource({
      patientId,
      sourceType: "imaging_order",
      sourceOrderId: orderRow.id,
      category: "imagenologia",
      itemIds: typeIds,
    });

    return response.json({
      order: shapeImagingOrderRow(orderRow),
      billing: billing.order ? shapeBillingOrderRow(billing.order) : null,
      billingWarning: billing.warning,
    });
  } catch (error) {
    console.error("Error al crear orden de imagenología:", error);
    return response
      .status(500)
      .json({ error: "No fue posible crear la orden de imagenología." });
  }
});

app.get("/patients/:id/imaging-orders", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);

    let ordersQuery = supabase
      .from("imaging_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("requested_at", { ascending: false });

    // Mismo criterio que /patients: solo filtra si quien pide tiene clínica
    // asignada.
    if (request.staffProfile?.clinic_id) {
      ordersQuery = ordersQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data: orderRows, error: ordersError } = await ordersQuery;
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

app.get("/patients/:id/imaging-orders/:orderId", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    const orderId = request.params.orderId;

    let orderQuery = supabase
      .from("imaging_orders")
      .select("*")
      .eq("id", orderId)
      .eq("patient_id", patientId);
    if (request.staffProfile?.clinic_id) {
      orderQuery = orderQuery.eq("clinic_id", request.staffProfile.clinic_id);
    }
    const { data: orderRow, error: orderError } = await orderQuery.maybeSingle();
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
  requireRole(CLINICAL_STAFF),
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;

      let performedQuery = supabase
        .from("imaging_orders")
        .update({ status: "realizado", performed_at: new Date().toISOString() })
        .eq("id", orderId)
        .eq("patient_id", patientId);
      if (request.staffProfile?.clinic_id) {
        performedQuery = performedQuery.eq("clinic_id", request.staffProfile.clinic_id);
      }
      const { data: updatedOrder, error } = await performedQuery.select().maybeSingle();
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
  requireRole(CLINICAL_STAFF),
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
        .select("id, clinic_id")
        .eq("id", orderId)
        .eq("patient_id", patientId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      // Etapa 5: la orden ya se cargó arriba, solo falta comparar su
      // clínica contra la de quien sube la imagen.
      if (
        request.staffProfile?.clinic_id &&
        orderRow.clinic_id &&
        orderRow.clinic_id !== request.staffProfile.clinic_id
      ) {
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      }

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
  requireRole(CLINICAL_STAFF),
  async (request, response) => {
    try {
      const patientId = Number(request.params.id);
      const orderId = request.params.orderId;

      const { data: orderRow, error: orderError } = await supabase
        .from("imaging_orders")
        .select("id, clinic_id")
        .eq("id", orderId)
        .eq("patient_id", patientId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      // Etapa 5: la orden ya se cargó arriba, solo falta comparar su
      // clínica contra la de quien pide las imágenes.
      if (
        request.staffProfile?.clinic_id &&
        orderRow.clinic_id &&
        orderRow.clinic_id !== request.staffProfile.clinic_id
      ) {
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      }

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

// ============================================
// IMAGENOLOGÍA — ETAPA 2.5: estudios de Orthanc sin vincular
// ============================================

function shapeOrthancStudyRow(row) {
  return {
    orthancStudyId: row.orthanc_study_id,
    accessionNumberReceived: row.accession_number_received,
    patientNameReceived: row.patient_name_received,
    patientIdReceived: row.patient_id_received,
    studyDate: row.study_date,
    createdAt: row.created_at,
  };
}

app.get("/orthanc-studies", requireRole(CLINICAL_STAFF), async (request, response) => {
  try {
    const status = typeof request.query.status === "string" ? request.query.status : null;

    let query = supabase
      .from("orthanc_studies")
      .select(
        "orthanc_study_id, accession_number_received, patient_name_received, patient_id_received, study_date, created_at",
      )
      .order("created_at", { ascending: false });

    if (status) {
      query = query.eq("status", status);
    }

    // Etapa 4 (paso 2): mismo criterio que /patients y /patients/today --
    // solo filtra si quien pide tiene clínica asignada.
    if (request.staffProfile?.clinic_id) {
      query = query.eq("clinic_id", request.staffProfile.clinic_id);
    }

    const { data, error } = await query;
    if (error) throw error;

    return response.json({ studies: (data ?? []).map(shapeOrthancStudyRow) });
  } catch (error) {
    console.error("Error al obtener estudios de Orthanc:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener los estudios de Orthanc." });
  }
});

app.post(
  "/orthanc-studies/:id/link",
  requireRole(CLINICAL_STAFF),
  async (request, response) => {
    try {
      const orthancStudyId = request.params.id;
      const orderId = request.body?.orderId;

      if (typeof orderId !== "string" || orderId.trim().length === 0) {
        return response
          .status(400)
          .json({ error: "Debes indicar la orden a la que vincular el estudio." });
      }

      // Etapa 5: mismo criterio que agenda -- ninguno de los dos recursos
      // (el estudio de Orthanc y la orden de imagenología) puede pertenecer
      // a una clínica distinta a la de quien pide el vínculo. No se revela
      // que el recurso existe en otra clínica: se responde 404 igual que si
      // no existiera.
      const requesterClinicId = request.staffProfile?.clinic_id ?? null;

      const { data: studyRow, error: studyError } = await supabase
        .from("orthanc_studies")
        .select("status, clinic_id")
        .eq("orthanc_study_id", orthancStudyId)
        .maybeSingle();
      if (studyError) throw studyError;
      if (!studyRow)
        return response
          .status(404)
          .json({ error: "Estudio de Orthanc no encontrado." });
      if (requesterClinicId && studyRow.clinic_id && studyRow.clinic_id !== requesterClinicId) {
        return response
          .status(404)
          .json({ error: "Estudio de Orthanc no encontrado." });
      }
      if (studyRow.status === "linked")
        return response
          .status(409)
          .json({ error: "Este estudio ya está vinculado a una orden." });

      const { data: orderRow, error: orderError } = await supabase
        .from("imaging_orders")
        .select("id, clinic_id")
        .eq("id", orderId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow)
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      if (requesterClinicId && orderRow.clinic_id && orderRow.clinic_id !== requesterClinicId) {
        return response
          .status(404)
          .json({ error: "Orden de imagenología no encontrada." });
      }

      const { totalInstances, copiedNow } = await linkOrthancStudyToOrder(supabase, {
        orthancStudyId,
        orderId: orderRow.id,
      });

      return response.json({ linked: true, orderId: orderRow.id, totalInstances, copiedNow });
    } catch (error) {
      console.error("Error al vincular estudio de Orthanc:", error);
      return response.status(500).json({
        error: "No fue posible vincular el estudio de Orthanc a la orden.",
        detalle:
          typeof error?.message === "string" ? error.message : "Error desconocido.",
      });
    }
  },
);

// ============================================
// MÓDULO DE CONTABILIDAD Y FACTURACIÓN
// ============================================

const PAYMENT_METHODS = [
  "efectivo",
  "tarjeta",
  "transferencia",
  "bono_isapre",
  "bono_fonasa",
  "convenio",
];

function shapeBillingOrderRow(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    sourceType: row.source_type,
    sourceOrderId: row.source_order_id,
    totalAmount: row.total_amount === null ? null : Number(row.total_amount),
    status: row.status,
    bonoFolio: row.bono_folio,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function shapePaymentRow(row) {
  return {
    id: row.id,
    billingOrderId: row.billing_order_id,
    method: row.method,
    amount: row.amount === null ? null : Number(row.amount),
    reference: row.reference,
    paidAt: row.paid_at,
    registeredBy: row.registered_by,
  };
}

// Suma el precio (billing_items.price) de cada examen pedido. `category` es
// "laboratorio" o "imagenologia"; `itemIds` son ids de lab_panels o de
// imaging_types. Devuelve el total y la lista de exámenes que no tienen
// precio en el catálogo.
async function sumBillingItems(category, itemIds) {
  const ids = Array.isArray(itemIds) ? itemIds.filter(Boolean) : [];
  if (ids.length === 0) return { total: 0, missing: [] };

  const { data, error } = await supabase
    .from("billing_items")
    .select("item_id, price, active")
    .eq("category", category)
    .in("item_id", ids);
  if (error) throw error;

  const priceByItem = new Map(
    (data ?? [])
      .filter((row) => row.active !== false)
      .map((row) => [row.item_id, Number(row.price) || 0]),
  );

  let total = 0;
  const missing = [];
  for (const id of ids) {
    if (priceByItem.has(id)) total += priceByItem.get(id);
    else missing.push(id);
  }
  return { total, missing };
}

// Crea el billing_order asociado a una orden de laboratorio o imagenología.
// Nunca lanza: si falla, devuelve { order: null, warning } para que la orden
// clínica no se caiga por un problema de facturación.
async function createBillingOrderForSource({
  patientId,
  sourceType,
  sourceOrderId,
  category,
  itemIds,
}) {
  try {
    const { total, missing } = await sumBillingItems(category, itemIds);

    const { data, error } = await supabase
      .from("billing_orders")
      .insert({
        patient_id: patientId,
        source_type: sourceType,
        source_order_id: sourceOrderId,
        total_amount: total,
      })
      .select()
      .single();
    if (error) throw error;

    const warning =
      missing.length > 0
        ? `${missing.length} examen(es) sin precio en el catálogo: el total puede estar incompleto.`
        : null;

    return { order: data, warning };
  } catch (error) {
    console.error(
      `No fue posible crear el cobro para ${sourceType} ${sourceOrderId}:`,
      error,
    );
    return {
      order: null,
      warning: "No fue posible generar el cobro automático de esta orden.",
    };
  }
}

// Recalcula lo pagado sobre un cobro y, si cubre el total, lo marca "pagado".
async function refreshBillingOrderStatus(billingOrderRow) {
  const { data: paymentRows, error } = await supabase
    .from("payments")
    .select("amount")
    .eq("billing_order_id", billingOrderRow.id);
  if (error) throw error;

  const totalPaid = (paymentRows ?? []).reduce(
    (sum, row) => sum + (Number(row.amount) || 0),
    0,
  );

  let order = billingOrderRow;
  const total = Number(billingOrderRow.total_amount) || 0;
  if (
    billingOrderRow.status === "pendiente" &&
    totalPaid > 0 &&
    totalPaid >= total
  ) {
    const { data, error: updateError } = await supabase
      .from("billing_orders")
      .update({ status: "pagado", updated_at: new Date().toISOString() })
      .eq("id", billingOrderRow.id)
      .select()
      .single();
    if (updateError) throw updateError;
    order = data;
  }

  return { order, totalPaid };
}

// Lista los cobros de un paciente con sus pagos. Accesible a cualquier rol
// con sesión: el personal clínico ya ve la ficha y recepción necesita ver
// los cobros para poder registrar pagos.
app.get("/patients/:id/billing", async (request, response) => {
  try {
    const patientId = Number(request.params.id);
    if (!Number.isInteger(patientId)) {
      return response
        .status(400)
        .json({ error: "Identificador de paciente inválido." });
    }

    const { data: orderRows, error: ordersError } = await supabase
      .from("billing_orders")
      .select("*")
      .eq("patient_id", patientId)
      .order("created_at", { ascending: false });
    if (ordersError) throw ordersError;

    const orderIds = (orderRows ?? []).map((row) => row.id);

    const { data: paymentRows, error: paymentsError } = orderIds.length
      ? await supabase
          .from("payments")
          .select("*")
          .in("billing_order_id", orderIds)
          .order("paid_at", { ascending: true })
      : { data: [], error: null };
    if (paymentsError) throw paymentsError;

    const billingOrders = (orderRows ?? []).map((order) => {
      const payments = (paymentRows ?? []).filter(
        (p) => p.billing_order_id === order.id,
      );
      const totalPaid = payments.reduce(
        (sum, p) => sum + (Number(p.amount) || 0),
        0,
      );
      const totalAmount = Number(order.total_amount) || 0;
      return {
        ...shapeBillingOrderRow(order),
        payments: payments.map(shapePaymentRow),
        totalPaid,
        balance: Math.max(totalAmount - totalPaid, 0),
      };
    });

    return response.json({ patientId, billingOrders });
  } catch (error) {
    console.error("Error al obtener los cobros del paciente:", error);
    return response
      .status(500)
      .json({ error: "No fue posible obtener los cobros del paciente." });
  }
});

// Registra un pago sobre un cobro. Solo administrador y recepción.
app.post(
  "/billing/orders/:id/payments",
  requireRole(BILLING_STAFF),
  async (request, response) => {
    try {
      const billingOrderId = request.params.id;
      const method = request.body?.method;
      const amount = Number(request.body?.amount);
      const referenceRaw = request.body?.reference;
      const reference =
        typeof referenceRaw === "string" && referenceRaw.trim() !== ""
          ? referenceRaw.trim()
          : null;

      if (!PAYMENT_METHODS.includes(method)) {
        return response.status(400).json({
          error: `Método de pago inválido. Debe ser uno de: ${PAYMENT_METHODS.join(", ")}.`,
        });
      }
      if (!Number.isFinite(amount) || amount <= 0) {
        return response
          .status(400)
          .json({ error: "El monto del pago debe ser un número mayor a cero." });
      }

      const { data: orderRow, error: orderError } = await supabase
        .from("billing_orders")
        .select("*")
        .eq("id", billingOrderId)
        .maybeSingle();
      if (orderError) throw orderError;
      if (!orderRow) {
        return response.status(404).json({ error: "Cobro no encontrado." });
      }

      const { data: paymentRow, error: paymentError } = await supabase
        .from("payments")
        .insert({
          billing_order_id: billingOrderId,
          method,
          amount,
          reference,
          registered_by: request.user?.id ?? null,
        })
        .select()
        .single();
      if (paymentError) throw paymentError;

      const { order, totalPaid } = await refreshBillingOrderStatus(orderRow);

      return response.json({
        payment: shapePaymentRow(paymentRow),
        order: shapeBillingOrderRow(order),
        totalPaid,
        balance: Math.max((Number(order.total_amount) || 0) - totalPaid, 0),
      });
    } catch (error) {
      console.error("Error al registrar el pago:", error);
      return response
        .status(500)
        .json({ error: "No fue posible registrar el pago." });
    }
  },
);

// Edita manualmente el folio del bono de un cobro (por ahora solo ese campo).
// Solo administrador y recepción.
app.patch(
  "/billing/orders/:id",
  requireRole(BILLING_STAFF),
  async (request, response) => {
    try {
      const billingOrderId = request.params.id;
      const body = request.body ?? {};
      const hasField = "bonoFolio" in body || "bono_folio" in body;
      if (!hasField) {
        return response
          .status(400)
          .json({ error: "Debes enviar el campo bonoFolio." });
      }

      const raw = "bonoFolio" in body ? body.bonoFolio : body.bono_folio;
      let bonoFolio;
      if (raw === null) {
        bonoFolio = null;
      } else if (typeof raw === "string") {
        bonoFolio = raw.trim() === "" ? null : raw.trim();
      } else {
        return response
          .status(400)
          .json({ error: "bonoFolio debe ser texto o null." });
      }

      const { data: orderRow, error } = await supabase
        .from("billing_orders")
        .update({ bono_folio: bonoFolio, updated_at: new Date().toISOString() })
        .eq("id", billingOrderId)
        .select()
        .maybeSingle();
      if (error) throw error;
      if (!orderRow) {
        return response.status(404).json({ error: "Cobro no encontrado." });
      }

      return response.json({ order: shapeBillingOrderRow(orderRow) });
    } catch (error) {
      console.error("Error al editar el folio del bono:", error);
      return response
        .status(500)
        .json({ error: "No fue posible actualizar el folio del bono." });
    }
  },
);

// ============================================
// GESTIÓN DE EQUIPO (solo Administrador)
// ============================================

app.get("/staff", async (_request, response) => {
  try {
    const { data, error } = await supabase
      .from("staff_profiles")
      .select("*")
      .order("created_at", { ascending: true });
    if (error) throw error;

    return response.json({ staff: (data ?? []).map(shapeStaffRow) });
  } catch (error) {
    console.error("Error al obtener el equipo:", error);
    return response.status(500).json({ error: "No fue posible obtener el equipo." });
  }
});

app.post("/staff/invite", async (request, response) => {
  try {
    const email = typeof request.body?.email === "string" ? request.body.email.trim() : "";
    const fullName = typeof request.body?.fullName === "string" ? request.body.fullName.trim() : "";
    const role = request.body?.role;

    if (!email || !ALL_ROLES.includes(role)) {
      return response.status(400).json({ error: "Debes indicar un email válido y un rol." });
    }

    const { data: inviteData, error: inviteError } = await supabase.auth.admin.inviteUserByEmail(email);
    if (inviteError) throw inviteError;

    const newUserId = inviteData?.user?.id;
    if (!newUserId) {
      return response.status(500).json({ error: "No fue posible crear el usuario invitado." });
    }

    const { data: profileRow, error: profileError } = await supabase
      .from("staff_profiles")
      .insert({ id: newUserId, email, full_name: fullName || null, role })
      .select()
      .single();
    if (profileError) throw profileError;

    return response.json({ staff: shapeStaffRow(profileRow) });
  } catch (error) {
    console.error("Error al invitar al equipo:", error);
    return response.status(500).json({
      error: "No fue posible invitar a esta persona.",
      detalle: typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.patch("/staff/:id/role", async (request, response) => {
  try {
    const staffId = request.params.id;
    const role = request.body?.role;

    if (!ALL_ROLES.includes(role)) {
      return response.status(400).json({ error: "Rol inválido." });
    }

    const { data: updatedRow, error } = await supabase
      .from("staff_profiles")
      .update({ role })
      .eq("id", staffId)
      .select()
      .single();
    if (error) throw error;
    if (!updatedRow) return response.status(404).json({ error: "Persona no encontrada." });

    return response.json({ staff: shapeStaffRow(updatedRow) });
  } catch (error) {
    console.error("Error al actualizar rol:", error);
    return response.status(500).json({ error: "No fue posible actualizar el rol." });
  }
});

app.delete("/staff/:id", async (request, response) => {
  try {
    const staffId = request.params.id;

    if (staffId === request.user?.id) {
      return response.status(400).json({ error: "No puedes quitarte a ti mismo del equipo." });
    }

    const { error } = await supabase.from("staff_profiles").delete().eq("id", staffId);
    if (error) throw error;

    return response.json({ ok: true });
  } catch (error) {
    console.error("Error al quitar del equipo:", error);
    return response.status(500).json({ error: "No fue posible quitar a esta persona del equipo." });
  }
});

// ============================================
// GESTIÓN DE CLÍNICAS (solo Administrador)
// ============================================
// Alta de clínicas nuevas, con asignación automática del AE Title y puerto
// DICOM que le va a corresponder en el plugin MultitenantDicom de Orthanc
// (plan-dicom-pacs.md, Etapa 4). MILMED es un caso legado (IMAGENDA_MILMED /
// 4244, cargado a mano) y queda tal cual -- desde acá en adelante, el AE
// Title sale del offset numérico respecto a ese puerto, nunca del nombre de
// la clínica: un nombre largo rompería el límite duro de 16 caracteres que
// tiene el AE Title en el estándar DICOM.
//
// Por ahora la asignación al droplet sigue siendo manual: esta ruta calcula
// y guarda los valores en clinics, y devuelve el bloque de configuración
// listo para pegar en /etc/orthanc/multitenant.json del droplet -- todavía
// no hay ninguna automatización que toque Orthanc directamente.
//
// Etapa 5: el plugin MultitenantDicom no soporta TLS nativo (confirmado por
// el propio creador de Orthanc), así que cada tenant va detrás de un stunnel
// propio en el droplet: Orthanc escucha en texto plano en un puerto interno
// (puerto público + 10000) solo accesible en 127.0.0.1, y stunnel es quien
// escucha el puerto público real, descifra el TLS y reenvía en texto plano a
// ese puerto interno -- nunca sale nada sin cifrar de la máquina. Mismo
// esquema que ya se aplicó a MILMED (4244 público -> 14244 interno).
const DICOM_MULTITENANT_BASE_PORT = 4244; // puerto legado de MILMED
const DICOM_INTERNAL_PORT_OFFSET = 10000;

app.get("/clinics", async (_request, response) => {
  try {
    const { data, error } = await supabase
      .from("clinics")
      .select("*")
      .order("created_at", { ascending: true });
    if (error) throw error;

    return response.json({ clinics: (data ?? []).map(shapeClinicRow) });
  } catch (error) {
    console.error("Error al obtener las clínicas:", error);
    return response.status(500).json({ error: "No fue posible obtener las clínicas." });
  }
});

app.post("/clinics", async (request, response) => {
  try {
    const name = typeof request.body?.name === "string" ? request.body.name.trim() : "";
    const address =
      typeof request.body?.address === "string" && request.body.address.trim().length > 0
        ? request.body.address.trim()
        : null;

    if (!name) {
      return response.status(400).json({ error: "Debes indicar el nombre de la clínica." });
    }

    const { data: maxPortRow, error: maxPortError } = await supabase
      .from("clinics")
      .select("dicom_port")
      .not("dicom_port", "is", null)
      .order("dicom_port", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (maxPortError) throw maxPortError;

    const dicomPort = maxPortRow?.dicom_port
      ? maxPortRow.dicom_port + 1
      : DICOM_MULTITENANT_BASE_PORT;
    const offset = dicomPort - DICOM_MULTITENANT_BASE_PORT;
    const dicomAeTitle = `IMAGENDA_${String(offset).padStart(3, "0")}`;

    const { data: clinicRow, error: insertError } = await supabase
      .from("clinics")
      .insert({ name, address, dicom_ae_title: dicomAeTitle, dicom_port: dicomPort })
      .select()
      .single();
    if (insertError) {
      if (insertError.code === "23505") {
        return response.status(409).json({
          error: "Ya existe una clínica con ese puerto o AE Title (probablemente una carrera entre dos altas al mismo tiempo). Reintenta.",
        });
      }
      throw insertError;
    }

    const internalPort = dicomPort + DICOM_INTERNAL_PORT_OFFSET;
    const stunnelName = dicomAeTitle.toLowerCase().replace(/_/g, "-");

    const orthancServerConfig = JSON.stringify(
      {
        AET: dicomAeTitle,
        Port: internalPort,
        Labels: [clinicRow.id],
        LabelsConstraint: "All",
      },
      null,
      2,
    );

    const stunnelConfig =
      `foreground = yes\n\n` +
      `[${stunnelName}]\n` +
      `accept = ${dicomPort}\n` +
      `connect = 127.0.0.1:${internalPort}\n` +
      `cert = /opt/orthanc-dicom-tls/cert.pem\n` +
      `key = /opt/orthanc-dicom-tls/key.pem\n` +
      `setuid = stunnel4\n` +
      `setgid = stunnel4\n`;

    return response.json({
      clinic: shapeClinicRow(clinicRow),
      orthancSetup: {
        aeTitle: dicomAeTitle,
        port: dicomPort,
        internalPort,
        label: clinicRow.id,
        serverConfig: orthancServerConfig,
        stunnelConfig,
        instructions:
          `1) Agregar el bloque de Orthanc de arriba (puerto interno ${internalPort}) al array "Servers" de ` +
          `/opt/orthanc-config/multitenant.json en el droplet. ` +
          `2) Guardar el bloque de stunnel en /etc/stunnel/${stunnelName}.conf y habilitarlo/arrancarlo con ` +
          `"systemctl enable --now stunnel@${stunnelName}.service". ` +
          `3) Si el contenedor de Orthanc todavía no mapea el puerto ${internalPort}, agregarlo SOLO en loopback ` +
          `("-p 127.0.0.1:${internalPort}:${internalPort}", nunca "-p ${internalPort}:${internalPort}") y recrear el contenedor orthanc-test. ` +
          `4) Abrir en ufw únicamente el puerto público ("ufw allow ${dicomPort}/tcp"), nunca el ${internalPort} interno -- ` +
          `Orthanc ya no escucha directo en el puerto público, ahora lo hace stunnel.`,
      },
    });
  } catch (error) {
    console.error("Error al crear la clínica:", error);
    return response.status(500).json({ error: "No fue posible crear la clínica." });
  }
});

app.post("/chat", async (request, response) => {
  try {
    const message = request.body?.message;

    if (typeof message !== "string" || message.trim().length === 0) {
      return response.status(400).json({ error: "Debes enviar un mensaje válido." });
    }

    const result = await openai.responses.create({
      model,
      instructions: `
Eres Imagenda, un asistente de inteligencia artificial para empresas y equipos de salud.

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

// ============================================
// GMAIL: credenciales compartidas
// ============================================
// Credenciales OAuth de Google (scope gmail.modify) guardadas en
// backend/.env. Las usan tanto la campanita de notificaciones (solo
// lectura, rol administrador) como el módulo de Correo (lectura y
// respuesta, roles administrador/recepcion).

const gmailConfigured =
  Boolean(process.env.GMAIL_CLIENT_ID) &&
  Boolean(process.env.GMAIL_CLIENT_SECRET) &&
  Boolean(process.env.GMAIL_REFRESH_TOKEN);

function getGmailClient() {
  const oauth2Client = new google.auth.OAuth2(
    process.env.GMAIL_CLIENT_ID,
    process.env.GMAIL_CLIENT_SECRET,
  );
  oauth2Client.setCredentials({
    refresh_token: process.env.GMAIL_REFRESH_TOKEN,
  });
  return google.gmail({ version: "v1", auth: oauth2Client });
}

// "2026-09-20" -> "domingo 20 de septiembre de 2026", en español, sin
// depender de que el servidor tenga el locale es-CL instalado.
const DIAS_ES = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
const MESES_ES = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
];
function formatFechaLargaEs(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d, 12));
  return `${DIAS_ES[date.getUTCDay()]} ${d} de ${MESES_ES[m - 1]} de ${y}`;
}

// Confirmación de reserva por correo (Etapa 4 del plan de autoagendamiento
// web). Reutiliza las mismas credenciales de Gmail que ya usan la campanita
// de notificaciones y el módulo de Correo -- no es una cuenta nueva, es el
// mismo Gmail del centro enviando en su nombre. Se llama solo si el paciente
// dejó correo y gmailConfigured es true; el llamador ya envuelve esto en un
// try/catch propio, así que acá no hace falta atraparlo de nuevo.
async function sendBookingConfirmationEmail({ to, name, fecha, hora, tipo }) {
  const gmail = getGmailClient();

  const fechaLegible = formatFechaLargaEs(fecha);
  const asunto = `Confirmación de tu hora — ${fechaLegible} a las ${hora}`;
  const cuerpo = [
    `Hola ${name},`,
    "",
    `Tu hora quedó reservada para el ${fechaLegible} a las ${hora} (${tipo}).`,
    "",
    "La sala y el profesional los asigna el centro antes de tu atención; no necesitas elegirlos tú.",
    "",
    "Si necesitas cambiar o cancelar esta hora, comunícate directamente con el centro.",
    "",
    "Este correo es una confirmación automática, no es necesario responderlo.",
  ].join("\n");

  const mail = new MailComposer({ to, subject: asunto, text: cuerpo });
  const mensajeMime = await new Promise((resolve, reject) => {
    mail.compile().build((error, message) => {
      if (error) reject(error);
      else resolve(message);
    });
  });

  await gmail.users.messages.send({
    userId: "me",
    requestBody: { raw: mensajeMime.toString("base64url") },
  });
}

// Registro en memoria: referencia opaca -> URL de imagen de un correo real.
// Es lo que evita que el proxy de imágenes sea un proxy abierto (SSRF).
const registroImagenesProxy = crearRegistroImagenesProxy();

// URL pública base del endpoint de proxy de imágenes. Debe apuntar al host
// por el que el NAVEGADOR llega al backend (no al interno). Orden:
//   1. PUBLIC_BACKEND_URL (recomendado fijarlo en backend/.env)
//   2. RENDER_EXTERNAL_URL (lo pone Render automáticamente)
//   3. X-Forwarded-Host / -Proto (proxies como GitHub Codespaces, que
//      reescriben el Host a "localhost:3000" pero conservan el real acá)
//   4. Host + esquema deducido
function urlBaseProxyImagenes(request) {
  const base = (process.env.PUBLIC_BACKEND_URL || process.env.RENDER_EXTERNAL_URL || "")
    .trim()
    .replace(/\/+$/, "");
  if (base) return `${base}/gmail/image-proxy`;

  const primero = (valor) => (valor || "").split(",")[0].trim();
  const host = primero(request.headers["x-forwarded-host"]) || request.get("host") || "localhost";
  const esLocal = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i.test(host);
  const proto =
    primero(request.headers["x-forwarded-proto"]) || (esLocal ? "http" : "https");
  return `${proto}://${host}/gmail/image-proxy`;
}

// Proxy de imágenes de correos. NO va bajo /notifications (el cargador de
// imágenes del navegador no puede enviar el token de sesión): la seguridad
// viene de que solo acepta referencias opacas generadas por el backend a
// partir de correos reales, más el filtro anti-SSRF de gmailImageProxy.mjs.
app.get("/gmail/image-proxy", async (request, response) => {
  response.set(
    "Access-Control-Allow-Origin",
    process.env.GMAIL_IMAGE_PROXY_ORIGIN || "*",
  );
  response.set("Vary", "Origin");
  response.set("Cross-Origin-Resource-Policy", "cross-origin");

  const registro = registroImagenesProxy.resolver(request.query.ref);
  if (!registro) {
    // Referencia inválida/expirada: 404 sin cuerpo. El frontend cae al
    // ícono de imagen (mismo comportamiento que cuando no carga).
    return response.status(404).end();
  }

  const imagen = await descargarImagenSegura(registro.url, {
    timeoutMs: TIMEOUT_MS_DEFECTO,
    maxBytes: MAX_BYTES_DEFECTO,
  });
  if (!imagen) {
    return response.status(502).end();
  }

  response.set("Content-Type", imagen.contentType);
  response.set("Content-Length", String(imagen.buffer.length));
  response.set("Cache-Control", "private, max-age=3600");
  return response.status(200).end(imagen.buffer);
});

app.get(
  "/notifications/gmail",
  requireRole(ADMIN_ONLY),
  async (_request, response) => {
    if (!gmailConfigured) {
      return response.status(503).json({
        error:
          "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
      });
    }

    try {
      const gmail = getGmailClient();

      // Máximo los 20 correos no leídos más recientes de la bandeja de entrada.
      const listResult = await gmail.users.messages.list({
        userId: "me",
        q: "is:unread in:inbox",
        maxResults: 20,
      });

      const messages = listResult.data.messages ?? [];

      const detailed = await Promise.all(
        messages.map((message) =>
          gmail.users.messages.get({
            userId: "me",
            id: message.id,
            format: "metadata",
            metadataHeaders: ["Subject", "From", "Date"],
          }),
        ),
      );

      const correos = detailed.map((result) => {
        const message = result.data;
        const headers = message.payload?.headers ?? [];
        const getHeader = (name) =>
          headers.find(
            (header) => (header.name ?? "").toLowerCase() === name.toLowerCase(),
          )?.value ?? "";

        return {
          id: message.id,
          asunto: getHeader("Subject") || "(sin asunto)",
          remitente: getHeader("From"),
          fecha: message.internalDate
            ? new Date(Number(message.internalDate)).toISOString()
            : getHeader("Date"),
          // El snippet de Gmail ya es un extracto corto del cuerpo del correo.
          extracto: (message.snippet ?? "").trim(),
        };
      });

      return response.json({ total: correos.length, correos });
    } catch (error) {
      console.error("Error al consultar Gmail:", error);
      return response.status(502).json({
        error: "No fue posible consultar la bandeja de entrada de Gmail.",
        detalle:
          typeof error?.message === "string" ? error.message : "Error desconocido.",
      });
    }
  },
);

// Recorre recursivamente las partes MIME de un mensaje buscando el cuerpo
// en texto plano y en HTML (los correos multipart anidan las partes).
function extraerCuerpos(payload) {
  let textoPlano = "";
  let textoHtml = "";

  function decodificar(data) {
    if (!data) return "";
    return Buffer.from(data, "base64url").toString("utf-8");
  }

  function recorrer(part) {
    if (!part) return;
    const mimeType = part.mimeType ?? "";

    if (mimeType === "text/plain" && part.body?.data && !textoPlano) {
      textoPlano = decodificar(part.body.data);
    } else if (mimeType === "text/html" && part.body?.data && !textoHtml) {
      textoHtml = decodificar(part.body.data);
    }

    if (Array.isArray(part.parts)) {
      part.parts.forEach(recorrer);
    }
  }

  recorrer(payload);

  // Mensajes simples (no multipart) traen el cuerpo directo en el payload raíz.
  if (!textoPlano && !textoHtml && payload?.body?.data) {
    const contenido = decodificar(payload.body.data);
    if ((payload.mimeType ?? "").includes("html")) {
      textoHtml = contenido;
    } else {
      textoPlano = contenido;
    }
  }

  return { textoPlano, textoHtml };
}

app.get(
  "/notifications/gmail/:messageId",
  requireRole(ADMIN_ONLY),
  async (request, response) => {
    if (!gmailConfigured) {
      return response.status(503).json({
        error:
          "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
      });
    }

    try {
      const gmail = getGmailClient();
      const { messageId } = request.params;

      const result = await gmail.users.messages.get({
        userId: "me",
        id: messageId,
        format: "full",
      });

      const message = result.data;
      const headers = message.payload?.headers ?? [];
      const getHeader = (name) =>
        headers.find(
          (header) => (header.name ?? "").toLowerCase() === name.toLowerCase(),
        )?.value ?? "";

      const { textoPlano, textoHtml } = extraerCuerpos(message.payload);

      // Reescribe las imágenes remotas del cuerpo para que pasen por nuestro
      // proxy (así se ven igual que en Gmail en vez de bloquearse por CORS).
      const cuerpoHtml = reescribirImagenesRemotas(textoHtml, {
        registrar: (url, msgId) => registroImagenesProxy.registrar(url, msgId),
        messageId: message.id,
        urlBaseProxy: urlBaseProxyImagenes(request),
      });

      return response.json({
        id: message.id,
        asunto: getHeader("Subject") || "(sin asunto)",
        remitente: getHeader("From"),
        fecha: message.internalDate
          ? new Date(Number(message.internalDate)).toISOString()
          : getHeader("Date"),
        cuerpoTexto: textoPlano,
        cuerpoHtml,
      });
    } catch (error) {
      console.error("Error al consultar el correo de Gmail:", error);
      const status = error?.code === 404 ? 404 : 502;
      return response.status(status).json({
        error:
          status === 404
            ? "El correo solicitado no existe o ya no está disponible."
            : "No fue posible consultar el correo de Gmail.",
        detalle:
          typeof error?.message === "string" ? error.message : "Error desconocido.",
      });
    }
  },
);

// Recorre las partes MIME buscando adjuntos reales (tienen filename y un
// attachmentId con el que luego se puede pedir su contenido por separado).
function extraerAdjuntos(payload) {
  const adjuntos = [];

  function recorrer(part) {
    if (!part) return;
    if ((part.filename ?? "").trim().length > 0 && part.body?.attachmentId) {
      adjuntos.push({
        attachmentId: part.body.attachmentId,
        nombre: part.filename,
        mimeType: part.mimeType || "application/octet-stream",
        tamano: part.body.size ?? 0,
      });
    }
    if (Array.isArray(part.parts)) {
      part.parts.forEach(recorrer);
    }
  }

  recorrer(payload);
  return adjuntos;
}

// ============================================
// MÓDULO: CORREO (lectura y respuesta)
// ============================================
// Sección "Correo" del menú principal. A diferencia de la campanita de
// notificaciones (solo administrador, solo no leídos), aquí administrador y
// recepcion pueden navegar toda la bandeja de entrada y responder correos.

app.get("/mail/messages", async (request, response) => {
  if (!gmailConfigured) {
    return response.status(503).json({
      error:
        "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
    });
  }

  try {
    const gmail = getGmailClient();
    const pageToken =
      typeof request.query.pageToken === "string" && request.query.pageToken.trim()
        ? request.query.pageToken.trim()
        : undefined;
    const q =
      typeof request.query.q === "string" && request.query.q.trim()
        ? request.query.q.trim()
        : "in:inbox";

    const listResult = await gmail.users.messages.list({
      userId: "me",
      q,
      maxResults: 25,
      pageToken,
    });

    const messages = listResult.data.messages ?? [];

    const detailed = await Promise.all(
      messages.map((message) =>
        gmail.users.messages.get({
          userId: "me",
          id: message.id,
          format: "metadata",
          metadataHeaders: ["Subject", "From", "Date"],
        }),
      ),
    );

    const correos = detailed.map((result) => {
      const message = result.data;
      const headers = message.payload?.headers ?? [];
      const getHeader = (name) =>
        headers.find(
          (header) => (header.name ?? "").toLowerCase() === name.toLowerCase(),
        )?.value ?? "";

      return {
        id: message.id,
        threadId: message.threadId,
        asunto: getHeader("Subject") || "(sin asunto)",
        remitente: getHeader("From"),
        fecha: message.internalDate
          ? new Date(Number(message.internalDate)).toISOString()
          : getHeader("Date"),
        extracto: (message.snippet ?? "").trim(),
        noLeido: (message.labelIds ?? []).includes("UNREAD"),
      };
    });

    return response.json({
      total: correos.length,
      correos,
      siguientePagina: listResult.data.nextPageToken ?? null,
    });
  } catch (error) {
    console.error("Error al consultar Gmail:", error);
    return response.status(502).json({
      error: "No fue posible consultar la bandeja de entrada de Gmail.",
      detalle:
        typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.get("/mail/messages/:id", async (request, response) => {
  if (!gmailConfigured) {
    return response.status(503).json({
      error:
        "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
    });
  }

  try {
    const gmail = getGmailClient();
    const { id } = request.params;

    const result = await gmail.users.messages.get({
      userId: "me",
      id,
      format: "full",
    });

    const message = result.data;
    const headers = message.payload?.headers ?? [];
    const getHeader = (name) =>
      headers.find(
        (header) => (header.name ?? "").toLowerCase() === name.toLowerCase(),
      )?.value ?? "";

    const { textoPlano, textoHtml } = extraerCuerpos(message.payload);

    const cuerpoHtml = reescribirImagenesRemotas(textoHtml, {
      registrar: (url, msgId) => registroImagenesProxy.registrar(url, msgId),
      messageId: message.id,
      urlBaseProxy: urlBaseProxyImagenes(request),
    });

    return response.json({
      id: message.id,
      threadId: message.threadId,
      asunto: getHeader("Subject") || "(sin asunto)",
      remitente: getHeader("From"),
      destinatarios: getHeader("To"),
      fecha: message.internalDate
        ? new Date(Number(message.internalDate)).toISOString()
        : getHeader("Date"),
      cuerpoTexto: textoPlano,
      cuerpoHtml,
      adjuntos: extraerAdjuntos(message.payload),
    });
  } catch (error) {
    console.error("Error al consultar el correo de Gmail:", error);
    const status = error?.code === 404 ? 404 : 502;
    return response.status(status).json({
      error:
        status === 404
          ? "El correo solicitado no existe o ya no está disponible."
          : "No fue posible consultar el correo de Gmail.",
      detalle:
        typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.get("/mail/messages/:id/attachments/:attachmentId", async (request, response) => {
  if (!gmailConfigured) {
    return response.status(503).json({
      error:
        "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
    });
  }

  try {
    const gmail = getGmailClient();
    const { id, attachmentId } = request.params;

    const result = await gmail.users.messages.attachments.get({
      userId: "me",
      messageId: id,
      id: attachmentId,
    });

    const data = result.data?.data;
    if (!data) {
      return response.status(404).end();
    }

    const nombreCrudo =
      typeof request.query.nombre === "string" && request.query.nombre.trim()
        ? request.query.nombre.trim()
        : "adjunto";
    // Content-Disposition no admite comillas ni saltos de línea dentro del
    // valor citado: se sanean para no romper el header.
    const nombre = nombreCrudo.replace(/["\r\n]/g, "_");
    const mimeType =
      typeof request.query.mimeType === "string" && request.query.mimeType.trim()
        ? request.query.mimeType.trim()
        : "application/octet-stream";

    response.set("Content-Type", mimeType);
    response.set("Content-Disposition", `attachment; filename="${nombre}"`);
    return response.status(200).end(Buffer.from(data, "base64url"));
  } catch (error) {
    console.error("Error al descargar el adjunto de Gmail:", error);
    const status = error?.code === 404 ? 404 : 502;
    return response.status(status).json({
      error:
        status === 404
          ? "El adjunto solicitado no existe o ya no está disponible."
          : "No fue posible descargar el adjunto.",
      detalle:
        typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

function limpiarAsuntoRespuesta(asuntoOriginal) {
  const asunto = (asuntoOriginal ?? "").trim();
  if (!asunto) return "Re: (sin asunto)";
  return /^re:/i.test(asunto) ? asunto : `Re: ${asunto}`;
}

// Límite del propio Gmail para el tamaño total de un correo saliente
// (adjuntos incluidos, ya codificados en base64). Se deja algo de margen.
const LIMITE_TOTAL_ADJUNTOS_BASE64 = 25 * 1024 * 1024;

app.post("/gmail/reply", requireAuth, requireRole(MAIL_STAFF), async (request, response) => {
  if (!gmailConfigured) {
    return response.status(503).json({
      error:
        "La integración con Gmail no está configurada en el servidor (faltan credenciales en backend/.env).",
    });
  }

  const { messageId, cuerpoTexto, adjuntos } = request.body ?? {};

  if (typeof messageId !== "string" || messageId.trim().length === 0) {
    return response.status(400).json({ error: "Falta el id del correo a responder." });
  }
  if (typeof cuerpoTexto !== "string" || cuerpoTexto.trim().length === 0) {
    return response.status(400).json({ error: "El cuerpo de la respuesta no puede estar vacío." });
  }

  const listaAdjuntos = Array.isArray(adjuntos) ? adjuntos : [];
  let tamanoTotalBase64 = 0;
  for (const adjunto of listaAdjuntos) {
    if (
      typeof adjunto?.nombre !== "string" ||
      adjunto.nombre.trim().length === 0 ||
      typeof adjunto?.base64Data !== "string" ||
      adjunto.base64Data.trim().length === 0
    ) {
      return response.status(400).json({
        error: "Cada adjunto necesita al menos nombre y contenido.",
      });
    }
    tamanoTotalBase64 += adjunto.base64Data.length;
  }
  if (tamanoTotalBase64 > LIMITE_TOTAL_ADJUNTOS_BASE64) {
    return response.status(413).json({
      error: "Los adjuntos superan el límite permitido por Gmail (25 MB en total).",
    });
  }

  try {
    const gmail = getGmailClient();

    const original = await gmail.users.messages.get({
      userId: "me",
      id: messageId,
      format: "metadata",
      metadataHeaders: ["Subject", "From", "To", "Reply-To", "Message-Id", "References"],
    });

    const headers = original.data.payload?.headers ?? [];
    const getHeader = (name) =>
      headers.find(
        (header) => (header.name ?? "").toLowerCase() === name.toLowerCase(),
      )?.value ?? "";

    const destinatario = getHeader("Reply-To") || getHeader("From");
    if (!destinatario) {
      return response.status(502).json({
        error: "No fue posible determinar el destinatario del correo original.",
      });
    }

    const messageIdOriginal = getHeader("Message-Id") || undefined;
    const referencesOriginal = getHeader("References");
    const references =
      [referencesOriginal, messageIdOriginal].filter(Boolean).join(" ").trim() || undefined;
    const asunto = limpiarAsuntoRespuesta(getHeader("Subject"));

    const mail = new MailComposer({
      to: destinatario,
      subject: asunto,
      text: cuerpoTexto,
      inReplyTo: messageIdOriginal,
      references,
      attachments: listaAdjuntos.map((adjunto) => ({
        filename: adjunto.nombre,
        contentType:
          typeof adjunto.mimeType === "string" && adjunto.mimeType.trim()
            ? adjunto.mimeType.trim()
            : undefined,
        content: Buffer.from(adjunto.base64Data, "base64"),
      })),
    });

    const mensajeMime = await new Promise((resolve, reject) => {
      mail.compile().build((error, message) => {
        if (error) reject(error);
        else resolve(message);
      });
    });

    const enviado = await gmail.users.messages.send({
      userId: "me",
      requestBody: {
        raw: mensajeMime.toString("base64url"),
        threadId: original.data.threadId,
      },
    });

    return response.status(201).json({
      id: enviado.data.id,
      threadId: enviado.data.threadId,
    });
  } catch (error) {
    console.error("Error al enviar la respuesta por Gmail:", error);
    const status = error?.code === 404 ? 404 : 502;
    return response.status(status).json({
      error:
        status === 404
          ? "El correo original ya no existe o no está disponible."
          : "No fue posible enviar la respuesta.",
      detalle:
        typeof error?.message === "string" ? error.message : "Error desconocido.",
    });
  }
});

app.listen(port, () => {
  console.log("");
  console.log("========================================");
  console.log("Imagenda Backend iniciado correctamente");
  console.log(`Servidor:      http://localhost:${port}`);
  console.log(`Estado:        http://localhost:${port}/health`);
  console.log(`Modelo:        ${model}`);
  console.log(`Base de datos: Supabase (${process.env.SUPABASE_URL})`);
  console.log(`Gmail:         ${gmailConfigured ? "configurado (lectura y respuesta)" : "no configurado"}`);
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
