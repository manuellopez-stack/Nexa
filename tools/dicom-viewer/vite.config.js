import { defineConfig } from 'vite';
import { viteCommonjs } from '@originjs/vite-plugin-commonjs';
import { nodePolyfills } from 'vite-plugin-node-polyfills';

// El visor se sirve desde  <app>/dicom-viewer/  (Flutter copia web/ tal cual).
// Vite compila esta carpeta y deja el resultado en web/dicom-viewer/.
//
// Config basada en la recomendación oficial de Cornerstone3D para Vite, más:
//  - nodePolyfills()  -> @cornerstonejs/dicom-image-loader arrastra xmlbuilder2,
//                        que hace `class ... extends events.EventEmitter`; sin
//                        polyfill de `events` el módulo revienta al cargar.
export default defineConfig({
  base: './',
  plugins: [
    viteCommonjs(),
    nodePolyfills({
      include: ['events', 'util', 'stream', 'buffer', 'url', 'process'],
      globals: { Buffer: true, global: true, process: true },
    }),
  ],
  build: {
    outDir: '../../web/dicom-viewer',
    emptyOutDir: true,
    target: 'es2020',
    chunkSizeWarningLimit: 6000,
  },
  optimizeDeps: {
    exclude: ['@cornerstonejs/dicom-image-loader'],
    include: ['dicom-parser'],
  },
  worker: {
    format: 'es',
    rollupOptions: {
      external: ['@icr/polyseg-wasm'],
    },
  },
});
