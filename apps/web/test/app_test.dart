import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:n_ui/n_ui.dart';
import 'package:signal_hrm_web/app/app.dart';
import 'package:signal_hrm_web/app/permissions.dart';
import 'package:signal_hrm_web/app/services.dart';
import 'package:signal_hrm_web/data/api.dart';
import 'package:signal_hrm_web/data/health_api.dart';

/// A fake API: the widget tests exercise the real ApiClient, SessionController and router.
Map<String, dynamic> _me(String role, List<String> permissions) => {
      'user': {'id': 'u1', 'fullName': 'Meera Iyer', 'displayName': 'Meera', 'email': 'meera@example.test', 'role': role, 'status': 'active'},
      'employee': {'id': 'e1', 'firstName': 'Meera', 'lastName': 'Iyer'},
      'organization': {'id': 'o1', 'name': 'Bulletproof Brands', 'timezone': 'Asia/Kolkata', 'currency': 'INR', 'weekStart': 1, 'features': <String, dynamic>{}},
      'role': role,
      'permissions': permissions,
      'preferences': null,
    };

const _employeeGrants = [
  'attendance:view:own',
  'attendance:create:own',
  'leave:view:own',
  'leave:create:own',
  'expenses:view:own',
  'expenses:create:own',
  'tasks:view:own',
  'approvals:view:own',
  'documents:view:own',
  'payslips:view:own',
  'holidays:view:organization',
  'announcements:view:organization',
  'notifications:view:own',
  'privacy:export:own',
];

Map<String, dynamic> _dashboard() => {
      'generatedAt': '2026-10-12T06:00:00.000Z',
      'today': '2026-10-12',
      'timezone': 'Asia/Kolkata',
      'me': {
        'attendance': null,
        'leaveBalances': [
          {'leaveTypeId': 't1', 'code': 'CL', 'name': 'Casual Leave', 'total': 12, 'used': 2, 'pending': 0, 'available': 10},
        ],
        'pendingRequests': {'leave': 1, 'expenses': 0, 'corrections': 0},
        'tasks': {'byStatus': {'todo': 3}, 'due': []},
        'upcomingHolidays': [],
        'announcements': [],
        'upcomingEvents': [],
        'latestPayslip': null,
      },
      'team': null,
      'organization': null,
      'system': null,
      'attention': [
        {'key': 'me.tasks_overdue', 'severity': 'warning', 'title': 'Overdue tasks', 'count': 2, 'link': '/tasks?filter=overdue', 'snoozable': true},
      ],
      'snoozed': [],
    };

Map<String, dynamic> _today() => {
      'serverTime': '2026-10-12T06:00:00.000Z',
      'workDate': '2026-10-12',
      'timezone': 'Asia/Kolkata',
      'record': null,
      'state': 'not_checked_in',
      'shift': {'name': 'General', 'startTime': '10:00', 'endTime': '19:00'},
      'location': {'id': 'l1', 'name': 'Ahmedabad studio', 'radiusMeters': 150},
      'requirements': {
        'checkIn': {'requireLocation': true, 'requireSelfie': false},
        'checkOut': {'requireLocation': true, 'requireSelfie': false},
        'maxAccuracyMeters': 50,
        'allowRemote': false,
        'gpsRetryLimit': 2,
      },
      'gpsFailuresToday': 0,
      'exceptionAvailable': false,
      'holiday': null,
      'onLeave': null,
    };

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

AppServices _services({required bool signedIn, String role = 'employee', List<String> grants = _employeeGrants, List<String>? calls}) {
  final client = MockClient((req) async {
    calls?.add('${req.method} ${req.url.path}');
    final p = req.url.path.replaceFirst('/api/v1', '');
    if (p == '/auth/refresh') {
      if (!signedIn) return _json({'error': {'status': 401, 'code': 'UNAUTHENTICATED', 'message': 'Sign in to continue.', 'correlationId': 'c1'}}, 401);
      return _json({'accessToken': 'token-1', 'expiresIn': 900, 'sessionId': 's1', 'me': _me(role, grants)});
    }
    expect(req.headers['authorization'], 'Bearer token-1', reason: 'every call after sign-in carries the access token');
    expect(req.headers['x-device-id'], isNotEmpty);
    if (req.method != 'GET') expect(req.headers['idempotency-key'], isNotEmpty, reason: 'mutations always carry an Idempotency-Key');
    return switch (p) {
      '/dashboard' => _json(_dashboard()),
      '/dashboard/setup-checklist' => _json({'steps': [], 'done': 0, 'total': 0, 'requiredRemaining': 0}),
      '/attendance/today' => _json(_today()),
      '/notifications' => _json({'items': [], 'page': 1, 'limit': 1, 'total': 0, 'hasMore': false, 'unread': 3}),
      _ => _json({'items': [], 'page': 1, 'limit': 25, 'total': 0, 'hasMore': false}),
    };
  });
  return AppServices(
    api: ApiClient('http://test/api', client: client),
    health: HealthApi('http://test/api', client: MockClient((_) async => _json({'state': 'healthy', 'components': []}))),
  );
}

Future<void> _pump(WidgetTester tester, AppServices s, {Size size = const Size(1280, 900), double textScale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(SignalApp(services: s, initialPreferences: NPreferences(reducedMotion: true, textScale: textScale)));
  await tester.pumpAndSettle();
}

/// Pumps at [size] and fails with the full Flutter error report (including the file and line of
/// the widget that overflowed) instead of only the one-line summary.
Future<void> _expectNoLayoutErrors(WidgetTester tester, AppServices s, Size size, {double textScale = 1}) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await _pump(tester, s, size: size, textScale: textScale);
  } finally {
    FlutterError.onError = previous;
  }
  expect(errors, isEmpty, reason: 'at ${size.width}x${size.height}, text x$textScale:\n${errors.map((e) => e.toString()).join('\n\n')}');
}

void main() {
  test('permission strings parse; unknown ones are ignored; scopes rank', () {
    final p = PermissionSet.fromStrings(['leave:view:team', 'leave:view:own', 'bogus', 'payroll:fly:organization'], role: 'manager');
    expect(p.grants.length, 2);
    expect(p.can('leave', 'view', 'team'), isTrue);
    expect(p.can('leave', 'view', 'organization'), isFalse);
    expect(p.can('payroll', 'view'), isFalse);
  });

  testWidgets('signed out: the sign-in screen is shown and nothing private is requested', (tester) async {
    final calls = <String>[];
    await _pump(tester, _services(signedIn: false, calls: calls));
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Work email'), findsOneWidget);
    expect(calls, ['POST /api/v1/auth/refresh']);
  });

  testWidgets('employee: dashboard shows real data; navigation follows permissions', (tester) async {
    await _pump(tester, _services(signedIn: true));
    expect(find.text('Needs attention'), findsWidgets); // KPI label and the card title
    expect(find.text('Overdue tasks'), findsOneWidget);
    expect(find.text('Casual Leave'), findsOneWidget);
    expect(find.text('Check in'), findsOneWidget);
    // Employee: no Admin, People directory, Reports or System in the navigation.
    expect(find.text('Admin'), findsNothing);
    expect(find.text('System'), findsNothing);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Time'), findsWidgets);
  });

  testWidgets('Super Admin sees the admin and system areas', (tester) async {
    await _pump(tester, _services(signedIn: true, role: 'super_admin', grants: ['organization:configure:organization', 'system:view:organization', 'roles:view:organization', 'reports:view:organization', ..._employeeGrants]));
    expect(find.text('Admin'), findsWidgets);
    expect(find.text('System'), findsWidgets);
    expect(find.text('Reports'), findsWidgets);
  });

  testWidgets('layouts render without overflow at every test width', (tester) async {
    for (final w in const [360.0, 390.0, 430.0, 600.0, 768.0, 820.0, 1024.0, 1280.0, 1440.0, 1920.0]) {
      await _expectNoLayoutErrors(tester, _services(signedIn: true), Size(w, 900));
    }
  });

  testWidgets('200% text scale renders without overflow on mobile and desktop', (tester) async {
    for (final w in const [390.0, 1280.0]) {
      await _expectNoLayoutErrors(tester, _services(signedIn: true), Size(w, 1000), textScale: 2.0);
    }
  });
}
