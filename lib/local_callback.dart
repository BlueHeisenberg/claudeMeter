// Conditional export: IO platforms can start a real HTTP server on localhost
// for the OAuth callback. Web cannot — the stub returns kSupported=false.
export 'local_callback_io.dart'
    if (dart.library.js_interop) 'local_callback_web.dart';
