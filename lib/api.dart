import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';

class RateLimitedException implements Exception {
  final String? retryAfterText;
  const RateLimitedException([this.retryAfterText]);
  @override
  String toString() => 'Rate limited${retryAfterText != null ? ' (retry: $retryAfterText)' : ''}';
}

class NotAuthenticatedException implements Exception {
  @override
  String toString() => 'Not authenticated';
}

class UsagePool {
  final double utilization;
  final DateTime? resetsAt;

  const UsagePool({required this.utilization, required this.resetsAt});

  factory UsagePool.fromJson(Map<String, dynamic> json) {
    final reset = json['resets_at'];
    return UsagePool(
      utilization: (json['utilization'] as num?)?.toDouble() ?? 0.0,
      resetsAt: reset is String ? DateTime.parse(reset).toLocal() : null,
    );
  }
}

class Usage {
  final UsagePool fiveHour;
  final UsagePool sevenDay;
  final DateTime fetchedAt;

  const Usage({
    required this.fiveHour,
    required this.sevenDay,
    required this.fetchedAt,
  });
}

class UsageApi {
  static const Duration _timeout = Duration(seconds: 15);
  final AuthStore store;

  UsageApi(this.store);

  Future<Usage> fetch() async {
    if (!store.isAuthenticated) {
      throw NotAuthenticatedException();
    }
    var res = await _get();
    if (res.statusCode == 401) {
      try {
        final t = await refreshTokens(store.tokens!.refreshToken);
        await store.save(t);
      } catch (_) {
        await store.clear();
        throw NotAuthenticatedException();
      }
      res = await _get();
    }
    if (res.statusCode == 429) {
      throw RateLimitedException(res.headers['retry-after']);
    }
    if (res.statusCode != 200) {
      throw Exception('Usage fetch failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return Usage(
      fiveHour: UsagePool.fromJson(body['five_hour'] as Map<String, dynamic>),
      sevenDay: UsagePool.fromJson(body['seven_day'] as Map<String, dynamic>),
      fetchedAt: DateTime.now(),
    );
  }

  Future<http.Response> _get() {
    return http
        .get(
          Uri.parse(OAuthConfig.usageUrl),
          headers: {
            'Authorization': 'Bearer ${store.tokens!.accessToken}',
            'Content-Type': 'application/json',
            'anthropic-beta': 'oauth-2025-04-20',
          },
        )
        .timeout(_timeout);
  }
}
