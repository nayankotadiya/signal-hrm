import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/links.dart';
import '../../app/services.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';

/// Notification center. Opening a notification marks it read and follows its link.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _unreadOnly = false;
  int _rev = 0;

  Future<void> _markAll() async {
    try {
      final r = await context.api.post('/notifications/read', body: {'ids': 'all'});
      if (!mounted) return;
      context.services.unread.value = (r is Map ? (r['unread'] as num?)?.toInt() : null) ?? 0;
      setState(() => _rev++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Back to Home',
              onPressed: () => context.go('/'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: NSectionHeader(
                title: 'Notifications',
                trailing: [
                  NFilterChips<bool>(value: _unreadOnly, onChanged: (v) => setState(() => _unreadOnly = v), options: const [NOption(false, 'All'), NOption(true, 'Unread')]),
                  NButton(label: 'Mark all read', icon: Icons.done_all_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _markAll),
                ],
              ),
            ),
          ],
        ),
        PagedList(
          path: '/notifications',
          query: {if (_unreadOnly) 'unread': true},
          reloadKey: '$_unreadOnly|$_rev',
          emptyTitle: _unreadOnly ? 'No unread notifications' : 'No notifications yet',
          emptyIcon: Icons.notifications_none_rounded,
          itemBuilder: (context, n, reload) => NListRow(
            leading: Icon(
              n['priority'] == 'essential' || n['priority'] == 'high' ? Icons.priority_high_rounded : Icons.notifications_rounded,
              color: n['readAt'] == null ? t.accent : t.muted,
            ),
            title: '${n['title']}',
            subtitle: [n['body'], Fmt.relative(n['createdAt'])].whereType<String>().join(' · '),
            trailing: n['readAt'] == null ? Container(width: 8, height: 8, decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle)) : null,
            semanticLabel: '${n['readAt'] == null ? 'Unread. ' : ''}${n['title']}',
            onTap: () async {
              if (n['readAt'] == null) {
                try {
                  final r = await context.api.post('/notifications/read', body: {
                    'ids': [n['id']],
                  });
                  if (context.mounted && r is Map) context.services.unread.value = (r['unread'] as num?)?.toInt() ?? 0;
                } catch (_) {}
              }
              if (!context.mounted) return;
              if (n['link'] != null) {
                context.go(resolveLink('${n['link']}'));
              } else {
                reload();
              }
            },
          ),
        ),
      ]),
    );
  }
}
