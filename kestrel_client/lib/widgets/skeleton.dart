import 'package:flutter/material.dart';

import '../theme.dart';

/// Placeholders shaped like the cards they stand in for, shown while the
/// trip loads the first time, so the page keeps its layout (nothing jumps
/// when the data arrives) and the passenger sees where things will be.
///
/// A soft highlight sweeps across them; with reduce-motion it stays still.
/// Screen readers hear one "Loading …" label instead of empty boxes.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, required this.label, required this.child});

  /// Read out by screen readers, e.g. "Loading your trip".
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        liveRegion: true,
        container: true,
        child: ExcludeSemantics(child: Shimmer(child: child)),
      );
}

/// The moving highlight over [child]'s shapes.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  static const _highlight = Color(0xFF2A2A35);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value * 3 - 1; // -1 .. 2: the band crosses fully
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [K.elevated, _highlight, K.elevated],
            stops: [(t - 0.3).clamp(0.0, 1.0), t.clamp(0.0, 1.0), (t + 0.3).clamp(0.0, 1.0)],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// One grey shape.
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, this.height = 14, this.radius = 6});
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: K.elevated, borderRadius: BorderRadius.circular(radius)),
      );
}

/// A card outline with bones inside, at the size of the real card.
class BoneCard extends StatelessWidget {
  const BoneCard({super.key, required this.child, this.height});
  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        padding: const EdgeInsets.all(K.s5),
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
        ),
        child: child,
      );
}

/// A flight option row (FlightOptionCard): badge, route line, button.
class FlightRowSkeleton extends StatelessWidget {
  const FlightRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const BoneCard(
        child: Row(children: [
          Bone(width: 64, height: 64, radius: 14),
          SizedBox(width: K.s4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Bone(width: 120, height: 12),
              SizedBox(height: K.s3),
              Bone(height: 18),
              SizedBox(height: K.s3),
              Bone(width: 200, height: 12),
            ]),
          ),
          SizedBox(width: K.s4),
          Bone(width: 88, height: 40, radius: 12),
        ]),
      );
}

/// A voucher or entitlement card.
class VoucherSkeleton extends StatelessWidget {
  const VoucherSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const BoneCard(
        child: Row(children: [
          Bone(width: 44, height: 44, radius: 12),
          SizedBox(width: K.s4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Bone(width: 140, height: 14),
              SizedBox(height: K.s2),
              Bone(width: 220, height: 12),
            ]),
          ),
          SizedBox(width: K.s4),
          Bone(width: 72, height: 18),
        ]),
      );
}

/// My trip: the greeting, the ticket and the first flights.
class TripSkeleton extends StatelessWidget {
  const TripSkeleton({super.key, this.rows = 2});
  final int rows;

  @override
  Widget build(BuildContext context) => Skeleton(
        label: 'Loading your trip',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Bone(width: 180, height: 28, radius: 8),
          const SizedBox(height: K.s2),
          const Bone(width: 320, height: 14),
          const SizedBox(height: K.s5),
          const BoneCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Bone(width: 40, height: 40, radius: 12),
                SizedBox(width: K.s3),
                Bone(width: 160, height: 16),
                Spacer(),
                Bone(width: 96, height: 26, radius: 13),
              ]),
              SizedBox(height: K.s5),
              Row(children: [
                Bone(width: 64, height: 28),
                SizedBox(width: K.s4),
                Expanded(child: Bone(height: 2)),
                SizedBox(width: K.s4),
                Bone(width: 64, height: 28),
              ]),
              SizedBox(height: K.s5),
              Bone(height: 12),
              SizedBox(height: K.s2),
              Bone(width: 240, height: 12),
            ]),
          ),
          const SizedBox(height: K.s6),
          const Bone(width: 200, height: 18),
          const SizedBox(height: K.s4),
          for (var i = 0; i < rows; i++) ...[
            const FlightRowSkeleton(),
            const SizedBox(height: K.s3),
          ],
        ]),
      );
}

/// A list of [count] cards of one kind, e.g. flights or vouchers.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, required this.label, required this.item, this.count = 3});
  final String label;
  final Widget item;
  final int count;

  @override
  Widget build(BuildContext context) => Skeleton(
        label: label,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < count; i++) ...[
            item,
            if (i < count - 1) const SizedBox(height: K.s3),
          ],
        ]),
      );
}
