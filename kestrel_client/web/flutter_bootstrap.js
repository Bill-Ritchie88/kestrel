{{flutter_js}}
{{flutter_build_config}}

// Kestrel starts the app straight away. Flutter's default bootstrap first
// registers its (deprecated, clean-up only) service worker and waits up to
// 4 s for it to activate; that worker then reloads open pages. Kestrel keeps
// nothing offline, so it has no use for one.
_flutter.loader.load();
