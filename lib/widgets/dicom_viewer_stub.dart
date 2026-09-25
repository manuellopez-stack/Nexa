import 'package:flutter/material.dart';

import 'dvd_download.dart';

/// Implementación para plataformas no-web: el visor DICOM necesita el `<iframe>`
/// con Cornerstone3D, así que fuera de web solo avisamos.
Future<void> showDicomViewer(
  BuildContext context, {
  required List<String> dicomUrls,
  int initialIndex = 0,
  String? title,
  DvdOrderRef? dvdOrder,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => const AlertDialog(
      title: Text('Visor no disponible'),
      content: Text(
        'El visor DICOM solo está disponible en la versión web de Imagenda.',
      ),
    ),
  );
}
