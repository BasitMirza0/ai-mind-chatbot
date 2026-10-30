import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../screens/home_screen.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'conversation_components.dart';
import 'entry_components.dart';
import 'mind_mark.dart';

/// Login and sign-up share one route. Successful authentication returns to the
/// caller (including a draft in Chat), rather than stacking another Home.
class AuthForm extends StatefulWidget {
  final bool signUp;
  final AuthGateway? gateway;
  final WidgetBuilder? homeBuilder;
  const AuthForm({super.key, this.signUp = false, this.gateway, this.homeBuilder});
  @override State<AuthForm> createState() => _AuthFormState();
}
class _AuthFormState extends State<AuthForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  late final AuthGateway _auth = widget.gateway ?? AuthService();
  late bool _signup = widget.signUp;
  bool _busy = false, _obscure = true, _obscureConfirm = true, _done = false;
  String? _error;
  @override void dispose() { _email.dispose(); _password.dispose(); _confirmation.dispose(); super.dispose(); }
  Future<void> _submit({bool google = false}) async {
    if (_busy || _done || (!google && !_form.currentState!.validate())) return;
    FocusScope.of(context).unfocus();
    setState(() { _busy = true; _error = null; });
    String? error;
    try {
      error = google ? await _auth.signInWithGoogle() : _signup
        ? await _auth.signUp(_email.text.trim(), _password.text)
        : await _auth.login(_email.text.trim(), _password.text);
    } catch (_) { error = 'Could not connect. Please try again.'; }
    if (!mounted) return;
    setState(() { _busy = false; _error = error; });
    if (error != null) return;
    _done = true;
    TextInput.finishAutofillContext();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).pushReplacement(mindRoute(context, widget.homeBuilder?.call(context) ?? const HomeScreen()));
    }
  }
  Future<void> _reset(BuildContext context) async {
    await Navigator.of(context).push(mindRoute(context, PasswordResetScreen(gateway: _auth, email: _email.text.trim())));
  }
  String? _emailError(String? value) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '') ? null : 'Enter a valid email address.';
  @override Widget build(BuildContext context) => MindPage(builder: (ctx) => Scaffold(
    resizeToAvoidBottomInset: true,
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
      child: LayoutBuilder(builder: (_, constraints) {
        final gap = constraints.maxHeight < 700 ? 10.0 : 16.0;
        return SingleChildScrollView(key: const Key('auth-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page, vertical: 12),
              child: AutofillGroup(child: Form(key: _form, child: Column(
                mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (Navigator.of(ctx).canPop()) Align(alignment: Alignment.centerLeft, child: IconButton(
            tooltip: 'Back', onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.arrow_back_rounded))),
          const Row(children: [MindMark(size: 40), SizedBox(width: 12), Expanded(child: Text('AI Mind', style: AppTypography.title))]),
          SizedBox(height: gap + 4),
          Text(_signup ? 'Your own space.' : 'Welcome back.', key: const Key('auth-heading'),
            style: AppTypography.title.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4), Text(_signup ? 'Create an account to keep your ideas together.' : 'Sign in to continue your conversations.',
            style: AppTypography.body.copyWith(fontSize: 14, height: 1.4)),
          SizedBox(height: gap + 4),
          TextFormField(key: const Key('auth-email'), controller: _email, enabled: !_busy,
            autofillHints: const [AutofillHints.email], keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next,
            autocorrect: false, validator: _emailError, decoration: authField('Email address', Icons.mail_outline_rounded)),
          SizedBox(height: gap),
          TextFormField(key: const Key('auth-password'), controller: _password, enabled: !_busy,
            autofillHints: [_signup ? AutofillHints.newPassword : AutofillHints.password], obscureText: _obscure,
            enableSuggestions: false, autocorrect: false, textInputAction: _signup ? TextInputAction.next : TextInputAction.done,
            onFieldSubmitted: (_) { if (!_signup) _submit(); },
            validator: (value) => value == null || value.isEmpty ? 'Enter your password.' : _signup && value.length < 6 ? 'Use at least 6 characters.' : null,
            decoration: authField('Password', Icons.lock_outline_rounded).copyWith(suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password', onPressed: _busy ? null : () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined)))),
          if (_signup) ...[SizedBox(height: gap), TextFormField(key: const Key('auth-confirm'), controller: _confirmation,
            enabled: !_busy, obscureText: _obscureConfirm, autocorrect: false, enableSuggestions: false,
            autofillHints: const [AutofillHints.newPassword], textInputAction: TextInputAction.done, onFieldSubmitted: (_) => _submit(),
            validator: (value) => value != _password.text ? 'Passwords do not match.' : null,
            decoration: authField('Confirm password', Icons.lock_outline_rounded).copyWith(suffixIcon: IconButton(
              tooltip: _obscureConfirm ? 'Show confirmation' : 'Hide confirmation', onPressed: _busy ? null : () => setState(() => _obscureConfirm = !_obscureConfirm),
              icon: Icon(_obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined))))]
          else Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _busy ? null : () => _reset(ctx), child: const Text('Forgot password?'))),
          if (_error != null) Padding(padding: EdgeInsets.symmetric(vertical: gap), child: Semantics(liveRegion: true,
            child: Text(_error!, style: AppTypography.body.copyWith(color: _error == 'Sign in cancelled' ? AppColors.secondaryInk : AppColors.errorInk)))),
          SizedBox(height: _signup ? gap + 4 : 4),
          FilledButton(key: const Key('auth-submit'), onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm))),
            child: _busy ? const EntryLoadingIndicator(label: 'Signing in') : Text(_signup ? 'Create account' : 'Sign in')),
          Padding(padding: EdgeInsets.symmetric(vertical: gap), child: const Row(children: [Expanded(child: Divider(color: AppColors.outline)),
            Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('or', style: AppTypography.caption)), Expanded(child: Divider(color: AppColors.outline))])),
          OutlinedButton(key: const Key('auth-google'), onPressed: _busy ? null : () => _submit(google: true),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52), backgroundColor: AppColors.paper, foregroundColor: AppColors.ink,
              side: const BorderSide(color: AppColors.controlOutline), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm))),
            child: const Text('Continue with Google')),
          SizedBox(height: gap),
          TextButton(key: const Key('auth-mode'), onPressed: _busy ? null : () => setState(() {
            _signup = !_signup; _error = null; _password.clear(); _confirmation.clear(); _form.currentState!.reset();
          }), child: Text(_signup ? 'Already have an account? Sign in' : 'New here? Create an account', textAlign: TextAlign.center)),
        ]))))));
      }),
    ))),
  ));
}

InputDecoration authField(String label, IconData icon) => InputDecoration(labelText: label,
  prefixIcon: Icon(icon, size: 22), filled: true, fillColor: AppColors.paper, isDense: true,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.controlOutline)),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.controlOutline)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.purple, width: 2)));

class PasswordResetScreen extends StatefulWidget {
  final AuthGateway gateway;
  final String email;
  const PasswordResetScreen({super.key, required this.gateway, this.email = ''});
  @override State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}
class _PasswordResetScreenState extends State<PasswordResetScreen> {
  late final _email = TextEditingController(text: widget.email);
  bool _busy = false, _sent = false;
  String? _error;
  @override void dispose() { _email.dispose(); super.dispose(); }
  Future<void> _send() async {
    if (_busy) return;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      setState(() => _error = 'Enter a valid email address.'); return;
    }
    setState(() { _busy = true; _error = null; });
    String? error;
    try { error = await widget.gateway.resetPassword(_email.text.trim()); }
    catch (_) { error = 'Could not connect. Please try again.'; }
    if (!mounted) return;
    setState(() { _busy = false; _error = error; _sent = error == null; });
  }
  @override Widget build(BuildContext context) => MindPage(builder: (ctx) => Scaffold(
    appBar: AppBar(backgroundColor: AppColors.canvas, title: const Text('Reset password')),
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
        const Text('A fresh start.', style: AppTypography.title), const SizedBox(height: 12),
        const Text('Enter your email and we’ll help you get back to your space.', style: AppTypography.body), const SizedBox(height: 24),
        TextField(controller: _email, enabled: !_busy, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done, onSubmitted: (_) => _send(), decoration: authField('Email address', Icons.mail_outline_rounded)),
        const SizedBox(height: 20),
        if (_sent) Semantics(liveRegion: true, child: const Text('If this email is registered, a password reset link will arrive shortly.', style: AppTypography.body)),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: AppTypography.body.copyWith(color: AppColors.errorInk))),
        const SizedBox(height: 16), FilledButton(onPressed: _busy ? null : _send, child: Text(_busy ? 'Sending…' : 'Send reset link')),
      ]),
    ))),
  ));
}
