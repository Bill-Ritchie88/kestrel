import 'package:flutter/material.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import 'confirm_screen.dart';

/// M10 · Choose seat (UC4, FR-16). The passenger's cabin on the flight they
/// picked, seat by seat, between choosing a flight and Confirm. A seat is
/// only reserved when the rebooking is confirmed (row lock in the stored
/// procedure), so two passengers can pick the same seat here; the second to
/// confirm is sent back with "That seat was just taken" and a fresh map.
///
/// Pops with `true` when the list of flights should be refreshed.
class SeatMapScreen extends StatefulWidget {
  const SeatMapScreen({super.key, required this.flight});
  final Flight flight;

  static const takenMessage = 'That seat was just taken. Please pick another';

  @override
  State<SeatMapScreen> createState() => _SeatMapScreenState();
}

class _SeatMapScreenState extends State<SeatMapScreen> {
  SeatMap? _map;
  String? _error;
  Seat? _selected;

  /// Shown after a 409 SEAT_TAKEN from Confirm.
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final map = await SessionScope.read(context).api.seatMap(widget.flight.id);
      if (mounted) setState(() => _map = map);
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      if (msg != null) setState(() => _error = msg);
    }
  }

  Future<void> _confirm(Seat? seat) async {
    final outcome = await Navigator.of(context).push<ConfirmOutcome>(
      MaterialPageRoute(builder: (_) => ConfirmScreen(flight: widget.flight, seat: seat)),
    );
    if (!mounted) return;
    switch (outcome) {
      case ConfirmOutcome.seatTaken:
        setState(() {
          _notice = SeatMapScreen.takenMessage;
          _selected = null;
        });
        await _load();
      case ConfirmOutcome.chooseAnotherFlight:
        Navigator.of(context).pop(true);
      case null:
        break; // Back from Confirm: the choice stands.
    }
  }

  void _toggle(Seat s) => setState(() {
        _selected = _selected?.id == s.id ? null : s;
        _notice = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = widget.flight;
    final map = _map;
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose your seat')),
      body: PageList(
        children: [
          Text(
            '${f.number} · ${dayLabel(f.departureLocal)} · ${titleCase(map?.cabin ?? f.cabin ?? 'economy')}. '
            'Pick a free seat, or let Kestrel choose one for you.',
            style: t.bodyMedium?.copyWith(color: K.textSecondary),
          ),
          const SizedBox(height: K.s4),
          const _Legend(),
          const SizedBox(height: K.s4),
          if (_notice != null) ...[
            ErrorNotice(message: _notice!),
            const SizedBox(height: K.s4),
          ],
          if (_error != null)
            ErrorNotice(message: _error!, onRetry: _load)
          else if (map == null)
            const Loading('Loading seats')
          else
            _SeatGrid(map: map, selected: selected, onTap: _toggle),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Center(
          heightFactor: 1,
          child: Container(
            constraints: const BoxConstraints(maxWidth: Breakpoints.readable),
            padding: const EdgeInsets.all(K.s3),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              PrimaryButton(
                label: selected == null ? 'Choose a seat' : 'Continue with seat ${selected.number}',
                height: 52,
                onPressed: selected == null ? null : () => _confirm(selected),
              ),
              const SizedBox(height: K.s2),
              SecondaryButton(
                label: 'Let Kestrel choose',
                icon: Icons.auto_awesome,
                height: 48,
                onPressed: () => _confirm(null),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Free, taken and selected, drawn as the seats are.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget item(_SeatLook look, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          _SeatBox(look: look, size: 20),
          const SizedBox(width: K.s2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]);
    return Wrap(spacing: K.s5, runSpacing: K.s2, children: [
      item(_SeatLook.free, 'Free'),
      item(_SeatLook.taken, 'Taken'),
      item(_SeatLook.selected, 'Selected'),
    ]);
  }
}

enum _SeatLook { free, taken, selected }

class _SeatBox extends StatelessWidget {
  const _SeatBox({required this.look, required this.size, this.label});
  final _SeatLook look;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (fill, border) = switch (look) {
      _SeatLook.free => (K.elevated, K.textSecondary),
      _SeatLook.taken => (K.inset, K.hairline),
      _SeatLook.selected => (K.crimson, K.glow),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(size / 4),
        border: Border.all(color: border, width: look == _SeatLook.selected ? 2 : 1),
      ),
      child: look == _SeatLook.taken
          ? Icon(Icons.close, size: size * .45, color: K.muted)
          : label == null
              ? null
              : Text(label!,
                  style: K.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: look == _SeatLook.selected ? Colors.white : K.textPrimary)),
    );
  }
}

/// Rows down, seat letters across with a gap for each aisle. Seats are at
/// least 48 px (K.touch); a cabin too wide for the screen scrolls sideways.
class _SeatGrid extends StatelessWidget {
  const _SeatGrid({required this.map, required this.selected, required this.onTap});
  final SeatMap map;
  final Seat? selected;
  final void Function(Seat) onTap;

  static const _rowLabel = 32.0, _aisle = 20.0, _gap = 4.0, _max = 56.0;

  @override
  Widget build(BuildContext context) {
    final seats = map.seats;
    final groups = map.groups;
    final columns = groups.fold<int>(0, (n, g) => n + g.length);
    final byRow = <int, Map<String, Seat>>{};
    for (final s in seats) {
      (byRow[s.row] ??= {})[s.letter] = s;
    }
    final rows = byRow.keys.toList()..sort();
    final label = K.label(context);

    return LayoutBuilder(builder: (context, c) {
      final fixed = _rowLabel + (groups.length - 1) * _aisle + columns * _gap;
      final cell = ((c.maxWidth - fixed) / columns).clamp(K.touch, _max).toDouble();
      final width = fixed + columns * cell;

      Widget line(Widget Function(String letter) seatAt, Widget lead) => Row(children: [
            SizedBox(width: _rowLabel, child: lead),
            for (final (i, g) in groups.indexed) ...[
              if (i > 0) const SizedBox(width: _aisle),
              for (final letter in g)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _gap / 2),
                  child: SizedBox(width: cell, child: seatAt(letter)),
                ),
            ],
          ]);

      final grid = SizedBox(
        width: width,
        child: Column(children: [
          ExcludeSemantics(
            child: line((l) => Center(child: Text(l, style: label)), const SizedBox.shrink()),
          ),
          const SizedBox(height: K.s2),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: _gap * 2),
              child: line(
                (l) {
                  final s = byRow[r]![l];
                  return s == null ? SizedBox(height: cell) : _seat(s, cell);
                },
                ExcludeSemantics(child: Text('$r', style: label)),
              ),
            ),
        ]),
      );
      return width <= c.maxWidth
          ? Center(child: grid)
          : SingleChildScrollView(scrollDirection: Axis.horizontal, child: grid);
    });
  }

  Widget _seat(Seat s, double size) {
    final isSelected = selected?.id == s.id;
    final look = isSelected ? _SeatLook.selected : (s.isFree ? _SeatLook.free : _SeatLook.taken);
    return Semantics(
      button: true,
      enabled: s.isFree,
      selected: isSelected,
      label: 'Seat ${s.number}, ${isSelected ? 'selected' : s.isFree ? 'free' : 'taken'}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('seat-${s.number}'),
        onTap: s.isFree ? () => onTap(s) : null,
        borderRadius: BorderRadius.circular(size / 4),
        child: _SeatBox(look: look, size: size, label: s.letter),
      ),
    );
  }
}
