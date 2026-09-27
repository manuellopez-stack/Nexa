// Equipo Imagenda con acceso a TODAS las clínicas: header X-Clinic-Id (ver
// requireAuth), contra la base en memoria de test/support/supabase-mock.mjs.
// Lo crítico: el header solo lo respeta un miembro activo del equipo con
// all_clinics; para cualquier otra cuenta se ignora por completo.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";

import { db, passwords, resetDb, users } from "./support/supabase-mock.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const MISSING_CLINIC = "33333333-3333-3333-3333-333333333333";
const TOKENS = {
  todas: "tok-todas",
  todasConBase: "tok-todas-base",
  equipoBase: "tok-equipo-base",
  equipoSolo: "tok-equipo-solo",
  clinica: "tok-clinica",
  exEquipo: "tok-ex-equipo",
};

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      // Equipo con acceso a todas, sin clínica base.
      {
        id: "u-todas",
        email: "todas@imagenda.cl",
        role: "administrador",
        clinic_id: null,
        is_platform_admin: true,
        platform_role: "admin",
        all_clinics: true,
      },
      // Equipo con acceso a todas y clínica base (sin header usa la base).
      {
        id: "u-todas-base",
        email: "todas-base@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: true,
        platform_role: "soporte",
        all_clinics: true,
      },
      // Equipo SIN all_clinics, con clínica base.
      {
        id: "u-equipo-base",
        email: "equipo-base@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: true,
        platform_role: "admin",
        all_clinics: false,
      },
      // Equipo SIN all_clinics y "Solo Imagenda".
      {
        id: "u-equipo-solo",
        email: "equipo-solo@imagenda.cl",
        role: "administrador",
        clinic_id: null,
        is_platform_admin: true,
        platform_role: "soporte",
        all_clinics: false,
      },
      // Personal de clínica: aunque tuviera all_clinics en la base, no es del
      // equipo y el header se ignora.
      {
        id: "u-clinica",
        email: "jefe@clinica.cl",
        role: "administrador",
        clinic_id: CLINIC,
        all_clinics: true,
      },
      // Ex miembro del equipo (quitaron el acceso a plataforma pero sigue con
      // perfil sin disabled_at, p. ej. estado intermedio): is_platform_admin
      // false -> header ignorado.
      {
        id: "u-ex-equipo",
        email: "ex@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: false,
        platform_role: "admin",
        all_clinics: true,
      },
    ],
    patients: [
      { id: 1, name: "Paciente Test", clinic_id: CLINIC, ai_summary: "Resumen." },
      { id: 2, name: "Paciente Otra", clinic_id: OTHER_CLINIC, ai_summary: "Resumen." },
    ],
  });
  users[TOKENS.todas] = { id: "u-todas", email: "todas@imagenda.cl" };
  users[TOKENS.todasConBase] = { id: "u-todas-base", email: "todas-base@imagenda.cl" };
  users[TOKENS.equipoBase] = { id: "u-equipo-base", email: "equipo-base@imagenda.cl" };
  users[TOKENS.equipoSolo] = { id: "u-equipo-solo", email: "equipo-solo@imagenda.cl" };
  users[TOKENS.clinica] = { id: "u-clinica", email: "jefe@clinica.cl" };
  users[TOKENS.exEquipo] = { id: "u-ex-equipo", email: "ex@imagenda.cl" };
}

function call(method, url, as, { clinic, body, headers = {} } = {}) {
  return fetch(`${BASE}${url}`, {
    method,
    headers: {
      ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}),
      ...(clinic ? { "X-Clinic-Id": clinic } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function patientNames(as, clinic) {
  const response = await call("GET", "/patients", as, { clinic });
  assert.equal(response.status, 200, `GET /patients como ${as} con ${clinic}`);
  return (await response.json()).patients.map((patient) => patient.name);
}

before(async () => {
  process.env.OPENAI_API_KEY = "test";
  process.env.SUPABASE_URL = "http://supabase.mock";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test";

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

test("equipo con all_clinics ve los pacientes de la clínica del header", async () => {
  assert.deepEqual(await patientNames("todas", CLINIC), ["Paciente Test"]);
  assert.deepEqual(await patientNames("todas", OTHER_CLINIC), ["Paciente Otra"]);

  assert.equal((await call("GET", "/patients/2", "todas", { clinic: OTHER_CLINIC })).status, 200);
  assert.equal((await call("GET", "/patients/2", "todas", { clinic: CLINIC })).status, 404);
});

test("equipo con all_clinics: lo que crea queda en la clínica del header, sin tocar su perfil", async () => {
  const response = await call("POST", "/patients", "todas", {
    clinic: OTHER_CLINIC,
    body: { name: "Nuevo Paciente", rut: "11.111.111-1" },
  });
  assert.ok([200, 201].includes(response.status), `POST /patients respondió ${response.status}`);
  const created = db.patients.find((patient) => patient.name === "Nuevo Paciente");
  assert.equal(created.clinic_id, OTHER_CLINIC);
  assert.equal(db.staff_profiles.find((row) => row.id === "u-todas").clinic_id, null);
});

test("equipo con all_clinics sin header usa su clínica base (o 403 si no tiene)", async () => {
  assert.deepEqual(await patientNames("todasConBase"), ["Paciente Test"]);
  const response = await call("GET", "/patients", "todas");
  assert.equal(response.status, 403);
  assert.match((await response.json()).error, /no tiene una clínica asignada/);
});

test("X-Clinic-Id con una clínica inexistente o mal formada da 400", async () => {
  for (const clinic of [MISSING_CLINIC, "no-es-un-uuid"]) {
    const response = await call("GET", "/patients", "todas", { clinic });
    assert.equal(response.status, 400, clinic);
    assert.equal((await response.json()).error, "La clínica elegida no existe.");
  }
});

test("personal de clínica con header de otra clínica sigue viendo solo la suya", async () => {
  assert.deepEqual(await patientNames("clinica", OTHER_CLINIC), ["Paciente Test"]);
  assert.equal((await call("GET", "/patients/2", "clinica", { clinic: OTHER_CLINIC })).status, 404);
  // El header se ignora por completo: ni siquiera se valida.
  assert.deepEqual(await patientNames("clinica", MISSING_CLINIC), ["Paciente Test"]);

  const createResponse = await call("POST", "/patients", "clinica", {
    clinic: OTHER_CLINIC,
    body: { name: "Paciente Colado", rut: "22.222.222-2" },
  });
  assert.ok([200, 201].includes(createResponse.status), `POST /patients respondió ${createResponse.status}`);
  const created = db.patients.find((patient) => patient.name === "Paciente Colado");
  assert.equal(created.clinic_id, CLINIC);
});

test("equipo sin all_clinics ignora el header", async () => {
  assert.deepEqual(await patientNames("equipoBase", OTHER_CLINIC), ["Paciente Test"]);
  assert.deepEqual(await patientNames("equipoBase", MISSING_CLINIC), ["Paciente Test"]);

  // "Solo Imagenda" sin all_clinics: el header no le da acceso a pacientes.
  const response = await call("GET", "/patients", "equipoSolo", { clinic: OTHER_CLINIC });
  assert.equal(response.status, 403);
});

test("quien ya no es del equipo (is_platform_admin false) ignora el header aunque tenga all_clinics", async () => {
  assert.deepEqual(await patientNames("exEquipo", OTHER_CLINIC), ["Paciente Test"]);
});

test("el header no cambia el alcance de las rutas de plataforma", async () => {
  // /platform-team sigue listando a todo el equipo, con allClinics.
  const response = await call("GET", "/platform-team", "todas", { clinic: CLINIC });
  assert.equal(response.status, 200);
  const { team } = await response.json();
  const byId = Object.fromEntries(team.map((member) => [member.id, member]));
  assert.equal(byId["u-todas"].allClinics, true);
  assert.equal(byId["u-equipo-base"].allClinics, false);
  // Y la clínica base guardada no cambia por el header.
  assert.equal(byId["u-todas"].clinicId, null);
});

test("login devuelve allClinics solo para el equipo activo con all_clinics", async () => {
  const cases = [
    ["todas@imagenda.cl", true],
    ["equipo-base@imagenda.cl", false],
    ["jefe@clinica.cl", false],
    ["ex@imagenda.cl", false],
  ];
  for (const [email, expected] of cases) {
    passwords[email] = "clave-segura";
    const response = await fetch(`${BASE}/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password: "clave-segura" }),
    });
    assert.equal(response.status, 200, email);
    assert.equal((await response.json()).user.allClinics, expected, email);
  }
});

test("CORS permite el header X-Clinic-Id", async () => {
  const response = await fetch(`${BASE}/patients`, {
    method: "OPTIONS",
    headers: {
      Origin: "http://localhost:5000",
      "Access-Control-Request-Method": "GET",
      "Access-Control-Request-Headers": "authorization,x-clinic-id",
    },
  });
  assert.ok(response.status < 300);
  const allowed = (response.headers.get("access-control-allow-headers") ?? "").toLowerCase();
  for (const header of ["authorization", "content-type", "accept", "x-clinic-id"]) {
    assert.ok(allowed.split(",").map((value) => value.trim()).includes(header), header);
  }
});

test("invitar y cambiar acceso: todas / ninguna / una clínica", async () => {
  const invite = async (email, patientAccess) => {
    const response = await call("POST", "/platform-team/invite", "equipoBase", {
      body: { email, fullName: "Persona", platformRole: "soporte", patientAccess },
    });
    assert.equal(response.status, 200, `${email}: ${patientAccess}`);
    const { member } = await response.json();
    return db.staff_profiles.find((row) => row.id === member.id);
  };

  const todas = await invite("a@imagenda.cl", "todas");
  assert.equal(todas.all_clinics, true);
  assert.equal(todas.clinic_id, null);

  const ninguna = await invite("b@imagenda.cl", "ninguna");
  assert.equal(ninguna.all_clinics, false);
  assert.equal(ninguna.clinic_id, null);

  const una = await invite("c@imagenda.cl", OTHER_CLINIC);
  assert.equal(una.all_clinics, false);
  assert.equal(una.clinic_id, OTHER_CLINIC);

  const inexistente = await call("POST", "/platform-team/invite", "equipoBase", {
    body: { email: "d@imagenda.cl", platformRole: "soporte", patientAccess: MISSING_CLINIC },
  });
  assert.equal(inexistente.status, 400);

  // Cambiar: una clínica -> todas -> ninguna -> una clínica.
  const patch = async (patientAccess) => {
    const response = await call("PATCH", `/platform-team/${una.id}/clinic`, "equipoBase", {
      body: { patientAccess },
    });
    assert.equal(response.status, 200, String(patientAccess));
    return (await response.json()).member;
  };
  let member = await patch("todas");
  assert.equal(member.allClinics, true);
  assert.equal(member.clinicId, null);
  member = await patch("ninguna");
  assert.equal(member.allClinics, false);
  assert.equal(member.clinicId, null);
  member = await patch(CLINIC);
  assert.equal(member.allClinics, false);
  assert.equal(member.clinicId, CLINIC);

  // Soporte no puede cambiarlo.
  const soporte = await call("PATCH", `/platform-team/${una.id}/clinic`, "todasConBase", {
    body: { patientAccess: "todas" },
  });
  assert.equal(soporte.status, 403);
  assert.equal(db.staff_profiles.find((row) => row.id === una.id).all_clinics, false);
});
