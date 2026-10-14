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
  const AuthFrame({super.key, required this.child, this.maxWidth = 440});
  final Widget child;
  final double maxWidth;

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
                constraints: BoxConstraints(maxWidth: maxWidth),
                // Brand, card and footer rise in one after another; the mark keeps a gentle pulse.
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const NEntrance(
                    order: 0,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 14,
                      runSpacing: 8,
                      children: [
                        SignalMark(size: 44),
                        SignalWordmark(size: 24),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
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
  bool _keepSignedIn = true;
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
    await _run(() async {
      await _session.password(id, pwd, rememberMe: _keepSignedIn);
      _persistRememberPreference(id);
    });
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
    final id = _identifier.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    await _run(() async {
      await _session.verifyOtp(id, code, rememberMe: _keepSignedIn);
      _persistRememberPreference(id);
    });
  }

  Widget _buildKeepSignedInRow(NTokens t) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _keepSignedIn = !_keepSignedIn),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _keepSignedIn,
                onChanged: (v) => setState(() => _keepSignedIn = v ?? true),
                activeColor: t.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Keep me signed in',
              style: t.text.caption(color: t.ink).copyWith(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
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
          autofillHints: const [AutofillHints.email, AutofillHints.username],
        ),
        const SizedBox(height: 12),
        NTextField(
          label: 'Recovery code',
          controller: _code,
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
        const SizedBox(height: 18),

        // Responsive, instant-touch Segmented Mode Selector
        Container(
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: t.pillTrack,
            borderRadius: BorderRadius.circular(NTokens.radiusPill),
            border: t.cardBorder == const Color(0x00000000) ? null : Border.all(color: t.cardBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    onTap: () {
                      setState(() {
                        _mode = _AuthMode.password;
                        _error = null;
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: _mode == _AuthMode.password ? t.card : Colors.transparent,
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        boxShadow: _mode == _AuthMode.password
                            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.password_rounded, size: 16, color: _mode == _AuthMode.password ? t.ink : t.muted),
                          const SizedBox(width: 8),
                          Text(
                            'Password',
                            style: t.text.caption(color: _mode == _AuthMode.password ? t.ink : t.muted).copyWith(
                                  fontWeight: _mode == _AuthMode.password ? FontWeight.w600 : FontWeight.w500,
                                  fontSize: 13,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    onTap: () {
                      setState(() {
                        _mode = _AuthMode.otp;
                        _error = null;
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: _mode == _AuthMode.otp ? t.card : Colors.transparent,
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        boxShadow: _mode == _AuthMode.otp
                            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.mail_outline_rounded, size: 16, color: _mode == _AuthMode.otp ? t.ink : t.muted),
                          const SizedBox(width: 8),
                          Text(
                            'One-time OTP',
                            style: t.text.caption(color: _mode == _AuthMode.otp ? t.ink : t.muted).copyWith(
                                  fontWeight: _mode == _AuthMode.otp ? FontWeight.w600 : FontWeight.w500,
                                  fontSize: 13,
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
        ),
        const SizedBox(height: 18),

        if (_mode == _AuthMode.password) ...[
          AutofillGroup(
            child: Column(
              children: [
                NTextField(
                  label: 'Work email',
                  controller: _identifier,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email, AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                NTextField(
                  label: 'Password',
                  controller: _password,
                  obscure: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
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
                child: Text('Forgot password?', style: t.text.caption(color: t.accent).copyWith(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          NButton(
            label: 'Sign in',
            icon: Icons.arrow_forward_rounded,
            variant: NButtonVariant.accent,
            busy: _busy,
            onPressed: _submitPassword,
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.mail_outline_rounded, size: 16),
              label: Text('Sign in with Email OTP instead', style: t.text.caption(color: t.ink)),
              onPressed: () => setState(() {
                _mode = _AuthMode.otp;
                _error = null;
              }),
            ),
          ),
        ] else ...[
          // OTP Mode
          if (!_codeSent) ...[
            AutofillGroup(
              child: NTextField(
                label: 'Work email or mobile number',
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email, AutofillHints.telephoneNumber],
                textInputAction: TextInputAction.go,
                autofocus: true,
                onSubmitted: (_) => _sendCode(),
              ),
            ),
            const SizedBox(height: 6),
            Text('We will send a 6-digit code to verify your identity.', style: t.text.caption(color: t.muted)),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: _buildKeepSignedInRow(t)),
            const SizedBox(height: 14),
            NButton(
              label: 'Send 6-digit verification code',
              icon: Icons.send_rounded,
              variant: NButtonVariant.accent,
              busy: _busy,
              onPressed: _sendCode,
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.password_rounded, size: 16),
                label: Text('Sign in with Password instead', style: t.text.caption(color: t.ink)),
                onPressed: () => setState(() {
                  _mode = _AuthMode.password;
                  _error = null;
                }),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: t.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.green.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.mark_email_read_rounded, color: t.green, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Verification Code Sent ✓', style: t.text.caption(color: t.green).copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('Check inbox: ${_destination ?? _identifier.text}', style: t.text.caption(color: t.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('Enter 6-digit Code', style: t.text.title(size: 15)),
            const SizedBox(height: 8),
            NTextField(
              label: '6-digit OTP code',
              controller: _code,
              keyboardType: TextInputType.number,
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
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _codeSent = false;
                    _code.clear();
                  }),
                  child: Text('Change email address', style: t.text.caption(color: t.ink)),
                ),
                TextButton(
                  onPressed: _resendIn > 0 || _busy ? null : _sendCode,
                  child: Text(
                    _resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend code',
                    style: t.text.caption(color: _resendIn > 0 ? t.muted : t.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.password_rounded, size: 16),
                label: Text('Use Password instead', style: t.text.caption(color: t.muted)),
                onPressed: () => setState(() {
                  _mode = _AuthMode.password;
                  _error = null;
                }),
              ),
            ),
          ],
        ],

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
