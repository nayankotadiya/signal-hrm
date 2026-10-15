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
                        order: 1,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
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
                            const SizedBox(height: 10),
                            Text(
                              kNUiAttribution,
                              textAlign: TextAlign.center,
                              style: t.text.caption(
                                color: t.muted.withValues(alpha: isDark ? 0.75 : 0.85),
                                weight: FontWeight.w500,
                              ).copyWith(fontSize: 12),
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

enum _AuthMode { password, otp, recovery }

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

  // OTP state
  bool _codeSent = false;
  String? _destination;
  String? _codePreview;
  String? _deliveryNotice;
  int _resendIn = 0;
  Timer? _resendTimer;

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
    _resendTimer?.cancel();
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

  Future<void> _sendCode() async {
    final id = _identifier.text.trim();
    if (id.isEmpty) {
      setState(() => _error = 'Enter your work email or mobile number.');
      return;
    }
    await _run(() async {
      final sent = await _session.requestOtp(id);
      _persistRememberPreference(id);
      if (mounted) {
        setState(() {
          _codeSent = true;
          _destination = sent.destination;
          _codePreview = sent.codePreview;
          _deliveryNotice = sent.notice;
          _resendIn = sent.resendAfterSeconds;
          if (sent.codePreview != null && sent.codePreview!.isNotEmpty) {
            _code.text = sent.codePreview!;
          }
        });
        _startResendTimer();
      }
    });
  }

  void _startResendTimer() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendIn <= 1) {
        timer.cancel();
        setState(() => _resendIn = 0);
      } else {
        setState(() => _resendIn--);
      }
    });
  }

  Future<void> _verifyOtp() async {
    final id = _identifier.text.trim();
    final c = _code.text.trim();
    if (id.isEmpty) {
      setState(() => _error = 'Enter your work email or mobile number.');
      return;
    }
    if (c.length != 6) {
      setState(() => _error = 'Enter the 6-digit verification code.');
      return;
    }
    await _run(() async {
      await _session.verifyOtp(id, c, rememberMe: _keepSignedIn);
      _persistRememberPreference(id);
    });
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
        Text('Welcome back! Choose your preferred way to sign in.', style: t.text.body(color: t.muted)),
        const SizedBox(height: 18),

        // Segmented Switch: Password vs Email Code
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.divider),
          ),
          child: Row(
            children: [
              Expanded(
                child: _TabButton(
                  title: 'Password',
                  icon: Icons.lock_outline_rounded,
                  selected: _mode == _AuthMode.password,
                  onTap: () => setState(() {
                    _mode = _AuthMode.password;
                    _error = null;
                  }),
                ),
              ),
              Expanded(
                child: _TabButton(
                  title: 'Email Code (OTP)',
                  icon: Icons.mark_email_read_outlined,
                  selected: _mode == _AuthMode.otp,
                  onTap: () => setState(() {
                    _mode = _AuthMode.otp;
                    _error = null;
                  }),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        if (_mode == _AuthMode.password) ...[
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
            label: 'Sign in with Password',
            icon: Icons.login_rounded,
            variant: NButtonVariant.accent,
            busy: _busy,
            onPressed: _submitPassword,
          ),
        ] else ...[
          // Email Code (OTP) Mode
          AutofillGroup(
            child: NTextField(
              label: 'Work email or mobile number',
              controller: _identifier,
              keyboardType: TextInputType.emailAddress,
              prefixIcon: Icons.alternate_email_rounded,
              autofillHints: const [AutofillHints.email, AutofillHints.telephoneNumber],
              textInputAction: TextInputAction.next,
              autofocus: !_codeSent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: NButton(
                  label: _resendIn > 0
                      ? 'Resend code in ${_resendIn}s'
                      : (_codeSent ? 'Resend verification code' : 'Send 6-digit verification code'),
                  icon: Icons.send_rounded,
                  variant: _codeSent ? NButtonVariant.secondary : NButtonVariant.accent,
                  busy: _busy,
                  onPressed: _resendIn > 0 || _busy ? null : _sendCode,
                ),
              ),
            ],
          ),
          if (_codeSent) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: t.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.green.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.mark_email_read_rounded, color: t.green, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Code sent to ${_destination ?? _identifier.text}',
                      style: t.text.caption(color: t.ink, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            if (_codePreview != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.verified_rounded, color: t.accent, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Verification Code: $_codePreview', style: t.text.body(color: t.accent, weight: FontWeight.w700)),
                          if (_deliveryNotice != null)
                            Text(_deliveryNotice!, style: t.text.caption(color: t.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Enter 6-digit Code', style: t.text.title(size: 15)),
            const SizedBox(height: 8),
            NTextField(
              label: '6-digit OTP code',
              controller: _code,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.pin_rounded,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              autofillHints: const [AutofillHints.oneTimeCode],
              autofocus: true,
              onSubmitted: (_) => _verifyOtp(),
              onChanged: (v) {
                if (v.trim().length == 6 && !_busy) _verifyOtp();
              },
            ),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: _buildKeepSignedInRow(t)),
            const SizedBox(height: 14),
            NButton(
              label: 'Verify Code & Sign In',
              icon: Icons.login_rounded,
              variant: NButtonVariant.accent,
              busy: _busy,
              onPressed: _verifyOtp,
            ),
          ],
        ],

        // Single Sign-On (Apple if configured)
        if (AppConfig.appleClientId.isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: Divider(color: t.divider)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('or continue with', style: t.text.caption())),
            Expanded(child: Divider(color: t.divider)),
          ]),
          const SizedBox(height: 14),
        ],

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

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Material(
      color: selected ? t.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? Colors.white : t.muted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.text.caption(
                    color: selected ? Colors.white : t.ink,
                    weight: selected ? FontWeight.w700 : FontWeight.w500,
                  ).copyWith(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
