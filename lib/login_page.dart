import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth.dart';
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

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  Future<void> _startLogin() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    final pkce = PkcePair.generate();
    final state = randomState();
    final url = buildAuthorizeUri(
      codeChallenge: pkce.challenge,
      state: state,
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      setState(() {
        _busy = false;
        _error = 'Could not open browser.';
      });
      return;
    }
    if (!mounted) return;
    final pasted = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PasteCodeDialog(),
    );
    if (!mounted) return;
    if (pasted == null || pasted.trim().isEmpty) {
      setState(() => _busy = false);
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
    await _completeExchange(code, returnedState, pkce.verifier);
  }

  Future<void> _completeExchange(
    String code,
    String state,
    String verifier,
  ) async {
    try {
      final tokens = await exchangeCodeForTokens(
        code: code,
        state: state,
        codeVerifier: verifier,
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
                        _busy ? 'Waiting for browser…' : 'Sign in with Claude',
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Opens your browser. After signing in (Google, email, or any provider), copy the code from the success page and paste it here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 11,
                      color: _textDim,
                    ),
                  ),
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
    // Heuristic: long OAuth code, optionally `code#state`.
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
