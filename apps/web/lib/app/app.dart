import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../features/auth/reauth_dialog.dart';
import '../l10n/gen/app_localizations.dart';
import '../widgets/async_view.dart';
import 'destinations.dart';
import 'preferences.dart';
import 'router.dart';
import 'services.dart';
import 'session.dart';

class SignalApp extends StatefulWidget {
  const SignalApp({super.key, this.services, this.initialPreferences = const NPreferences()});

  final AppServices? services;
  final NPreferences initialPreferences;

  @override
  State<SignalApp> createState() => _SignalAppState();
}

class _SignalAppState extends State<SignalApp> {
  late final PreferencesController _prefs = PreferencesController(widget.initialPreferences);
  late final AppServices _services = widget.services ?? AppServices();
  final GlobalKey<NavigatorState> _rootKey = GlobalKey<NavigatorState>();
  GoRouter? _router;
  String? _routerSignature;

  SessionController get _session => _services.session;
  Timer? _prefsSave;
  bool _applyingServerPrefs = false;

  /// Appearance changes are saved to the user's account (debounced) so they follow them across devices.
  void _onPrefs() {
    if (_applyingServerPrefs || _session.status != SessionStatus.signedIn) return;
    _prefsSave?.cancel();
    _prefsSave = Timer(const Duration(milliseconds: 800), () {
      _services.api.put('/me/preferences', body: {'nui': _prefs.value.toJson()}).catchError((_) => null);
    });
  }

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _prefs.addListener(_onPrefs);
    _services.api.onReauthRequired = () async {
      final ctx = _rootKey.currentContext;
      if (ctx == null) return false;
      return showReauthDialog(ctx, _services.api, usePassword: _session.me?.hasPassword ?? false);
    };
    _session.loadCached();
    _rebuildRouter();
    _session.restore();
  }

  /// Navigation is built from permissions and modules, so the router is rebuilt when they change
  /// (sign-in, sign-out, role change). The current location is kept.
  String _signature() {
    final me = _session.me;
    final ids = visibleDestinations(me).map((d) => d.id).join(',');
    return '${_session.status.name}|$ids';
  }

  void _rebuildRouter() {
    final sig = _signature();
    if (sig == _routerSignature && _router != null) return;
    final old = _router;
    String location = '/';
    try {
      location = old?.routerDelegate.currentConfiguration.uri.toString() ?? '/';
    } catch (_) {}
    _routerSignature = sig;
    _router = buildRouter(session: _session, destinations: visibleDestinations(_session.me), rootKey: _rootKey, initialLocation: location);
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _onSession() {
    final me = _session.me;
    if (me?.preferences != null) {
      final p = NPreferences.fromJson(me!.preferences!);
      if (p != _prefs.value) {
        _applyingServerPrefs = true;
        _prefs.value = p;
        _applyingServerPrefs = false;
      }
    }
    final before = _routerSignature;
    _rebuildRouter();
    if (before != _routerSignature) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _prefs.removeListener(_onPrefs);
    _prefsSave?.cancel();
    _router?.dispose();
    _prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: _services,
      child: SessionScope(
        session: _session,
        child: ApiScope(
          api: _services.api,
          child: PreferencesScope(
            controller: _prefs,
            child: ValueListenableBuilder<NPreferences>(
              valueListenable: _prefs,
              builder: (context, p, _) => MaterialApp.router(
                key: ValueKey(_routerSignature),
                onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
                debugShowCheckedModeBanner: false,
                theme: NTheme.build(p, Brightness.light),
                darkTheme: NTheme.build(p, Brightness.dark),
                themeMode: switch (p.appearance) {
                  NAppearance.light => ThemeMode.light,
                  NAppearance.dark => ThemeMode.dark,
                  NAppearance.system => ThemeMode.system,
                },
                themeAnimationDuration: p.reducedMotion ? Duration.zero : const Duration(milliseconds: 300),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                routerConfig: _router!,
                builder: (context, child) {
                  // User text scale multiplies the platform's, capped at 200% so layouts stay testable.
                  final mq = MediaQuery.of(context);
                  final platform = mq.textScaler.scale(14) / 14;
                  final scale = (platform * p.effectiveTextScale).clamp(0.85, 2.0);
                  return MediaQuery(
                    data: mq.copyWith(textScaler: TextScaler.linear(scale)),
                    child: NBreakpointBuilder(
                      builder: (context, bp) => NToastHost(
                        bottomInset: bp.isMobile ? 104 : 24,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
