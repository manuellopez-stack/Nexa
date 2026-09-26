import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'browser_download.dart';

bool startBrowserDownload(String url, {String? filename}) {
  // El backend responde con Content-Disposition: attachment, así que el
  // navegador descarga sin salir de la app aunque sea otro origen (en ese
  // caso ignora el atributo download y usa el nombre que manda el servidor).
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename ?? ''
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  return true;
}

// Los blob: URL viven lo que la pestaña de Imagenda; se liberan después de
// un rato para no acumular PDFs en memoria (el visor ya los cargó).
const _blobUrlLifetime = Duration(minutes: 5);

String _blobUrl(Uint8List bytes, String mimeType) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  Timer(_blobUrlLifetime, () => web.URL.revokeObjectURL(url));
  return url;
}

class _WebPendingTab implements PendingBrowserTab {
  _WebPendingTab(this._window);

  final web.Window _window;

  @override
  void showBytes(Uint8List bytes, String mimeType) {
    // La pestaña nació como about:blank desde esta página, así que es del
    // mismo origen y puede abrir el blob: URL.
    _window.location.href = _blobUrl(bytes, mimeType);
  }

  @override
  void navigate(String url) {
    // Corta window.opener antes de ir a otro origen.
    _window.opener = null;
    _window.location.href = url;
  }

  @override
  void close() => _window.close();
}

PendingBrowserTab? openPendingBrowserTab() {
  final window = web.window.open('', '_blank');
  if (window == null) return null;
  try {
    window.document.title = 'Cargando…';
    window.document.body?.textContent = 'Cargando documento…';
  } catch (_) {
    // Solo es un texto de espera.
  }
  return _WebPendingTab(window);
}

bool saveBytesAsFile(Uint8List bytes, String filename, String mimeType) =>
    startBrowserDownload(_blobUrl(bytes, mimeType), filename: filename);
