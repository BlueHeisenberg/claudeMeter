const bool kLocalCallbackSupported = false;

class LocalCallbackResult {
  final String? code;
  final String? state;
  final String? error;
  LocalCallbackResult({this.code, this.state, this.error});
}

class LocalCallbackServer {
  Future<int> start() async =>
      throw UnsupportedError('Localhost callback is not available on web.');
  Future<LocalCallbackResult> waitForCallback({Duration? timeout}) =>
      throw UnsupportedError('Localhost callback is not available on web.');
  Future<void> close() async {}
}
