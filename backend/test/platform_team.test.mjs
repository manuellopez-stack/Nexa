// Equipo Imagenda: tipos de acceso (Administrador total / Soporte), cuentas
// desactivadas y rutas /platform-team, contra la base en memoria de
// test/support/supabase-mock.mjs. No toca Supabase.
//
// Usa el puerto 3000 como el resto: npm test corre los archivos de a uno.

import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";

import { authAdminCalls, authAdminHooks, db, resetDb, users } from "./support/supabase-mock.mjs";

const BASE = "http://localhost:3000";
const CLINIC = "11111111-1111-1111-1111-111111111111";
const OTHER_CLINIC = "22222222-2222-2222-2222-222222222222";
const TOKENS = {
  admin: "tok-admin",
  soporte: "tok-soporte",
  legado: "tok-legado",
  clinica: "tok-clinica",
  desactivado: "tok-desactivado",
  soloImagenda: "tok-solo-imagenda",
};

function seed() {
  resetDb({
    clinics: [
      { id: CLINIC, name: "Clínica Test", status: "activa" },
      { id: OTHER_CLINIC, name: "Otra clínica", status: "activa" },
    ],
    staff_profiles: [
      {
        id: "u-admin",
        email: "admin@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: true,
        platform_role: "admin",
      },
      {
        id: "u-soporte",
        email: "soporte@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: true,
        platform_role: "soporte",
      },
      // Admin de plataforma anterior a la migración (sin platform_role).
      {
        id: "u-legado",
        email: "legado@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: true,
      },
      // Miembro del equipo "Solo Imagenda": sin clínica base.
      {
        id: "u-solo",
        email: "solo@imagenda.cl",
        role: "administrador",
        clinic_id: null,
        is_platform_admin: true,
        platform_role: "soporte",
      },
      { id: "u-clinica", email: "jefe@clinica.cl", role: "administrador", clinic_id: OTHER_CLINIC },
      {
        id: "u-desactivado",
        email: "ex@imagenda.cl",
        role: "administrador",
        clinic_id: CLINIC,
        is_platform_admin: false,
        platform_role: "soporte",
        disabled_at: "2026-09-01T00:00:00.000Z",
      },
    ],
  });
  users[TOKENS.admin] = { id: "u-admin", email: "admin@imagenda.cl" };
  users[TOKENS.soporte] = { id: "u-soporte", email: "soporte@imagenda.cl" };
  users[TOKENS.legado] = { id: "u-legado", email: "legado@imagenda.cl" };
  users[TOKENS.clinica] = { id: "u-clinica", email: "jefe@clinica.cl" };
  users[TOKENS.desactivado] = { id: "u-desactivado", email: "ex@imagenda.cl" };
  users[TOKENS.soloImagenda] = { id: "u-solo", email: "solo@imagenda.cl" };
}

function call(method, url, as, body) {
  return fetch(`${BASE}${url}`, {
    method,
    headers: {
      ...(as ? { Authorization: `Bearer ${TOKENS[as]}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

const profile = (id) => db.staff_profiles.find((row) => row.id === id);

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

test("cuenta desactivada: 403 en cualquier ruta aunque tenga sesión", async () => {
  const response = await call("GET", "/staff", "desactivado");
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error, "Tu acceso a Imagenda fue desactivado.");
  assert.equal((await call("GET", "/platform-team", "desactivado")).status, 403);
});

test("GET /platform-team: solo el equipo; Soporte puede ver, incluye a los desactivados", async () => {
  assert.equal((await call("GET", "/platform-team", "clinica")).status, 403);

  const response = await call("GET", "/platform-team", "soporte");
  assert.equal(response.status, 200);
  const { team } = await response.json();
  const byId = Object.fromEntries(team.map((member) => [member.id, member]));
  assert.deepEqual(Object.keys(byId).sort(), ["u-admin", "u-desactivado", "u-legado", "u-solo", "u-soporte"]);
  assert.equal(byId["u-solo"].clinicId, null);
  assert.equal(byId["u-solo"].clinicName, null);
  assert.equal(byId["u-legado"].platformRole, "admin");
  assert.equal(byId["u-soporte"].platformRole, "soporte");
  assert.equal(byId["u-admin"].clinicName, "Clínica Test");
  assert.equal(byId["u-admin"].active, true);
  assert.equal(byId["u-desactivado"].active, false);
  assert.equal(byId["u-desactivado"].platformRole, "soporte");
});

test("Soporte no puede crear clínicas ni editar su logo", async () => {
  const create = await call("POST", "/clinics", "soporte", { name: "Nueva" });
  assert.equal(create.status, 403);
  assert.match((await create.json()).error, /Soporte/);
  assert.equal(db.clinics.length, 2);

  const logo = await call("DELETE", `/clinics/${CLINIC}/logo`, "soporte");
  assert.equal(logo.status, 403);
});

test("Soporte no puede invitar, cambiar, quitar ni reactivar acceso del equipo", async () => {
  const invite = await call("POST", "/platform-team/invite", "soporte", {
    email: "nuevo@imagenda.cl",
    platformRole: "soporte",
    clinicId: CLINIC,
  });
  assert.equal(invite.status, 403);
  assert.equal((await call("PATCH", "/platform-team/u-legado", "soporte", { platformRole: "soporte" })).status, 403);
  assert.equal((await call("POST", "/platform-team/u-admin/revoke", "soporte")).status, 403);
  assert.equal(
    (await call("POST", "/platform-team/u-desactivado/restore", "soporte", { platformRole: "soporte" })).status,
    403,
  );
  assert.equal(authAdminCalls.length, 0);
  assert.equal(profile("u-admin").is_platform_admin, true);
  assert.equal(profile("u-legado").platform_role, undefined);
});

test("Soporte no puede gestionar a un miembro del equipo desde /staff", async () => {
  assert.equal((await call("PATCH", "/staff/u-admin/role", "soporte", { role: "medico" })).status, 404);
  assert.equal((await call("DELETE", "/staff/u-admin", "soporte")).status, 404);
  assert.equal(profile("u-admin").role, "administrador");
});

test("/staff no permite tocar is_platform_admin ni platform_role", async () => {
  const invite = await call("POST", "/staff/invite", "admin", {
    email: "tec@clinica.cl",
    role: "tecnico",
    clinicId: CLINIC,
    isPlatformAdmin: true,
    is_platform_admin: true,
    platformRole: "admin",
    platform_role: "admin",
  });
  assert.equal(invite.status, 200);
  const { staff } = await invite.json();
  assert.equal(profile(staff.id).is_platform_admin, undefined);
  assert.equal(profile(staff.id).platform_role, undefined);

  const patch = await call("PATCH", "/staff/u-clinica/role", "admin", {
    role: "medico",
    is_platform_admin: true,
    platform_role: "admin",
  });
  assert.equal(patch.status, 200);
  assert.equal(profile("u-clinica").is_platform_admin, undefined);
  assert.equal(profile("u-clinica").platform_role, undefined);
});

test("nadie puede cambiarse ni quitarse el acceso a sí mismo", async () => {
  const patch = await call("PATCH", "/platform-team/u-admin", "admin", { platformRole: "soporte" });
  assert.equal(patch.status, 400);
  const revoke = await call("POST", "/platform-team/u-admin/revoke", "admin");
  assert.equal(revoke.status, 400);
  assert.equal(profile("u-admin").is_platform_admin, true);
  assert.equal(profile("u-admin").platform_role, "admin");
  assert.equal(authAdminCalls.length, 0);
});

test("nunca queda el equipo sin un Administrador total activo", async () => {
  // Dos Administradores totales (u-admin y u-legado) se quitan el acceso
  // mutuamente al mismo tiempo. El primer revoke se detiene justo al bloquear
  // el login en Auth (ya pasó el conteo); el segundo llega con su sesión aún
  // válida y debe esperar su turno, ver que queda un solo admin y fallar.
  let release;
  const paused = new Promise((resolve) => (release = resolve));
  authAdminHooks.beforeUpdateUser = () => paused;

  const first = call("POST", "/platform-team/u-legado/revoke", "admin");
  await new Promise((resolve) => setTimeout(resolve, 100));
  const second = call("POST", "/platform-team/u-admin/revoke", "legado");
  await new Promise((resolve) => setTimeout(resolve, 100));
  delete authAdminHooks.beforeUpdateUser;
  release();

  assert.equal((await first).status, 200);
  const blocked = await second;
  assert.equal(blocked.status, 400);
  assert.match((await blocked.json()).error, /al menos un Administrador total activo/);
  assert.equal(profile("u-admin").is_platform_admin, true);
  assert.equal(profile("u-admin").disabled_at, undefined);
});

test("bajar a Soporte al último Administrador total se rechaza", async () => {
  // Misma carrera con el cambio de tipo de acceso: u-admin baja a u-legado a
  // Soporte mientras u-legado intenta bajar a u-admin.
  seed();
  let release;
  const paused = new Promise((resolve) => (release = resolve));
  // PATCH no llama a Auth: se pausa con una revocación de u-soporte en cola
  // delante, para que ambos PATCH lleguen mientras la cola está ocupada.
  authAdminHooks.beforeUpdateUser = () => paused;
  const blocker = call("POST", "/platform-team/u-soporte/revoke", "admin");
  await new Promise((resolve) => setTimeout(resolve, 100));
  const first = call("PATCH", "/platform-team/u-legado", "admin", { platformRole: "soporte" });
  await new Promise((resolve) => setTimeout(resolve, 50));
  const second = call("PATCH", "/platform-team/u-admin", "legado", { platformRole: "soporte" });
  await new Promise((resolve) => setTimeout(resolve, 100));
  release();

  assert.equal((await blocker).status, 200);
  assert.equal((await first).status, 200);
  const blocked = await second;
  assert.equal(blocked.status, 400);
  assert.match((await blocked.json()).error, /al menos un Administrador total activo/);
  assert.equal(profile("u-admin").platform_role, "admin");
});

test("admin total puede invitar, cambiar tipo, quitar y reactivar acceso", async () => {
  const invite = await call("POST", "/platform-team/invite", "admin", {
    email: "nueva@imagenda.cl",
    fullName: "Nueva Persona",
    platformRole: "soporte",
    clinicId: OTHER_CLINIC,
  });
  assert.equal(invite.status, 200);
  const { member } = await invite.json();
  assert.equal(member.platformRole, "soporte");
  assert.equal(member.clinicName, "Otra clínica");
  assert.equal(member.active, true);
  const created = profile(member.id);
  assert.equal(created.role, "administrador");
  assert.equal(created.is_platform_admin, true);
  assert.equal(created.platform_role, "soporte");
  assert.equal(created.clinic_id, OTHER_CLINIC);
  assert.deepEqual(authAdminCalls[0], { method: "inviteUserByEmail", args: ["nueva@imagenda.cl"] });

  const patch = await call("PATCH", `/platform-team/${member.id}`, "admin", { platformRole: "admin" });
  assert.equal(patch.status, 200);
  assert.equal(profile(member.id).platform_role, "admin");

  const revoke = await call("POST", `/platform-team/${member.id}/revoke`, "admin");
  assert.equal(revoke.status, 200);
  assert.equal(profile(member.id).is_platform_admin, false);
  assert.ok(profile(member.id).disabled_at);
  assert.equal(profile(member.id).platform_role, "admin");
  assert.deepEqual(authAdminCalls.at(-1), {
    method: "updateUserById",
    args: [member.id, { ban_duration: "876000h" }],
  });

  const restore = await call("POST", `/platform-team/${member.id}/restore`, "admin", { platformRole: "soporte" });
  assert.equal(restore.status, 200);
  assert.equal(profile(member.id).is_platform_admin, true);
  assert.equal(profile(member.id).disabled_at, null);
  assert.equal(profile(member.id).platform_role, "soporte");
  assert.deepEqual(authAdminCalls.at(-1), { method: "updateUserById", args: [member.id, { ban_duration: "none" }] });

  const create = await call("POST", "/clinics", "admin", { name: "Clínica Nueva" });
  assert.equal(create.status, 200);
});

test("invitar al equipo exige tipo de acceso y, si viene, una clínica base que exista", async () => {
  const clinicaFalsa = await call("POST", "/platform-team/invite", "admin", {
    email: "x@imagenda.cl",
    platformRole: "admin",
    clinicId: "33333333-3333-3333-3333-333333333333",
  });
  assert.equal(clinicaFalsa.status, 400);
  const tipoMalo = await call("POST", "/platform-team/invite", "admin", {
    email: "x@imagenda.cl",
    platformRole: "dueño",
    clinicId: CLINIC,
  });
  assert.equal(tipoMalo.status, 400);
  assert.equal(authAdminCalls.length, 0);
});

test("invitar sin clínica base crea un miembro \"Solo Imagenda\" (clinic_id null)", async () => {
  for (const clinicId of [undefined, null, ""]) {
    const email = `solo-${String(clinicId)}@imagenda.cl`;
    const response = await call("POST", "/platform-team/invite", "admin", {
      email,
      fullName: "Sin Clínica",
      platformRole: "soporte",
      ...(clinicId === undefined ? {} : { clinicId }),
    });
    assert.equal(response.status, 200, `clinicId=${JSON.stringify(clinicId)}`);
    const { member } = await response.json();
    assert.equal(member.clinicId, null);
    assert.equal(member.clinicName, null);
    assert.equal(profile(member.id).clinic_id, null);
    assert.equal(profile(member.id).is_platform_admin, true);
  }
});

test("cuenta del equipo sin clínica: 403 en datos clínicos, 200 en plataforma", async () => {
  const clinicalRoutes = [
    ["GET", "/patients"],
    ["GET", "/patients/1"],
    ["GET", "/appointments"],
    ["GET", "/rooms"],
    ["GET", "/dashboard/summary"],
    ["GET", "/validation-queue"],
    ["GET", "/lab/panels"],
    ["GET", "/imaging/types"],
    ["GET", "/dental/procedures"],
    ["GET", "/orthanc-studies"],
    ["GET", "/billing/daily-summary"],
  ];
  for (const [method, url] of clinicalRoutes) {
    const response = await call(method, url, "soloImagenda");
    assert.equal(response.status, 403, `${method} ${url}`);
    assert.match((await response.json()).error, /no tiene una clínica asignada/, `${method} ${url}`);
  }

  for (const url of ["/clinics", "/platform-team", "/staff"]) {
    assert.equal((await call("GET", url, "soloImagenda")).status, 200, url);
  }

  // Puede invitar personal a cualquier clínica (/staff no distingue tipo de acceso).
  const invite = await call("POST", "/staff/invite", "soloImagenda", {
    email: "tecnico@otra.cl",
    role: "tecnico",
    clinicId: OTHER_CLINIC,
  });
  assert.equal(invite.status, 200);
  const { staff } = await invite.json();
  assert.equal(profile(staff.id).clinic_id, OTHER_CLINIC);
});

test("cambiar la clínica base: solo Administrador total; null = Solo Imagenda", async () => {
  const soporte = await call("PATCH", "/platform-team/u-legado/clinic", "soporte", { clinicId: null });
  assert.equal(soporte.status, 403);
  assert.equal(profile("u-legado").clinic_id, CLINIC);

  const toNone = await call("PATCH", "/platform-team/u-legado/clinic", "admin", { clinicId: null });
  assert.equal(toNone.status, 200);
  assert.equal((await toNone.json()).member.clinicId, null);
  assert.equal(profile("u-legado").clinic_id, null);

  const toOther = await call("PATCH", "/platform-team/u-legado/clinic", "admin", { clinicId: OTHER_CLINIC });
  assert.equal(toOther.status, 200);
  assert.equal((await toOther.json()).member.clinicName, "Otra clínica");
  assert.equal(profile("u-legado").clinic_id, OTHER_CLINIC);

  const fake = await call("PATCH", "/platform-team/u-legado/clinic", "admin", {
    clinicId: "33333333-3333-3333-3333-333333333333",
  });
  assert.equal(fake.status, 400);
  assert.equal(profile("u-legado").clinic_id, OTHER_CLINIC);

  // Desactivados: primero hay que reactivarlos.
  const inactive = await call("PATCH", "/platform-team/u-desactivado/clinic", "admin", { clinicId: null });
  assert.equal(inactive.status, 400);
  // Quien no es del equipo no existe para esta ruta.
  const outsider = await call("PATCH", "/platform-team/u-clinica/clinic", "admin", { clinicId: null });
  assert.equal(outsider.status, 404);
  assert.equal(profile("u-clinica").clinic_id, OTHER_CLINIC);
});
