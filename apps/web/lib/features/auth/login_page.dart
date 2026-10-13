import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../app/session.dart';
import '../../data/api.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import '../../widgets/brand.dart';
import '../../widgets/format.dart';

/// Centered sign-in card on the page background.
class AuthFrame extends StatelessWidget {
  const AuthFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NPageBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                // Brand, card and footer rise in one after another; the mark keeps a gentle pulse.
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const NEntrance(
                    order: 0,
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      SignalMark(size: 44),
                      SizedBox(width: 14),
                      SignalWordmark(size: 24),
                    ]),
                  ),
                  const SizedBox(height: 26),
                  NEntrance(order: 1, child: NGlassCard(padding: const EdgeInsets.all(24), child: child)),
                  const SizedBox(height: 14),
                  NEntrance(order: 2, child: Text(kNUiAttribution, textAlign: TextAlign.center, style: t.text.caption())),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Step { identifier, code, password, recovery }

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.expired = false, this.recovery = false});
  final bool expired;
  final bool recovery;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late _Step _step = widget.recovery ? _Step.recovery : _Step.identifier;
  final _identifier = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  String? _destination;
  bool _busy = false;
  int _resendIn = 0;
  Timer? _timer;

  SessionController get _session => context.services.session;

  /// Sign-in options this server offers (GET /setup/status). Null until loaded or if unreachable.
  Json? _server;
  bool get _passwordOn => AppConfig.passwordLogin || _server?['passwordLogin'] == true;
  bool get _emailCodes => _server?['emailCodes'] != false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final s = jsonMap(await context.api.get('/setup/status'));
        if (!mounted) return;
        setState(() {
          _server = s;
          // Without email codes, the password form is the way in.
          if (!_emailCodes && _passwordOn && _step == _Step.identifier) _step = _Step.password;
        });
      } catch (_) {
        // Older server or offline: keep the default options.
      }
    });
  }

  List<Widget> _setupBanner() => [
        if (_server?['setupAvailable'] == true) ...[
          const NBanner(message: "This server isn't set up yet. Create the first administrator to start.", tone: NBannerTone.info),
          const SizedBox(height: 10),
          NButton(label: 'Set up Signal HRM', icon: Icons.rocket_launch_outlined, variant: NButtonVariant.accent, onPressed: () => context.go('/setup')),
          const SizedBox(height: 18),
        ],
      ];

  @override
  void dispose() {
    _timer?.cancel();
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    setState(() => _resendIn = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn = _resendIn > 0 ? _resendIn - 1 : 0);
      if (_resendIn == 0) t.cancel();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    final id = _identifier.text.trim();
    if (id.length < 3) {
      setState(() => _error = 'Enter your work email.');
      return;
    }
    await _run(() async {
      final r = await _session.requestOtp(id);
      _destination = r.destination;
      _code.clear();
      _step = _Step.code;
      _startTimer(r.resendAfterSeconds);
    });
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    await _run(() => _session.verifyOtp(_identifier.text, code));
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final children = <Widget>[];
    switch (_step) {
      case _Step.identifier:
        children.addAll([
          ..._setupBanner(),
          Text('Sign in', style: t.text.heading(size: 28)),
          const SizedBox(height: 4),
          Text('Use the work email your administrator invited.', style: t.text.body(color: t.muted)),
          const SizedBox(height: 18),
          AutofillGroup(
            child: NTextField(
              label: 'Work email',
              controller: _identifier,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              textInputAction: TextInputAction.go,
              autofocus: true,
              onSubmitted: (_) => _sendCode(),
            ),
          ),
          const SizedBox(height: 14),
          NButton(label: 'Email me a code', icon: Icons.mail_outline_rounded, variant: NButtonVariant.accent, busy: _busy, onPressed: _sendCode),
          if (AppConfig.googleClientId.isNotEmpty || AppConfig.appleClientId.isNotEmpty || _passwordOn) ...[
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: Divider(color: t.divider)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('or', style: t.text.caption())),
              Expanded(child: Divider(color: t.divider)),
            ]),
            const SizedBox(height: 14),
          ],
          if (AppConfig.googleClientId.isNotEmpty)
            Center(
              child: bridge.googleButton(
                    clientId: AppConfig.googleClientId,
                    onToken: (token) => _run(() => _session.google(token)),
                    onError: () => setState(() => _error = "Google sign-in couldn't start. Use your email instead."),
                  ) ??
                  const SizedBox.shrink(),
            ),
          if (AppConfig.appleClientId.isNotEmpty) ...[
            const SizedBox(height: 10),
            NButton(
              label: 'Continue with Apple',
              icon: Icons.apple,
              variant: NButtonVariant.secondary,
              busy: _busy,
              onPressed: () => _run(() async {
                final token = await bridge.appleSignIn(AppConfig.appleClientId, AppConfig.appleRedirectUri);
                if (token == null) throw const ApiException(status: 0, code: 'APPLE_CANCELLED', message: 'Apple sign-in was cancelled.');
                await _session.apple(token);
              }),
            ),
          ],
          if (_passwordOn) ...[
            const SizedBox(height: 10),
            NButton(label: 'Sign in with a password', icon: Icons.password_rounded, variant: NButtonVariant.secondary, onPressed: () => setState(() => _step = _Step.password)),
          ],
          const SizedBox(height: 14),
          Center(child: TextButton(onPressed: () => setState(() => _step = _Step.recovery), child: Text('Lost access? Use a recovery code', style: t.text.caption(color: t.ink)))),
          Center(child: TextButton(onPressed: () => context.go('/status'), child: Text('Server status', style: t.text.caption()))),
        ]);
      case _Step.code:
        children.addAll([
          Text('Check your email', style: t.text.heading(size: 28)),
          const SizedBox(height: 4),
          Text('If ${_destination ?? 'that address'} has an account, a 6-digit code is on its way. It expires in a few minutes.', style: t.text.body(color: t.muted)),
          const SizedBox(height: 18),
          NTextField(
            label: 'Code',
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            autofillHints: const [AutofillHints.oneTimeCode],
            autofocus: true,
            onSubmitted: (_) => _verify(),
            onChanged: (v) {
              if (v.length == 6 && !_busy) _verify();
            },
          ),
          const SizedBox(height: 14),
          NButton(label: 'Sign in', variant: NButtonVariant.accent, busy: _busy, onPressed: _verify),
          const SizedBox(height: 10),
          Wrap(alignment: WrapAlignment.spaceBetween, children: [
            TextButton(onPressed: () => setState(() => _step = _Step.identifier), child: Text('Use a different email', style: t.text.caption(color: t.ink))),
            TextButton(
              onPressed: _resendIn > 0 || _busy ? null : _sendCode,
              child: Text(_resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Send a new code', style: t.text.caption(color: _resendIn > 0 ? t.muted : t.ink)),
            ),
          ]),
        ]);
      case _Step.password:
        children.addAll([
          ..._setupBanner(),
          Text('Sign in', style: t.text.heading(size: 28)),
          const SizedBox(height: 18),
          AutofillGroup(
            child: Column(children: [
              NTextField(label: 'Work email', controller: _identifier, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.username]),
              const SizedBox(height: 12),
              NTextField(label: 'Password', controller: _password, obscure: true, autofillHints: const [AutofillHints.password], onSubmitted: (_) => _run(() => _session.password(_identifier.text, _password.text))),
            ]),
          ),
          const SizedBox(height: 14),
          NButton(label: 'Sign in', variant: NButtonVariant.accent, busy: _busy, onPressed: () => _run(() => _session.password(_identifier.text, _password.text))),
          if (_emailCodes)
            TextButton(onPressed: () => setState(() => _step = _Step.identifier), child: Text('Use an email code instead', style: t.text.caption(color: t.ink)))
          else
            TextButton(onPressed: () => setState(() => _step = _Step.recovery), child: Text('Forgot your password? Use a recovery code', style: t.text.caption(color: t.ink))),
          Center(child: TextButton(onPressed: () => context.go('/status'), child: Text('Server status', style: t.text.caption()))),
        ]);
      case _Step.recovery:
        children.addAll([
          Text('Recovery code', style: t.text.heading(size: 28)),
          const SizedBox(height: 4),
          Text('Each recovery code works once. Signing in this way alerts your security team.', style: t.text.body(color: t.muted)),
          const SizedBox(height: 18),
          NTextField(label: 'Work email', controller: _identifier, keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 12),
          NTextField(label: 'Recovery code', controller: _code, inputFormatters: [LengthLimitingTextInputFormatter(20)]),
          const SizedBox(height: 14),
          NButton(label: 'Sign in', variant: NButtonVariant.accent, busy: _busy, onPressed: () => _run(() => _session.recover(_identifier.text, _code.text))),
          TextButton(
            onPressed: () => setState(() => _step = !_emailCodes && _passwordOn ? _Step.password : _Step.identifier),
            child: Text('Back to sign in', style: t.text.caption(color: t.ink)),
          ),
        ]);
    }
    return AuthFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.expired && _step == _Step.identifier) ...[
          const NBanner(message: 'Your session ended. Sign in again to continue.', tone: NBannerTone.warning),
          const SizedBox(height: 14),
        ],
        if (_error != null) ...[NBanner(message: _error!, tone: NBannerTone.danger), const SizedBox(height: 14)],
        ...children,
      ]),
    );
  }
}

/// Invitation acceptance: proves control of the invited email with a code, then signs in.
class InvitationPage extends StatefulWidget {
  const InvitationPage({super.key, required this.token});
  final String token;

  @override
  State<InvitationPage> createState() => _InvitationPageState();
}

class _InvitationPageState extends State<InvitationPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final session = context.services.session;
    return AuthFrame(
      child: AsyncView<Json>(
        load: () async => jsonMap(await context.api.get('/auth/invitations/${widget.token}')),
        builder: (context, inv, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Join ${inv['organization']}', style: t.text.heading(size: 26)),
          const SizedBox(height: 4),
          Text('You were invited as ${Fmt.label(inv['role'])}${inv['email'] != null ? ' using ${inv['email']}' : ''}. The invitation expires ${Fmt.dateTime(inv['expiresAt'])}.', style: t.text.body(color: t.muted)),
          const SizedBox(height: 18),
          if (_error != null) ...[NBanner(message: _error!, tone: NBannerTone.danger), const SizedBox(height: 12)],
          NTextField(label: 'Invited email', controller: _email, keyboardType: TextInputType.emailAddress, enabled: !_sent),
          const SizedBox(height: 12),
          if (!_sent)
            NButton(
              label: 'Email me a code',
              variant: NButtonVariant.accent,
              busy: _busy,
              onPressed: () => _run(() async {
                await session.requestOtp(_email.text);
                setState(() => _sent = true);
              }),
            )
          else ...[
            NTextField(label: '6-digit code', controller: _code, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)], autofocus: true),
            const SizedBox(height: 12),
            NButton(label: 'Accept and sign in', variant: NButtonVariant.accent, busy: _busy, onPressed: () => _run(() => session.acceptInvitation(widget.token, _code.text))),
          ],
          TextButton(onPressed: () => context.go('/login'), child: Text('I already have an account', style: t.text.caption(color: t.ink))),
        ]),
      ),
    );
  }
}
