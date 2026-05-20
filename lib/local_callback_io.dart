import 'dart:async';
import 'dart:io';

const bool kLocalCallbackSupported = true;

class LocalCallbackResult {
  final String? code;
  final String? state;
  final String? error;
  LocalCallbackResult({this.code, this.state, this.error});
}

/// Binds a one-shot HTTP server on 127.0.0.1 (random port), awaits a single
/// `/callback?code=...&state=...` request, responds with a small success
/// page, and returns the parsed result.
class LocalCallbackServer {
  HttpServer? _server;
  final Completer<LocalCallbackResult> _completer =
      Completer<LocalCallbackResult>();

  Future<int> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: _failOnce);
    return server.port;
  }

  Future<LocalCallbackResult> waitForCallback({Duration? timeout}) {
    if (timeout == null) return _completer.future;
    return _completer.future.timeout(timeout, onTimeout: () {
      _failOnce(TimeoutException('OAuth callback timed out', timeout));
      throw TimeoutException('OAuth callback timed out', timeout);
    });
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
    if (!_completer.isCompleted) {
      _completer.completeError(StateError('canceled'));
    }
  }

  void _failOnce(Object e) {
    if (!_completer.isCompleted) _completer.completeError(e);
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != '/callback') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final params = req.uri.queryParameters;
    final result = LocalCallbackResult(
      code: params['code'],
      state: params['state'],
      error: params['error'],
    );

    final ok = result.error == null && result.code != null;
    req.response
      ..headers.contentType = ContentType.html
      ..write(_successPage(ok, result.error));
    await req.response.close();

    if (!_completer.isCompleted) _completer.complete(result);
    // Tear down so the port is released.
    await _server?.close(force: true);
    _server = null;
  }

  String _successPage(bool ok, String? error) {
    final title = ok ? 'Signed in' : 'Sign-in failed';
    final body = ok
        ? 'You can close this tab and return to Claude Meter.'
        : 'Error: ${error ?? "no code"}';
    return '''
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Meter — $title</title>
<style>
  html,body{margin:0;height:100%;background:#0A0A0A;color:#fff;
    font-family:serif;display:flex;align-items:center;justify-content:center}
  .card{padding:32px 28px;max-width:420px;text-align:center}
  h1{margin:0 0 12px;font-size:28px}
  p{margin:0;color:#B8A8C4;font-size:15px;line-height:1.45}
  .check{color:#CFE36B;font-size:48px;margin-bottom:6px}
  .x{color:#E85A3D;font-size:48px;margin-bottom:6px}
</style>
</head><body>
  <div class="card">
    <div class="${ok ? "check" : "x"}">${ok ? "✓" : "✕"}</div>
    <h1>$title</h1>
    <p>$body</p>
  </div>
  <script>setTimeout(function(){window.close();}, 1500);</script>
</body></html>
''';
  }
}
