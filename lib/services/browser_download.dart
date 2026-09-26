import 'dart:typed_data';

import 'browser_download_stub.dart'
    if (dart.library.js_interop) 'browser_download_web.dart' as impl;

/// Hace que el navegador baje `url` como archivo, con su propia barra de
/// descarga: el contenido nunca pasa por la memoria de la app (sirve para
/// archivos de cientos de MB, como el ZIP "Descargar para DVD").
///
/// Devuelve false si la plataforma no puede hacerlo (la app hoy solo se usa
/// en web).
bool startBrowserDownload(String url, {String? filename}) =>
    impl.startBrowserDownload(url, filename: filename);

/// Pestaña nueva del navegador que se abre ya y se llena después, cuando
/// llega el contenido (por ejemplo un PDF pedido con el token de sesión).
///
/// Hay que abrirla dentro del mismo clic, ANTES de cualquier `await`: si se
/// abre después, el navegador la bloquea como ventana emergente.
abstract class PendingBrowserTab {
  /// Muestra los bytes en la pestaña (el PDF se ve e imprime con el visor
  /// del navegador).
  void showBytes(Uint8List bytes, String mimeType);

  /// Cierra la pestaña (si algo falló antes de tener el contenido).
  void close();
}

/// Abre la pestaña vacía. null si la plataforma no puede o si el navegador
/// la bloqueó.
PendingBrowserTab? openPendingBrowserTab() => impl.openPendingBrowserTab();

/// Plan B si la pestaña fue bloqueada: baja los bytes como archivo. false si
/// la plataforma no puede.
bool saveBytesAsFile(Uint8List bytes, String filename, String mimeType) =>
    impl.saveBytesAsFile(bytes, filename, mimeType);
