/// The HTTP client for streamed replies (POST :8001/api/chat/stream): in a
/// browser, fetch() with a readable body (package:fetch_client), because
/// the default browser client delivers a response only when it is complete;
/// elsewhere the ordinary client, which streams already.
library;

export 'streaming_client_io.dart' if (dart.library.js_interop) 'streaming_client_web.dart';
