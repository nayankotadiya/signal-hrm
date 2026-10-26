import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Demo mode backend (`--dart-define=DEMO=true`).
///
/// Serves responses that were recorded from the real Signal HRM API running with the demo seed
/// data (`npm run seed:demo`), so every screen shows exactly what the server would return. Nothing
/// is sent anywhere and nothing is saved: changes are acknowledged but not stored, except the
/// check-in / check-out walk-through, which follows the recorded server responses.
class DemoBackend {
  DemoBackend._(this._fixtures);

  static const baseUrl = 'https://demo.signal-hrm.invalid/api';

  final Map<String, dynamic> _fixtures;
  String _role = 'super_admin';
  int _attendanceStep = 0; // 0: not_checked_in, 1: checked_in, 2: on_break, 3: session_2_active, 4: checked_out
  Map<String, dynamic>? _session1CheckIn;
  Map<String, dynamic>? _session1CheckOut;
  Map<String, dynamic>? _session2CheckIn;
  Map<String, dynamic>? _session2CheckOut;

  Map<String, dynamic> _makePunch(Map<String, dynamic> body, String label, String defaultIso) {
    return {
      'at': defaultIso,
      'method': 'geofence',
      'label': label,
      'latitude': body['latitude'] ?? 23.0225,
      'longitude': body['longitude'] ?? 72.5714,
      'accuracyMeters': body['accuracyMeters'] ?? 12,
      'locationId': '6acd16ce62a34a601a08c860',
      'distanceMeters': 0,
      'verification': 'within_radius',
      'deviceId': 'demo-device-1',
      'ip': '127.0.0.1',
      'address': body['address'] ?? 'Bulletproof Brands HQ, S.G. Highway, Bodakdev, Ahmedabad',
      'selfieFileId': body['selfieFileId'] ?? 'file-demo-selfie',
      'queuedOffline': false,
    };
  }

  Map<String, dynamic> _getTodayAttendance() {
    final base = jsonDecode(jsonEncode(_fixtures['GET /attendance/today'])) as Map<String, dynamic>;
    final workDate = base['workDate'] as String? ?? '2026-10-12';

    String state;
    if (_attendanceStep == 0) {
      state = 'not_checked_in';
    } else if (_attendanceStep == 1) {
      state = 'checked_in';
    } else if (_attendanceStep == 2) {
      state = 'on_break';
    } else if (_attendanceStep == 3) {
      state = 'session_2_active';
    } else {
      state = 'checked_out';
    }

    base['state'] = state;
    base['step'] = _attendanceStep;
    base['totalSteps'] = 4;
    base['trackBreakPunches'] = true;
    base['twoPunchesPerDayCount'] = true;
    base['attendanceDayCount'] = _attendanceStep == 4 ? 1.0 : (_attendanceStep >= 2 ? 0.5 : 0.0);

    if (_attendanceStep == 0) {
      base['record'] = null;
      return base;
    }

    final record = <String, dynamic>{
      'id': 'rec-demo-$workDate',
      'organizationId': '6acd16cd62a34a601a08c785',
      'employeeId': '6acd16ce62a34a601a08c866',
      'workDate': workDate,
      'status': _attendanceStep == 4 ? 'present' : (_attendanceStep >= 2 ? 'half_day' : 'late'),
      'dayCount': _attendanceStep == 4 ? 1.0 : (_attendanceStep >= 2 ? 0.5 : 0.0),
      'workedMinutes': _attendanceStep == 4 ? 480 : (_attendanceStep >= 2 ? 210 : 0),
      'breakMinutes': _attendanceStep >= 3 ? 60 : 0,
      'lateMinutes': 0,
      'earlyLeaveMinutes': 0,
      'shiftId': '6acd16ce62a34a601a08c862',
      'session1': {
        'checkIn': _session1CheckIn,
        'checkOut': _session1CheckOut,
        'workedMinutes': _session1CheckOut != null ? 210 : 0,
      },
      'session2': {
        'checkIn': _session2CheckIn,
        'checkOut': _session2CheckOut,
        'workedMinutes': _session2CheckOut != null ? 270 : 0,
      },
      'checkIn': _session1CheckIn,
      'checkOut': _session2CheckOut ?? _session1CheckOut,
    };

    base['record'] = record;
    return base;
  }

  Map<String, dynamic> _getMe() {
    final base = jsonDecode(jsonEncode(_fixtures['GET /auth/me'])) as Map<String, dynamic>;
    final rolesList = (_fixtures['GET /roles'] as Map<String, dynamic>?)?['items'] as List<dynamic>? ?? [];

    if (_role == 'manager') {
      final mgrRole = rolesList.firstWhere((r) => r is Map && r['key'] == 'manager', orElse: () => null);
      final grants = mgrRole != null ? mgrRole['grants'] : null;
      base['role'] = 'manager';
      base['permissions'] = grants ?? [
        'privacy:export:own',
        'notifications:view:own',
        'employees:view:own',
        'attendance:view:own',
        'attendance:create:own',
        'shifts:view:own',
        'shifts:create:own',
        'leave:view:own',
        'leave:create:own',
        'expenses:view:own',
        'expenses:create:own',
        'travel:view:own',
        'travel:create:own',
        'tasks:view:own',
        'tasks:edit:own',
        'meetings:view:own',
        'meetings:create:own',
        'documents:view:own',
        'payslips:view:own',
        'approvals:view:own',
        'holidays:view:organization',
        'announcements:view:organization',
        'employees:view:team',
        'attendance:view:team',
        'attendance:approve:team',
        'attendance:reject:team',
        'shifts:view:team',
        'shifts:approve:team',
        'shifts:reject:team',
        'leave:view:team',
        'leave:approve:team',
        'leave:reject:team',
        'expenses:view:team',
        'expenses:approve:team',
        'expenses:reject:team',
        'travel:view:team',
        'travel:approve:team',
        'travel:reject:team',
        'tasks:view:team',
        'tasks:create:team',
        'tasks:edit:team',
        'tasks:assign:team',
        'meetings:view:team',
        'meetings:create:team',
        'meetings:edit:team',
        'approvals:view:team',
        'approvals:approve:team',
        'approvals:reject:team',
        'reports:view:team',
        'teams:view:team',
      ];
      final user = base['user'] as Map<String, dynamic>;
      user['fullName'] = 'Rohan Joshi';
      user['displayName'] = 'Rohan';
      user['role'] = 'manager';
      user['email'] = 'rohan.joshi@demo.signal-hrm.test';
      final emp = _fixtures['GET /employees/6acd16ce62a34a601a08c87a'];
      if (emp != null) base['employee'] = emp;
    } else if (_role == 'employee') {
      final empRole = rolesList.firstWhere((r) => r is Map && r['key'] == 'employee', orElse: () => null);
      final grants = empRole != null ? empRole['grants'] : null;
      base['role'] = 'employee';
      base['permissions'] = grants ?? [
        'privacy:export:own',
        'notifications:view:own',
        'employees:view:own',
        'attendance:view:own',
        'attendance:create:own',
        'shifts:view:own',
        'shifts:create:own',
        'leave:view:own',
        'leave:create:own',
        'expenses:view:own',
        'expenses:create:own',
        'travel:view:own',
        'travel:create:own',
        'tasks:view:own',
        'tasks:edit:own',
        'meetings:view:own',
        'meetings:create:own',
        'documents:view:own',
        'payslips:view:own',
        'approvals:view:own',
        'holidays:view:organization',
        'announcements:view:organization',
      ];
      final user = base['user'] as Map<String, dynamic>;
      user['fullName'] = 'Anaya Kulkarni';
      user['displayName'] = 'Anaya';
      user['role'] = 'employee';
      user['email'] = 'anaya.kulkarni@demo.signal-hrm.test';
      final emp = _fixtures['GET /employees/6acd16ce62a34a601a08c889'];
      if (emp != null) base['employee'] = emp;
    }
    return base;
  }

  Map<String, dynamic> _getDashboard() {
    final base = jsonDecode(jsonEncode(_fixtures['GET /dashboard'])) as Map<String, dynamic>;
    final balances = (_fixtures['GET /leave/balances'] as Map<String, dynamic>?)?['items'] as List<dynamic>? ?? [];

    final me = (base['me'] as Map<String, dynamic>?) ?? {};
    if (balances.isNotEmpty) {
      me['leaveBalances'] = balances.take(3).map((b) => {
        'leaveTypeId': b['leaveTypeId'],
        'code': b['code'],
        'name': b['name'],
        'color': b['color'],
        'total': b['entitled'] ?? 5,
        'used': b['used'] ?? 0,
        'pending': b['pending'] ?? 0,
        'available': b['available'] ?? 5,
      }).toList();
    }
    me['latestPayslip'] = {
      'period': 'Sep 2026',
      'net': _role == 'employee' ? 62000 : (_role == 'manager' ? 95000 : 120000),
      'publishedAt': '2026-10-01T00:00:00.000Z',
    };
    base['me'] = me;

    if (_role == 'employee') {
      base['team'] = null;
      base['organization'] = null;
      base['system'] = null;
      base['attention'] = <dynamic>[];
    } else if (_role == 'manager') {
      base['organization'] = null;
      base['system'] = null;
      base['team'] = {
        'headcount': 5,
        'today': {'checkedIn': 4, 'late': 1, 'onLeave': 0, 'notCheckedIn': 0},
        'trend': base['organization']?['trend'] ?? <dynamic>[],
        'tasksByStatus': {'todo': 3, 'in_progress': 5, 'completed': 8},
        'approvalsWaiting': 2,
      };
      base['attention'] = [
        {
          'snoozable': true,
          'key': 'approvals.pending',
          'severity': 'warning',
          'title': 'Pending team approvals',
          'detail': '2 leave requests waiting for your approval.',
          'count': 2,
          'link': '/approvals',
        }
      ];
    }
    return base;
  }

  static Future<DemoBackend> load() async {
    final raw = await rootBundle.loadString('assets/demo/fixtures.json');
    return DemoBackend._(jsonDecode(raw) as Map<String, dynamic>);
  }

  http.Client get client => MockClient(_handle);

  static const _emptyPage = {'items': <Object>[], 'page': 1, 'limit': 25, 'total': 0, 'hasMore': false};

  http.Response _json(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  http.Response _error(int status, String code, String message) =>
      _json({'error': {'status': status, 'code': code, 'message': message, 'correlationId': 'demo'}}, status);

  Future<http.Response> _handle(http.Request req) async {
    await Future<void>.delayed(const Duration(milliseconds: 180)); // feel like a network
    var path = req.url.path;
    final i = path.indexOf('/v1/');
    if (i >= 0) path = path.substring(i + 3);
    final method = req.method;

    if (method == 'GET') {
      if (path == '/demo/role') return _json({'role': _role});
      if (path == '/auth/me') return _json(_getMe());
      if (path == '/dashboard') return _json(_getDashboard());
      if (path == '/attendance/today') return _json(_getTodayAttendance());
      if (path == '/integrations') {
        return _json([
          {
            'provider': 'slack',
            'status': 'connected',
            'available': true,
            'webhookConfigured': true,
            'connection': {
              'id': 'conn-slack-1',
              'name': 'Slack Attendance Alerts',
              'status': 'connected',
              'config': {
                'channelName': '#attendance-alerts',
                'notifyCheckIn': true,
                'notifyCheckOut': true,
                'notifyReminder': true,
              },
              'lastSyncAt': DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String(),
            },
            'last24h': {'success': 18, 'failed': 0},
          },
          {
            'provider': 'whatsapp',
            'status': 'connected',
            'available': true,
            'webhookConfigured': true,
            'connection': {
              'id': 'conn-wa-1',
              'name': 'WhatsApp Cloud Alerts',
              'status': 'connected',
              'config': {
                'phoneNumberId': '108294729102941',
                'recipientNumber': '+919876543210',
                'notifyCheckIn': true,
                'notifyCheckOut': true,
                'notifyReminder': true,
              },
              'lastSyncAt': DateTime.now().subtract(const Duration(minutes: 42)).toIso8601String(),
            },
            'last24h': {'success': 14, 'failed': 0},
          },
          {
            'provider': 'meta_leads',
            'status': 'disabled',
            'available': true,
            'webhookConfigured': true,
            'connection': null,
            'last24h': {},
          },
          {
            'provider': 'sms',
            'status': 'disabled',
            'available': false,
            'webhookConfigured': false,
            'connection': null,
            'last24h': {},
          },
        ]);
      }
      final hit = _fixtures['GET $path'];
      if (hit != null) return _json(hit);
      final found = _findInParentList(path);
      if (found != null) return _json(found);
      if (path.endsWith('/content')) {
        final byteData = await rootBundle.load('assets/demo/selfie.jpg');
        return http.Response.bytes(byteData.buffer.asUint8List(), 200, headers: {'content-type': 'image/jpeg'});
      }
      if (path.contains('/export') || path.endsWith('/bank-file')) {
        return _error(404, 'DEMO_UNAVAILABLE', 'Downloads are not available in demo mode.');
      }
      return _json(_emptyPage);
    }

    Map<String, dynamic> body = {};
    final contentType = req.headers['content-type'] ?? '';
    if (contentType.contains('json') && req.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(req.bodyBytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {}
    }

    if (path == '/demo/role') {
      final target = body['role'] as String?;
      if (target != null) _role = target;
      return _json({'role': _role});
    }

    // Sign-in: any code works in demo mode.
    if (path == '/auth/refresh' || path == '/auth/otp/verify' || path == '/auth/reauth/verify') {
      final refresh = jsonDecode(jsonEncode(_fixtures['POST /auth/refresh'])) as Map<String, dynamic>;
      refresh['me'] = _getMe();
      return _json(refresh);
    }
    if (path == '/auth/otp/request' || path == '/auth/reauth/request') return _json({'sent': true, 'resendAfterSeconds': 30});
    if (path == '/auth/logout') return http.Response('', 204);

    if (path == '/attendance/check-in') {
      final nowStr = DateTime.now().toUtc().toIso8601String();
      if (_attendanceStep == 0) {
        _session1CheckIn = _makePunch(body, '1. Check In', nowStr);
        _attendanceStep = 1;
      } else if (_attendanceStep >= 2) {
        _session2CheckIn = _makePunch(body, '3. Break Out', nowStr);
        _attendanceStep = 3;
      }
      final today = _getTodayAttendance();
      final rec = today['record'] as Map<String, dynamic>;
      return _json({
        'record': rec,
        'state': today['state'],
        'step': today['step'],
        'attendanceDayCount': today['attendanceDayCount'],
        'checkIn': rec['checkIn'],
      });
    }

    if (path == '/attendance/check-out') {
      final nowStr = DateTime.now().toUtc().toIso8601String();
      if (_attendanceStep == 1) {
        _session1CheckOut = _makePunch(body, '2. Break In', nowStr);
        _attendanceStep = 2;
      } else if (_attendanceStep >= 3) {
        _session2CheckOut = _makePunch(body, '4. Check Out', nowStr);
        _attendanceStep = 4;
      }
      final today = _getTodayAttendance();
      final rec = today['record'] as Map<String, dynamic>;
      return _json({
        'record': rec,
        'state': today['state'],
        'step': today['step'],
        'attendanceDayCount': today['attendanceDayCount'],
        'checkOut': rec['checkOut'],
      });
    }

    if (path == '/attendance/reset-demo') {
      _attendanceStep = 0;
      _session1CheckIn = null;
      _session1CheckOut = null;
      _session2CheckIn = null;
      _session2CheckOut = null;
      return _json({'status': 'reset', 'state': 'not_checked_in'});
    }

    if (path == '/files') {
      return _json({
        'id': 'file-demo-${DateTime.now().microsecondsSinceEpoch}',
        'name': 'selfie.jpg',
        'mimeType': 'image/jpeg',
        'size': 1024,
        'purpose': 'selfie',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }, 201);
    }

    if (path.startsWith('/integrations/') && path.endsWith('/test')) {
      final provider = path.split('/')[2];
      return _json({
        'success': true,
        'message': provider == 'slack'
            ? 'Test alert sent to Slack channel.'
            : 'Test alert sent via WhatsApp.',
      });
    }

    // Every other change is acknowledged but not stored.

    if (path.startsWith('/organization/settings/') && (method == 'PUT' || method == 'PATCH')) {
      final section = path.substring('/organization/settings/'.length);
      final org = _fixtures['GET /organization'] as Map<String, dynamic>?;
      if (org != null) {
        final settings = org['settings'] as Map<String, dynamic>?;
        if (settings != null) {
          final cur = settings[section] as Map<String, dynamic>? ?? {};
          settings[section] = {...cur, ...body};
          if (section == 'attendance') {
            final today = _fixtures['GET /attendance/today'] as Map<String, dynamic>?;
            if (today != null) {
              final req = today['requirements'] as Map<String, dynamic>? ?? {};
              if (body['checkIn'] is Map) req['checkIn'] = body['checkIn'];
              if (body['checkOut'] is Map) req['checkOut'] = body['checkOut'];
              today['requirements'] = req;
            }
          }
        }
      }
      return _json(org ?? {'id': 'demo-org', ...body});
    }

    if (method == 'DELETE') return http.Response('', 204);
    return _json({'id': 'demo-${DateTime.now().microsecondsSinceEpoch}', 'status': 'pending', ...body, 'demo': true}, method == 'POST' ? 201 : 200);
  }

  /// `/employees/<id>` → the matching row of `GET /employees`.
  Object? _findInParentList(String path) {
    final cut = path.lastIndexOf('/');
    if (cut <= 0) return null;
    final parent = _fixtures['GET ${path.substring(0, cut)}'];
    final id = path.substring(cut + 1);
    if (parent is Map && parent['items'] is List) {
      for (final row in parent['items'] as List) {
        if (row is Map && (row['id'] == id || row['key'] == id)) return row;
      }
    }
    return null;
  }

}
