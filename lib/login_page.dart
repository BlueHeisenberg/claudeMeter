import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth.dart';
import 'local_callback.dart';
import 'mascot.dart';

const _bg = Color(0xFF0A0A0A);
const _cardBg = Color(0xFF1A0F1A);
const _orange = Color(0xFFE85A3D);
const _textDim = Color(0xFFB8A8C4);

class LoginPage extends StatefulWidget {
  final AuthStore store;
  final VoidCallback onLoggedIn;
  const LoginPage({super.key, required this.store, required this.onLoggedIn});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;
  String _status = '';

  // Web-only: pending PKCE state used by the on-resume clipboard sniffer.
  PkcePair? _pendingPkce;
  String? _pendingState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        kIsWeb &&
        _pendingPkce != null &&
        _pendingState != null) {
      // User returned to the app after signing in via the browser.
      // Try to auto-complete using the clipboard.
      _tryClipboardAutoComplete();
    }
  }

  Future<void> _startLogin() async {
    setState(() {
      _error = null;
      _busy = true;
      _status = 'Opening browser…';
    });
    final pkce = PkcePair.generate();
    final state = randomState();

    if (kLocalCallbackSupported) {
      await _localhostFlow(pkce, state);
    } else {
      await _webFlow(pkce, state);
    }
  }

  Future<void> _localhostFlow(PkcePair pkce, String state) async {
    final server = LocalCallbackServer();
    int port;
    try {
      port = await server.start();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not start local callback server: $e';
      });
      return;
    }
    final redirectUri = 'http://localhost:$port/callback';
    final authorizeUri = buildAuthorizeUri(
      codeChallenge: pkce.challenge,
      state: state,
      redirectUri: redirectUri,
    );

    if (!await launchUrl(authorizeUri, mode: LaunchMode.externalApplication)) {
      await server.close();
      setState(() {
        _busy = false;
        _error = 'Could not open the browser.';
      });
      return;
    }

    setState(() => _status = 'Waiting for sign-in…');

    LocalCallbackResult result;
    try {
      result = await server.waitForCallback(
        timeout: const Duration(minutes: 5),
      );
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Sign-in timed out or was canceled.';
      });
      return;
    }

    if (result.error != null) {
      setState(() {
        _busy = false;
        _error = 'OAuth error: ${result.error}';
      });
      return;
    }
    if (result.state != state) {
      setState(() {
        _busy = false;
        _error = 'State mismatch — possible CSRF, please try again.';
      });
      return;
    }
    if (result.code == null) {
      setState(() {
        _busy = false;
        _error = 'No code returned.';
      });
      return;
    }

    await _completeExchange(
      code: result.code!,
      state: state,
      verifier: pkce.verifier,
      redirectUri: redirectUri,
    );
  }

  Future<void> _webFlow(PkcePair pkce, String state) async {
    _pendingPkce = pkce;
    _pendingState = state;
    final authorizeUri = buildAuthorizeUri(
      codeChallenge: pkce.challenge,
      state: state,
    );

    if (!await launchUrl(authorizeUri, mode: LaunchMode.externalApplication)) {
      _pendingPkce = null;
      _pendingState = null;
      setState(() {
        _busy = false;
        _error = 'Could not open the browser.';
      });
      return;
    }

    setState(() => _status = 'Waiting for sign-in… return here when done.');
    // The didChangeAppLifecycleState handler will trigger _tryClipboardAutoComplete
    // when the user comes back. If auto-complete fails (empty clipboard), the
    // user can tap "I copied the code" to invoke the paste dialog manually.
  }

  Future<void> _tryClipboardAutoComplete() async {
    final pkce = _pendingPkce;
    final state = _pendingState;
    if (pkce == null || state == null) return;
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      // Fall back to the paste dialog.
      await _promptPaste(pkce, state);
      return;
    }
    String code = text;
    String returnedState = state;
    if (code.contains('#')) {
      final parts = code.split('#');
      code = parts[0].trim();
      returnedState = parts[1].trim();
    }
    if (returnedState != state ||
        code.length < 16 ||
        code.contains(' ') ||
        code.contains('\n')) {
      // Doesn't look like our code; show the paste dialog so user can intervene.
      await _promptPaste(pkce, state);
      return;
    }
    // Clear pending so resume doesn't re-fire.
    _pendingPkce = null;
    _pendingState = null;
    await _completeExchange(code: code, state: state, verifier: pkce.verifier);
  }

  Future<void> _promptPaste(PkcePair pkce, String state) async {
    if (!mounted) return;
    final pasted = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PasteCodeDialog(),
    );
    if (!mounted) return;
    if (pasted == null || pasted.trim().isEmpty) {
      setState(() {
        _busy = false;
        _status = '';
      });
      _pendingPkce = null;
      _pendingState = null;
      return;
    }
    String code = pasted.trim();
    String returnedState = state;
    if (code.contains('#')) {
      final parts = code.split('#');
      code = parts[0].trim();
      returnedState = parts[1].trim();
    }
    if (returnedState != state) {
      setState(() {
        _busy = false;
        _error = 'State mismatch. Re-open sign-in and try again.';
      });
      return;
    }
    _pendingPkce = null;
    _pendingState = null;
    await _completeExchange(code: code, state: state, verifier: pkce.verifier);
  }

  Future<void> _completeExchange({
    required String code,
    required String state,
    required String verifier,
    String? redirectUri,
  }) async {
    setState(() => _status = 'Finishing sign-in…');
    try {
      final tokens = await exchangeCodeForTokens(
        code: code,
        state: state,
        codeVerifier: verifier,
        redirectUri: redirectUri,
      );
      await widget.store.save(tokens);
      if (!mounted) return;
      widget.onLoggedIn();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const ClaudeMascot(size: 64),
                  const SizedBox(height: 14),
                  const Text(
                    'Claude Meter',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Sign in to your Claude account to see your usage.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 14,
                      color: _textDim,
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _cardBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _orange),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 12,
                          color: _orange,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _startLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        _busy ? _status : 'Sign in with Claude',
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (kIsWeb && _busy && _pendingPkce != null) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        final pkce = _pendingPkce!;
                        final state = _pendingState!;
                        _promptPaste(pkce, state);
                      },
                      style: TextButton.styleFrom(foregroundColor: _textDim),
                      child: const Text(
                        'Paste the code manually',
                        style: TextStyle(fontFamily: 'serif', fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasteCodeDialog extends StatefulWidget {
  const _PasteCodeDialog();
  @override
  State<_PasteCodeDialog> createState() => _PasteCodeDialogState();
}

class _PasteCodeDialogState extends State<_PasteCodeDialog> {
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _maybePrefillFromClipboard();
  }

  Future<void> _maybePrefillFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    if (text.length >= 16 && !text.contains(' ') && !text.contains('\n')) {
      _ctrl.text = text;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _cardBg,
      title: const Text(
        'Paste the code',
        style: TextStyle(color: Colors.white, fontFamily: 'serif'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'After signing in, the success page shows a code. Copy it and paste below.',
            style: TextStyle(
              color: _textDim,
              fontFamily: 'serif',
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontFamily: 'serif'),
            decoration: const InputDecoration(
              hintText: 'code#state',
              hintStyle: TextStyle(color: _textDim),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: _textDim),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: _orange),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel', style: TextStyle(color: _textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Done', style: TextStyle(color: _orange)),
        ),
      ],
    );
  }
}
