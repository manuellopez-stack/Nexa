// Reemplazo en memoria de @supabase/supabase-js, SOLO para tests (lo carga
// test/support/mock-loader.mjs). Implementa la parte del query builder que
// usa server.mjs: select con embebidos (alias:tabla!inner(cols)), filtros
// eq/neq/in/not/is/gte/gt/lt/lte (también sobre columnas embebidas, como
// "patient.clinic_id"), order, limit, count/head, single/maybeSingle,
// insert/update/delete. No toca ninguna base real.

import { randomUUID } from "node:crypto";

/** Tablas en memoria: { nombreTabla: [filas] }. Tablas ausentes = vacías. */
export const db = {};
/** Tokens de sesión simulados: { token: { id, email } }. */
export const users = {};

export function resetDb(seed = {}) {
  for (const key of Object.keys(db)) delete db[key];
  for (const key of Object.keys(users)) delete users[key];
  for (const [table, rows] of Object.entries(seed)) {
    db[table] = rows.map((row) => ({ ...row }));
  }
}

const table = (name) => (db[name] ??= []);

// Clave foránea de cada tabla embebida "muchos a uno".
const FOREIGN_KEYS = {
  patients: "patient_id",
  clinics: "clinic_id",
  rooms: "room_id",
  lab_panels: "panel_id",
  lab_parameters: "parameter_id",
  imaging_types: "imaging_type_id",
  dental_procedures: "procedure_id",
};

function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let current = "";
  for (const char of text) {
    if (char === "(") depth++;
    if (char === ")") depth--;
    if (char === "," && depth === 0) {
      parts.push(current.trim());
      current = "";
    } else {
      current += char;
    }
  }
  if (current.trim()) parts.push(current.trim());
  return parts;
}

function parseSelect(selectText) {
  return splitTopLevel(selectText || "*").map((token) => {
    const embed = token.match(/^(?:(\w+):)?(\w+)(!inner)?\((.*)\)$/s);
    if (embed) {
      const [, alias, name, inner, sub] = embed;
      return { kind: "embed", key: alias ?? name, table: name, inner: Boolean(inner), sub };
    }
    return { kind: "column", name: token };
  });
}

function resolveEmbed(row, spec) {
  const fk = FOREIGN_KEYS[spec.table];
  if (!fk || !(fk in row)) {
    throw new Error(`supabase-mock: no sé embeber ${spec.table} desde ${JSON.stringify(Object.keys(row))}`);
  }
  const target = table(spec.table).find((candidate) => candidate.id === row[fk]);
  return target ? project(target, parseSelect(spec.sub)) : null;
}

function withEmbeds(row, fields) {
  const full = { ...row };
  for (const field of fields) {
    if (field.kind === "embed") full[field.key] = resolveEmbed(row, field);
  }
  return full;
}

function project(full, fields) {
  const out = {};
  for (const field of fields) {
    if (field.kind === "embed") {
      out[field.key] = field.key in full ? full[field.key] : resolveEmbed(full, field);
    } else if (field.name === "*") {
      for (const [key, value] of Object.entries(full)) {
        if (!fields.some((f) => f.kind === "embed" && f.key === key)) out[key] = value;
      }
    } else {
      out[field.name] = full[field.name] ?? null;
    }
  }
  return out;
}

function valueAt(row, path) {
  return path.split(".").reduce((value, key) => (value == null ? undefined : value[key]), row);
}

function compare(a, b) {
  if (a == null || b == null) return NaN;
  return a < b ? -1 : a > b ? 1 : 0;
}

class QueryBuilder {
  constructor(tableName) {
    this.tableName = tableName;
    this.op = "select";
    this.selectText = "*";
    this.returning = null;
    this.countMode = null;
    this.head = false;
    this.filters = [];
    this.orders = [];
    this.limitCount = null;
    this.singleMode = null;
    this.payload = null;
  }

  select(columns = "*", options = {}) {
    if (this.op === "select") {
      this.selectText = columns;
      this.countMode = options.count ?? null;
      this.head = options.head === true;
    } else {
      this.returning = columns;
    }
    return this;
  }

  insert(payload) {
    this.op = "insert";
    this.payload = Array.isArray(payload) ? payload : [payload];
    return this;
  }

  update(payload) {
    this.op = "update";
    this.payload = payload;
    return this;
  }

  delete() {
    this.op = "delete";
    return this;
  }

  eq(column, value) {
    this.filters.push((row) => valueAt(row, column) === value);
    return this;
  }

  neq(column, value) {
    this.filters.push((row) => valueAt(row, column) !== value);
    return this;
  }

  in(column, values) {
    this.filters.push((row) => values.includes(valueAt(row, column)));
    return this;
  }

  is(column, value) {
    this.filters.push((row) => (valueAt(row, column) ?? null) === value);
    return this;
  }

  not(column, operator, value) {
    if (operator === "is") {
      this.filters.push((row) => (valueAt(row, column) ?? null) !== value);
    } else if (operator === "in") {
      const list = String(value).replace(/^\(|\)$/g, "").split(",").map((v) => v.trim());
      this.filters.push((row) => !list.includes(String(valueAt(row, column))));
    } else {
      throw new Error(`supabase-mock: not(${operator}) no implementado`);
    }
    return this;
  }

  gte(column, value) {
    this.filters.push((row) => compare(valueAt(row, column), value) >= 0);
    return this;
  }

  gt(column, value) {
    this.filters.push((row) => compare(valueAt(row, column), value) > 0);
    return this;
  }

  lt(column, value) {
    this.filters.push((row) => compare(valueAt(row, column), value) < 0);
    return this;
  }

  lte(column, value) {
    this.filters.push((row) => compare(valueAt(row, column), value) <= 0);
    return this;
  }

  order(column, { ascending = true } = {}) {
    this.orders.push({ column, ascending });
    return this;
  }

  limit(count) {
    this.limitCount = count;
    return this;
  }

  single() {
    this.singleMode = "single";
    return this;
  }

  maybeSingle() {
    this.singleMode = "maybe";
    return this;
  }

  then(resolve, reject) {
    try {
      resolve(this.execute());
    } catch (error) {
      reject(error);
    }
  }

  matches(fields) {
    return table(this.tableName)
      .map((row) => ({ row, full: withEmbeds(row, fields) }))
      .filter(({ full }) => {
        for (const field of fields) {
          if (field.kind === "embed" && field.inner && full[field.key] == null) return false;
        }
        return this.filters.every((filter) => filter(full));
      });
  }

  finish(rows) {
    let result = rows;
    for (const { column, ascending } of [...this.orders].reverse()) {
      result = [...result].sort((a, b) => {
        const order = compare(a[column], b[column]);
        return (Number.isNaN(order) ? 0 : order) * (ascending ? 1 : -1);
      });
    }
    if (this.limitCount != null) result = result.slice(0, this.limitCount);

    if (this.singleMode === "single" && result.length !== 1) {
      return { data: null, error: { code: "PGRST116", message: `se esperaba 1 fila, hay ${result.length}` } };
    }
    if (this.singleMode === "maybe" && result.length > 1) {
      return { data: null, error: { code: "PGRST116", message: `más de 1 fila (${result.length})` } };
    }
    const data = this.singleMode ? result[0] ?? null : result;
    return { data, error: null };
  }

  execute() {
    if (this.op === "select") {
      const fields = parseSelect(this.selectText);
      const rows = this.matches(fields).map(({ full }) => project(full, fields));
      if (this.head) return { data: null, count: rows.length, error: null };
      const result = this.finish(rows);
      if (this.countMode) result.count = rows.length;
      return result;
    }

    if (this.op === "insert") {
      const inserted = this.payload.map((row) => {
        const newRow = { ...row };
        if (newRow.id === undefined) {
          newRow.id = this.tableName === "patients" ? table("patients").length + 1000 : randomUUID();
        }
        newRow.created_at ??= new Date().toISOString();
        table(this.tableName).push(newRow);
        return newRow;
      });
      if (this.returning == null) return { data: null, error: null };
      const fields = parseSelect(this.returning);
      return this.finish(inserted.map((row) => project(withEmbeds(row, fields), fields)));
    }

    const fields = parseSelect("*");
    const targets = this.matches(fields).map(({ row }) => row);

    if (this.op === "update") {
      for (const row of targets) Object.assign(row, this.payload);
    } else {
      db[this.tableName] = table(this.tableName).filter((row) => !targets.includes(row));
    }
    if (this.returning == null) return { data: null, error: null };
    const returning = parseSelect(this.returning);
    return this.finish(targets.map((row) => project(withEmbeds(row, returning), returning)));
  }
}

export function createClient() {
  return {
    from: (tableName) => new QueryBuilder(tableName),
    rpc: async (name) => ({ data: null, error: { message: `supabase-mock: rpc ${name} no disponible` } }),
    auth: {
      getUser: async (token) =>
        users[token]
          ? { data: { user: users[token] }, error: null }
          : { data: { user: null }, error: { message: "token inválido" } },
    },
    storage: {
      from: () => ({
        download: async () => ({ data: null, error: { message: "supabase-mock: sin storage" } }),
        upload: async () => ({ data: null, error: { message: "supabase-mock: sin storage" } }),
        remove: async () => ({ data: null, error: null }),
      }),
    },
  };
}
