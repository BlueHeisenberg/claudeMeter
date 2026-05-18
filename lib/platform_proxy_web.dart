import 'dart:js_interop';

@JS('CLAUDE_METER_PROXY_URL')
external String? _proxyUrl;

/// Web: reads the proxy base URL injected by `web/proxy_url.js`.
/// Returns null (and the app falls back to direct calls, which will hit CORS)
/// if the script hasn't been edited with a deployed Worker URL.
String? proxyBaseUrl() {
  final u = _proxyUrl;
  if (u == null || u.isEmpty) return null;
  return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
}
