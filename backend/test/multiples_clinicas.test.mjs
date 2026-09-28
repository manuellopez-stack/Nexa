// Una cuenta, varias clínicas (sql/multiples_clinicas.sql): membresías en
// staff_clinic_memberships con un rol por clínica, elegidas con el header
// X-Clinic-Id (ver requireAuth), contra la base en memoria de
// test/support/supabase-mock.mjs.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";

import { authAdminCalls, db, passwords, resetDb, users } from "./support/supabase-mock.mjs";

const BASE = "http://localhost:3000";
const RENCA = "11111111-1111-1111-1111-111111111111";
const LIDER = "22222222-2222-2222-2222-222222222222";
const TERCERA = "33333333-3333-3333-3333-333333333333";
const TOKENS = {
  multi: "tok-multi",
  rencaAdmin: "tok-renca-admin",
  liderAdmin: "tok-lider-admin",
  liderTec: "tok-lider-tec",
  rencaTec: "tok-renca-tec",
};

function seed() {
  resetDb({
    clinics: [
      { id: RENCA, name: "Clínica Renca", status: "activa" },
      { id: LIDER, name: "Clínica Líder", status: "activa" },
      { id: TERCERA, name: "Tercera clínica", status: "activa" },
    ],
    staff_profiles: [
      // Dos clínicas: administradora en Renca (principal), médica en Líder.
      { id: "u-multi", email: "multi@correo.cl", role: "administrador", clinic_id: RENCA, created_at: "2026-01-01" },
      { id: "u-renca-admin", email: "admin@renca.cl", role: "administrador", clinic_id: RENCA, created_at: "2026-01-02" },
      { id: "u-lider-admin", email: "admin@lider.cl", role: "administrador", clinic_id: LIDER, created_at: "2026-01-03" },
      { id: "u-lider-tec", email: "tec@lider.cl", role: "tecnico", clinic_id: LIDER, created_at: "2026-01-04" },
      // Sin fila de membresía (anterior al backfill): su principal cuenta igual.
      { id: "u-renca-tec", email: "tec@renca.cl", role: "tecnico", clinic_id: RENCA, created_at: "2026-01-05" },
    ],
    staff_clinic_memberships: [
      { id: "m1", staff_id: "u-multi", clinic_id: RENCA, role: "administrador", created_at: "2026-01-01" },
      { id: "m2", staff_id: "u-multi", clinic_id: LIDER, role: "medico", created_at: "2026-01-02" },
      { id: "m3", staff_id: "u-renca-admin", clinic_id: RENCA, role: "administrador", created_at: "2026-01-02" },
      { id: "m4", staff_id: "u-lider-admin", clinic_id: LIDER, role: "administrador", created_at: "2026-01-03" },
      { id: "m5", staff_id: "u-lider-tec", clinic_id: LIDER, role: "tecnico", created_at: "2026-01-04" },
    ],
    patients: [
      { id: 1, name: "Paciente Renca", clinic_id: RENCA },
      { id: 2, name: "Paciente Líder", clinic_id: LIDER },
    ],
  });
  users[TOKENS.multi] = { id: "u-multi", email: "multi@correo.cl" };
  users[TOKENS.rencaAdmin] = { id: "u-renca-admin", email: "admin@renca.cl" };
  users[TOKENS.liderAdmin] = { id: "u-lider-admin", email: "admin@lider.cl" };
  users[TOKENS.liderTec] = { id: "u-lider-tec", email: "tec@lider.cl" };
  users[TOKENS.rencaTec] = { id: "u-renca-tec", email: "tec@renca.cl" };
}

function call(method, url, as, { clinic, body } = {}) {
  return fetch(`${BASE}${url}`, {
    method,
    headers: {
      ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}),
      ...(clinic ? { "X-Clinic-Id": clinic } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function patientNames(as, clinic) {
  const response = await call("GET", "/patients", as, { clinic });
  assert.equal(response.status, 200, `GET /patients como ${as} con ${clinic}`);
  return (await response.json()).patients.map((patient) => patient.name);
}

async function staffOf(as, clinic) {
  const response = await call("GET", "/staff", as, { clinic });
  assert.equal(response.status, 200, `GET /staff como ${as}`);
  return Object.fromEntries((await response.json()).staff.map((row) => [row.id, row]));
}

const memberships = (staffId) =>
  (db.staff_clinic_memberships ?? []).filter((row) => row.staff_id === staffId);

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

test("usuario con 2 clínicas ve los pacientes de la clínica del header, con el rol de esa clínica", async () => {
  assert.deepEqual(await patientNames("multi"), ["Paciente Renca"]);
  assert.deepEqual(await patientNames("multi", RENCA), ["Paciente Renca"]);
  assert.deepEqual(await patientNames("multi", LIDER), ["Paciente Líder"]);
  assert.equal((await call("GET", "/patients/2", "multi", { clinic: LIDER })).status, 200);
  assert.equal((await call("GET", "/patients/2", "multi", { clinic: RENCA })).status, 404);

  // Administradora en Renca: gestiona el equipo. Médica en Líder: no.
  assert.equal((await call("GET", "/staff", "multi", { clinic: RENCA })).status, 200);
  assert.equal((await call("GET", "/staff", "multi", { clinic: LIDER })).status, 403);

  // Lo que crea queda en la clínica del header, sin tocar su perfil.
  const created = await call("POST", "/patients", "multi", {
    clinic: LIDER,
    body: { name: "Nuevo Líder", rut: "11.111.111-1" },
  });
  assert.equal(created.status, 201);
  assert.equal(db.patients.find((p) => p.name === "Nuevo Líder").clinic_id, LIDER);
  assert.equal(db.staff_profiles.find((row) => row.id === "u-multi").clinic_id, RENCA);
});

test("header de una clínica sin membresía se ignora: ve solo su principal", async () => {
  assert.deepEqual(await patientNames("multi", TERCERA), ["Paciente Renca"]);
  assert.deepEqual(await patientNames("multi", "no-es-un-uuid"), ["Paciente Renca"]);
  assert.deepEqual(await patientNames("rencaTec", LIDER), ["Paciente Renca"]);
  assert.equal((await call("GET", "/patients/2", "rencaAdmin", { clinic: LIDER })).status, 404);
  // Sin membresía en Líder, su rol sigue siendo el de Renca.
  assert.equal((await call("GET", "/staff", "rencaAdmin", { clinic: LIDER })).status, 200);
});

test("login y /me devuelven las clínicas con el rol de cada una", async () => {
  passwords["multi@correo.cl"] = "clave-segura";
  const response = await fetch(`${BASE}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "multi@correo.cl", password: "clave-segura" }),
  });
  assert.equal(response.status, 200);
  const { user } = await response.json();
  assert.equal(user.clinicId, RENCA);
  assert.equal(user.clinicName, "Clínica Renca");
  assert.equal(user.role, "administrador");
  assert.deepEqual(user.clinics, [
    { clinicId: RENCA, clinicName: "Clínica Renca", role: "administrador" },
    { clinicId: LIDER, clinicName: "Clínica Líder", role: "medico" },
  ]);

  // Sin fila de membresía, la principal aparece igual.
  const me = await call("GET", "/me", "rencaTec");
  assert.equal(me.status, 200);
  assert.deepEqual((await me.json()).user.clinics, [
    { clinicId: RENCA, clinicName: "Clínica Renca", role: "tecnico" },
  ]);
});

test("invitar un correo que ya tiene cuenta crea la membresía sin invitar de nuevo", async () => {
  const response = await call("POST", "/staff/invite", "rencaAdmin", {
    body: { email: "TEC@lider.cl", role: "recepcion" },
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(
    body.message,
    "Esta persona ya tenía cuenta en Imagenda: se le dio acceso a esta clínica. Entrará con su misma contraseña.",
  );
  assert.equal(body.staff.clinicId, RENCA);
  assert.equal(body.staff.role, "recepcion");
  assert.equal(authAdminCalls.filter((c) => c.method === "inviteUserByEmail").length, 0);
  assert.deepEqual(
    memberships("u-lider-tec").map((m) => [m.clinic_id, m.role]).sort(),
    [[LIDER, "tecnico"], [RENCA, "recepcion"]].sort(),
  );
  // La clínica y el rol principal no cambian.
  const profile = db.staff_profiles.find((row) => row.id === "u-lider-tec");
  assert.equal(profile.clinic_id, LIDER);
  assert.equal(profile.role, "tecnico");

  // Ahora entra a Renca con el rol de Renca.
  assert.deepEqual(await patientNames("liderTec", RENCA), ["Paciente Renca"]);
  assert.equal((await call("GET", "/patients/1", "liderTec", { clinic: RENCA })).status, 403);

  // Aparece en el equipo de Renca con el rol de Renca.
  assert.equal((await staffOf("rencaAdmin"))["u-lider-tec"].role, "recepcion");

  // Invitarla otra vez a la misma clínica: 400.
  const again = await call("POST", "/staff/invite", "rencaAdmin", {
    body: { email: "tec@lider.cl", role: "tecnico" },
  });
  assert.equal(again.status, 400);
  assert.equal((await again.json()).error, "Esta persona ya pertenece a esta clínica.");

  // Su clínica principal también cuenta, aunque no tenga fila de membresía.
  const principal = await call("POST", "/staff/invite", "rencaAdmin", {
    body: { email: "tec@renca.cl", role: "medico" },
  });
  assert.equal(principal.status, 400);
});

test("invitar un correo nuevo invita en Auth y crea la membresía", async () => {
  const response = await call("POST", "/staff/invite", "liderAdmin", {
    body: { email: "nueva@lider.cl", role: "medico" },
  });
  assert.equal(response.status, 200);
  const { staff } = await response.json();
  assert.equal(authAdminCalls.filter((c) => c.method === "inviteUserByEmail").length, 1);
  assert.equal(staff.clinicId, LIDER);
  assert.deepEqual(memberships(staff.id).map((m) => [m.clinic_id, m.role]), [[LIDER, "medico"]]);
});

test("quitar de una clínica no quita la otra", async () => {
  // Líder quita a la persona multi-clínica: sigue en Renca (su principal).
  const fromLider = await call("DELETE", "/staff/u-multi", "liderAdmin");
  assert.equal(fromLider.status, 200);
  assert.deepEqual(memberships("u-multi").map((m) => m.clinic_id), [RENCA]);
  assert.equal(db.staff_profiles.find((row) => row.id === "u-multi").clinic_id, RENCA);
  assert.deepEqual(await patientNames("multi", LIDER), ["Paciente Renca"]);
});

test("quitar la clínica principal pasa la principal a otra membresía", async () => {
  const response = await call("DELETE", "/staff/u-multi", "rencaAdmin");
  assert.equal(response.status, 200);
  const profile = db.staff_profiles.find((row) => row.id === "u-multi");
  assert.ok(profile, "el perfil no se borra");
  assert.equal(profile.clinic_id, LIDER);
  assert.equal(profile.role, "medico");
  assert.deepEqual(memberships("u-multi").map((m) => m.clinic_id), [LIDER]);

  // Ya no entra a Renca, ni pidiéndolo por header.
  assert.deepEqual(await patientNames("multi"), ["Paciente Líder"]);
  assert.deepEqual(await patientNames("multi", RENCA), ["Paciente Líder"]);
  assert.equal((await staffOf("rencaAdmin"))["u-multi"], undefined);
});

test("quitar a alguien con una sola clínica lo quita de Imagenda, como antes", async () => {
  const response = await call("DELETE", "/staff/u-renca-tec", "rencaAdmin");
  assert.equal(response.status, 200);
  assert.equal(db.staff_profiles.find((row) => row.id === "u-renca-tec"), undefined);
});

test("cambiar el rol cambia solo la membresía de la clínica del administrador", async () => {
  const response = await call("PATCH", "/staff/u-multi/role", "liderAdmin", { body: { role: "tecnico" } });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).staff.role, "tecnico");
  assert.equal(memberships("u-multi").find((m) => m.clinic_id === LIDER).role, "tecnico");
  assert.equal(memberships("u-multi").find((m) => m.clinic_id === RENCA).role, "administrador");
  assert.equal(db.staff_profiles.find((row) => row.id === "u-multi").role, "administrador");

  // En su clínica principal cambia también el rol principal.
  const principal = await call("PATCH", "/staff/u-renca-tec/role", "rencaAdmin", { body: { role: "medico" } });
  assert.equal(principal.status, 200);
  assert.equal(db.staff_profiles.find((row) => row.id === "u-renca-tec").role, "medico");
  assert.deepEqual(memberships("u-renca-tec").map((m) => [m.clinic_id, m.role]), [[RENCA, "medico"]]);
});

test("admin de una clínica no ve personal ni datos de la otra", async () => {
  const renca = await staffOf("rencaAdmin");
  assert.deepEqual(Object.keys(renca).sort(), ["u-multi", "u-renca-admin", "u-renca-tec"]);
  assert.equal(renca["u-multi"].role, "administrador");

  const lider = await staffOf("liderAdmin");
  assert.deepEqual(Object.keys(lider).sort(), ["u-lider-admin", "u-lider-tec", "u-multi"]);
  // Rol y clínica de ESTA clínica, no la principal (Renca) de la persona.
  assert.equal(lider["u-multi"].role, "medico");
  assert.equal(lider["u-multi"].clinicId, LIDER);

  // Personal de Líder: invisible e intocable para el admin de Renca, con o sin header.
  for (const clinic of [undefined, LIDER]) {
    assert.equal(
      (await call("PATCH", "/staff/u-lider-tec/role", "rencaAdmin", { clinic, body: { role: "medico" } })).status,
      404,
    );
    assert.equal((await call("DELETE", "/staff/u-lider-admin", "rencaAdmin", { clinic })).status, 404);
    assert.equal(
      (await call("PATCH", "/staff/u-lider-tec/signature", "rencaAdmin", { clinic, body: { rut: "1-9" } })).status,
      404,
    );
  }
  assert.equal(db.staff_profiles.find((row) => row.id === "u-lider-tec").role, "tecnico");
  assert.ok(db.staff_profiles.find((row) => row.id === "u-lider-admin"));

  // Tampoco puede invitar a Líder ni ver sus pacientes.
  const invite = await call("POST", "/staff/invite", "rencaAdmin", {
    body: { email: "otra@correo.cl", role: "medico", clinicId: LIDER },
  });
  assert.equal(invite.status, 403);
  assert.deepEqual(await patientNames("rencaAdmin", LIDER), ["Paciente Renca"]);
});
