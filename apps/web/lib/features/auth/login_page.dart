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

/// Centered sign-in card framed by the N UI page background and ambient glow.
class AuthFrame extends StatelessWidget {
  const AuthFrame({super.key, required this.child, this.maxWidth = 440});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isMobile = NBreakpoint.of(context).isMobile;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NPageBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                // Brand, card and footer rise in one after another; the mark keeps a gentle pulse.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NEntrance(
                      order: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SignalMark(size: 46),
                          const SizedBox(height: 12),
                          const SignalWordmark(size: 26),
                          const SizedBox(height: 4),
                          Text(
                            'People & Operations Platform',
                            textAlign: TextAlign.center,
                            style: t.text.caption(color: t.muted, weight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    NEntrance(
                      order: 1,
                      child: NGlassCard(
                        padding: EdgeInsets.all(isMobile ? 20 : 28),
                        child: child,
                      ),
                    ),
                    const SizedBox(height: 18),
                    NEntrance(
                      order: 2,
                      child: Column(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(NTokens.radiusPill),
                            onTap: () => context.go('/status'),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(shape: BoxShape.circle, color: t.green),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'All systems normal · Server status',
                                    style: t.text.caption(color: t.muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            kNUiAttribution,
                            textAlign: TextAlign.center,
                            style: t.text.caption(color: t.muted.withValues(alpha: 0.85)),
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
  bool _codeSent = false;
  String? _error;
  String? _destination;
  bool _busy = false;
  int _resendIn = 0;
  Timer? _timer;

  SessionController get _session => context.services.session;

  /// Sign-in options this server offers (GET /setup/status).
  Json? _server;

  @override
  void initState() {
    super.initState();
    if (!AppConfig.passwordLogin) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final s = jsonMap(await context.api.get('/setup/status'));
          if (mounted) setState(() => _server = s);
        } catch (_) {}
      });
    }
  }

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
    await _run(() => _session.password(id, pwd));
  }

  Future<void> _sendCode() async {
    final id = _identifier.text.trim();
    if (id.length < 3) {
      setState(() => _error = 'Enter your work email or mobile number.');
      return;
    }
    await _run(() async {
      final r = await _session.requestOtp(id);
      if (mounted) {
        setState(() {
          _destination = r.destination;
          _code.clear();
          _codeSent = true;
          _mode = _AuthMode.otp;
          _startTimer(r.resendAfterSeconds);
        });
      }
    });
  }

  Future<void> _verifyOtp() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit verification code.');
      return;
    }
    await _run(() => _session.verifyOtp(_identifier.text.trim(), code));
  }

  List<Widget> _setupBanner() => [
        if (_server?['setupAvailable'] == true) ...[
          const NBanner(
            message: "This server isn't set up yet. Create the first administrator to start.",
            tone: NBannerTone.info,
          ),
          const SizedBox(height: 12),
          NButton(
            label: 'Set up Signal HRM',
            icon: Icons.rocket_launch_outlined,
            variant: NButtonVariant.accent,
            onPressed: () => context.go('/setup'),
          ),
          const SizedBox(height: 18),
        ],
      ];

  Widget _buildPasswordForm(NTokens t) {
    return Column(
      key: const ValueKey('password_form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AutofillGroup(
          child: Column(
            children: [
              NTextField(
                label: 'Work email',
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                prefixIcon: Icons.alternate_email_rounded,
                hint: 'alex@company.com',
                autofillHints: const [AutofillHints.email, AutofillHints.username],
                textInputAction: TextInputAction.next,
                autofocus: true,
              ),
              const SizedBox(height: 14),
              NTextField(
                label: 'Password',
                controller: _password,
                obscure: _obscurePassword,
                prefixIcon: Icons.lock_outline_rounded,
                hint: '••••••••••••',
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.go,
                suffix: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20,
                    color: t.muted,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
                onSubmitted: (_) => _submitPassword(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        NButton(
          label: 'Sign in',
          icon: Icons.arrow_forward_rounded,
          variant: NButtonVariant.accent,
          busy: _busy,
          onPressed: _submitPassword,
        ),
      ],
    );
  }

  Widget _buildOtpForm(NTokens t) {
    if (!_codeSent) {
      return Column(
        key: const ValueKey('otp_request_form'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AutofillGroup(
            child: NTextField(
              label: 'Work email or mobile number',
              controller: _identifier,
              keyboardType: TextInputType.emailAddress,
              prefixIcon: Icons.alternate_email_rounded,
              hint: 'alex@company.com or +1...',
              autofillHints: const [AutofillHints.email, AutofillHints.telephoneNumber],
              textInputAction: TextInputAction.go,
              autofocus: true,
              onSubmitted: (_) => _sendCode(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We will send a 6-digit one-time passcode to verify your identity.',
            style: t.text.caption(color: t.muted),
          ),
          const SizedBox(height: 16),
          NButton(
            label: 'Send verification code',
            icon: Icons.send_rounded,
            variant: NButtonVariant.accent,
            busy: _busy,
            onPressed: _sendCode,
          ),
        ],
      );
    } else {
      return Column(
        key: const ValueKey('otp_verify_form'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(t.radiusTile),
              border: Border.all(color: t.green.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: t.green.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.mark_email_read_rounded, color: t.green, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Verification Code Sent', style: t.text.caption(color: t.green, weight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        _destination ?? _identifier.text,
                        style: t.text.caption(color: t.ink, weight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _codeSent = false;
                    _code.clear();
                  }),
                  child: Text('Edit', style: t.text.caption(color: t.accent, weight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          NTextField(
            label: '6-digit OTP code',
            controller: _code,
            keyboardType: TextInputType.number,
            prefixIcon: Icons.pin_outlined,
            hint: '••••••',
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            autofillHints: const [AutofillHints.oneTimeCode],
            autofocus: true,
            onSubmitted: (_) => _verifyOtp(),
            onChanged: (v) {
              if (v.trim().length == 6 && !_busy) _verifyOtp();
            },
          ),
          const SizedBox(height: 16),
          NButton(
            label: 'Verify code & sign in',
            icon: Icons.login_rounded,
            variant: NButtonVariant.accent,
            busy: _busy,
            onPressed: _verifyOtp,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.arrow_back_rounded, size: 14),
                label: Text('Change email', style: t.text.caption(color: t.ink)),
                onPressed: () => setState(() {
                  _codeSent = false;
                  _code.clear();
                }),
              ),
              TextButton.icon(
                icon: Icon(Icons.refresh_rounded, size: 14, color: _resendIn > 0 ? t.muted : t.accent),
                label: Text(
                  _resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend code',
                  style: t.text.caption(color: _resendIn > 0 ? t.muted : t.accent, weight: FontWeight.w600),
                ),
                onPressed: _resendIn > 0 || _busy ? null : _sendCode,
              ),
            ],
          ),
        ],
      );
    }
  }

  Widget _buildRecoveryForm(NTokens t) {
    return Column(
      key: const ValueKey('recovery_mode'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            NIconButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back to sign in',
              onPressed: () => setState(() {
                _mode = _AuthMode.password;
                _error = null;
              }),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recovery code', style: t.text.heading(size: 22)),
                  Text('One-time emergency sign-in', style: t.text.caption(color: t.muted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const NBanner(
          message: 'Each recovery code works once. Signing in this way alerts your security team.',
          tone: NBannerTone.warning,
        ),
        const SizedBox(height: 18),
        NTextField(
          label: 'Work email',
          controller: _identifier,
          keyboardType: TextInputType.emailAddress,
          prefixIcon: Icons.alternate_email_rounded,
          hint: 'alex@company.com',
          autofillHints: const [AutofillHints.email, AutofillHints.username],
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 14),
        NTextField(
          label: 'Recovery code',
          controller: _code,
          prefixIcon: Icons.key_rounded,
          hint: 'XXXX-XXXX-XXXX-XXXX',
          inputFormatters: [LengthLimitingTextInputFormatter(24)],
          autofocus: true,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _run(() => _session.recover(_identifier.text.trim(), _code.text.trim())),
        ),
        const SizedBox(height: 18),
        NButton(
          label: 'Sign in with recovery code',
          icon: Icons.lock_open_rounded,
          variant: NButtonVariant.accent,
          busy: _busy,
          onPressed: () => _run(() => _session.recover(_identifier.text.trim(), _code.text.trim())),
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: () => setState(() {
              _mode = _AuthMode.password;
              _error = null;
            }),
            child: Text('Cancel and return to sign in', style: t.text.caption(color: t.ink)),
          ),
        ),
      ],
    );
  }

  Widget _ssoSection(NTokens t) {
    final hasGoogle = AppConfig.googleClientId.isNotEmpty;
    final hasApple = AppConfig.appleClientId.isNotEmpty;
    if (!hasGoogle && !hasApple) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Divider(color: t.divider, height: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or continue with', style: t.text.caption(color: t.muted)),
            ),
            Expanded(child: Divider(color: t.divider, height: 1)),
          ],
        ),
        const SizedBox(height: 16),
        if (hasGoogle)
          Center(
            child: bridge.googleButton(
                  clientId: AppConfig.googleClientId,
                  onToken: (token) => _run(() => _session.google(token)),
                  onError: () => setState(() => _error = "Google sign-in couldn't start. Use email and password instead."),
                ) ??
                const SizedBox.shrink(),
          ),
        if (hasApple) ...[
          if (hasGoogle) const SizedBox(height: 10),
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
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);

    Widget content;
    if (_mode == _AuthMode.recovery) {
      content = _buildRecoveryForm(t);
    } else {
      content = Column(
        key: const ValueKey('main_login_form'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._setupBanner(),
          Text('Sign in', style: t.text.heading(size: 28)),
          const SizedBox(height: 4),
          Text(
            'Welcome back! Enter your work credentials to access your account.',
            style: t.text.body(color: t.muted),
          ),
          const SizedBox(height: 18),
          NSlidingPills(
            items: const [
              NPillItem(label: 'Password', icon: Icons.password_rounded),
              NPillItem(label: 'One-time code', icon: Icons.mail_outline_rounded),
            ],
            selectedIndex: _mode == _AuthMode.password ? 0 : 1,
            expand: true,
            size: NPillSize.medium,
            onChanged: (i) => setState(() {
              _mode = i == 0 ? _AuthMode.password : _AuthMode.otp;
              _error = null;
            }),
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: NCurves.emphasized,
            switchOutCurve: Curves.easeIn,
            child: _mode == _AuthMode.password ? _buildPasswordForm(t) : _buildOtpForm(t),
          ),
          _ssoSection(t),
          const SizedBox(height: 18),
          Center(
            child: TextButton.icon(
              icon: Icon(Icons.vpn_key_outlined, size: 14, color: t.muted),
              label: Text('Lost access? Use a recovery code', style: t.text.caption(color: t.muted)),
              onPressed: () => setState(() {
                _mode = _AuthMode.recovery;
                _error = null;
              }),
            ),
          ),
        ],
      );
    }

    return AuthFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.expired) ...[
            const NBanner(message: 'Your session ended. Sign in again to continue.', tone: NBannerTone.warning),
            const SizedBox(height: 14),
          ],
          if (_error != null) ...[
            NBanner(message: _error!, tone: NBannerTone.danger),
            const SizedBox(height: 14),
          ],
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: NCurves.emphasized,
            switchOutCurve: Curves.easeIn,
            child: content,
          ),
        ],
      ),
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
        builder: (context, inv, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Join ${inv['organization'] ?? 'Signal HRM'}', style: t.text.heading(size: 26)),
            const SizedBox(height: 6),
            Text(
              'You were invited as ${Fmt.label(inv['role'])}${inv['email'] != null ? ' using ${inv['email']}' : ''}. The invitation expires ${Fmt.dateTime(inv['expiresAt'])}.',
              style: t.text.body(color: t.muted),
            ),
            const SizedBox(height: 18),
            if (_error != null) ...[
              NBanner(message: _error!, tone: NBannerTone.danger),
              const SizedBox(height: 14),
            ],
            NTextField(
              label: 'Invited email',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              prefixIcon: Icons.alternate_email_rounded,
              hint: 'alex@company.com',
              enabled: !_sent,
            ),
            const SizedBox(height: 14),
            if (!_sent)
              NButton(
                label: 'Email me a code',
                icon: Icons.send_rounded,
                variant: NButtonVariant.accent,
                busy: _busy,
                onPressed: () => _run(() async {
                  await session.requestOtp(_email.text);
                  setState(() => _sent = true);
                }),
              )
            else ...[
              NTextField(
                label: '6-digit code',
                controller: _code,
                keyboardType: TextInputType.number,
                prefixIcon: Icons.pin_outlined,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                autofocus: true,
              ),
              const SizedBox(height: 14),
              NButton(
                label: 'Accept and sign in',
                icon: Icons.check_circle_outline_rounded,
                variant: NButtonVariant.accent,
                busy: _busy,
                onPressed: () => _run(() => session.acceptInvitation(widget.token, _code.text)),
              ),
            ],
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: () => context.go('/login'),
                child: Text('I already have an account', style: t.text.caption(color: t.ink)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
