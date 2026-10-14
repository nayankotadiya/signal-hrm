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

/// Centered sign-in card on the page background with modern ambient lighting.
class AuthFrame extends StatelessWidget {
  const AuthFrame({super.key, required this.child, this.maxWidth = 450});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isDark = t.isDark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const NPageBackground(child: SizedBox.expand()),
          // Ambient lighting spheres
          Positioned(
            top: -100,
            left: -80,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    t.accent.withValues(alpha: isDark ? 0.25 : 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -90,
            right: -70,
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    (isDark ? const Color(0xFF06B6D4) : const Color(0xFF3B82F6)).withValues(alpha: isDark ? 0.20 : 0.15),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NEntrance(
                        order: 0,
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: t.card.withValues(alpha: isDark ? 0.45 : 0.8),
                                border: Border.all(
                                  color: t.accent.withValues(alpha: isDark ? 0.35 : 0.2),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: t.accent.withValues(alpha: isDark ? 0.28 : 0.14),
                                    blurRadius: 22,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: const SignalMark(size: 44),
                            ),
                            const SizedBox(height: 12),
                            const SignalWordmark(size: 26),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: t.accent.withValues(alpha: isDark ? 0.18 : 0.10),
                                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                border: Border.all(
                                  color: t.accent.withValues(alpha: isDark ? 0.3 : 0.2),
                                ),
                              ),
                              child: Text(
                                'PEOPLE • WORK • TIME • OPERATIONS',
                                style: t.text.caption(weight: FontWeight.w700).copyWith(
                                      color: t.accent,
                                      letterSpacing: 1.2,
                                      fontSize: 10.5,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      NEntrance(
                        order: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.08),
                                blurRadius: 32,
                                offset: const Offset(0, 12),
                                spreadRadius: -4,
                              ),
                              BoxShadow(
                                color: t.accent.withValues(alpha: isDark ? 0.10 : 0.04),
                                blurRadius: 24,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: NGlassCard(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
                              child: child,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      NEntrance(
                        order: 2,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield_outlined, size: 13, color: t.muted),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Enterprise Grade Security · 256-bit Encrypted',
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: t.text.caption(color: t.muted).copyWith(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _AuthMode { password, recovery }

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.expired = false, this.recovery = false});
  final bool expired;
  final bool recovery;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late _AuthMode _mode = widget.recovery ? _AuthMode.recovery : _AuthMode.password;
  final _identifier = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  bool _keepSignedIn = true;
  String? _error;
  bool _busy = false;

  SessionController get _session => context.services.session;

  /// Sign-in options this server offers (GET /setup/status).
  Json? _server;

  @override
  void initState() {
    super.initState();
    final savedEmail = bridge.readLocal('shrm_remembered_email');
    if (savedEmail != null && savedEmail.isNotEmpty) {
      _identifier.text = savedEmail;
    }
    final savedKeep = bridge.readLocal('shrm_keep_signed_in');
    if (savedKeep != null) {
      _keepSignedIn = savedKeep == '1' || savedKeep == 'true';
    }
    if (!AppConfig.passwordLogin) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final s = jsonMap(await context.api.get('/setup/status'));
          if (mounted) setState(() => _server = s);
        } catch (_) {}
      });
    }
  }

  void _persistRememberPreference(String email) {
    if (_keepSignedIn) {
      bridge.writeLocal('shrm_remembered_email', email);
      bridge.writeLocal('shrm_keep_signed_in', 'true');
    } else {
      bridge.writeLocal('shrm_remembered_email', null);
      bridge.writeLocal('shrm_keep_signed_in', 'false');
      bridge.writeLocal('shrm_rt', null);
    }
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
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
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

  Future<void> _submitPassword() async {
    final id = _identifier.text.trim();
    final pwd = _password.text;
    if (id.isEmpty) {
      setState(() => _error = 'Enter your work email.');
      return;
    }
    if (pwd.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    await _run(() async {
      await _session.password(id, pwd, rememberMe: _keepSignedIn);
      _persistRememberPreference(id);
    });
  }

  Widget _buildKeepSignedInRow(NTokens t) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() => _keepSignedIn = !_keepSignedIn);
          bridge.writeLocal('shrm_keep_signed_in', _keepSignedIn ? 'true' : 'false');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _keepSignedIn ? t.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _keepSignedIn ? t.accent : t.muted.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: _keepSignedIn
                    ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 10),
              Text(
                'Keep me signed in',
                style: t.text.body(color: t.ink, weight: FontWeight.w500).copyWith(fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final children = <Widget>[];

    if (_mode == _AuthMode.recovery) {
      children.addAll([
        Text('Recovery code', style: t.text.heading(size: 28)),
        const SizedBox(height: 4),
        Text('Each recovery code works once. Signing in this way alerts your security team.', style: t.text.body(color: t.muted)),
        const SizedBox(height: 18),
        NTextField(
          label: 'Work email',
          controller: _identifier,
          keyboardType: TextInputType.emailAddress,
          prefixIcon: Icons.alternate_email_rounded,
          autofillHints: const [AutofillHints.email, AutofillHints.username],
        ),
        const SizedBox(height: 14),
        NTextField(
          label: 'Recovery code',
          controller: _code,
          prefixIcon: Icons.key_rounded,
          inputFormatters: [LengthLimitingTextInputFormatter(20)],
          autofocus: true,
          onSubmitted: (_) => _run(() => _session.recover(_identifier.text.trim(), _code.text.trim())),
        ),
        const SizedBox(height: 14),
        NButton(
          label: 'Sign in with recovery code',
          icon: Icons.key_rounded,
          variant: NButtonVariant.accent,
          busy: _busy,
          onPressed: () => _run(() => _session.recover(_identifier.text.trim(), _code.text.trim())),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () => setState(() {
              _mode = _AuthMode.password;
              _error = null;
            }),
            child: Text('Back to sign in', style: t.text.caption(color: t.ink)),
          ),
        ),
      ]);
    } else {
      // Unified Main Login (Password & OTP seamlessly together)
      children.addAll([
        ..._setupBanner(),
        Text('Sign in', style: t.text.heading(size: 28)),
        const SizedBox(height: 4),
        Text('Welcome back! Enter your work credentials to access your account.', style: t.text.body(color: t.muted)),
        const SizedBox(height: 20),

        AutofillGroup(
          child: Column(
            children: [
              NTextField(
                label: 'Work email',
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email, AutofillHints.username],
                prefixIcon: Icons.alternate_email_rounded,
                textInputAction: TextInputAction.next,
                autofocus: true,
              ),
              const SizedBox(height: 14),
              NTextField(
                label: 'Password',
                controller: _password,
                obscure: _obscurePassword,
                autofillHints: const [AutofillHints.password],
                prefixIcon: Icons.lock_outline_rounded,
                textInputAction: TextInputAction.go,
                suffix: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20, color: t.muted),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
                onSubmitted: (_) => _submitPassword(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            _buildKeepSignedInRow(t),
            TextButton(
              onPressed: () => setState(() {
                _mode = _AuthMode.recovery;
                _error = null;
              }),
              child: Text('Forgot password?', style: t.text.caption(color: t.accent).copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        NButton(
          label: 'Sign in to Account',
          icon: Icons.login_rounded,
          variant: NButtonVariant.accent,
          busy: _busy,
          onPressed: _submitPassword,
        ),

        // Single Sign-On (Google / Apple)
        if (AppConfig.googleClientId.isNotEmpty || AppConfig.appleClientId.isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: Divider(color: t.divider)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('or continue with', style: t.text.caption())),
            Expanded(child: Divider(color: t.divider)),
          ]),
          const SizedBox(height: 14),
        ],

        if (AppConfig.googleClientId.isNotEmpty)
          Center(
            child: bridge.googleButton(
                  clientId: AppConfig.googleClientId,
                  onToken: (token) => _run(() => _session.google(token)),
                  onError: () => setState(() => _error = "Google sign-in couldn't start. Use email and password instead."),
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

        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: () => setState(() {
              _mode = _AuthMode.recovery;
              _error = null;
            }),
            child: Text('Lost access? Use a recovery code', style: t.text.caption(color: t.ink)),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () => context.go('/status'),
            child: Text('Server status', style: t.text.caption()),
          ),
        ),
      ]);
    }

    return AuthFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.expired) ...[
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
