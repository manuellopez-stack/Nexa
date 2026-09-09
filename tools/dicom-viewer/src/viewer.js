// Visor DICOM real para Imagenología de Nexa — Cornerstone3D.
// `npm run build` (Vite) lo compila a web/dicom-viewer/, que la app Flutter
// sirve e incrusta en un <iframe> (ver lib/widgets/dicom_viewer_web.dart).
//
// Comunicación con la app Flutter (window.postMessage):
//   recibe  { type: 'nexa:load',  urls: [signedUrl, ...] }
//   recibe  { type: 'nexa:tool',  tool: 'WindowLevel' | 'Zoom' | 'Pan' }
//   recibe  { type: 'nexa:reset' }
//   emite   { type: 'nexa:ready' }
//   emite   { type: 'nexa:loaded', count }
//   emite   { type: 'nexa:error', message }

import {
  RenderingEngine,
  Enums,
  init as coreInit,
} from '@cornerstonejs/core';
import * as csTools from '@cornerstonejs/tools';
import { init as dicomImageLoaderInit } from '@cornerstonejs/dicom-image-loader';

const { ViewportType } = Enums;
const {
  PanTool,
  ZoomTool,
  WindowLevelTool,
  ToolGroupManager,
  Enums: csToolsEnums,
} = csTools;
const { MouseBindings } = csToolsEnums;

const RENDERING_ENGINE_ID = 'nexa-engine';
const VIEWPORT_ID = 'nexa-stack';
const TOOL_GROUP_ID = 'nexa-tools';
const PRIMARY_TOOLS = [WindowLevelTool.toolName, ZoomTool.toolName, PanTool.toolName];

const statusEl = () => document.getElementById('status');
const DEBUG = new URLSearchParams(location.search).has('debug');
function log(msg, cls) {
  const el = statusEl();
  if (!el) return;
  const t = new Date().toISOString().substr(11, 8);
  el.insertAdjacentHTML('beforeend', `\n<span class="${cls || ''}">[${t}] ${msg}</span>`);
  el.scrollTop = el.scrollHeight;
  // Sin ?debug, la barra de estado solo se muestra si hay un error.
  el.hidden = !DEBUG && cls !== 'err';
}
function post(msg) {
  try { window.parent.postMessage(msg, '*'); } catch (_) { /* standalone */ }
}

let viewport = null;
let toolGroup = null;
let cornerstoneReady = false;
let pendingUrls = null;
const embedded = window.parent !== window;

// El listener se registra ya (antes de que termine el init async) para no
// perder un `nexa:load` que llegue temprano desde la app Flutter.
window.addEventListener('message', (ev) => {
  const d = ev.data || {};
  if (d.type === 'nexa:load') {
    if (cornerstoneReady) loadUrls(d.urls);
    else pendingUrls = d.urls;
  } else if (d.type === 'nexa:tool') {
    setPrimaryTool(d.tool);
  } else if (d.type === 'nexa:reset') {
    resetView();
  }
});

function setPrimaryTool(name) {
  if (!toolGroup || !PRIMARY_TOOLS.includes(name)) return;
  for (const toolName of PRIMARY_TOOLS) {
    if (toolName === name) {
      toolGroup.setToolActive(toolName, {
        bindings: [{ mouseButton: MouseBindings.Primary }],
      });
    } else {
      toolGroup.setToolPassive(toolName);
    }
  }
  for (const b of document.querySelectorAll('.bar button[data-tool]')) {
    b.classList.toggle('active', b.dataset.tool === name);
  }
}

function resetView() {
  if (!viewport) return;
  viewport.resetCamera();
  viewport.resetProperties();
  viewport.render();
  log('reset');
}

async function loadUrls(urls) {
  if (!viewport) return;
  const clean = (urls || [])
    .filter((u) => typeof u === 'string' && u.length > 0)
    // Cornerstone resuelve mal las rutas relativas "desnudas"; las absolutizamos
    // contra la página del visor. Las signed URLs de Supabase ya son absolutas.
    .map((u) => new URL(u, document.baseURI).href);
  if (clean.length === 0) { log('sin URLs para cargar', 'err'); return; }
  const imageIds = clean.map((u) => `wadouri:${u}`);
  const t0 = performance.now();
  log(`cargando ${imageIds.length} imagen(es)…`);
  try {
    await viewport.setStack(imageIds, 0);
    resetView();
    setPrimaryTool(WindowLevelTool.toolName);
    log(`listo ✓ (${Math.round(performance.now() - t0)} ms)`, 'ok');
    post({ type: 'nexa:loaded', count: imageIds.length });
  } catch (err) {
    const message = err?.message || String(err);
    log('ERROR al cargar: ' + message + '  (¿URL vencida / CORS?)', 'err');
    post({ type: 'nexa:error', message });
  }
}

async function main() {
  await coreInit();
  dicomImageLoaderInit({ maxWebWorkers: 2 });
  await csTools.init();

  csTools.addTool(WindowLevelTool);
  csTools.addTool(ZoomTool);
  csTools.addTool(PanTool);

  toolGroup = ToolGroupManager.createToolGroup(TOOL_GROUP_ID);
  for (const toolName of PRIMARY_TOOLS) toolGroup.addTool(toolName);

  const element = document.getElementById('viewport');
  element.oncontextmenu = (e) => e.preventDefault();

  const renderingEngine = new RenderingEngine(RENDERING_ENGINE_ID);
  renderingEngine.enableElement({
    viewportId: VIEWPORT_ID,
    type: ViewportType.STACK,
    element,
    defaultOptions: { background: [0, 0, 0] },
  });
  toolGroup.addViewport(VIEWPORT_ID, RENDERING_ENGINE_ID);
  viewport = renderingEngine.getViewport(VIEWPORT_ID);

  setPrimaryTool(WindowLevelTool.toolName);

  // Zoom con la rueda del mouse (Cornerstone no lo trae para viewports de stack).
  element.addEventListener('wheel', (e) => {
    e.preventDefault();
    const factor = e.deltaY < 0 ? 1.12 : 1 / 1.12;
    viewport.setZoom(viewport.getZoom() * factor);
    viewport.render();
  }, { passive: false });

  for (const b of document.querySelectorAll('.bar button[data-tool]')) {
    b.addEventListener('click', () => setPrimaryTool(b.dataset.tool));
  }
  const resetBtn = document.getElementById('reset');
  if (resetBtn) resetBtn.addEventListener('click', resetView);

  window.addEventListener('resize', () => {
    try { renderingEngine.resize(true); } catch (_) { /* noop */ }
  });

  cornerstoneReady = true;
  log('Cornerstone3D iniciado ✓', 'ok');
  post({ type: 'nexa:ready' });

  const params = new URLSearchParams(location.search);
  if (pendingUrls) {
    await loadUrls(pendingUrls);
    pendingUrls = null;
  } else if (params.get('url')) {
    await loadUrls([params.get('url')]);
  } else if (!embedded) {
    // Solo en modo standalone (abrir la página directo) cargamos el DICOM
    // de prueba. Incrustado en Flutter esperamos el `nexa:load`.
    await loadUrls(['./CT_small.dcm']);
  }
}

main().catch((err) => {
  log('FALLO al iniciar: ' + (err?.message || err), 'err');
  post({ type: 'nexa:error', message: String(err?.message || err) });
});
