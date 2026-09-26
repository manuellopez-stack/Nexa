// Fase 2B: scripts/migrarStorageAOrthanc.mjs contra un Orthanc simulado
// (servidor HTTP local) y la base/Storage en memoria de
// test/support/supabase-mock.mjs. No toca Orthanc ni Supabase reales.
//
// El DICOM simulado lleva su propio ID de instancia, estudio, serie y número:
// "inst:<id>|study:<id>|series:<id>|num:<n>".

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, beforeEach, test } from "node:test";

import { db, resetDb, storageFiles } from "./support/supabase-mock.mjs";
import { createClient } from "@supabase/supabase-js";
import { deleteStorage, migrate, simulate } from "../scripts/migrarStorageAOrthanc.mjs";

const CLINIC_A = "b69403c3-4e71-40f3-9c38-0d47a4b1d067";
const CLINIC_B = "36534a07-6b68-4e15-88a4-d09ddfbebf64";

const orthanc = { instances: new Map(), labels: [], writes: [], deletes: [], failUploads: new Map() };

const fakeOrthanc = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (c) => chunks.push(c));
  request.on("end", () => {
    const body = Buffer.concat(chunks).toString();
    const json = (value) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(value));
    };
    let match;
    if (request.method !== "GET") orthanc.writes.push(`${request.method} ${request.url}`);

    if (request.method === "DELETE") {
      orthanc.deletes.push(request.url);
      return json({});
    }
    if (request.method === "GET" && request.url === "/system") return json({ Version: "1.13.0" });
    if (request.method === "POST" && request.url === "/instances") {
      const [, id, study, series, num] = body.match(/^inst:([\w-]+)\|study:([\w-]+)\|series:([\w-]+)\|num:(\d+)$/) ?? [];
      if (!id) return response.writeHead(400).end();
      const failures = orthanc.failUploads.get(id) ?? 0;
      if (failures > 0) {
        orthanc.failUploads.set(id, failures - 1);
        return response.writeHead(503).end("ocupado");
      }
      const status = orthanc.instances.has(id) ? "AlreadyStored" : "Success";
      orthanc.instances.set(id, { id, study, series, num });
      return json({ ID: id, ParentStudy: study, Status: status });
    }
    if (request.method === "PUT" && (match = request.url.match(/^\/studies\/([\w-]+)\/labels\/([\w-]+)$/))) {
      orthanc.labels.push([match[1], match[2]]);
      return json({});
    }
    if (request.method === "GET" && (match = request.url.match(/^\/instances\/([\w-]+)$/))) {
      const instance = orthanc.instances.get(match[1]);
      if (!instance) return response.writeHead(404).end();
      return json({ ID: instance.id, ParentSeries: instance.series, MainDicomTags: { InstanceNumber: instance.num } });
    }
    if (request.method === "GET" && (match = request.url.match(/^\/series\/([\w-]+)$/))) {
      return json({ ID: match[1], MainDicomTags: { SeriesNumber: match[1].endsWith("2") ? "2" : "1" } });
    }
    if (request.method === "GET" && (match = request.url.match(/^\/studies\/([\w-]+)$/))) {
      if (![...orthanc.instances.values()].some((i) => i.study === match[1])) return response.writeHead(404).end();
      return json({
        ID: match[1],
        MainDicomTags: { AccessionNumber: match[1] === "st-a" ? "IMD000018" : "IMD000019", StudyDate: "20260901" },
        PatientMainDicomTags: { PatientName: "PRUEBA^MIGRACION", PatientID: "P-1" },
      });
    }
    response.writeHead(404).end();
  });
});

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "migrar-storage-test-"));
const manifestPath = path.join(tmpDir, "manifest.json");
const logs = [];
const log = (line) => logs.push(line);
const supabase = createClient();

function file(id, orderId, { instance = id, study, series, num, png = true } = {}) {
  const dicomPath = `orders/${orderId}/${id}.dcm`;
  const pngPath = png ? `orders/${orderId}/${id}-preview.png` : null;
  storageFiles[`imaging/${dicomPath}`] = Buffer.from(`inst:${instance}|study:${study}|series:${series}|num:${num}`);
  if (pngPath) storageFiles[`imaging/${pngPath}`] = Buffer.from("PNG");
  return { id, order_id: orderId, dicom_path: dicomPath, png_path: pngPath, orthanc_instance_id: id, uploaded_at: "2026-09-01T10:00:00Z" };
}

beforeEach(() => {
  resetDb({
    imaging_orders: [
      { id: "io-a", accession_number: "IMD000018", clinic_id: CLINIC_A, status: "realizado" },
      { id: "io-b", accession_number: "IMD000019", clinic_id: CLINIC_B, status: "realizado" },
    ],
    orthanc_studies: [
      // Fila que dejó el vínculo antiguo (estudio copiado y borrado de Orthanc).
      { orthanc_study_id: "st-a", status: "linked", linked_order_id: "io-a", clinic_id: CLINIC_A },
    ],
    imaging_files: [],
  });
  db.imaging_files = [
    file("i-a1", "io-a", { study: "st-a", series: "se-a1", num: "2" }),
    file("i-a2", "io-a", { study: "st-a", series: "se-a1", num: "1" }),
    file("i-a3", "io-a", { study: "st-a", series: "se-a2", num: "1", png: false }),
    file("i-b1", "io-b", { study: "st-b", series: "se-b1", num: "1" }),
    file("i-b2", "io-b", { study: "st-b", series: "se-b1", num: "2" }),
  ];
  // Un objeto que no pertenece a ninguna fila.
  storageFiles["imaging/huerfanos/suelto.dcm"] = Buffer.from("x");
  orthanc.instances.clear();
  orthanc.labels.length = 0;
  orthanc.writes.length = 0;
  orthanc.deletes.length = 0;
  orthanc.failUploads.clear();
  fs.rmSync(manifestPath, { force: true });
  logs.length = 0;
});

before(async () => {
  await new Promise((resolve) => fakeOrthanc.listen(0, resolve));
  process.env.ORTHANC_URL = `http://127.0.0.1:${fakeOrthanc.address().port}`;
  process.env.ORTHANC_USER = "orthanc";
  process.env.ORTHANC_PASSWORD = "secreto";
});

after(() => {
  fakeOrthanc.close();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

const snapshot = () => JSON.stringify({ db, storage: Object.keys(storageFiles).sort() });
const row = (id) => db.imaging_files.find((r) => r.id === id);
const opts = { supabase, manifestPath, log, retryDelayMs: 0 };

test("simulación: cuenta y lista sin cambiar base, Storage, Orthanc ni escribir manifiesto", async () => {
  const before = snapshot();
  const result = await simulate({ supabase, manifestPath, log });
  assert.deepEqual(result, { pendingRows: 5, orders: 2, bucketObjects: 10 });
  assert.equal(snapshot(), before);
  assert.deepEqual(orthanc.writes, []);
  assert.equal(fs.existsSync(manifestPath), false);
  assert.ok(logs.some((l) => l.includes("IMD000019") && l.includes("2 fila(s)")));
  assert.ok(!logs.join("\n").includes("secreto"));
});

test("--migrate: migra, etiqueta, vincula el estudio y deja dicom_path/png_path en null", async () => {
  const result = await migrate(opts);
  assert.equal(result.migrated, 5);
  assert.deepEqual(result.failures, []);

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  assert.equal(manifest.entries.length, 5);
  assert.deepEqual(manifest.entries.find((e) => e.file_id === "i-a3"), {
    file_id: "i-a3", order: "io-a", dicom_path: "orders/io-a/i-a3.dcm", png_path: null, orthanc_instance_id: "i-a3",
  });

  assert.equal(row("i-a1").dicom_path, null);
  assert.equal(row("i-a1").png_path, null);
  assert.equal(row("i-a1").orthanc_series_id, "se-a1");
  assert.equal(row("i-a1").orthanc_series_number, 1);
  assert.equal(row("i-a1").orthanc_instance_number, 2);
  assert.equal(row("i-a3").orthanc_series_number, 2);

  assert.deepEqual(orthanc.labels.sort(), [["st-a", CLINIC_A], ["st-b", CLINIC_B]]);
  const studyB = db.orthanc_studies.find((s) => s.orthanc_study_id === "st-b");
  assert.equal(studyB.status, "linked");
  assert.equal(studyB.linked_order_id, "io-b");
  assert.equal(studyB.clinic_id, CLINIC_B);
  assert.equal(studyB.accession_number_received, "IMD000019");
  assert.equal(db.orthanc_studies.filter((s) => s.orthanc_study_id === "st-a").length, 1);

  // Storage intacto (se borra recién con --delete-storage) y nada borrado en Orthanc.
  assert.ok(storageFiles["imaging/orders/io-a/i-a1.dcm"]);
  assert.deepEqual(orthanc.deletes, []);
});

test("--migrate: si Orthanc devuelve otro ID, detiene esa orden y la deja sin tocar", async () => {
  // i-b1 en realidad es otra instancia.
  storageFiles["imaging/orders/io-b/i-b1.dcm"] = Buffer.from("inst:otra-cosa|study:st-b|series:se-b1|num:1");
  const result = await migrate({ ...opts, concurrency: 1 });

  assert.deepEqual(result.stoppedOrders, ["io-b"]);
  assert.equal(row("i-b1").dicom_path, "orders/io-b/i-b1.dcm");
  assert.equal(row("i-b2").dicom_path, "orders/io-b/i-b2.dcm", "no sigue con el resto de la orden");
  assert.ok(!orthanc.instances.has("i-b2"), "no sube el resto de la orden");
  assert.ok(!orthanc.labels.some(([study]) => study === "st-b"));
  assert.ok(!db.orthanc_studies.some((s) => s.orthanc_study_id === "st-b"));
  assert.ok(logs.some((l) => l.includes("esperaba la instancia i-b1") && l.includes("otra-cosa")));

  // La otra orden sí se migra.
  for (const id of ["i-a1", "i-a2", "i-a3"]) assert.equal(row(id).dicom_path, null);
});

test("--migrate reanudable: tras un corte sigue donde quedó sin duplicar", async () => {
  // Orthanc rechaza i-a2 más veces que los reintentos: queda pendiente.
  orthanc.failUploads.set("i-a2", 3);
  const first = await migrate(opts);
  assert.equal(first.migrated, 4);
  assert.equal(first.failures.length, 1);
  assert.equal(row("i-a2").dicom_path, "orders/io-a/i-a2.dcm");
  const migratedBefore = JSON.stringify(row("i-a1"));

  const second = await migrate(opts);
  assert.equal(second.migrated, 1);
  assert.equal(second.remaining, 0);
  assert.equal(row("i-a2").dicom_path, null);
  assert.equal(JSON.stringify(row("i-a1")), migratedBefore, "lo ya migrado no se toca");

  assert.equal(db.imaging_files.length, 5);
  assert.equal(db.orthanc_studies.filter((s) => s.orthanc_study_id === "st-a").length, 1);
  assert.equal(db.orthanc_studies.filter((s) => s.orthanc_study_id === "st-b").length, 1);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  assert.equal(manifest.entries.length, 5, "el manifiesto conserva las filas ya migradas sin duplicar");
  assert.equal(new Set(manifest.entries.map((e) => e.file_id)).size, 5);

  const third = await migrate(opts);
  assert.equal(third.migrated, 0);
});

test("--delete-storage: solo borra rutas de filas migradas con la instancia en Orthanc", async () => {
  storageFiles["imaging/orders/io-b/i-b1.dcm"] = Buffer.from("inst:otra-cosa|study:st-b|series:se-b1|num:1");
  await migrate({ ...opts, concurrency: 1 });
  // Migrada, pero su instancia ya no está en Orthanc: no se borra.
  orthanc.instances.delete("i-a3");
  orthanc.writes.length = 0;

  const result = await deleteStorage({ supabase, manifestPath, log });
  assert.equal(result.verified, 2);
  assert.equal(result.skipped.notMigrated, 2);
  assert.equal(result.skipped.missingInOrthanc, 1);
  assert.equal(result.removed, 4);

  for (const gone of ["orders/io-a/i-a1.dcm", "orders/io-a/i-a1-preview.png", "orders/io-a/i-a2.dcm", "orders/io-a/i-a2-preview.png"]) {
    assert.equal(storageFiles[`imaging/${gone}`], undefined, gone);
  }
  for (const kept of ["orders/io-a/i-a3.dcm", "orders/io-b/i-b1.dcm", "orders/io-b/i-b1-preview.png", "orders/io-b/i-b2.dcm", "huerfanos/suelto.dcm"]) {
    assert.ok(storageFiles[`imaging/${kept}`], kept);
  }
  assert.deepEqual(result.outside, ["huerfanos/suelto.dcm"]);
  assert.deepEqual(orthanc.writes, [], "no escribe ni borra nada en Orthanc");
});

test("--delete-storage sin manifiesto falla sin borrar nada", async () => {
  const before = snapshot();
  await assert.rejects(deleteStorage({ supabase, manifestPath, log }), /No existe el manifiesto/);
  assert.equal(snapshot(), before);
});
