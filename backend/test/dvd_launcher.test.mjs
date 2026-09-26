// Lanzador del DVD: sin Windows a mano, se simula el camino completo de la
// línea del start hasta la propiedad weasis.portable.dir que lee Weasis:
//   1. cmd.exe: qué partes de la línea le quedan sin comillas (ahí & o ^ en la
//      ruta cortarían el comando) y la expansión de %~dp0 y !DISCO!;
//   2. la línea de comandos de Windows partida en argv (reglas de
//      CommandLineToArgvW / CRT de Microsoft);
//   3. el parser de Weasis 4.7.3 (ConfigData.splitArgToCmd,
//      extractWeasisConfigArguments, Utils.splitSpaceExceptInQuotes,
//      removeEnglobingQuotes y addProperties), portado tal cual.
// `node test/dvd_launcher.test.mjs --mostrar` imprime el .cmd y el autorun.inf.
import test from "node:test";
import assert from "node:assert/strict";
import { buildAutorunInf, buildLauncherCmd, LAUNCHER_NAME } from "../dvdExport.mjs";

// --- 1. cmd.exe ---------------------------------------------------------------

// Tramos que cmd.exe ve fuera de comillas (alterna el estado en cada ").
function unquotedSegments(line) {
  const parts = line.split('"');
  return parts.filter((_, i) => i % 2 === 0);
}

// Ejecuta el .cmd "a mano" para una carpeta del lanzador y devuelve la línea
// del start ya expandida. Solo cubre lo que usa el lanzador.
function expandStartLine(cmd, launcherDir) {
  const dp0 = launcherDir.endsWith("\\") ? launcherDir : `${launcherDir}\\`;
  const vars = {};
  let delayed = false;
  for (const line of cmd.split("\r\n")) {
    // Fase 1 (%): lo expandido NO vuelve a pasar por esta fase.
    const phase1 = line.replaceAll("%~dp0", dp0);
    const set = /^set "(\w+)=(.*)"$/.exec(phase1);
    if (set) vars[set[1]] = set[2];
    if (/^setlocal EnableDelayedExpansion$/i.test(line)) delayed = true;
    if (line.startsWith("start ")) {
      assert.ok(delayed, "la línea del start necesita la expansión diferida activa");
      assert.ok(!line.includes("%"), "el start no debe usar %: pasaría por la expansión diferida");
      // Fase de !: ocurre después de interpretar & ^ | < > ( ), y su resultado
      // no se vuelve a interpretar.
      return phase1.replace(/!(\w+)!/g, (_, name) => vars[name]);
    }
  }
  throw new Error("el lanzador no tiene línea start");
}

// start "" "<programa>" <parámetros>: start pasa los parámetros tal cual.
function startToCommandLine(startLine) {
  const match = /^start "" ("[^"]*") (.*)$/.exec(startLine);
  assert.ok(match, `línea start inesperada: ${startLine}`);
  return { program: match[1].slice(1, -1), params: match[2] };
}

// --- 2. argv de Windows (reglas del CRT de Microsoft) ------------------------

function windowsArgv(commandLine) {
  const args = [];
  let current = "";
  let inQuotes = false;
  let hasArg = false;
  for (let i = 0; i < commandLine.length; ) {
    const c = commandLine[i];
    if (c === "\\") {
      let n = 0;
      while (commandLine[i] === "\\") {
        n += 1;
        i += 1;
      }
      if (commandLine[i] === '"') {
        current += "\\".repeat(Math.floor(n / 2));
        if (n % 2 === 1) {
          current += '"';
          i += 1;
        }
      } else {
        current += "\\".repeat(n);
      }
      hasArg = true;
      continue;
    }
    if (c === '"') {
      inQuotes = !inQuotes;
      hasArg = true;
      i += 1;
      continue;
    }
    if ((c === " " || c === "\t") && !inQuotes) {
      if (hasArg) args.push(current);
      current = "";
      hasArg = false;
      i += 1;
      continue;
    }
    current += c;
    hasArg = true;
    i += 1;
  }
  if (hasArg) args.push(current);
  return args;
}

// --- 3. Weasis 4.7.3 ---------------------------------------------------------

function splitArgToCmd(args) {
  const commands = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("$") && args[i].length > 1) {
      let command = args[i].substring(1);
      while (i + 1 < args.length && !args[i + 1].startsWith("$")) {
        i++;
        command += ` ${args[i]}`;
      }
      commands.push(command);
    }
  }
  return commands;
}

function splitSpaceExceptInQuotes(s) {
  const result = [];
  const pattern = /'[^']*'|"[^"]*"|( )/g;
  let last = 0;
  let buffer = "";
  for (const m of s.matchAll(pattern)) {
    if (m[1] === undefined) continue; // tramo entre comillas: sigue en el buffer
    buffer += s.slice(last, m.index);
    last = m.index + 1;
    if (buffer.trim()) result.push(buffer.trim());
    buffer = "";
  }
  buffer += s.slice(last);
  if (buffer.trim()) result.push(buffer.trim());
  return result;
}

function weasisProperties(args) {
  assert.ok(
    !args.some((a) => /^weasis(-.*)?:\/\//.test(a)),
    "sin URI weasis://, para que la ruta no pase por URLDecoder",
  );
  const commands = splitArgToCmd(args);
  const properties = {};
  const configCmd = commands.find((c) => c.startsWith("weasis:config"));
  for (const param of splitSpaceExceptInQuotes(configCmd.substring("weasis:config".length + 1))) {
    const [name, value] = param.split(/=(.*)/s);
    if (name !== "pro") continue;
    const unquoted = value.replace(/^"|"$/g, "");
    const [key, propValue] = unquoted.split(/\s+(.*)/s);
    properties[key] = propValue;
  }
  return { commands, properties };
}

// -----------------------------------------------------------------------------

const TRICKY_DIRS = [
  "D:\\",
  "C:\\Users\\x\\OneDrive\\Documentos\\Mi carpeta\\DVD_Perez_2026-09-24_IMD1",
  "C:\\Users\\José Núñez\\Música y Imágenes\\DVD_Diaz_2026-09-24_IMD1",
  "C:\\Tom & Jerry (copia)\\100% listo+1\\$raro!\\O'Brien's\\a^b\\DVD",
];

test("el .cmd abre Weasis en modo portable con la ruta absoluta de su carpeta", () => {
  const cmd = buildLauncherCmd();
  const startLine = cmd.split("\r\n").find((l) => l.startsWith("start "));

  // Lo que cmd ve sin comillas no puede traer la ruta ya expandida.
  for (const segment of unquotedSegments(startLine)) {
    assert.ok(!segment.includes("%"), `tramo sin comillas con %: ${segment}`);
  }

  for (const dir of TRICKY_DIRS) {
    const { program, params } = startToCommandLine(expandStartLine(cmd, dir));
    const root = `${dir.replace(/\\$/, "")}\\.`;
    assert.equal(program, `${root}\\viewer\\Weasis.exe`);

    const { commands, properties } = weasisProperties(windowsArgv(params));
    assert.ok(commands.includes("dicom:get -p"), commands.join(" | "));
    assert.equal(properties["weasis.portable.dir"], root, `carpeta: ${dir}`);
  }
});

test("el autorun.inf ejecuta el lanzador", () => {
  const autorun = buildAutorunInf();
  assert.equal(LAUNCHER_NAME, "Abrir_imagenes.cmd");
  assert.ok(!LAUNCHER_NAME.includes(" "), "el autorun no puede citar un nombre con espacio");
  assert.match(autorun, /^\[autorun\]\r\nshellexecute=Abrir_imagenes\.cmd\r\n/);
  assert.ok(!/^open=/m.test(autorun));
});

if (process.argv.includes("--mostrar")) {
  console.log(`===== ${LAUNCHER_NAME} =====`);
  process.stdout.write(buildLauncherCmd().replaceAll("\r\n", "⏎\n"));
  console.log("===== autorun.inf =====");
  process.stdout.write(buildAutorunInf().replaceAll("\r\n", "⏎\n"));
}
