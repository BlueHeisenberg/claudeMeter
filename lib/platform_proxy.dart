// Conditional export: the IO version returns null, the web version reads
// `window.CLAUDE_METER_PROXY_URL` set in web/proxy_url.js.
export 'platform_proxy_io.dart'
    if (dart.library.js_interop) 'platform_proxy_web.dart';
