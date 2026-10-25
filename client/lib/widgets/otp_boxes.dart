import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Six boxes for an emailed verification code. Digits only; typing moves to
/// the next box and Backspace on an empty box moves back; pasting (or the
/// browser's one-time-code autofill) fills every box at once. Calls
/// [onCompleted] when the sixth digit is in.
class OtpBoxes extends StatefulWidget {
  const OtpBoxes({
    super.key,
    required this.onChanged,
    this.onCompleted,
    this.enabled = true,
    this.error = false,
  });
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onCompleted;
  final bool enabled;

  /// Draws the boxes in the error colour (wrong or expired code).
  final bool error;

  static const length = 6;

  @override
  State<OtpBoxes> createState() => OtpBoxesState();
}

class OtpBoxesState extends State<OtpBoxes> {
  final _controllers = List.generate(OtpBoxes.length, (_) => TextEditingController());
  late final _nodes = List.generate(OtpBoxes.length, (i) => FocusNode(onKeyEvent: (_, e) => _onKey(i, e)));

  String get code => _controllers.map((c) => c.text).join();

  @override
  void initState() {
    super.initState();
    for (final (i, node) in _nodes.indexed) {
      // Focusing a filled box selects its digit, so typing replaces it.
      node.addListener(() {
        if (node.hasFocus) {
          final c = _controllers[i];
          c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Empties every box and puts the cursor in the first.
  void clear() {
    for (final c in _controllers) {
      c.clear();
    }
    widget.onChanged('');
    _nodes.first.requestFocus();
  }

  void focusFirst() => _nodes.first.requestFocus();

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.backspace && _controllers[i].text.isEmpty && i > 0) {
      _controllers[i - 1].clear();
      _nodes[i - 1].requestFocus();
      widget.onChanged(code);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onChanged(int i, String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 1) {
      // A paste or autofill: spread the digits from this box onwards.
      for (var k = 0; k < digits.length && i + k < OtpBoxes.length; k++) {
        _controllers[i + k].text = digits[k];
      }
      final next = (i + digits.length).clamp(0, OtpBoxes.length - 1);
      _nodes[next].requestFocus();
    } else {
      _controllers[i].text = digits;
      if (digits.isNotEmpty && i < OtpBoxes.length - 1) _nodes[i + 1].requestFocus();
    }
    final c = code;
    widget.onChanged(c);
    if (c.length == OtpBoxes.length) widget.onCompleted?.call(c);
  }

  Widget _box(int i) {
    final border = widget.error ? K.glow : K.hairline;
    return Semantics(
      label: 'Digit ${i + 1} of ${OtpBoxes.length}',
      child: TextField(
        controller: _controllers[i],
        focusNode: _nodes[i],
        enabled: widget.enabled,
        autofocus: i == 0,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        textInputAction: i == OtpBoxes.length - 1 ? TextInputAction.done : TextInputAction.next,
        autofillHints: i == 0 ? const [AutofillHints.oneTimeCode] : null,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: K.mono(fontSize: 22, fontWeight: FontWeight.w600, color: K.textPrimary),
        onChanged: (v) => _onChanged(i, v),
        decoration: InputDecoration(
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: K.glow, width: 2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Row(children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: K.s2),
          Expanded(child: _box(i)),
        ],
        const ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: K.s2),
            child: Text('–', style: TextStyle(color: K.textSecondary)),
          ),
        ),
        for (var i = 3; i < OtpBoxes.length; i++) ...[
          if (i > 3) const SizedBox(width: K.s2),
          Expanded(child: _box(i)),
        ],
      ]),
    );
  }
}
