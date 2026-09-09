# Visor DICOM de Nexa (Cornerstone3D)

Código fuente del visor de imágenes que se incrusta (vía `<iframe>`) en la
sección de Imagenología de la app Flutter.

- **Librería:** Cornerstone3D (`@cornerstonejs/*`), licencia MIT.
- **Entrada:** signed URLs de Supabase Storage vía `postMessage` desde Flutter
  (`lib/widgets/dicom_viewer_web.dart`). Camino A: fetch directo, sin proxy.
- **Herramientas:** brillo/contraste (windowing), zoom (rueda + botón), pan, reset.

## Compilar

```bash
cd tools/dicom-viewer
npm install
npm run build      # deja el resultado en ../../web/dicom-viewer/
```

El output de `web/dicom-viewer/` **se commitea** (no hay CI que lo compile) para
que `flutter build web` funcione sin pasos extra. Reconstruir y commitear cada
vez que cambie `src/viewer.js` o se suba la versión de Cornerstone.

## Probar suelto (sin Flutter)

```bash
npm run dev        # abre la página; carga public/CT_small.dcm
# o con una URL propia:  http://localhost:5173/?url=<signed-url>&debug
```
