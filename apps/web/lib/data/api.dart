import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:n_ui/n_ui.dart' show newIdempotencyKey;

import '../platform/bridge.dart';

typedef Json = Map<String, dynamic>;

class FieldError {
  const FieldError(this.field, this.message);
  final String field;
  final String message;
}

/// Structured API error. [message] is safe to show; [correlationId] goes in the error sheet.
class ApiException implements Exception {
  const ApiException({required this.status, required this.code, required this.message, this.details = const [], this.meta = const {}, this.correlationId});

  factory ApiException.network() => const ApiException(status: 0, code: 'NETWORK', message: "Can't reach Signal HRM. Check your connection and try again.");
  factory ApiException.timeout() => const ApiException(status: 0, code: 'TIMEOUT', message: 'The server took too long to answer. Try again.');

  final int status;
  final String code;
  final String message;
  final List<FieldError> details;
  final Map<String, dynamic> meta;
  final String? correlationId;

  bool get isNetwork => status == 0;
  bool get isAuth => status == 401;
  bool get isForbidden => status == 403;

  String? fieldError(String field) {
    for (final d in details) {
      if (d.field == field || d.field.startsWith('$field.')) return d.message;
    }
    return null;
  }

  @override
  String toString() => 'ApiException($status $code: $message)';
}

class DownloadedFile {
  const DownloadedFile(this.bytes, this.fileName, this.mimeType);
  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

/// The one HTTP client for the API.
///
/// - Access token in memory only; the refresh token is an httpOnly cookie the browser sends.
/// - Every mutation carries an Idempotency-Key. A network failure is retried once with the SAME key,
///   so the server replays instead of duplicating (check-in, approvals, payments).
/// - 401 TOKEN_EXPIRED triggers one single-flight refresh, then the request is retried.
class ApiClient {
  ApiClient(this.baseUrl, {http.Client? client, PlatformBridge? platform})
      : _platform = platform ?? bridge,
        _client = client ?? (platform ?? bridge).httpClient();

  final String baseUrl;
  final PlatformBridge _platform;
  final http.Client _client;

  String? _accessToken;
  DateTime? _expiresAt;
  Future<bool>? _refreshing;

  /// Called after a refresh succeeds (with the fresh `me`) or when the session is gone (null).
  void Function(Json? me)? onSession;

  /// Called when the server asks for re-authentication. Should return true when the user confirmed.
  Future<bool> Function()? onReauthRequired;

  bool get hasToken => _accessToken != null;
  String? get token => _accessToken;

  void setToken(String? token, {int? expiresIn}) {
    _accessToken = token;
    _expiresAt = token == null || expiresIn == null ? null : DateTime.now().add(Duration(seconds: expiresIn));
  }

  Uri uri(String path, [Map<String, Object?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      q[k] = v is DateTime ? v.toUtc().toIso8601String() : '$v';
    });
    final u = Uri.parse('$baseUrl/v1$path');
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  Map<String, String> _headers({String? idempotencyKey, bool json = true}) => {
        'accept': 'application/json',
        if (json) 'content-type': 'application/json',
        'x-correlation-id': 'pwa-${newIdempotencyKey()}',
        'x-device-id': _platform.deviceId(),
        if (_accessToken != null) 'authorization': 'Bearer $_accessToken',
        if (idempotencyKey != null) 'idempotency-key': idempotencyKey,
      };

  Future<dynamic> get(String path, {Map<String, Object?>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body, String? idempotencyKey}) => _send('POST', path, body: body ?? const {}, idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<dynamic> put(String path, {Object? body, String? idempotencyKey}) => _send('PUT', path, body: body ?? const {}, idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<dynamic> patch(String path, {Object? body, String? idempotencyKey}) => _send('PATCH', path, body: body ?? const {}, idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<dynamic> delete(String path, {String? idempotencyKey}) => _send('DELETE', path, idempotencyKey: idempotencyKey ?? newIdempotencyKey());

  Future<void> _ensureFresh(String path) async {
    if (path.startsWith('/auth/') && !path.startsWith('/auth/me') && !path.startsWith('/auth/sessions') && !path.startsWith('/auth/reauth') && !path.startsWith('/auth/logout')) return;
    if (_refreshing != null) {
      await _refreshing;
    }
    final exp = _expiresAt;
    if (_accessToken == null || (exp != null && DateTime.now().isAfter(exp.subtract(const Duration(seconds: 30))))) {
      final savedRt = _platform.readLocal('shrm_rt');
      if (savedRt != null && savedRt.isNotEmpty) {
        await refresh();
      }
    }
  }

  Future<dynamic> _send(String method, String path, {Map<String, Object?>? query, Object? body, String? idempotencyKey, bool retried = false, bool authRetried = false, bool reauthRetried = false}) async {
    await _ensureFresh(path);
    final req = http.Request(method, uri(path, query))..headers.addAll(_headers(idempotencyKey: idempotencyKey, json: body != null));
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      if (!retried && idempotencyKey != null) return _send(method, path, query: query, body: body, idempotencyKey: idempotencyKey, retried: true, authRetried: authRetried);
      throw ApiException.timeout();
    } catch (_) {
      if (!retried && method != 'GET' && idempotencyKey != null) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return _send(method, path, query: query, body: body, idempotencyKey: idempotencyKey, retried: true, authRetried: authRetried);
      }
      throw ApiException.network();
    }
    if (res.statusCode == 401 && !authRetried && !path.startsWith('/auth/refresh')) {
      final err = _error(res);
      if (err.code == 'TOKEN_EXPIRED' || (err.code == 'UNAUTHENTICATED' && _accessToken != null)) {
        if (await refresh()) return _send(method, path, query: query, body: body, idempotencyKey: idempotencyKey, retried: retried, authRetried: true);
      }
      throw err;
    }
    if (res.statusCode == 403 && !reauthRetried && onReauthRequired != null) {
      final err = _error(res);
      if (err.code == 'REAUTH_REQUIRED') {
        if (await onReauthRequired!()) {
          // A new idempotency key: the first attempt was rejected before running.
          return _send(method, path, query: query, body: body, idempotencyKey: idempotencyKey == null ? null : newIdempotencyKey(), retried: retried, authRetried: authRetried, reauthRetried: true);
        }
      }
      throw err;
    }
    if (res.statusCode >= 400) throw _error(res);
    if (res.body.isEmpty) return null;
    final ct = res.headers['content-type'] ?? '';
    if (!ct.contains('json')) return res.body;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  ApiException _error(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final e = (j is Map ? j['error'] : null) as Map<String, dynamic>?;
      if (e != null) {
        return ApiException(
          status: res.statusCode,
          code: e['code'] as String? ?? 'ERROR',
          message: e['message'] as String? ?? 'Something went wrong.',
          details: [
            for (final d in (e['details'] as List? ?? const []))
              if (d is Map) FieldError('${d['field'] ?? ''}', '${d['message'] ?? ''}'),
          ],
          meta: (e['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
          correlationId: e['correlationId'] as String? ?? res.headers['x-correlation-id'],
        );
      }
    } catch (_) {}
    return ApiException(status: res.statusCode, code: 'HTTP_${res.statusCode}', message: 'Something went wrong (${res.statusCode}).', correlationId: res.headers['x-correlation-id']);
  }

  /// Exchanges the refresh cookie or saved token for a new access token. Single-flight.
  Future<bool> refresh() {
    return _refreshing ??= () async {
      try {
        final savedRt = _platform.readLocal('shrm_rt');
        final req = http.Request('POST', uri('/auth/refresh'))
          ..headers.addAll(_headers()..remove('authorization'));
        if (savedRt != null && savedRt.isNotEmpty) {
          req.body = jsonEncode({'refreshToken': savedRt});
        }
        final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 6)));
        if (res.statusCode != 200) {
          // Only clear stored session on definitive auth rejection (401 / 403).
          // Temporary server wakeup / cold start (5xx) must NOT wipe the user's session!
          if (res.statusCode == 401 || res.statusCode == 403) {
            _platform.writeLocal('shrm_rt', null);
            _platform.writeLocal('shrm_me', null);
            setToken(null);
            onSession?.call(null);
          }
          return false;
        }
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Json;
        final nextRt = j['refreshToken'] as String?;
        if (nextRt != null && nextRt.isNotEmpty) {
          _platform.writeLocal('shrm_rt', nextRt);
        }
        setToken(j['accessToken'] as String?, expiresIn: (j['expiresIn'] as num?)?.toInt());
        onSession?.call(j['me'] as Json?);
        return true;
      } catch (_) {
        return false; // network: keep the current state, the next call will try again
      } finally {
        _refreshing = null;
      }
    }();
  }

  /// Downloads a binary (file content, PDF, CSV export) with the same auth.
  Future<DownloadedFile> download(String path, {Map<String, Object?>? query, bool retried = false}) async {
    await _ensureFresh(path);
    final req = http.Request('GET', uri(path, query))..headers.addAll(_headers(json: false)..['accept'] = '*/*');
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 60)));
    } catch (_) {
      throw ApiException.network();
    }
    if (res.statusCode == 401 && !retried && await refresh()) return download(path, query: query, retried: true);
    if (res.statusCode == 403 && !retried && onReauthRequired != null) {
      final err = _error(res);
      if (err.code == 'REAUTH_REQUIRED' && await onReauthRequired!()) return download(path, query: query, retried: true);
      throw err;
    }
    if (res.statusCode >= 400) throw _error(res);
    final cd = res.headers['content-disposition'] ?? '';
    final m = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''').firstMatch(cd);
    final name = m == null ? 'download' : Uri.decodeComponent(m.group(1)!);
    return DownloadedFile(res.bodyBytes, name, res.headers['content-type'] ?? 'application/octet-stream');
  }

  /// Multipart upload to `POST /files`. Returns the stored file record.
  Future<Json> upload(PickedFile file, {required String purpose, Map<String, String> fields = const {}}) async {
    await _ensureFresh('/files');
    final req = http.MultipartRequest('POST', uri('/files'))
      ..headers.addAll(_headers(idempotencyKey: newIdempotencyKey(), json: false))
      ..fields.addAll({'purpose': purpose, ...fields})
      ..files.add(http.MultipartFile.fromBytes('file', file.bytes, filename: file.name, contentType: _mediaType(file.mimeType)));
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 120)));
    } catch (_) {
      throw ApiException.network();
    }
    if (res.statusCode >= 400) throw _error(res);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Json;
  }
}

MediaType? _mediaType(String mime) {
  try {
    return MediaType.parse(mime);
  } catch (_) {
    return null;
  }
}
