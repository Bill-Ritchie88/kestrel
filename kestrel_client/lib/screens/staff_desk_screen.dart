import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../format.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/shell.dart';

/// FR-09 · Disruption desk. Staff see the cases the assistant handed to a
/// person (newest first), read what it already did, and resolve each case
/// with a note. Calls GET /api/staff/cases and POST .../resolve with the
/// shared staff key.
class StaffDeskScreen extends StatefulWidget {
  const StaffDeskScreen({super.key});

  @override
  State<StaffDeskScreen> createState() => _StaffDeskScreenState();
}

enum _Filter { open, resolved, all }

const _filterLabels = {_Filter.open: 'Open cases', _Filter.resolved: 'Resolved', _Filter.all: 'All cases'};
const _filterIcons = {
  _Filter.open: Icons.inbox_outlined,
  _Filter.resolved: Icons.task_alt,
  _Filter.all: Icons.list_alt,
};

/// How each trigger reads to staff, and its icon.
(String, IconData) triggerInfo(String trigger) => switch (trigger) {
      'PASSENGER_REQUEST' => ('Passenger asked for a person', Icons.record_voice_over_outlined),
      'LOW_SIMILARITY' => ('Question outside the policy', Icons.help_outline),
      'NO_ALTERNATIVES' => ('No seat on other flights', Icons.event_busy_outlined),
      'REBOOKING_FAILED' => ('Rebooking refused', Icons.lock_outline),
      'STEP_LIMIT' => ('Assistant reached its step limit', Icons.repeat),
      'FRUSTRATION' => ('Frustrated passenger', Icons.sentiment_dissatisfied_outlined),
      _ => (titleCase(trigger.replaceAll('_', ' ')), Icons.support_agent),
    };

class _StaffDeskScreenState extends State<StaffDeskScreen> {
  List<HandoffCase>? _cases;
  String? _error;
  bool _loading = false;
  _Filter _filter = _Filter.open;
  int? _selectedId;
  String _query = '';

  @override
  void initState() {
    super.initState();
    PublicScope.read(context).resetForSignedIn();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Open cases are asked for on their own and come newest first, so a
      // new case is never cut off by a long history (issue #6); the most
      // recent resolved ones fill the Resolved and All views.
      final api = SessionScope.read(context).api;
      final (open, resolved) =
          await (api.staffCases(status: 'OPEN', limit: 200), api.staffCases(status: 'RESOLVED', limit: 50)).wait;
      if (mounted) setState(() => _cases = [...open, ...resolved]);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.sessionExpired) {
        _expired();
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The key stopped working (rotated, or the service restarted with another).
  void _expired() {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((r) => r.isFirst);
    PublicScope.read(context).signIn(SignInMode.staff);
    SessionScope.read(context).signOut();
    messenger.showSnackBar(
      const SnackBar(content: Text('The staff key was not accepted. Please sign in again.')),
    );
  }

  Future<HandoffCase> _resolve(HandoffCase c, String note) async {
    final session = SessionScope.read(context);
    try {
      final updated = await session.api.resolveCase(c.id, by: session.staffName!, note: note);
      if (mounted) {
        setState(() {
          _cases = [for (final x in _cases ?? <HandoffCase>[]) x.id == c.id ? updated : x];
          // Keep the case in the panel (with its resolution) even though it
          // has left the open list, until the next one is picked.
          _selectedId = c.id;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Case #${c.id} resolved.')));
      }
      return updated;
    } on ApiException catch (e) {
      if (e.sessionExpired && mounted) _expired();
      rethrow;
    }
  }

  List<HandoffCase> get _visible {
    final q = _query.trim().toUpperCase();
    return (_cases ?? const <HandoffCase>[]).where((c) {
      final keep = switch (_filter) {
        _Filter.open => c.isOpen,
        _Filter.resolved => !c.isOpen,
        _Filter.all => true,
      };
      return keep && (q.isEmpty || c.pnr.toUpperCase().contains(q));
    }).toList();
  }

  int _count(_Filter f) => (_cases ?? const <HandoffCase>[])
      .where((c) => switch (f) { _Filter.open => c.isOpen, _Filter.resolved => !c.isOpen, _Filter.all => true })
      .length;

  void _open(HandoffCase c, {required bool inPanel}) {
    if (inPanel) {
      setState(() => _selectedId = c.id);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _CaseDetailPage(initial: c, onResolve: _resolve),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final name = session.staffName ?? '';
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= Breakpoints.wide;
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _StaffSidebar(
                filter: _filter,
                count: _cases == null ? null : _count,
                staffName: name,
                onFilter: (f) => setState(() => _filter = f),
                onSignOut: session.signOut,
              ),
              Expanded(
                child: Column(children: [
                  _DeskTopBar(
                    loading: _loading,
                    onRefresh: _load,
                    onQuery: (q) => setState(() => _query = q),
                    staffName: name,
                  ),
                  Expanded(child: _content(phone: false)),
                ]),
              ),
            ]),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          titleSpacing: K.s4,
          title: const Row(children: [
            KestrelMark(size: 30),
            SizedBox(width: K.s3),
            Text('Disruption desk'),
          ]),
          actions: [
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
            PopupMenuButton<String>(
              tooltip: 'Account',
              position: PopupMenuPosition.under,
              onSelected: (_) => session.signOut(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'signout', child: Text('Sign out'))],
              child: Padding(
                padding: const EdgeInsets.all(K.s2),
                child: InitialsAvatar(initials(name, ''), size: 34),
              ),
            ),
            const SizedBox(width: K.s2),
          ],
        ),
        body: _content(phone: true),
      );
    });
  }

  Widget _content({required bool phone}) {
    final t = Theme.of(context).textTheme;
    final visible = _visible;
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(builder: (context, c) {
        // The case detail sits beside the table from a ~1224 px window, a
        // little narrower until there is room for the full 440.
        final withPanel = !phone && c.maxWidth >= 960;
        final panelWidth = c.maxWidth >= 1100 ? 440.0 : 400.0;
        final narrowRows = c.maxWidth < 700;
        final cases = _cases ?? const <HandoffCase>[];
        HandoffCase? selected;
        if (withPanel) {
          selected = cases.where((x) => x.id == _selectedId).firstOrNull ??
              (visible.isEmpty ? null : visible.first);
        }
        // With the panel open on a smaller laptop, "Opened" gives its room to
        // the reason (the panel shows when the case was opened).
        final hideOpened = selected != null && MediaQuery.sizeOf(context).width < 1360;
        final open = cases.where((x) => x.isOpen);
        final list = <Widget>[
          if (_loading && _cases == null) const Loading('Loading cases'),
          if (_error != null) ErrorNotice(message: _error!, onRetry: _load),
          if (_cases != null && visible.isEmpty)
            KCard(
              child: Row(children: [
                const IconChip(Icons.inbox_outlined, color: K.teal, background: K.tealSoft),
                const SizedBox(width: K.s4),
                Expanded(
                  child: Text(
                    _query.isNotEmpty
                        ? 'No cases for a booking matching "${_query.trim().toUpperCase()}".'
                        : _filter == _Filter.open
                            ? 'No open cases. The assistant is handling everything right now.'
                            : 'Nothing here yet.',
                    style: t.bodyMedium?.copyWith(color: K.textSecondary),
                  ),
                ),
              ]),
            ),
          if (visible.isNotEmpty)
            _CaseTable(
              cases: visible,
              selectedId: selected?.id,
              stacked: narrowRows,
              hideOpened: hideOpened,
              onOpen: (x) => _open(x, inPanel: withPanel),
            ),
        ];
        return ListView(
          padding: pagePadding(c.maxWidth, maxWidth: 1400, top: phone ? K.s4 : 28, bottom: K.s6),
          children: [
            PageHeading(
              _filterLabels[_filter]!,
              subtitle: 'Cases the assistant handed to a person, newest first. '
                  'Each one carries the booking and what the assistant already did.',
            ),
            const SizedBox(height: K.s5),
            Wrap(spacing: K.s4, runSpacing: K.s4, children: [
              _Stat(label: 'Open cases', value: _cases == null ? '–' : '${open.length}', icon: Icons.inbox_outlined, accent: true),
              _Stat(label: 'Resolved', value: _cases == null ? '–' : '${cases.length - open.length}', icon: Icons.task_alt),
              _Stat(
                  label: 'Asked for a person',
                  value: _cases == null ? '–' : '${open.where((x) => x.trigger == 'PASSENGER_REQUEST').length}',
                  icon: Icons.record_voice_over_outlined),
              _Stat(
                  label: 'Outside the policy',
                  value: _cases == null ? '–' : '${open.where((x) => x.trigger == 'LOW_SIMILARITY').length}',
                  icon: Icons.help_outline),
            ]),
            const SizedBox(height: K.s5),
            if (phone) ...[
              SegmentedButton<_Filter>(
                segments: [
                  for (final f in _Filter.values)
                    ButtonSegment(value: f, label: Text(f == _Filter.open ? 'Open' : f == _Filter.resolved ? 'Resolved' : 'All')),
                ],
                selected: {_filter},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
              const SizedBox(height: K.s3),
              TextField(
                onChanged: (q) => setState(() => _query = q),
                decoration: const InputDecoration(
                  hintText: 'Search by booking reference',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: K.s4),
            ],
            if (withPanel && selected != null)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: list)),
                const SizedBox(width: K.s5),
                SizedBox(
                  width: panelWidth,
                  child: _CaseDetail(key: ValueKey(selected.id), c: selected, onResolve: _resolve),
                ),
              ])
            else
              ...list,
          ],
        );
      }),
    );
  }
}

class _StaffSidebar extends StatelessWidget {
  const _StaffSidebar({
    required this.filter,
    required this.count,
    required this.staffName,
    required this.onFilter,
    required this.onSignOut,
  });
  final _Filter filter;
  final int Function(_Filter)? count;
  final String staffName;
  final ValueChanged<_Filter> onFilter;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      width: Sidebar.width,
      decoration: const BoxDecoration(color: K.void_, border: Border(right: BorderSide(color: K.hairline))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(K.s5, 28, K.s5, 0),
          child: Align(alignment: Alignment.centerLeft, child: BrandLockup(markSize: 40)),
        ),
        const SizedBox(height: 40),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: K.s5),
          child: SectionLabel('Disruption desk'),
        ),
        const SizedBox(height: K.s3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: K.s4),
          child: Column(children: [
            for (final f in _Filter.values)
              Padding(
                padding: const EdgeInsets.only(bottom: K.s1),
                child: NavItem(
                  icon: _filterIcons[f]!,
                  label: _filterLabels[f]!,
                  selected: filter == f,
                  count: count?.call(f),
                  onTap: () => onFilter(f),
                ),
              ),
          ]),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.all(K.s4),
          child: Container(
            padding: const EdgeInsets.all(K.s4),
            decoration: BoxDecoration(
              color: K.surface,
              borderRadius: BorderRadius.circular(K.radius),
              border: Border.all(color: K.hairline),
            ),
            child: Row(children: [
              InitialsAvatar(initials(staffName, '')),
              const SizedBox(width: K.s3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(staffName, style: t.titleMedium?.copyWith(fontSize: 14), overflow: TextOverflow.ellipsis),
                  Text('Staff', style: t.bodySmall?.copyWith(color: K.textSecondary)),
                ]),
              ),
              IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout, size: 18), onPressed: onSignOut),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _DeskTopBar extends StatelessWidget {
  const _DeskTopBar({required this.loading, required this.onRefresh, required this.onQuery, required this.staffName});
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<String> onQuery;
  final String staffName;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: K.hairline))),
      child: Row(children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: TextField(
                onChanged: onQuery,
                decoration: const InputDecoration(
                  hintText: 'Search cases by booking reference',
                  prefixIcon: Icon(Icons.search, color: K.textSecondary),
                  contentPadding: EdgeInsets.symmetric(horizontal: K.s4, vertical: 14),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: K.s4),
        SecondaryButton(
          label: loading ? 'Refreshing…' : 'Refresh',
          icon: Icons.refresh,
          height: 44,
          expand: false,
          onPressed: loading ? null : onRefresh,
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon, this.accent = false});
  final String label, value;
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(K.s5),
        decoration: BoxDecoration(
          color: accent ? null : K.surface,
          gradient: accent ? K.primaryGradient : null,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: accent ? null : Border.all(color: K.hairline),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  style: K.dataLg(context).copyWith(fontSize: 30, height: 1.1, color: accent ? Colors.white : K.textPrimary)),
              const SizedBox(height: K.s1),
              Text(label, style: t.bodySmall?.copyWith(color: accent ? Colors.white : K.textSecondary)),
            ]),
          ),
          Icon(icon, color: accent ? Colors.white : K.glow),
        ]),
      ),
    );
  }
}

TextStyle? _caseStyle(TextTheme t) => t.titleMedium?.copyWith(fontSize: 15);
TextStyle _pnrStyle(BuildContext context) =>
    K.dataMd(context).copyWith(fontSize: 13, color: K.textSecondary, letterSpacing: 1);
TextStyle? _smallStyle(TextTheme t) => t.bodySmall?.copyWith(color: K.textSecondary);

/// The case table's column widths, measured from the text each column must
/// show at the current text size, so no case number or status chip is ever
/// cut short. The reason takes whatever is left.
class _Columns {
  const _Columns({required this.caseW, required this.bookingW, required this.statusW, required this.openedW});
  final double caseW, bookingW, statusW;

  /// Null when the Opened column is hidden.
  final double? openedW;

  static const gap = K.s4;
  static const badge = 40.0 + K.s3;

  /// Row padding left (with the 3 px selection bar) and right.
  static const padding = K.s5 + K.s5;

  /// Below this the reason would not read even on two lines: use cards.
  static const minReason = 100.0;

  double get fixed =>
      padding + badge + caseW + gap + gap + bookingW + (openedW == null ? 0 : gap + openedW!) + gap + statusW;

  static _Columns measure(BuildContext context, List<HandoffCase> cases, {required bool hideOpened}) {
    final t = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final label = K.label(context);
    double width(String s, TextStyle? style) => (TextPainter(
          text: TextSpan(text: s, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout())
            .width
            .ceilToDouble();
    double widest(Iterable<double> xs) => xs.fold(0, math.max);
    return _Columns(
      // "Case #20419" is the widest case number the desk is sized for.
      caseW: widest([
            width('CASE', label),
            for (final s in ['Case #20419', for (final c in cases) 'Case #${c.id}']) width(s, _caseStyle(t)),
            for (final c in cases) width(c.pnr, _pnrStyle(context)),
          ]) +
          4,
      bookingW: widest([
        width('BOOKING', label),
        for (final s in {'DISRUPTED', 'REACCOMMODATED', ...cases.map((c) => c.bookingStatus).whereType<String>()})
          StatusPill.widthFor(context, s),
      ]),
      statusW: widest([
        width('STATUS', label),
        for (final s in {'OPEN', 'RESOLVED', ...cases.map((c) => c.status)}) StatusPill.widthFor(context, s),
      ]),
      openedW: hideOpened
          ? null
          : widest([width('OPENED', label), for (final c in cases) width(since(c.createdAt, compact: true), _smallStyle(t))]) + 2,
    );
  }
}

/// The queue, as a table on a wide screen and as cards on a phone (or when
/// the columns would not fit, e.g. with very large text).
class _CaseTable extends StatelessWidget {
  const _CaseTable({
    required this.cases,
    required this.selectedId,
    required this.stacked,
    required this.hideOpened,
    required this.onOpen,
  });
  final List<HandoffCase> cases;
  final int? selectedId;
  final bool stacked, hideOpened;
  final ValueChanged<HandoffCase> onOpen;

  @override
  Widget build(BuildContext context) {
    final label = K.label(context);
    return LayoutBuilder(builder: (context, box) {
      final cols = _Columns.measure(context, cases, hideOpened: hideOpened);
      final asCards = stacked || box.maxWidth - 2 < cols.fixed + _Columns.minReason;
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
        ),
        child: Column(children: [
          if (!asCards)
            Padding(
              padding: const EdgeInsets.fromLTRB(K.s5, K.s4, K.s5, K.s3),
              child: Row(children: [
                const SizedBox(width: _Columns.badge),
                SizedBox(width: cols.caseW, child: Text('CASE', style: label)),
                const SizedBox(width: _Columns.gap),
                Expanded(child: Text('REASON', style: label)),
                const SizedBox(width: _Columns.gap),
                SizedBox(width: cols.bookingW, child: Text('BOOKING', style: label)),
                if (cols.openedW != null) ...[
                  const SizedBox(width: _Columns.gap),
                  SizedBox(width: cols.openedW, child: Text('OPENED', style: label)),
                ],
                const SizedBox(width: _Columns.gap),
                SizedBox(width: cols.statusW, child: Text('STATUS', style: label, textAlign: TextAlign.right)),
              ]),
            ),
          for (final (i, c) in cases.indexed) ...[
            if (i > 0 || !asCards) const Divider(height: 1),
            _CaseRow(c: c, selected: c.id == selectedId, cols: asCards ? null : cols, onTap: () => onOpen(c)),
          ],
        ]),
      );
    });
  }
}

class _CaseRow extends StatelessWidget {
  const _CaseRow({required this.c, required this.selected, required this.cols, required this.onTap});
  final HandoffCase c;
  final bool selected;

  /// The table's columns, or null to draw the case as a card.
  final _Columns? cols;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final (reason, icon) = triggerInfo(c.trigger);
    final small = _smallStyle(t);
    final badge = Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(gradient: K.primaryGradient, shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white, size: 19),
    );
    final question = c.question ?? c.summary ?? '';
    final cols = this.cols;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Case ${c.id}, booking ${c.pnr}, $reason, ${c.isOpen ? 'open' : 'resolved'}, opened ${since(c.createdAt)}',
      excludeSemantics: true,
      child: Material(
        color: selected ? K.elevated : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: selected ? K.glow : Colors.transparent, width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(K.s5 - 3, K.s3, K.s5, K.s3),
            child: cols == null
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    badge,
                    const SizedBox(width: K.s3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('Case #${c.id} · ${c.pnr}', style: _caseStyle(t))),
                          const SizedBox(width: K.s2),
                          StatusPill(c.status),
                        ]),
                        const SizedBox(height: 2),
                        Text(reason, style: t.bodyMedium),
                        if (question.isNotEmpty)
                          Text(question, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                        const SizedBox(height: K.s2),
                        Wrap(spacing: K.s3, runSpacing: K.s1, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          if (c.bookingStatus != null) StatusPill(c.bookingStatus!),
                          Text('Opened ${since(c.createdAt)}', style: small),
                        ]),
                      ]),
                    ),
                  ])
                : Row(children: [
                    badge,
                    const SizedBox(width: K.s3),
                    SizedBox(
                      width: cols.caseW,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Case #${c.id}', style: _caseStyle(t), maxLines: 1, softWrap: false),
                        Text(c.pnr, style: _pnrStyle(context), maxLines: 1, softWrap: false),
                      ]),
                    ),
                    const SizedBox(width: _Columns.gap),
                    Expanded(
                      child: Text(reason, style: t.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: _Columns.gap),
                    SizedBox(
                      width: cols.bookingW,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: c.bookingStatus == null ? const SizedBox.shrink() : StatusPill(c.bookingStatus!),
                      ),
                    ),
                    if (cols.openedW != null) ...[
                      const SizedBox(width: _Columns.gap),
                      SizedBox(
                        width: cols.openedW,
                        child: Text(since(c.createdAt, compact: true), style: small, maxLines: 1, softWrap: false),
                      ),
                    ],
                    const SizedBox(width: _Columns.gap),
                    SizedBox(
                      width: cols.statusW,
                      child: Align(alignment: Alignment.centerRight, child: StatusPill(c.status)),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }
}

/// One case in full: what happened, what the assistant handed over, the
/// retrieval scores, and the resolution (or the form to resolve it).
class _CaseDetail extends StatefulWidget {
  const _CaseDetail({super.key, required this.c, required this.onResolve});
  final HandoffCase c;
  final Future<HandoffCase> Function(HandoffCase c, String note) onResolve;

  @override
  State<_CaseDetail> createState() => _CaseDetailState();
}

class _CaseDetailState extends State<_CaseDetail> {
  final _note = TextEditingController();
  late HandoffCase _c = widget.c;
  bool _busy = false;
  String? _error;

  @override
  void didUpdateWidget(covariant _CaseDetail old) {
    super.didUpdateWidget(old);
    if (old.c != widget.c) _c = widget.c;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final note = _note.text.trim();
    if (note.isEmpty) {
      setState(() => _error = 'Write a short note on what you did, for the record.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.onResolve(_c, note);
      if (mounted) {
        setState(() => _c = updated);
        _note.clear();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = _c;
    final (reason, icon) = triggerInfo(c.trigger);
    final small = t.bodySmall?.copyWith(color: K.textSecondary);
    final scores = c.similarityScores;
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconChip(icon, size: 44),
          const SizedBox(width: K.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text('Case #${c.id}', style: t.titleLarge)),
              Text(reason, style: small),
            ]),
          ),
          StatusPill(c.status),
        ]),
        const SizedBox(height: K.s4),
        Wrap(spacing: K.s5, runSpacing: K.s3, children: [
          _Field('Booking', c.pnr),
          if (c.bookingStatus != null) _Field('Booking status', titleCase(c.bookingStatus!)),
          _Field('Opened', since(c.createdAt)),
          if (c.topSimilarity != null) _Field('Best match', c.topSimilarity!.toStringAsFixed(2)),
        ]),
        if ((c.question ?? '').isNotEmpty) ...[
          const SizedBox(height: K.s4),
          const SectionLabel('Passenger asked'),
          const SizedBox(height: K.s2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(K.s3),
            decoration: const BoxDecoration(
              color: K.inset,
              border: Border(left: BorderSide(color: K.glow, width: 3)),
            ),
            child: Text(c.question!, style: t.bodyMedium),
          ),
        ],
        if ((c.summary ?? '').isNotEmpty) ...[
          const SizedBox(height: K.s4),
          const SectionLabel('What the assistant handed over'),
          const SizedBox(height: K.s2),
          Text(c.summary!, style: t.bodyMedium),
        ],
        if (scores.isNotEmpty) ...[
          const SizedBox(height: K.s4),
          const SectionLabel('Policy clauses it looked at'),
          const SizedBox(height: K.s2),
          for (final s in scores)
            Padding(
              padding: const EdgeInsets.only(bottom: K.s2),
              child: Row(children: [
                Expanded(child: Text(s.clauseRef, style: t.bodySmall)),
                SizedBox(
                  width: 90,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: s.similarity.clamp(0, 1).toDouble(),
                      minHeight: 6,
                      backgroundColor: K.elevated,
                      color: K.crimson,
                    ),
                  ),
                ),
                const SizedBox(width: K.s2),
                Text(s.similarity.toStringAsFixed(2), style: K.label(context)),
              ]),
            ),
        ],
        const Divider(height: K.s6),
        if (!c.isOpen) ...[
          Row(children: [
            const Icon(Icons.task_alt, color: K.teal, size: 20),
            const SizedBox(width: K.s2),
            Expanded(
              child: Text(
                'Resolved by ${(c.resolvedBy ?? '').replaceFirst('STAFF:', '')}'
                '${c.resolvedAt == null ? '' : ' · ${since(c.resolvedAt)}'}',
                style: t.titleMedium?.copyWith(fontSize: 15),
              ),
            ),
          ]),
          if ((c.resolutionNote ?? '').isNotEmpty) ...[
            const SizedBox(height: K.s2),
            Text(c.resolutionNote!, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
          ],
        ] else ...[
          const SectionLabel('Resolve this case'),
          const SizedBox(height: K.s2),
          TextField(
            controller: _note,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: 'What did you do? e.g. Rebooked on KQ102 by phone and issued a hotel voucher.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: K.s2),
            ErrorNotice(message: _error!),
          ],
          const SizedBox(height: K.s3),
          PrimaryButton(label: 'Resolve case', icon: Icons.task_alt, busy: _busy, onPressed: _resolve, height: 52),
        ],
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: K.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: K.dataMd(context).copyWith(fontWeight: FontWeight.w600)),
      ]);
}

/// On a phone a case opens as its own page.
class _CaseDetailPage extends StatelessWidget {
  const _CaseDetailPage({required this.initial, required this.onResolve});
  final HandoffCase initial;
  final Future<HandoffCase> Function(HandoffCase c, String note) onResolve;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Case #${initial.id}')),
        body: PageList(children: [_CaseDetail(c: initial, onResolve: onResolve)]),
      );
}
