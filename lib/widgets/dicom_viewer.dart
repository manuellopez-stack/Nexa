import 'package:flutter/widgets.dart';

import 'dvd_download.dart';

import 'dicom_viewer_stub.dart'
    if (dart.library.js_interop) 'dicom_viewer_web.dart' as impl;

/// Abre el visor DICOM (Cornerstone3D) en un diálogo a pantalla casi completa.
///
/// En web incrusta `web/dicom-viewer/index.html` dentro de un `<iframe>` y le
/// pasa las signed URLs por `postMessage`. En otras plataformas muestra un
/// aviso (la app hoy solo se usa en web).
///
/// [initialIndex]: posición del stack en la que debe abrir el visor (por
/// ejemplo, la imagen cuya miniatura se clickeó). Navegar entre imágenes una
/// vez abierto (flechas/teclado) lo maneja el propio visor.
///
/// [dvdOrder]: si viene, el menú del visor ofrece "Descargar para DVD" de esa
/// orden (quien llama decide si el rol tiene el permiso).
Future<void> showDicomViewer(
  BuildContext context, {
  required List<String> dicomUrls,
  int initialIndex = 0,
  String? title,
  DvdOrderRef? dvdOrder,
}) {
  return impl.showDicomViewer(
    context,
    dicomUrls: dicomUrls,
    initialIndex: initialIndex,
    title: title,
    dvdOrder: dvdOrder,
  );
}
