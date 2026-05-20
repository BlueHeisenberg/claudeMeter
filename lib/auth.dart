import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_proxy.dart';

class OAuthConfig {
  // Production OAuth config used by Claude Code 2.1.x. All values are publicly
  // visible in the CLI binary.
  static const String clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String authorizeUrl = 'https://claude.ai/oauth/authorize';
  static const String redirectUri =
      'https://platform.claude.com/oauth/code/callback';
  // Reading /api/oauth/usage only needs the minimum scope set — identifying
  // the user and being recognized as a valid API token. Drops the CLI's
  // file_upload, mcp_servers, and sessions scopes that this app never uses.
  static const List<String> scopes = [
    'user:profile',
    'user:inference',
  ];

  // On Android we hit Anthropic directly; on web we go through our
  // Cloudflare Worker proxy (CORS bypass).
  static String get usageUrl {
    final proxy = proxyBaseUrl();
    if (proxy != null) return '$proxy/usage';
    return 'https://api.anthropic.com/api/oauth/usage';
  }

  static String get tokenUrl {
    final proxy = proxyBaseUrl();
    if (proxy != null) return '$proxy/token';
    return 'https://platform.claude.com/v1/oauth/token';
  }
}

class Tokens {
  final String accessToken;
  final String refreshToken;

  const Tokens(this.accessToken, this.refreshToken);
}

class AuthStore extends ChangeNotifier {
  static const _accessKey = 'cm_access_token';
  static const _refreshKey = 'cm_refresh_token';
  Tokens? _tokens;

  Tokens? get tokens => _tokens;
  bool get isAuthenticated => _tokens != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final a = prefs.getString(_accessKey);
    final r = prefs.getString(_refreshKey);
    if (a != null && r != null) {
      _tokens = Tokens(a, r);
    }
    notifyListeners();
  }

  Future<void> save(Tokens t) async {
    _tokens = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKey, t.accessToken);
    await prefs.setString(_refreshKey, t.refreshToken);
    notifyListeners();
  }

  Future<void> clear() async {
    _tokens = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessKey);
    await prefs.remove(_refreshKey);
    notifyListeners();
  }
}

class PkcePair {
  final String verifier;
  final String challenge;

  const PkcePair(this.verifier, this.challenge);

  factory PkcePair.generate() {
    final rnd = math.Random.secure();
    final verifierBytes = List<int>.generate(64, (_) => rnd.nextInt(256));
    final verifier = _base64UrlNoPad(verifierBytes);
    final challenge = _base64UrlNoPad(sha256.convert(utf8.encode(verifier)).bytes);
    return PkcePair(verifier, challenge);
  }
}

String _base64UrlNoPad(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

String randomState() {
  final rnd = math.Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return _base64UrlNoPad(bytes);
}

Uri buildAuthorizeUri({
  required String codeChallenge,
  required String state,
  String? redirectUri,
}) {
  return Uri.parse(OAuthConfig.authorizeUrl).replace(queryParameters: {
    'code': 'true',
    'client_id': OAuthConfig.clientId,
    'response_type': 'code',
    'redirect_uri': redirectUri ?? OAuthConfig.redirectUri,
    'scope': OAuthConfig.scopes.join(' '),
    'code_challenge': codeChallenge,
    'code_challenge_method': 'S256',
    'state': state,
  });
}

class TokenExchangeException implements Exception {
  final String message;
  TokenExchangeException(this.message);
  @override
  String toString() => message;
}

Future<Tokens> exchangeCodeForTokens({
  required String code,
  required String state,
  required String codeVerifier,
  String? redirectUri,
}) async {
  final res = await http
      .post(
        Uri.parse(OAuthConfig.tokenUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri ?? OAuthConfig.redirectUri,
          'client_id': OAuthConfig.clientId,
          'code_verifier': codeVerifier,
          'state': state,
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    throw TokenExchangeException(
      'Token exchange failed (${res.statusCode}): ${res.body}',
    );
  }
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  return Tokens(
    body['access_token'] as String,
    (body['refresh_token'] as String?) ?? '',
  );
}

Future<Tokens> refreshTokens(String refreshToken) async {
  final res = await http
      .post(
        Uri.parse(OAuthConfig.tokenUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': OAuthConfig.clientId,
          'scope': OAuthConfig.scopes.join(' '),
        }),
      )
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw TokenExchangeException(
      'Token refresh failed (${res.statusCode}): ${res.body}',
    );
  }
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  return Tokens(
    body['access_token'] as String,
    (body['refresh_token'] as String?) ?? refreshToken,
  );
}
