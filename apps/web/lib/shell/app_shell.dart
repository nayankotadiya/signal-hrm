import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../app/config.dart';
import '../app/destinations.dart';
import '../app/services.dart';
import '../platform/bridge.dart';
import '../widgets/brand.dart';
import 'command_palette.dart';
import '../app/preferences.dart';
import '../l10n/gen/app_localizations.dart';

/// The one shell every role uses. Destinations come from the permission-filtered registry.
/// Laptop/desktop/tablet: top bar with the pill nav in the centre. Mobile: compact top bar and a
/// floating, blurred bottom pill nav (up to 5 destinations; the rest go in a "More" sheet).
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.navigationShell, required this.destinations});

  final StatefulNavigationShell navigationShell;
  final List<AppDestination> destinations;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _maxBottomItems = 5;
  late final ValueNotifier<int> _unread = context.services.unread;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshUnread();
      final token = context.api.token;
      if (token != null && token.isNotEmpty) {
        bridge.connectRealtime(context.api.baseUrl, token, _onRealtimeEvent);
      }
    });
    // Fallback unread count poll every 60 seconds
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _refreshUnread());
  }

  void _onRealtimeEvent(String event, String payloadJson) {
    if (!mounted) return;
    if (event == 'notification' || event == 'notification:unread') {
      try {
        final data = jsonDecode(payloadJson);
        if (data is Map && data['unread'] is num) {
          _unread.value = (data['unread'] as num).toInt();
        } else {
          _refreshUnread();
        }
      } catch (_) {
        _refreshUnread();
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    bridge.disconnectRealtime();
    super.dispose();
  }

  Future<void> _refreshUnread() async {
    if (!mounted) return;
    try {
      final j = await context.api.get('/notifications', query: {'unread': true, 'limit': 1});
      if (mounted && j is Map) _unread.value = (j['unread'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // The badge is best-effort; the notification page shows errors properly.
    }
  }

  void _go(int index) {
    final d = widget.destinations[index];
    if (index == widget.navigationShell.currentIndex) {
      context.go(d.path);
    } else {
      widget.navigationShell.goBranch(index, initialLocation: true);
    }
  }

  void _palette() => showCommandPalette(context, widget.destinations, _go);

  @override
  Widget build(BuildContext context) {
    final destinations = widget.destinations;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _palette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _palette,
      },
      child: Focus(
        autofocus: true,
        child: NBreakpointBuilder(builder: (context, bp) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: NPageBackground(
              child: SafeArea(
                bottom: false,
                child: Stack(children: [
                  Column(children: [
                    _TopBar(
                      destinations: destinations,
                      currentIndex: widget.navigationShell.currentIndex,
                      onSelect: _go,
                      showNav: !bp.isMobile,
                      unread: _unread,
                      onSearch: _palette,
                      onNotifications: () => context.go('/notifications'),
                    ),
                    if (AppConfig.demo) const _DemoBar(),
                    StreamBuilder<bool>(
                      stream: bridge.onlineChanges,
                      initialData: bridge.online,
                      builder: (context, snap) => snap.data == false ? const _OfflineBar() : const SizedBox.shrink(),
                    ),
                    Expanded(child: widget.navigationShell),
                  ]),
                  if (bp.isMobile)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: MediaQuery.paddingOf(context).bottom + 12,
                      child: _BottomNav(
                        destinations: destinations,
                        currentIndex: widget.navigationShell.currentIndex,
                        onSelect: _go,
                        maxItems: _maxBottomItems,
                      ),
                    ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Shown on every screen in demo mode so sample data is never mistaken for real records.
class _DemoBar extends StatelessWidget {
  const _DemoBar();

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      container: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: t.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(NTokens.radiusPill)),
        child: Row(children: [
          Icon(Icons.science_outlined, size: 16, color: t.ink),
          const SizedBox(width: 8),
          Expanded(child: Text('Demo mode: sample data, not connected to a server. Changes are not saved.', style: t.text.caption(color: t.ink))),
        ]),
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar();

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: t.amber.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(NTokens.radiusPill)),
        child: Row(children: [
          Icon(Icons.wifi_off_rounded, size: 16, color: t.ink),
          const SizedBox(width: 8),
          Expanded(child: Text("You're offline. Changes won't be saved until you reconnect.", style: t.text.caption(color: t.ink))),
        ]),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.destinations,
    required this.currentIndex,
    required this.onSelect,
    required this.showNav,
    required this.unread,
    required this.onSearch,
    required this.onNotifications,
  });

  final List<AppDestination> destinations;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final bool showNav;
  final ValueListenable<int> unread;
  final VoidCallback onSearch;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final bp = NBreakpoint.of(context);
    final prefs = PreferencesScope.of(context);
    final dark = t.isDark;
    final me = context.maybeMe;

    final actions = Row(mainAxisSize: MainAxisSize.min, children: [
      if (!bp.isMobile) ...[
        NIconButton(
          icon: dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          label: dark ? l.topThemeToLight : l.topThemeToDark,
          onPressed: () => prefs.update((p) => p.copyWith(appearance: dark ? NAppearance.light : NAppearance.dark)),
        ),
        const SizedBox(width: 8),
      ],
      NIconButton(icon: Icons.search_rounded, label: l.topSearchHint, onPressed: onSearch),
      const SizedBox(width: 8),
      ValueListenableBuilder<int>(
        valueListenable: unread,
        builder: (context, n, _) => NIconButton(icon: Icons.notifications_none_rounded, label: l.topNotifications, badgeCount: n, onPressed: onNotifications),
      ),
      const SizedBox(width: 8),
      Tooltip(
        message: l.topAccount,
        child: Semantics(
          button: true,
          label: l.topAccount,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => context.go('/account'),
            child: NAvatar(name: me?.name ?? '?', size: 40),
          ),
        ),
      ),
    ]);

    final wordmark = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.go('/'),
      child: Semantics(
        header: true,
        label: '${l.appTitle}. ${me?.orgName ?? l.tagline}',
        excludeSemantics: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SignalMark(size: 34, animated: false),
          const SizedBox(width: 10),
          if (!bp.isMobile || NBreakpoint.widthOf(context) > 380)
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Signal ', style: t.text.title(size: 18).copyWith(fontWeight: FontWeight.w300)),
                      TextSpan(text: 'HRM', style: t.text.title(size: 18).copyWith(fontWeight: FontWeight.w600)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Bulletproof Brands',
                    style: t.text.caption(color: t.muted).copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
        ]),
      ),
    );


    return Padding(
      padding: EdgeInsets.fromLTRB(bp.isMobile ? 14 : 22, bp.isMobile ? 10 : 16, bp.isMobile ? 14 : 22, 8),
      child: Row(children: [
        if (showNav)
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: wordmark)
        else
          Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: wordmark)),
        if (showNav)
          Expanded(
            child: Center(
              child: NSlidingPills(
                semanticLabel: l.navMain,
                items: [for (final d in destinations) NPillItem(label: d.label(l), icon: d.icon)],
                selectedIndex: currentIndex.clamp(0, destinations.length - 1),
                onChanged: onSelect,
                showLabels: bp != NBreakpoint.tablet,
              ),
            ),
          ),
        actions,
      ]),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.destinations, required this.currentIndex, required this.onSelect, required this.maxItems});

  final List<AppDestination> destinations;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final overflow = destinations.length > maxItems;
    final primary = overflow ? destinations.take(maxItems - 1).toList() : destinations;
    final items = [
      for (final d in primary) NPillItem(label: d.label(l), icon: d.icon),
      if (overflow) NPillItem(label: l.navMore, icon: Icons.more_horiz_rounded),
    ];
    final selected = currentIndex < primary.length ? currentIndex : items.length - 1;
    if (items.isEmpty) return const SizedBox.shrink();

    Widget bar = Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(NTokens.radiusPill),
        boxShadow: t.cardShadow,
      ),
      padding: const EdgeInsets.all(4),
      child: NSlidingPills(
        semanticLabel: l.navMain,
        items: items,
        selectedIndex: selected,
        expand: true,
        showLabels: false,
        size: NPillSize.large,
        onChanged: (i) {
          if (overflow && i == items.length - 1) {
            _openMore(context, primary.length);
          } else {
            onSelect(i);
          }
        },
      ),
    );
    if (t.blurSigma > 0) {
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(NTokens.radiusPill),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: t.blurSigma, sigmaY: t.blurSigma), child: bar),
      );
    }
    return bar;
  }

  void _openMore(BuildContext context, int firstHidden) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.card.withValues(alpha: 1),
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusPanel))),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.moreTitle, style: t.text.title()),
            const SizedBox(height: 8),
            for (var i = firstHidden; i < destinations.length; i++)
              NButton(
                label: destinations[i].label(l),
                icon: destinations[i].icon,
                variant: i == currentIndex ? NButtonVariant.primary : NButtonVariant.secondary,
                onPressed: () {
                  Navigator.of(sheet).pop();
                  onSelect(i);
                },
              ),
          ]),
        ),
      ),
    );
  }
}

/// Standard page body: scrolls, centres to the max content width, sits in the pastel panel and
/// leaves room for the floating mobile nav.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bp = NBreakpoint.of(context);
    final mobile = bp.isMobile;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        mobile ? 12 : 22,
        mobile ? 14 : 16,
        mobile ? 12 : 22,
        (mobile ? 120 : 22) + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: bp == NBreakpoint.desktop ? 1440 : double.infinity),
          child: NPanel(child: child),
        ),
      ),
    );
  }
}
