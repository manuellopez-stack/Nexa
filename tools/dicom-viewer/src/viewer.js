// Visor DICOM real para Imagenología de Nexa — Cornerstone3D.
// `npm run build` (Vite) lo compila a web/dicom-viewer/, que la app Flutter
// sirve e incrusta en un <iframe> (ver lib/widgets/dicom_viewer_web.dart).
//
// Navegación entre varias imágenes de una misma orden (stack): es enteramente
// interna a este visor (flechas de la barra + teclado ← →). Flutter solo le
// dice en qué índice abrir; no hace falta que Flutter conozca ni sincronice
// el índice actual.
//
// Comunicación con la app Flutter (window.postMessage):
//   recibe  { type: 'nexa:load',  urls: [signedUrl, ...], initialIndex? }
//   recibe  { type: 'nexa:tool',  tool: 'WindowLevel' | 'Zoom' | 'Pan' }
//   recibe  { type: 'nexa:reset' }
//   emite   { type: 'nexa:ready' }
//   emite   { type: 'nexa:loaded', count }
//   emite   { type: 'nexa:index',  index, count }  (cambia la imagen del stack)
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
let pendingLoad = null;
// Estado del stack actual, para la navegación (flechas/teclado) y su UI.
let stackImageIds = [];
let currentIndex = 0;
const embedded = window.parent !== window;

// El listener se registra ya (antes de que termine el init async) para no
// perder un `nexa:load` que llegue temprano desde la app Flutter.
window.addEventListener('message', (ev) => {
  const d = ev.data || {};
  if (d.type === 'nexa:load') {
    const load = {
      urls: d.urls,
      initialIndex: Number.isInteger(d.initialIndex) ? d.initialIndex : 0,
    };
    if (cornerstoneReady) loadUrls(load.urls, load.initialIndex);
    else pendingLoad = load;
  } else if (d.type === 'nexa:tool') {
    setPrimaryTool(d.tool);
  } else if (d.type === 'nexa:reset') {
    resetView();
  }
});

// ---- Navegación entre imágenes del stack (flechas de la barra + teclado) --

const navEl = () => document.getElementById('nav');
const navCountEl = () => document.getElementById('navCount');
const prevBtnEl = () => document.getElementById('prevImg');
const nextBtnEl = () => document.getElementById('nextImg');

// Muestra/oculta el bloque de navegación (solo tiene sentido con 2+
// imágenes) y actualiza el contador y el estado disabled de las flechas.
function updateNavUI() {
  const nav = navEl();
  if (!nav) return;
  const total = stackImageIds.length;
  nav.hidden = total <= 1;
  if (total <= 1) return;

  const countEl = navCountEl();
  if (countEl) countEl.textContent = `${currentIndex + 1} / ${total}`;
  const prev = prevBtnEl();
  if (prev) prev.disabled = currentIndex <= 0;
  const next = nextBtnEl();
  if (next) next.disabled = currentIndex >= total - 1;
}

// Cambia la imagen actual dentro del stack ya cargado (sin recargar nada:
// setImageIdIndex reutiliza el caché de Cornerstone). Mantiene zoom/pan/
// windowing tal como estaban, como en cualquier visor de series.
async function goToIndex(index) {
  if (!viewport || stackImageIds.length === 0) return;
  const clamped = Math.max(0, Math.min(index, stackImageIds.length - 1));
  if (clamped === currentIndex) return;
  await viewport.setImageIdIndex(clamped);
  currentIndex = clamped;
  viewport.render();
  updateNavUI();
  post({ type: 'nexa:index', index: currentIndex, count: stackImageIds.length });
}

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

async function loadUrls(urls, initialIndex = 0) {
  if (!viewport) return;
  const clean = (urls || [])
    .filter((u) => typeof u === 'string' && u.length > 0)
    // Cornerstone resuelve mal las rutas relativas "desnudas"; las absolutizamos
    // contra la página del visor. Las signed URLs de Supabase ya son absolutas.
    .map((u) => new URL(u, document.baseURI).href);
  if (clean.length === 0) { log('sin URLs para cargar', 'err'); return; }
  const imageIds = clean.map((u) => `wadouri:${u}`);
  const startIndex = Math.max(0, Math.min(initialIndex, imageIds.length - 1));
  const t0 = performance.now();
  log(`cargando ${imageIds.length} imagen(es)…`);
  try {
    await viewport.setStack(imageIds, startIndex);
    stackImageIds = imageIds;
    currentIndex = startIndex;
    resetView();
    setPrimaryTool(WindowLevelTool.toolName);
    updateNavUI();
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

  const prevBtn = prevBtnEl();
  if (prevBtn) prevBtn.addEventListener('click', () => goToIndex(currentIndex - 1));
  const nextBtn = nextBtnEl();
  if (nextBtn) nextBtn.addEventListener('click', () => goToIndex(currentIndex + 1));

  // Flechas del teclado = siguiente/anterior imagen del stack. La rueda del
  // mouse se queda en Zoom (ver listener de 'wheel' más arriba), así que no
  // hay conflicto entre ambos gestos.
  window.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft') {
      e.preventDefault();
      goToIndex(currentIndex - 1);
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      goToIndex(currentIndex + 1);
    }
  });

  window.addEventListener('resize', () => {
    try { renderingEngine.resize(true); } catch (_) { /* noop */ }
  });

  cornerstoneReady = true;
  log('Cornerstone3D iniciado ✓', 'ok');
  post({ type: 'nexa:ready' });

  const params = new URLSearchParams(location.search);
  if (pendingLoad) {
    await loadUrls(pendingLoad.urls, pendingLoad.initialIndex);
    pendingLoad = null;
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
