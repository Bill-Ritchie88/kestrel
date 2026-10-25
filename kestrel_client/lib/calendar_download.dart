/// Saving a small text file (the calendar entry): a browser download on the
/// web; not available elsewhere.
library;

export 'calendar_download_io.dart' if (dart.library.js_interop) 'calendar_download_web.dart';
