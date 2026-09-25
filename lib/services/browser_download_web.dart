import 'package:web/web.dart' as web;

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
