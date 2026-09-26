import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/browser_download.dart';

/// Abre el PDF original de un documento guardado en una pestaña nueva del
/// navegador, para verlo o imprimirlo (GET
/// /patients/:id/documents/:filename/pdf).
///
/// Hay que llamarla directo desde el onPressed, sin `await` antes: la pestaña
/// se abre en el mismo clic (si no, el navegador la bloquea) y se llena
/// cuando llega el PDF. Si igual la bloquea, el PDF se descarga.
Future<void> openDocumentPdf(
  BuildContext context, {
  required int patientId,
  required String filename,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final tab = openPendingBrowserTab();

  String? message;
  try {
    final bytes = await ApiService.getDocumentPdf(
      patientId: patientId,
      filename: filename,
    );
    if (tab != null) {
      tab.showBytes(bytes, 'application/pdf');
    } else if (saveBytesAsFile(bytes, filename, 'application/pdf')) {
      message = 'El navegador bloqueó la pestaña nueva: el PDF se descargó.';
    } else {
      message = 'Ver el PDF solo está disponible en la versión web de Imagenda.';
    }
  } on ApiException catch (error) {
    tab?.close();
    message = error.message;
  } catch (_) {
    tab?.close();
    message = 'No fue posible abrir el PDF del documento.';
  }

  if (message != null) {
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }
}
