import 'package:flutter/material.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import 'confirm_screen.dart';
import 'handoff_screen.dart';

/// M09 · Alternate flights (UC4, FR-03). Same route and cabin, earliest
/// arrival first, read live from the REST tier.
class AlternativesScreen extends StatefulWidget {
  const AlternativesScreen({super.key});

  @override
  State<AlternativesScreen> createState() => _AlternativesScreenState();
}

class _AlternativesScreenState extends State<AlternativesScreen> {
  List<Flight>? _flights;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final flights = await SessionScope.read(context).api.alternatives();
      if (mounted) setState(() => _flights = flights);
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose(Flight f) async {
    final refresh = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConfirmScreen(flight: f)),
    );
    // The flight sold out while the passenger was deciding: show fresh seats.
    if (refresh == true && mounted) _load();
  }

  Future<void> _askPerson() async {
    final session = SessionScope.read(context);
    try {
      final c = await session.api
          .requestPerson('No suitable alternative flight; passenger asked for a person.');
      if (!mounted) return;
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => HandoffScreen(initial: c)));
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final booking = SessionScope.of(context).booking;
    final f = booking?.original;
    return Scaffold(
      appBar: AppBar(title: const Text('Other flights')),
      body: RefreshIndicator(
        onRefresh: _load,
        // Two cards per row in a desktop browser, one on a phone.
        child: LayoutBuilder(builder: (context, c) {
          final columns = c.maxWidth >= Breakpoints.twoColumn ? 2 : 1;
          final padding = pagePadding(
            c.maxWidth,
            maxWidth: columns == 2 ? Breakpoints.grid : Breakpoints.readable,
          );
          final cardWidth = (c.maxWidth - padding.horizontal - (columns - 1) * K.s3) / columns;
          return ListView(
            padding: padding,
            children: [
              if (f != null) ...[
                Text('${city(f.origin)} to ${city(f.destination)}', style: t.headlineSmall),
                const SizedBox(height: K.s1),
                Text(
                  'Same cabin (${titleCase(booking!.cabin)}), earliest arrival first. '
                  'All times are local to each airport.',
                  style: t.bodySmall?.copyWith(color: K.textSecondary),
                ),
                const SizedBox(height: K.s4),
              ],
              if (_loading && _flights == null)
                Padding(
                  padding: const EdgeInsets.all(K.s6),
                  child: Center(
                    child: Semantics(
                        label: 'Loading flights', child: const CircularProgressIndicator()),
                  ),
                ),
              if (_error != null) ErrorNotice(message: _error!, onRetry: _load),
              if (_flights != null && _flights!.isEmpty) ...[
                KCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('No seats on other flights', style: t.titleMedium),
                    const SizedBox(height: K.s2),
                    Text(
                      'There are no free seats in your cabin on this route right now. '
                      'A Kenya Airways agent can look at other options with you.',
                      style: t.bodyMedium?.copyWith(color: K.textSecondary),
                    ),
                  ]),
                ),
                const SizedBox(height: K.s4),
                PrimaryButton(label: 'Talk to a person', onPressed: _askPerson),
              ],
              if (_flights != null)
                Wrap(
                  spacing: K.s3,
                  runSpacing: K.s3,
                  children: [
                    for (final (i, flight) in _flights!.indexed)
                      SizedBox(
                        width: cardWidth,
                        child: FlightOptionCard(
                          flight: flight,
                          recommended: i == 0,
                          onSelect: () => _choose(flight),
                        ),
                      ),
                  ],
                ),
            ],
          );
        }),
      ),
    );
  }
}
