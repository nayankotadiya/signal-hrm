import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../features/account/account_page.dart';
import '../features/appearance/appearance_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/password_pages.dart';
import '../features/home/home_page.dart';
import '../features/not_found/not_found_page.dart';
import '../features/notifications/notifications_page.dart';
import '../shell/app_shell.dart';
import '../widgets/brand.dart';
import 'destinations.dart';
import 'session.dart';

/// Clean URLs with deep links. Sibling destinations live in one StatefulShellRoute whose branch
/// navigators are switched by NViewSwitcher.indexed: direction-aware motion, state preserved.
/// Signed-out users only reach the public routes; everything else redirects to sign-in and
/// returns to the original link afterwards.
GoRouter buildRouter({
  required SessionController session,
  required List<AppDestination> destinations,
  required GlobalKey<NavigatorState> rootKey,
  String initialLocation = '/',
}) {
  const public = ['/login', '/recover', '/status', '/setup'];
  bool isPublic(String loc) => public.contains(loc) || loc.startsWith('/invite/');

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    refreshListenable: session,
    errorBuilder: (context, state) => const NotFoundPage(),
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final from = state.uri.queryParameters['from'];
      switch (session.status) {
        case SessionStatus.unknown:
          if (loc == '/splash') return null;
          return Uri(path: '/splash', queryParameters: {'from': state.uri.toString()}).toString();
        case SessionStatus.signedOut:
          if (isPublic(loc)) return null;
          final target = loc == '/splash' ? from : state.uri.toString();
          return Uri(path: '/login', queryParameters: target == null || target == '/' ? null : {'from': target}).toString();
        case SessionStatus.signedIn:
          if (loc == '/status') return null;
          // A temporary password from an administrator: choose your own before anything else.
          if (session.me?.mustChangePassword == true) return loc == '/password' ? null : '/password';
          if (loc == '/splash' || isPublic(loc)) return (from != null && from.startsWith('/') && !from.startsWith('//')) ? from : '/';
          return null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashPage()),
      GoRoute(path: '/login', builder: (_, s) => LoginPage(expired: session.expiredNotice)),
      GoRoute(path: '/recover', builder: (_, __) => const LoginPage(recovery: true)),
      GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(backgroundColor: Colors.transparent, body: NPageBackground(child: SafeArea(child: HomePage()))),
      ),
      GoRoute(path: '/invite/:token', builder: (_, s) => InvitationPage(token: s.pathParameters['token']!)),
      GoRoute(path: '/setup', builder: (_, __) => const SetupPage()),
      GoRoute(path: '/password', builder: (_, __) => const ChangePasswordPage()),
      StatefulShellRoute(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell, destinations: destinations),
        navigatorContainerBuilder: (context, navigationShell, children) => NViewSwitcher.indexed(index: navigationShell.currentIndex, children: children),
        branches: [
          for (final d in destinations)
            StatefulShellBranch(routes: [
              GoRoute(
                path: d.path,
                name: d.id,
                pageBuilder: (context, state) => NoTransitionPage(child: d.builder(context, state)),
                routes: [
                  if (d.id == 'home') ...[
                    GoRoute(path: 'account', builder: (_, __) => const AccountPage()),
                    GoRoute(path: 'notifications', builder: (_, __) => const NotificationsPage()),
                    GoRoute(path: 'appearance', builder: (_, __) => const AppearancePage()),
                  ],
                  ...d.children,
                  if (d.tabbed) GoRoute(path: ':tab', pageBuilder: (context, state) => NoTransitionPage(child: d.builder(context, state))),
                ],
              ),
            ]),
        ],
      ),
    ],
  );
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NPageBackground(
        child: Center(
          child: Semantics(
            label: 'Loading Signal HRM',
            // Continues the HTML splash (same mark, rings and shimmer) while the session restores.
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SignalMark(size: 64),
              const SizedBox(height: 22),
              const SignalWordmark(size: 28),
              FittedBox(fit: BoxFit.scaleDown, child: Text('PEOPLE · WORK · TIME', style: t.text.caption().copyWith(letterSpacing: 1.2))),
              const SizedBox(height: 22),
              const SignalLoadingBar(),
            ]),
          ),
        ),
      ),
    );
  }
}
