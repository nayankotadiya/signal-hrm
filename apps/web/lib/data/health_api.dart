import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:n_ui/n_ui.dart' show NHealth, newIdempotencyKey;

NHealth parseHealth(Object? raw) => switch (raw) {
      'healthy' => NHealth.healthy,
      'degraded' => NHealth.degraded,
      'unavailable' => NHealth.unavailable,
      _ => NHealth.unknown, // anything unexpected is "unknown", never green
    };

class ComponentHealth {
  const ComponentHealth({required this.component, required this.state, required this.reason, required this.critical, this.latencyMs});

  factory ComponentHealth.fromJson(Map<String, Object?> j) => ComponentHealth(
        component: j['component'] as String? ?? 'unknown',
        state: parseHealth(j['state']),
        reason: j['reason'] as String? ?? 'check_failed',
        critical: j['critical'] as bool? ?? false,
        latencyMs: (j['latencyMs'] as num?)?.round(),
      );

  final String component;
  final NHealth state;
  final String reason;
  final bool critical;
  final int? latencyMs;
}

class HealthSummary {
  const HealthSummary({required this.state, required this.checkedAt, required this.version, required this.environment, required this.components});

  factory HealthSummary.fromJson(Map<String, Object?> j) => HealthSummary(
        state: parseHealth(j['state']),
        checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
        version: j['version'] as String? ?? '?',
        environment: j['environment'] as String? ?? '?',
        components: [
          for (final c in (j['components'] as List<Object?>? ?? const []))
            if (c is Map<String, Object?>) ComponentHealth.fromJson(c),
        ],
      );

  final NHealth state;
  final DateTime checkedAt;
  final String version;
  final String environment;
  final List<ComponentHealth> components;

  ComponentHealth? operator [](String name) {
    for (final c in components) {
      if (c.component == name) return c;
    }
    return null;
  }

  int count(NHealth s) => components.where((c) => c.state == s).length;
}

class HealthApiException implements Exception {
  const HealthApiException(this.message, {this.correlationId});
  final String message;
  final String? correlationId;
  @override
  String toString() => 'HealthApiException: $message';
}

/// Reads `GET /v1/health`. Every number on the home screen comes from this real response.
class HealthApi {
  HealthApi(this.baseUrl, {http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Future<HealthSummary> fetch() async {
    final correlationId = 'pwa-${newIdempotencyKey()}';
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse('$baseUrl/v1/health'), headers: {'accept': 'application/json', 'x-correlation-id': correlationId})
          .timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw HealthApiException('timeout', correlationId: correlationId);
    } catch (e) {
      throw HealthApiException('network', correlationId: correlationId);
    }
    if (res.statusCode != 200) {
      throw HealthApiException('http_${res.statusCode}', correlationId: res.headers['x-correlation-id'] ?? correlationId);
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, Object?>) throw HealthApiException('bad_body', correlationId: correlationId);
    return HealthSummary.fromJson(body);
  }
}
