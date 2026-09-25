import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:web/web.dart' as web;

import '../core/nexa_colors.dart';
import 'dvd_download.dart';

int _seq = 0;

Future<void> showDicomViewer(
  BuildContext context, {
  required List<String> dicomUrls,
  int initialIndex = 0,
  String? title,
  DvdOrderRef? dvdOrder,
}) {
  final urls = dicomUrls
      .where((u) => u.trim().isNotEmpty)
      .toList(growable: false);

  if (urls.isEmpty) {
    return showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(
        content: Text('Esta orden no tiene imágenes DICOM para mostrar.'),
      ),
    );
  }

  // Clamp defensivo: si el índice llega fuera de rango (por ejemplo, la lista
  // cambió entre que se armaron las miniaturas y el click), abre en la 0 en
  // vez de mandarle un índice inválido al visor.
  final safeInitialIndex = (initialIndex >= 0 && initialIndex < urls.length)
      ? initialIndex
      : 0;

  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.75),
    builder: (dialogContext) => _DicomViewerDialog(
      dicomUrls: urls,
      initialIndex: safeInitialIndex,
      title: title ?? 'Visor DICOM',
      dvdOrder: dvdOrder,
    ),
  );
}

class _DicomViewerDialog extends StatefulWidget {
  const _DicomViewerDialog({
    required this.dicomUrls,
    required this.initialIndex,
    required this.title,
    this.dvdOrder,
  });

  final List<String> dicomUrls;
  final int initialIndex;
  final String title;
  final DvdOrderRef? dvdOrder;

  @override
  State<_DicomViewerDialog> createState() => _DicomViewerDialogState();
}

class _DicomViewerDialogState extends State<_DicomViewerDialog> {
  late final String _viewId;
  web.HTMLIFrameElement? _iframe;
  JSFunction? _messageListener;
  String? _error;

  @override
  void initState() {
    super.initState();
    _viewId = 'nexa-dicom-viewer-${_seq++}';

    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int _) {
      final iframe = web.document.createElement('iframe') as web.HTMLIFrameElement
        ..src = 'dicom-viewer/index.html'
        ..allow = 'fullscreen'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      _iframe = iframe;
      return iframe;
    });

    final listener = (web.MessageEvent event) {
      final data = event.data?.dartify();
      if (data is! Map) return;
      switch (data['type']) {
        case 'nexa:ready':
          _sendUrls();
        case 'nexa:error':
          if (mounted) {
            setState(() => _error = data['message']?.toString());
          }
      }
    }.toJS;
    _messageListener = listener;
    web.window.addEventListener('message', listener);
  }

  void _sendUrls() {
    final payload = <String, Object?>{
      'type': 'nexa:load',
      'urls': widget.dicomUrls,
      'initialIndex': widget.initialIndex,
    }.jsify();
    _iframe?.contentWindow?.postMessage(payload, '*'.toJS);
  }

  // El <iframe> se queda con los clics que caen sobre él aunque Flutter
  // dibuje encima (menú desplegable, diálogos). Mientras hay algo abierto
  // sobre el visor se le desactivan los eventos.
  void _setIframeInteractive(bool interactive) {
    _iframe?.style.pointerEvents = interactive ? '' : 'none';
  }

  Future<void> _onMenuSelected(String value) async {
    final order = widget.dvdOrder;
    try {
      if (value == 'dvd' && order != null) {
        await downloadStudyForDvd(
          context,
          patientId: order.patientId,
          orderId: order.orderId,
        );
      } else if (value == 'dvd-ayuda') {
        await showDvdBurnHelp(context);
      }
    } finally {
      _setIframeInteractive(true);
    }
  }

  @override
  void dispose() {
    final listener = _messageListener;
    if (listener != null) {
      web.window.removeEventListener('message', listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: media.width < 700 ? 12 : 48,
        vertical: media.height < 600 ? 12 : 36,
      ),
      backgroundColor: const Color(0xFF0C0F10),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1100,
        height: 760,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              color: const Color(0xFF151B1C),
              child: Row(
                children: [
                  const Icon(Icons.medical_information_outlined,
                      size: 18, color: Color(0xFF9AABAB)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.dicomUrls.length > 1
                          ? '${widget.title} · ${widget.dicomUrls.length} imágenes'
                          : widget.title,
                      style: const TextStyle(
                        color: Color(0xFFDFE6E6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.dvdOrder != null)
                    PopupMenuButton<String>(
                      tooltip: 'Más opciones',
                      icon: const Icon(Icons.more_vert, color: Color(0xFF9AABAB)),
                      onOpened: () => _setIframeInteractive(false),
                      onCanceled: () => _setIframeInteractive(true),
                      onSelected: _onMenuSelected,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'dvd',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.album_outlined),
                            title: Text('Descargar para DVD'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'dvd-ayuda',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.help_outline),
                            title: Text('Cómo grabar el DVD'),
                          ),
                        ),
                      ],
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF9AABAB)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _error != null
                  ? _ErrorPane(message: _error!)
                  : PointerInterceptor(
                      child: HtmlElementView(viewType: _viewId),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                color: NexaColors.textSecondary, size: 40),
            const SizedBox(height: 12),
            const Text(
              'No fue posible cargar la imagen DICOM.',
              style: TextStyle(color: Color(0xFFDFE6E6), fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9AABAB), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
