import 'package:flutter/material.dart';

/// Implementación para plataformas no-web: el visor DICOM necesita el `<iframe>`
/// con Cornerstone3D, así que fuera de web solo avisamos.
Future<void> showDicomViewer(
  BuildContext context, {
  required List<String> dicomUrls,
  String? title,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => const AlertDialog(
      title: Text('Visor no disponible'),
      content: Text(
        'El visor DICOM solo está disponible en la versión web de Nexa.',
      ),
    ),
  );
}
