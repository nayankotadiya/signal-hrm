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
  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Notifications',
      subtitle: 'Essential notices (security, legal) are always delivered.',
      child: AsyncView<Json>(
        load: () async => jsonMap(await context.api.get('/notifications/preferences')),
        builder: (context, p, reload) {
          final events = jsonList(p['events']);
          Future<void> set(String event, String channel, bool v) async {
            try {
              await context.api.put('/notifications/preferences', body: {
                'channels': {
                  event: {channel: v},
                },
              });
              reload();
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          }

          return Column(children: [
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.cardBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.notifications_active_rounded, color: t.primaryButton),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('24/7 Background Push Alerts', style: t.text.body(weight: FontWeight.w600)),
                        Text('Receive instant alerts even when the browser or app is closed.', style: t.text.caption()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  NButton(
                    label: 'Enable',
                    variant: NButtonVariant.secondary,
                    onPressed: () async {
                      final ok = await bridge.subscribePushNotifications(context.api.baseUrl, context.api.token);
                      if (context.mounted) {
                        if (ok) {
                          NToast.of(context).show('24/7 background push notifications active on this device!');
                        } else {
                          NToast.of(context).show('Push notifications could not be enabled. Please check browser permissions.');
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
            Row(children: [
              const Expanded(child: SizedBox()),
              SizedBox(width: 56, child: Text('In app', textAlign: TextAlign.center, style: t.text.caption())),
              SizedBox(width: 56, child: Text('Email', textAlign: TextAlign.center, style: t.text.caption())),
            ]),
            for (final e in events)
              Row(children: [
                Expanded(child: Text('${Fmt.label(e['event'])}${e['essential'] == true ? ' (essential)' : ''}', style: t.text.body())),
                for (final ch in ['in_app', 'email'])
                  SizedBox(
                    width: 56,
                    child: Checkbox(
                      value: jsonMap(e['channels'])[ch] == true,
                      onChanged: e['essential'] == true ? null : (v) => set('${e['event']}', ch, v ?? false),
                      activeColor: t.primaryButton,
                      checkColor: t.onPrimaryButton,
                      semanticLabel: '${Fmt.label(e['event'])} by ${ch == 'email' ? 'email' : 'in app'}',
                    ),
                  ),
              ]),
          ]);
        },
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
