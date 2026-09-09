import 'package:flutter/widgets.dart';

import 'dicom_viewer_stub.dart'
    if (dart.library.js_interop) 'dicom_viewer_web.dart' as impl;

/// Abre el visor DICOM (Cornerstone3D) en un diálogo a pantalla casi completa.
///
/// En web incrusta `web/dicom-viewer/index.html` dentro de un `<iframe>` y le
/// pasa las signed URLs por `postMessage`. En otras plataformas muestra un
/// aviso (la app hoy solo se usa en web).
Future<void> showDicomViewer(
  BuildContext context, {
  required List<String> dicomUrls,
  String? title,
}) {
  return impl.showDicomViewer(context, dicomUrls: dicomUrls, title: title);
}
