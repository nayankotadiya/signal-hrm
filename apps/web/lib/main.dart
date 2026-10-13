import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'app/config.dart';
import 'app/services.dart';
import 'data/api.dart';
import 'data/demo_backend.dart';
import 'data/health_api.dart';

Future<void> main() async {
  usePathUrlStrategy(); // clean URLs: /gallery instead of /#/gallery
  if (AppConfig.demo) {
    WidgetsFlutterBinding.ensureInitialized();
    final demo = await DemoBackend.load();
    runApp(SignalApp(
      services: AppServices(
        api: ApiClient(DemoBackend.baseUrl, client: demo.client),
        health: HealthApi(DemoBackend.baseUrl, client: demo.client),
      ),
    ));
    return;
  }
  runApp(const SignalApp());
}
