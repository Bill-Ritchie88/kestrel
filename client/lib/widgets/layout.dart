import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Kestrel is used mainly in a desktop or laptop browser, and on phones. These
/// are the widths the layouts change at (logical pixels).
class Breakpoints {
  Breakpoints._();

  /// From here the chat gets a side panel with the booking and actions.
  static const wide = 1080.0;

  /// From here lists of flights show two cards per row.
  static const twoColumn = 900.0;

  /// Readable width for a column of text and cards (about 70 characters of
  /// body text), so nothing stretches across a 1920 px browser window.
  static const readable = 720.0;
  static const chat = 760.0;
  static const grid = 1100.0;
}

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= Breakpoints.wide;

/// Padding that centres content of at most [maxWidth] inside a full-width
/// scroll view. Using padding rather than a narrower box keeps the scrollbar
/// at the edge of the window, as on any web page.
EdgeInsets pagePadding(
  double availableWidth, {
  double maxWidth = Breakpoints.readable,
  double top = K.s4,
  double bottom = K.s4,
}) {
  final side = math.max(K.s4, (availableWidth - maxWidth) / 2);
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

/// A full-width scrolling page whose children sit in a centred column.
class PageList extends StatelessWidget {
  const PageList({
    super.key,
    required this.children,
    this.maxWidth = Breakpoints.readable,
    this.controller,
    this.bottom = K.s4,
  });

  final List<Widget> children;
  final double maxWidth;
  final ScrollController? controller;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => ListView(
        controller: controller,
        padding: pagePadding(c.maxWidth, maxWidth: maxWidth, bottom: bottom),
        children: children,
      ),
    );
  }
}

/// Centres a fixed bar (composer, action bar) at the same width as the page.
class CentredBar extends StatelessWidget {
  const CentredBar({super.key, required this.child, this.maxWidth = Breakpoints.readable});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}
