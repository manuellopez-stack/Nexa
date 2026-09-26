import 'dart:typed_data';

import 'browser_download.dart';

/// Fuera de web no hay navegador que haga la descarga.
bool startBrowserDownload(String url, {String? filename}) => false;

PendingBrowserTab? openPendingBrowserTab() => null;

bool saveBytesAsFile(Uint8List bytes, String filename, String mimeType) =>
    false;
