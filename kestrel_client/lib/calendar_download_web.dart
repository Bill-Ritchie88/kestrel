import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Hands [text] to the browser as a file called [name].
bool saveTextFile(String name, String mimeType, String text) {
  final blob = web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  link.click();
  web.URL.revokeObjectURL(url);
  return true;
}
