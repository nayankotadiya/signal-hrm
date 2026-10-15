import 'package:flutter/foundation.dart';

import '../data/api.dart';
import '../platform/bridge.dart';
import 'permissions.dart';

enum SessionStatus { unknown, signedOut, signedIn }

/// The signed-in user as returned by `GET /v1/auth/me`.
class Me {
  Me(this.raw)
      : permissions = PermissionSet.fromStrings(((raw['permissions'] as List?) ?? const []).map((e) => '$e'), role: '${raw['role'] ?? 'user'}');

  final Json raw;
  final PermissionSet permissions;

  Json get user => (raw['user'] as Map?)?.cast<String, dynamic>() ?? const {};
  Json? get employee => (raw['employee'] as Map?)?.cast<String, dynamic>();
  Json get organization => (raw['organization'] as Map?)?.cast<String, dynamic>() ?? const {};
  Json get features => (organization['features'] as Map?)?.cast<String, dynamic>() ?? const {};
  Json? get preferences => (raw['preferences'] as Map?)?.cast<String, dynamic>();
  Json get attendanceSettings => (organization['attendance'] as Map?)?.cast<String, dynamic>() ?? const {};

  String get role => '${raw['role'] ?? 'user'}';
  bool get isSuperAdmin => role == 'super_admin';
  String get userId => '${user['id'] ?? ''}';
  String? get employeeId => employee?['id'] as String?;
  String get name => '${user['displayName'] ?? user['fullName'] ?? ''}';
  String get fullName => '${user['fullName'] ?? name}';
  String? get email => user['email'] as String?;
  String get orgName => '${organization['name'] ?? ''}';
  String get timezone => '${organization['timezone'] ?? 'Asia/Kolkata'}';
  String get currency => '${organization['currency'] ?? 'INR'}';
  int get weekStart => (organization['weekStart'] as num?)?.toInt() ?? 1;
  bool get pending => user['status'] == 'pending';
  bool get hasPassword => user['hasPassword'] == true;

  /// An administrator issued a temporary password: the person must choose their own first.
  bool get mustChangePassword => user['mustChangePassword'] == true;

  /// Modules are on unless the organization switched them off (AI assistant is off by default).
  bool feature(String key) {
    final v = features[key];
    if (v is bool) return v;
    return key != 'ai_assistant';
  }

  bool can(String resource, String action, [String atLeast = 'own']) => permissions.can(resource, action, atLeast);
}

class OtpSent {
  const OtpSent({
    required this.destination,
    required this.resendAfterSeconds,
  });
  final String destination;
  final int resendAfterSeconds;
}

/// Owns sign-in state. The access token lives in [ApiClient] memory; a page reload restores the
/// session through the httpOnly refresh cookie.
class SessionController extends ChangeNotifier {
  SessionController(this.api) {
    api.onSession = (me) {
      if (me == null) {
        if (_status == SessionStatus.signedIn) {
          _me = null;
          _status = SessionStatus.signedOut;
          expiredNotice = true;
          notifyListeners();
        }
      } else {
        _apply(me);
      }
    };
  }

  final ApiClient api;
  SessionStatus _status = SessionStatus.unknown;
  Me? _me;

  /// Set when the session ended on its own (expired / revoked), so the login page can say so.
  bool expiredNotice = false;

  SessionStatus get status => _status;
  Me? get me => _me;
  PermissionSet get permissions => _me?.permissions ?? PermissionSet.empty;

  void _apply(Json me) {
    final next = Me(me);
    final changed = _me == null || _me!.permissions.signature != next.permissions.signature || _me!.raw['user'].toString() != next.raw['user'].toString() || _me!.features.toString() != next.features.toString();
    _me = next;
    _status = SessionStatus.signedIn;
    if (changed) notifyListeners();
  }

  Future<void> restore() async {
    final savedRt = bridge.readLocal('shrm_rt');
    if (savedRt == null || savedRt.isEmpty) {
      if (_status == SessionStatus.unknown) {
        _status = SessionStatus.signedOut;
        notifyListeners();
      }
      return;
    }
    final ok = await api.refresh();
    if (!ok && _status == SessionStatus.unknown) {
      if (bridge.readLocal('shrm_rt') == null) {
        _status = SessionStatus.signedOut;
        notifyListeners();
      }
    }
  }

  void _signedIn(dynamic j) {
    final m = j as Json;
    api.setToken(m['accessToken'] as String?, expiresIn: (m['expiresIn'] as num?)?.toInt());
    final rt = m['refreshToken'] as String?;
    if (rt != null && rt.isNotEmpty) {
      bridge.writeLocal('shrm_rt', rt);
    }
    expiredNotice = false;
    _me = null;
    _apply((m['me'] as Map).cast<String, dynamic>());
  }

  Future<OtpSent> requestOtp(String identifier) async {
    final j = await api.post('/auth/otp/request', body: {'identifier': identifier.trim()}) as Json;
    return OtpSent(
      destination: '${j['destination'] ?? identifier}',
      resendAfterSeconds: (j['resendAfterSeconds'] as num?)?.toInt() ?? 60,
    );
  }

  Future<void> verifyOtp(String identifier, String code, {bool rememberMe = true}) async =>
      _signedIn(await api.post('/auth/otp/verify', body: {'identifier': identifier.trim(), 'code': code.trim(), 'deviceName': 'Web browser', 'rememberMe': rememberMe}));
  Future<void> google(String idToken) async => _signedIn(await api.post('/auth/google', body: {'idToken': idToken, 'deviceName': 'Web browser'}));
  Future<void> apple(String idToken) async => _signedIn(await api.post('/auth/apple', body: {'idToken': idToken, 'deviceName': 'Web browser'}));
  Future<void> password(String identifier, String password, {bool rememberMe = true}) async =>
      _signedIn(await api.post('/auth/password', body: {'identifier': identifier.trim(), 'password': password, 'rememberMe': rememberMe}));
  Future<void> acceptInvitation(String token, String code) async => _signedIn(await api.post('/auth/invitations/accept', body: {'token': token, 'code': code.trim()}));
  Future<void> recover(String identifier, String code) async => _signedIn(await api.post('/auth/recover', body: {'identifier': identifier.trim(), 'recoveryCode': code.trim()}));

  Future<void> reloadMe() async {
    final j = await api.get('/auth/me') as Json;
    _apply(j);
    notifyListeners();
  }

  Future<void> signOut() async {
    bridge.writeLocal('shrm_rt', null);
    try {
      await api.post('/auth/logout');
    } catch (_) {
      // Signing out locally still matters if the network is down.
    }
    api.setToken(null);
    _me = null;
    _status = SessionStatus.signedOut;
    notifyListeners();
  }
}
