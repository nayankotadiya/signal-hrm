import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../platform/bridge.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

/// The signed-in person's own account: profile, notification choices, sessions, recovery codes,
/// personal data export and sign-out.
class AccountPage extends StatelessWidget {
  const AccountPage({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back to Home',
            onPressed: () => context.go('/'),
          ),
          const SizedBox(width: 8),
          NAvatar(name: me.name, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(me.fullName, style: t.text.heading(size: 28)),
              Text([me.email, Fmt.label(me.role), me.orgName].whereType<String>().where((s) => s.isNotEmpty).join(' · '), style: t.text.body(color: t.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        CardGrid(minTileWidth: 360, children: [
          const _Profile(),
          InfoCard(
            title: 'Appearance',
            subtitle: 'Theme, accent colour, density, text size and motion. Saved to your account.',
            trailing: NButton(label: 'Open', compact: true, variant: NButtonVariant.secondary, onPressed: () => context.go('/appearance')),
            child: Text('Changes apply instantly and never touch your data or permissions.', style: t.text.body(color: t.muted)),
          ),
          const _NotificationPrefs(),
          InfoCard(
            title: 'Password',
            subtitle: me.hasPassword ? 'You can sign in with your email and password.' : 'No password yet. You sign in with email codes.',
            trailing: NButton(label: me.hasPassword ? 'Change' : 'Set', compact: true, variant: NButtonVariant.secondary, onPressed: () => context.go('/password')),
            child: Text('Changing it signs you out on your other devices.', style: t.text.body(color: t.muted)),
          ),
          const _Sessions(),
          const _Security(),
          const _DataExport(),
        ]),
        const SizedBox(height: 18),
        Center(
          child: NButton(
            label: 'Sign out',
            icon: Icons.logout_rounded,
            variant: NButtonVariant.secondary,
            onPressed: () => context.services.session.signOut(),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text(kNUiAttribution, style: t.text.caption())),
      ]),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile();

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final u = me.user;
    return InfoCard(
      title: 'Profile',
      trailing: NButton(
        label: 'Edit',
        compact: true,
        variant: NButtonVariant.secondary,
        onPressed: () async {
          final r = await showFormSheet<Json>(
            context,
            title: 'Edit profile',
            initial: u,
            fields: const [
              FieldSpec('fullName', 'Full name', required: true),
              FieldSpec('displayName', 'Name people see'),
              FieldSpec('username', 'Username', helper: '3–30 letters, numbers, dots or dashes'),
              FieldSpec('phone', 'Phone', kind: FieldKind.phone, hint: '+919876543210'),
              FieldSpec('timezone', 'Time zone', hint: 'Asia/Kolkata'),
              FieldSpec('language', 'Language', kind: FieldKind.select, options: [NOption('en', 'English'), NOption('hi', 'हिन्दी'), NOption('gu', 'ગુજરાતી'), NOption('en-hinglish', 'Hinglish')]),
              FieldSpec('photoFileId', 'Photo', kind: FieldKind.file, filePurpose: 'avatar', fileAccept: 'image/*'),
            ],
            successMessage: 'Profile saved.',
            submit: (v, key) async => jsonMap(await context.api.patch('/me/profile', body: v, idempotencyKey: key)),
          );
          if (r != null && context.mounted) await context.services.session.reloadMe();
        },
      ),
      child: Column(children: [
        NInfoRow(label: 'Name', value: '${u['fullName'] ?? ''}'),
        NInfoRow(label: 'Shown as', value: '${u['displayName'] ?? ''}'),
        NInfoRow(label: 'Email', value: '${u['email'] ?? ''}'),
        NInfoRow(label: 'Phone', value: '${u['phone'] ?? ''}'),
        NInfoRow(label: 'Time zone', value: '${u['timezone'] ?? me.timezone}'),
        NInfoRow(label: 'Last sign-in', value: u['lastLoginAt'] == null ? '—' : Fmt.relative(u['lastLoginAt'])),
      ]),
    );
  }
}

class _NotificationPrefs extends StatefulWidget {
  const _NotificationPrefs();

  @override
  State<_NotificationPrefs> createState() => _NotificationPrefsState();
}

class _NotificationPrefsState extends State<_NotificationPrefs> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = [];
  final Map<String, Map<String, bool>> _channels = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPrefs());
  }

  Future<void> _loadPrefs() async {
    try {
      final res = jsonMap(await context.api.get('/notifications/preferences'));
      final rawEvents = jsonList(res['events']);
      final events = <Map<String, dynamic>>[];
      for (final raw in rawEvents) {
        final m = jsonMap(raw);
        final eventKey = '${m['event']}';
        events.add(m);
        final chMap = jsonMap(m['channels']);
        _channels[eventKey] = {
          'in_app': chMap['in_app'] == true,
          'email': chMap['email'] == true,
        };
      }
      if (mounted) {
        setState(() {
          _events = events;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _onToggle(String event, String channel, bool newValue) {
    // 1. Instant optimistic UI update - 0ms response time
    setState(() {
      _channels.putIfAbsent(event, () => {})[channel] = newValue;
    });

    // 2. Persist in background without wiping or reloading
    context.api.put('/notifications/preferences', body: {
      'channels': {
        event: {channel: newValue},
      },
    }).catchError((Object e) {
      if (mounted) {
        setState(() {
          _channels.putIfAbsent(event, () => {})[channel] = !newValue;
        });
        showError(context, e);
      }
    });
  }

  String _formatEventLabel(String event) {
    switch (event) {
      case 'attendance_check_in':
        return 'Check-in confirmation';
      case 'attendance_check_out':
        return 'Check-out confirmation';
      case 'attendance_checkout_reminder':
        return '7:00 PM check-out reminder';
      case 'attendance_reminder':
        return 'Attendance reminder';
      case 'leave_submitted':
        return 'Leave request submitted';
      case 'leave_decided':
        return 'Leave approval / status update';
      case 'expense_submitted':
        return 'Expense reimbursement submitted';
      case 'expense_decided':
        return 'Expense approval / payment';
      case 'payslip_available':
        return 'Monthly payslip published';
      case 'task_assigned':
        return 'New task assignment';
      case 'meeting_scheduled':
        return 'Meeting scheduled / updated';
      case 'announcement':
        return 'Company announcement';
      default:
        return Fmt.label(event);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Notifications',
      subtitle: 'Essential notices (security, legal) are always delivered.',
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    children: [
                      Expanded(child: Text('Could not load preferences: $_error', style: t.text.caption(color: t.dangerText))),
                      TextButton(onPressed: _loadPrefs, child: const Text('Retry')),
                    ],
                  ),
                )
              : Column(children: [
                  const _PushAlertsRow(),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Expanded(child: SizedBox()),
                    SizedBox(width: 56, child: Text('In app', textAlign: TextAlign.center, style: t.text.caption())),
                    SizedBox(width: 56, child: Text('Email', textAlign: TextAlign.center, style: t.text.caption())),
                  ]),
                  const SizedBox(height: 4),
                  for (final e in _events) ...[
                    Builder(builder: (context) {
                      final eventKey = '${e['event']}';
                      final isEssential = e['essential'] == true;
                      final label = _formatEventLabel(eventKey);
                      final inAppVal = isEssential ? true : (_channels[eventKey]?['in_app'] ?? true);
                      final emailVal = isEssential ? true : (_channels[eventKey]?['email'] ?? false);

                      return Row(children: [
                        Expanded(child: Text('$label${isEssential ? ' (essential)' : ''}', style: t.text.body())),
                        SizedBox(
                          width: 56,
                          child: Checkbox(
                            value: inAppVal,
                            onChanged: isEssential ? null : (v) => _onToggle(eventKey, 'in_app', v ?? false),
                            activeColor: t.primaryButton,
                            checkColor: t.onPrimaryButton,
                            semanticLabel: '$label in app',
                          ),
                        ),
                        SizedBox(
                          width: 56,
                          child: Checkbox(
                            value: emailVal,
                            onChanged: isEssential ? null : (v) => _onToggle(eventKey, 'email', v ?? false),
                            activeColor: t.primaryButton,
                            checkColor: t.onPrimaryButton,
                            semanticLabel: '$label by email',
                          ),
                        ),
                      ]);
                    }),
                  ],
                ]),
    );
  }
}

class _PushAlertsRow extends StatefulWidget {
  const _PushAlertsRow();

  @override
  State<_PushAlertsRow> createState() => _PushAlertsRowState();
}

class _PushAlertsRowState extends State<_PushAlertsRow> {
  bool _active = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final subbed = await bridge.isPushSubscribed();
      if (mounted) {
        setState(() {
          _active = subbed;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_active) {
        final ok = await bridge.unsubscribePushNotifications(context.api.baseUrl, context.api.token);
        if (mounted) {
          setState(() {
            _active = !ok;
            _busy = false;
          });
          if (ok) {
            NToast.of(context).show('24/7 background push notifications disabled.');
          } else {
            NToast.of(context).show('Could not disable notifications.');
          }
        }
      } else {
        final ok = await bridge.subscribePushNotifications(context.api.baseUrl, context.api.token);
        if (mounted) {
          setState(() {
            _active = ok;
            _busy = false;
          });
          if (ok) {
            NToast.of(context).show('24/7 background push notifications active on this device!');
          } else {
            NToast.of(context).show('Push notifications could not be enabled. Please check browser permissions.');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        NToast.of(context).show('Operation failed. Please check permissions.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isDark = t.isDark;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _active ? t.accent.withValues(alpha: isDark ? 0.12 : 0.06) : t.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _active ? t.accent.withValues(alpha: isDark ? 0.4 : 0.3) : t.cardBorder,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (_active ? t.accent : t.muted).withValues(alpha: 0.14),
            ),
            child: Icon(
              _active ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
              color: _active ? t.accent : t.muted,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '24/7 Background Push Alerts',
                        style: t.text.body(weight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: (_active ? t.accent : t.muted).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _active ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059669)) : t.muted,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _active ? 'Active' : 'Disabled',
                            style: t.text.caption(weight: FontWeight.w600).copyWith(
                                  fontSize: 10.5,
                                  color: _active ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059669)) : t.muted,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _active
                      ? 'Instant alerts enabled. You receive updates even when closed.'
                      : 'Receive instant alerts even when the browser or app is closed.',
                  style: t.text.caption(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_loading)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            NButton(
              label: _active ? 'Disable' : 'Enable',
              variant: _active ? NButtonVariant.secondary : NButtonVariant.accent,
              busy: _busy,
              compact: true,
              onPressed: _toggle,
            ),
        ],
      ),
    );
  }
}

class _Sessions extends StatelessWidget {
  const _Sessions();

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Signed-in devices',
      child: AsyncView<List<Json>>(
        load: () async => jsonList(await context.api.get('/auth/sessions')),
        builder: (context, items, reload) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final s in items)
            NListRow(
              dense: true,
              leading: Icon(Icons.devices_rounded, color: t.muted, size: 20),
              title: '${s['deviceName'] ?? 'Browser'}${s['current'] == true ? ' (this device)' : ''}',
              subtitle: '${s['provider'] ?? ''} · last used ${Fmt.relative(s['lastUsedAt'] ?? s['createdAt'])}${s['ip'] != null ? ' · ${s['ip']}' : ''}',
              trailing: s['current'] == true
                  ? null
                  : IconButton(
                      tooltip: 'Sign out this device',
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      onPressed: () async {
                        try {
                          await context.api.delete('/auth/sessions/${s['id']}');
                          reload();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
            ),
          if (items.length > 1)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () async {
                  try {
                    await context.api.post('/auth/sessions/revoke-others');
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Sign out all other devices'),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Security extends StatelessWidget {
  const _Security();

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final u = context.me.user;
    return InfoCard(
      title: 'Recovery codes',
      subtitle: u['recoveryCodesGeneratedAt'] == null ? 'Not generated yet.' : 'Generated ${Fmt.date(u['recoveryCodesGeneratedAt'])}.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Use a recovery code to sign in if you lose access to your email. Generating new codes cancels the old ones.', style: t.text.body(color: t.muted)),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: NButton(
            label: 'Generate new codes',
            icon: Icons.key_rounded,
            compact: true,
            variant: NButtonVariant.secondary,
            onPressed: () async {
              try {
                final r = jsonMap(await context.api.post('/auth/recovery-codes'));
                final codes = [for (final c in (r['codes'] as List? ?? const [])) '$c'];
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Your recovery codes'),
                    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('Shown once. Store them somewhere safe and offline.'),
                      const SizedBox(height: 12),
                      SelectableText(codes.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.6)),
                    ]),
                    actions: [
                      TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: codes.join('\n'))), child: const Text('Copy')),
                      TextButton(onPressed: () => bridge.downloadBytes(Uint8ListHelper.fromString(codes.join('\n')), 'signal-hrm-recovery-codes.txt', 'text/plain'), child: const Text('Download')),
                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('I saved them')),
                    ],
                  ),
                );
                if (context.mounted) await context.services.session.reloadMe();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
        ),
      ]),
    );
  }
}

class Uint8ListHelper {
  static Uint8List fromString(String s) => Uint8List.fromList(s.codeUnits);
}

class _DataExport extends StatefulWidget {
  const _DataExport();

  @override
  State<_DataExport> createState() => _DataExportState();
}

class _DataExportState extends State<_DataExport> {
  bool _busy = false;
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Your data',
      subtitle: 'Download a copy of your own records (JSON). Links expire after 7 days.',
      trailing: NButton(
        label: 'Request export',
        compact: true,
        busy: _busy,
        onPressed: () async {
          setState(() => _busy = true);
          try {
            await context.api.post('/me/data-exports');
            if (context.mounted) NToast.of(context).show('Your export is ready.');
            setState(() => _rev++);
          } catch (e) {
            if (context.mounted) showError(context, e);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
      ),
      child: AsyncView<List<Json>>(
        reloadKey: _rev,
        compact: true,
        load: () async => jsonList(await context.api.get('/me/data-exports')),
        builder: (context, items, _) => items.isEmpty
            ? Text('No exports yet.', style: t.text.body(color: t.muted))
            : Column(children: [
                for (final x in items)
                  NListRow(
                    dense: true,
                    title: Fmt.dateTime(x['createdAt']),
                    subtitle: x['expiresAt'] == null ? null : 'Expires ${Fmt.relative(x['expiresAt'])}',
                    trailing: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      StatusChip('${x['status']}'),
                      if (x['status'] == 'ready' && x['fileId'] != null)
                        IconButton(
                          tooltip: 'Download',
                          icon: const Icon(Icons.download_rounded, size: 18),
                          onPressed: () async {
                            try {
                              final f = await context.api.download('/files/${x['fileId']}/content');
                              bridge.downloadBytes(f.bytes, f.fileName == 'download' ? 'my-data.json' : f.fileName, 'application/json');
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        ),
                    ]),
                  ),
              ]),
      ),
    );
  }
}
