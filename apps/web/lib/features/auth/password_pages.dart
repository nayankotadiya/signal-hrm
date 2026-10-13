import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import 'login_page.dart';

/// Rules shown next to every "new password" field. The server enforces the same rules.
const kPasswordRules = 'At least 10 characters, mixing letters with numbers or symbols. Avoid your name and common words.';

/// Client-side check for instant feedback (the server has the final say).
String? passwordHint(String p) {
  if (p.length < 10) return 'Use at least 10 characters.';
  if (!RegExp('[A-Za-z]').hasMatch(p) || !RegExp('[^A-Za-z]').hasMatch(p)) return 'Mix letters with numbers or symbols.';
  return null;
}

/// Shows recovery codes once, with copy and download. Returns when the person confirms they saved them.
Future<void> showRecoveryCodesDialog(BuildContext context, List<String> codes) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Your recovery codes'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Shown once. Each code signs you in one time if you forget your password. Store them somewhere safe and offline.'),
          const SizedBox(height: 12),
          SelectableText(codes.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.6)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: codes.join('\n'))), child: const Text('Copy')),
        TextButton(
          onPressed: () => bridge.downloadBytes(Uint8List.fromList(codes.join('\n').codeUnits), 'signal-hrm-recovery-codes.txt', 'text/plain'),
          child: const Text('Download'),
        ),
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('I saved them')),
      ],
    ),
  );
}

// ============================================================================ first-time setup

/// One-time setup on a fresh server: creates the organization and the first Super Admin with a
/// password. Needs the setup key (SETUP_TOKEN) from the server's settings, so only the person who
/// controls the server can do it, and it stops working once a Super Admin exists.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _token = TextEditingController();
  final _org = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_token, _org, _name, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final local = _token.text.trim().isEmpty
        ? 'Paste the setup key from your server settings (SETUP_TOKEN).'
        : _org.text.trim().length < 2
            ? 'Enter your organization name.'
            : _name.text.trim().length < 2
                ? 'Enter your full name.'
                : !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())
                    ? 'Enter a valid email address.'
                    : passwordHint(_password.text) ?? (_password.text != _confirm.text ? 'The two passwords are different.' : null);
    if (local != null) {
      setState(() => _error = local);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.api;
    final session = context.services.session;
    try {
      final r = jsonMap(await api.post('/setup/first-admin', body: {
        'token': _token.text.trim(),
        'organization': _org.text.trim(),
        'fullName': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
      }));
      if (!mounted) return;
      await showRecoveryCodesDialog(context, [for (final c in (r['recoveryCodes'] as List? ?? const [])) '$c']);
      await session.password(_email.text.trim(), _password.text);
      // The router moves a signed-in session to the dashboard.
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AuthFrame(
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Set up Signal HRM', style: t.text.heading(size: 26)),
          const SizedBox(height: 4),
          Text('Create your organization and the first administrator. This works once, on a new server.', style: t.text.body(color: t.muted)),
          const SizedBox(height: 16),
          if (_error != null) ...[NBanner(message: _error!, tone: NBannerTone.danger), const SizedBox(height: 12)],
          NTextField(label: 'Setup key', controller: _token, obscure: true, helper: 'The SETUP_TOKEN value from your server settings.'),
          const SizedBox(height: 12),
          NTextField(label: 'Organization name', controller: _org, hint: 'Bulletproof Brands'),
          const SizedBox(height: 12),
          NTextField(label: 'Your full name', controller: _name, autofillHints: const [AutofillHints.name]),
          const SizedBox(height: 12),
          NTextField(label: 'Work email', controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email, AutofillHints.username]),
          const SizedBox(height: 12),
          NTextField(label: 'Password', controller: _password, obscure: true, helper: kPasswordRules, autofillHints: const [AutofillHints.newPassword]),
          const SizedBox(height: 12),
          NTextField(label: 'Confirm password', controller: _confirm, obscure: true, autofillHints: const [AutofillHints.newPassword], onSubmitted: (_) => _submit()),
          const SizedBox(height: 16),
          NButton(label: 'Create administrator', variant: NButtonVariant.accent, busy: _busy, onPressed: _submit),
          const SizedBox(height: 6),
          TextButton(onPressed: () => context.go('/login'), child: Text('Back to sign in', style: t.text.caption(color: t.ink))),
        ]),
      ),
    );
  }
}

// ============================================================================ change password

/// Choose or change your own password. When an administrator issued a temporary password, the
/// router sends the person here first and the rest of the app stays locked until it's done.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final me = context.me;
    final local = me.hasPassword && _current.text.isEmpty
        ? 'Enter your current password.'
        : passwordHint(_next.text) ?? (_next.text != _confirm.text ? 'The two new passwords are different.' : null);
    if (local != null) {
      setState(() => _error = local);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.api;
    final session = context.services.session;
    final toast = NToast.of(context);
    try {
      await api.post('/auth/password/change', body: {if (me.hasPassword) 'currentPassword': _current.text, 'newPassword': _next.text});
      await session.reloadMe();
      toast.show('Password saved. Other devices were signed out.');
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final forced = me.mustChangePassword;
    return AuthFrame(
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(forced ? 'Choose your password' : (me.hasPassword ? 'Change password' : 'Set a password'), style: t.text.heading(size: 26)),
          const SizedBox(height: 4),
          Text(
            forced
                ? 'You signed in with a temporary password from your administrator. Choose your own to continue.'
                : 'Your other devices are signed out after the change.',
            style: t.text.body(color: t.muted),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[NBanner(message: _error!, tone: NBannerTone.danger), const SizedBox(height: 12)],
          // Hidden username field so password managers save the right account.
          Offstage(child: NTextField(label: 'Email', initialValue: me.email ?? '', autofillHints: const [AutofillHints.username])),
          if (me.hasPassword) ...[
            NTextField(label: forced ? 'Temporary password' : 'Current password', controller: _current, obscure: true, autofillHints: const [AutofillHints.password]),
            const SizedBox(height: 12),
          ],
          NTextField(label: 'New password', controller: _next, obscure: true, helper: kPasswordRules, autofillHints: const [AutofillHints.newPassword]),
          const SizedBox(height: 12),
          NTextField(label: 'Confirm new password', controller: _confirm, obscure: true, autofillHints: const [AutofillHints.newPassword], onSubmitted: (_) => _submit()),
          const SizedBox(height: 16),
          NButton(label: 'Save password', variant: NButtonVariant.accent, busy: _busy, onPressed: _submit),
          const SizedBox(height: 6),
          if (forced)
            TextButton(onPressed: () => context.services.session.signOut(), child: Text('Sign out', style: t.text.caption(color: t.ink)))
          else
            TextButton(onPressed: () => context.go('/account'), child: Text('Cancel', style: t.text.caption(color: t.ink))),
        ]),
      ),
    );
  }
}

// ============================================================================ temporary password (admins)

/// Administrator action: issue a one-time temporary password for someone and show it once.
Future<void> issueTemporaryPassword(BuildContext context, {required String userId, required String name}) async {
  final api = context.api;
  final confirm = await showNConfirm(
    context,
    title: 'Set a temporary password for $name?',
    message: 'They are signed out everywhere. Give them the password in person or by phone; they must choose their own at the next sign-in.',
    confirmLabel: 'Create password',
  );
  if (!confirm.confirmed || !context.mounted) return;
  try {
    final r = jsonMap(await api.post('/users/$userId/temporary-password'));
    final pw = '${r['temporaryPassword'] ?? ''}';
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Temporary password for $name'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text("Shown once. It isn't stored anywhere you can see it again."),
            const SizedBox(height: 12),
            SelectableText(pw, style: const TextStyle(fontFamily: 'monospace', fontSize: 22, letterSpacing: 1)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: pw)), child: const Text('Copy')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Done')),
        ],
      ),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
