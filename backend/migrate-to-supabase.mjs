import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { createClient } from "@supabase/supabase-js";

dotenv.config({ quiet: true });

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const patientsFile = path.join(__dirname, "data", "patients.json");

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    "Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY en backend/.env. Revisa el archivo antes de continuar.",
  );
  process.exit(1);
}

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
);

async function migrate() {
  const patients = JSON.parse(fs.readFileSync(patientsFile, "utf-8"));
  console.log(`Migrando ${patients.length} paciente(s) desde patients.json...\n`);

  let patientsMigrated = 0;
  let documentsMigrated = 0;
  let historyMigrated = 0;

  for (const patient of patients) {
    const { data: insertedPatient, error: patientError } = await supabase
      .from("patients")
      .insert({
        time: patient.time ?? null,
        name: patient.name ?? null,
        rut: patient.rut ?? null,
        age: patient.age ?? null,
        doctor: patient.doctor ?? null,
        phone: patient.phone ?? null,
        exam: patient.exam ?? null,
        room: patient.room ?? null,
        status: patient.status ?? null,
        observations: patient.observations ?? null,
        priority: patient.priority ?? null,
        risk: patient.risk ?? null,
        ai_summary: patient.aiSummary ?? null,
      })
      .select()
      .single();

    if (patientError) {
      console.error(`✗ Error migrando paciente "${patient.name}":`, patientError.message);
      continue;
    }

    const newPatientId = insertedPatient.id;
    patientsMigrated += 1;
    console.log(`✓ Paciente "${patient.name}" migrado (id nuevo: ${newPatientId})`);

    // Mapa del id antiguo del documento (el que tenía en el JSON) al id
    // nuevo que le asignó Supabase, para poder enlazar el historial.
    const documentIdMap = new Map();

    const documentRecords = Array.isArray(patient.documentRecords)
      ? patient.documentRecords
      : [];

    for (const record of documentRecords) {
      const { data: insertedDoc, error: docError } = await supabase
        .from("documents")
        .insert({
          patient_id: newPatientId,
          filename: record.filename ?? null,
          document_type: record.documentType ?? null,
          exam: record.exam ?? null,
          patient_name: record.patientName ?? null,
          patient_rut: record.patientRut ?? null,
          patient_age: record.patientAge ?? null,
          reason: record.reason ?? null,
          priority: record.priority ?? null,
          is_clinical: record.isClinical ?? true,
          date: record.date ?? null,
          summary: record.summary ?? null,
          equipment: record.equipment ?? null,
          doctor: record.doctor ?? null,
          validation_status: record.validationStatus ?? "pendiente",
          validated_at: record.validatedAt ?? null,
          incorporated_at: record.incorporatedAt ?? new Date().toISOString(),
        })
        .select()
        .single();

      if (docError) {
        console.error(`  ✗ Error migrando documento "${record.filename}":`, docError.message);
        continue;
      }

      documentsMigrated += 1;
      if (record.id) documentIdMap.set(record.id, insertedDoc.id);
      console.log(`  ✓ Documento "${record.filename}" migrado`);
    }

    const history = Array.isArray(patient.history) ? patient.history : [];

    for (const event of history) {
      const mappedDocId = event.sourceDocumentId
        ? documentIdMap.get(event.sourceDocumentId) ?? null
        : null;

      const { error: historyError } = await supabase.from("history_events").insert({
        patient_id: newPatientId,
        document_id: mappedDocId,
        date: event.date ?? null,
        exam: event.exam ?? null,
        summary: event.summary ?? null,
      });

      if (historyError) {
        console.error("  ✗ Error migrando evento de historial:", historyError.message);
        continue;
      }

      historyMigrated += 1;
      console.log(`  ✓ Evento de historial migrado (${event.exam ?? "sin examen"})`);
    }

    console.log("");
  }

  console.log("========================================");
  console.log("Migración terminada");
  console.log(`Pacientes migrados:  ${patientsMigrated} de ${patients.length}`);
  console.log(`Documentos migrados: ${documentsMigrated}`);
  console.log(`Eventos de historial migrados: ${historyMigrated}`);
  console.log("========================================");
}

migrate().catch((error) => {
  console.error("Error general en la migración:", error);
  process.exit(1);
});
