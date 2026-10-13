import 'package:flutter/widgets.dart';

import '../data/api.dart';
import '../data/health_api.dart';
import 'config.dart';
import 'permissions.dart';
import 'session.dart';

/// App-wide services, injectable so tests can use fakes.
class AppServices {
  AppServices({HealthApi? health, ApiClient? api, SessionController? session})
      : health = health ?? HealthApi(AppConfig.apiBaseUrl),
        api = api ?? ApiClient(AppConfig.apiBaseUrl) {
    this.session = session ?? SessionController(this.api);
  }

  final HealthApi health;
  final ApiClient api;
  late final SessionController session;

  /// Unread notification count shown on the bell; updated by the shell and the notification center.
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  PermissionSet get permissions => session.permissions;
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({super.key, required this.services, required super.child});
  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'No ServicesScope above this context');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => services != oldWidget.services;
}

/// Rebuilds dependents when the session (user, permissions, features) changes.
class SessionScope extends InheritedNotifier<SessionController> {
  const SessionScope({super.key, required SessionController session, required super.child}) : super(notifier: session);

  static SessionController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'No SessionScope above this context');
    return scope!.notifier!;
  }
}

extension ServicesX on BuildContext {
  AppServices get services => ServicesScope.of(this);
  ApiClient get api => ServicesScope.of(this).api;
  Me get me => SessionScope.of(this).me!;
  Me? get maybeMe => SessionScope.of(this).me;
}
