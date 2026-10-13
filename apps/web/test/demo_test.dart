import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';
import 'package:signal_hrm_web/app/app.dart';
import 'package:signal_hrm_web/app/services.dart';
import 'package:signal_hrm_web/data/api.dart';
import 'package:signal_hrm_web/data/demo_backend.dart';
import 'package:signal_hrm_web/data/health_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('demo backend signs in, serves recorded data and walks through check-in', () async {
    final demo = await DemoBackend.load();
    final api = ApiClient(DemoBackend.baseUrl, client: demo.client);
    expect(await api.refresh(), isTrue);
    final dashboard = await api.get('/dashboard') as Map<String, dynamic>;
    expect(dashboard['me'], isNotNull);
    final employees = await api.get('/employees') as Map<String, dynamic>;
    expect((employees['items'] as List).length, greaterThan(5));
    final firstId = (employees['items'] as List).first['id'];
    final one = await api.get('/employees/$firstId') as Map<String, dynamic>;
    expect(one['id'], firstId);
    expect((await api.get('/attendance/today') as Map)['state'], 'not_checked_in');
    await api.post('/attendance/check-in', body: {'locationStatus': 'granted'});
    expect((await api.get('/attendance/today') as Map)['state'], 'checked_in');
  });

  testWidgets('demo mode opens on the dashboard with the recorded organization', (tester) async {
    final demo = await tester.runAsync(DemoBackend.load);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SignalApp(
      services: AppServices(api: ApiClient(DemoBackend.baseUrl, client: demo!.client), health: HealthApi(DemoBackend.baseUrl, client: demo.client)),
      initialPreferences: const NPreferences(reducedMotion: true),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Needs attention'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
