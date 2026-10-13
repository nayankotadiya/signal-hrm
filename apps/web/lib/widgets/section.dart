import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../app/services.dart';
import '../app/session.dart';
import '../shell/app_shell.dart';

/// One sub-page of a section (e.g. Time → Leave). Hidden when [visible] says so.
class SectionTab {
  const SectionTab(this.id, this.label, this.icon, this.builder, {this.visible});
  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
  final bool Function(Me me)? visible;
}

/// Section page: heading, sub-navigation pills and the active tab. Tabs are deep-linkable
/// (`/time/leave`) and switch with the direction-aware view transition.
class SectionPage extends StatelessWidget {
  const SectionPage({super.key, required this.basePath, required this.tabs, required this.tabId, required this.title, this.boldWord, this.subtitle, this.actions = const []});

  final String basePath;
  final List<SectionTab> tabs;
  final String? tabId;
  final String title;
  final String? boldWord;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final visible = [for (final t in tabs) if (t.visible == null || t.visible!(me)) t];
    if (visible.isEmpty) {
      return const PageFrame(child: NEmptyState(title: 'Nothing to show', message: "You don't have access to anything in this section.", icon: Icons.lock_outline_rounded));
    }
    var index = visible.indexWhere((t) => t.id == tabId);
    if (index < 0) index = 0;
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NSectionHeader(title: title, boldWord: boldWord, subtitle: subtitle, trailing: actions),
        if (visible.length > 1) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: NSlidingPills(
              semanticLabel: '$title sections',
              items: [for (final t in visible) NPillItem(label: t.label, icon: t.icon)],
              selectedIndex: index,
              onChanged: (i) => context.go(i == 0 ? basePath : '$basePath/${visible[i].id}'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        NViewSwitcher(index: index, child: KeyedSubtree(key: ValueKey(visible[index].id), child: visible[index].builder(context))),
      ]),
    );
  }
}

/// Grid of cards that collapses to one column on phones.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children, this.minTileWidth = 320});
  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minTileWidth).floor().clamp(1, 4);
      final w = (c.maxWidth - (cols - 1) * t.gap) / cols;
      return Wrap(spacing: t.gap, runSpacing: t.gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
    });
  }
}

/// Card with title, used throughout feature pages.
class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.title, required this.child, this.subtitle, this.trailing, this.onTap});
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => NGlassCard(
        blur: false,
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          NCardTitle(title, subtitle: subtitle, trailing: trailing),
          child,
        ]),
      );
}

/// Toolbar row of filters / actions above a list. Wraps on narrow screens.
class Toolbar extends StatelessWidget {
  const Toolbar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: children),
      );
}
