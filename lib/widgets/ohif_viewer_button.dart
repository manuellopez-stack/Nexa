import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/browser_download.dart';

/// "Ver en OHIF" (Fase 3): abre el visor OHIF del PACS en una pestaña nueva,
/// con un enlace que pide el backend (vence en 2 horas y solo abre los
/// estudios de la orden). Solo aparece si el backend tiene
/// OHIF_VIEWER_ENABLED; el visor propio de Imagenda sigue igual.
class OhifViewerButton extends StatelessWidget {
  const OhifViewerButton({
    super.key,
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // La pestaña se abre dentro del clic, antes del await: si no, el
    // navegador la bloquea como ventana emergente.
    final tab = openPendingBrowserTab();
    if (tab == null) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'El navegador bloqueó la pestaña del visor. Permite las ventanas '
            'emergentes de Imagenda e intenta de nuevo.',
          ),
        ),
      );
      return;
    }
    try {
      final url = await ApiService.getOhifViewerUrl(
        patientId: patientId,
        orderId: orderId,
      );
      tab.navigate(url);
    } on ApiException catch (error) {
      tab.close();
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      tab.close();
      messenger?.showSnackBar(
        const SnackBar(content: Text('No fue posible abrir el visor OHIF.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ApiService.ohifViewerEnabled) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () => _open(context),
      icon: const Icon(Icons.open_in_new, size: 18),
      label: const Text('Ver en OHIF'),
    );
  }
}
