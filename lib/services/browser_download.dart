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
