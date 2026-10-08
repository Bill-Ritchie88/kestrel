import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/kestrel_api.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// M02 / M03 · Authenticate (UC1, FR-01). PNR and surname are exchanged for a
/// 15-minute session token; nothing is stored on the device.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _pnr = TextEditingController();
  final _surname = TextEditingController();
  final _surnameFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pnr.dispose();
    _surname.dispose();
    _surnameFocus.dispose();
    super.dispose();
  }

  static String? _validatePnr(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Enter your 6-character booking reference.';
    if (!RegExp(r'^[A-Za-z0-9]{6}$').hasMatch(s)) {
      return 'A booking reference is 6 letters and numbers, e.g. A27Z99.';
    }
    return null;
  }

  static String? _validateSurname(String? v) =>
      (v ?? '').trim().isEmpty ? 'Enter the surname on the booking.' : null;

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionScope.read(context).signIn(_pnr.text, _surname.text);
      // SessionGate swaps this screen for the chat when signedIn changes.
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: K.void_,
      body: Backdrop(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(K.s5),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(alignment: Alignment.centerLeft, child: BrandLockup()),
                      const SizedBox(height: K.s6 * 1.5),
                      Semantics(
                        header: true,
                        child: Text('Your flight was disrupted.\nLet\'s get you moving.',
                            style: t.displaySmall?.copyWith(fontSize: 30)),
                      ),
                      const SizedBox(height: K.s3),
                      Text(
                        'Enter your booking reference and surname to see your options, '
                        'rebook and collect your vouchers.',
                        style: t.bodyMedium?.copyWith(color: K.textSecondary),
                      ),
                      const SizedBox(height: K.s5),
                      const SectionLabel('Booking reference (PNR)'),
                      const SizedBox(height: K.s2),
                      TextFormField(
                        controller: _pnr,
                        enabled: !_busy,
                        autofocus: true,
                        maxLength: 6,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                          _UpperCase(),
                        ],
                        style: K.dataMd(context).copyWith(letterSpacing: 2),
                        decoration: const InputDecoration(
                          hintText: 'e.g. A27Z99',
                          counterText: '',
                          prefixIcon: Icon(Icons.confirmation_number_outlined),
                        ),
                        validator: _validatePnr,
                        onFieldSubmitted: (_) => _surnameFocus.requestFocus(),
                      ),
                      const SizedBox(height: K.s4),
                      const SectionLabel('Surname'),
                      const SizedBox(height: K.s2),
                      TextFormField(
                        controller: _surname,
                        focusNode: _surnameFocus,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.familyName],
                        decoration: const InputDecoration(
                          hintText: 'As on your ticket',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: _validateSurname,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: K.s4),
                        ErrorNotice(message: _error!),
                      ],
                      const SizedBox(height: K.s5),
                      PrimaryButton(label: 'Find my booking', busy: _busy, onPressed: _submit),
                      const SizedBox(height: K.s4),
                      Row(children: [
                        const Icon(Icons.lock_outline, size: 16, color: K.textSecondary),
                        const SizedBox(width: K.s2),
                        Expanded(
                          child: Text(
                            'Your session ends after 15 minutes. Nothing is saved on this device.',
                            style: t.bodySmall?.copyWith(color: K.textSecondary),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
