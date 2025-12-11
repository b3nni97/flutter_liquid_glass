import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class LiquidRoundedSuperellipseBorder extends OutlinedBorder {
  const LiquidRoundedSuperellipseBorder({
    super.side,
    this.borderRadius = BorderRadius.zero,
    this.cornerSmoothing = 0.0,
  });

  /// The radius for each corner.
  /// Used fully at cornerSmoothing = 0.0.
  /// Ignored at cornerSmoothing = 1.0 (becomes full Ellipse).
  final BorderRadiusGeometry borderRadius;

  /// Interpolation factor.
  /// 0.0 = Standard RoundedRect (uses borderRadius, circular corners)
  /// 0.5 = Mix (larger radii, shorter straight edges)
  /// 1.0 = Perfect Ellipse (max radius, circular corners)
  final double cornerSmoothing;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) {
    return LiquidRoundedSuperellipseBorder(
      side: side.scale(t),
      borderRadius: borderRadius * t,
      cornerSmoothing: cornerSmoothing,
    );
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    final RRect borderRect = borderRadius.resolve(textDirection).toRRect(rect);
    final double safeWidth = math.min(side.width, borderRect.shortestSide);
    final RRect adjusted = borderRect.deflate(safeWidth);
    return _getMorphPath(adjusted, cornerSmoothing);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final RRect borderRect = borderRadius.resolve(textDirection).toRRect(rect);
    return _getMorphPath(borderRect, cornerSmoothing);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final RRect borderRect = borderRadius.resolve(textDirection).toRRect(rect);

    // Calculate the path for the center of the stroke
    final double halfWidth = side.width / 2.0;
    final RRect adjusted =
        borderRect.deflate(math.min(halfWidth, borderRect.shortestSide / 2.0));

    final Path path = _getMorphPath(adjusted, cornerSmoothing);
    canvas.drawPath(path, side.toPaint());
  }

  @override
  LiquidRoundedSuperellipseBorder copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
    double? cornerSmoothing,
  }) {
    return LiquidRoundedSuperellipseBorder(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
      cornerSmoothing: cornerSmoothing ?? this.cornerSmoothing,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is LiquidRoundedSuperellipseBorder &&
        other.side == side &&
        other.borderRadius == borderRadius &&
        other.cornerSmoothing == cornerSmoothing;
  }

  @override
  int get hashCode => Object.hash(side, borderRadius, cornerSmoothing);

  @override
  String toString() {
    return 'LiquidRoundedSuperellipseBorder($side, $borderRadius, smoothing: $cornerSmoothing)';
  }
}

Path _getMorphPath(RRect rrect, double smoothing) {
  final Rect rect = rrect.outerRect;
  final double t = smoothing.clamp(0.0, 1.0);

  // 1. Optimization: Simple cases
  if (t <= 1e-3) {
    return Path()..addRRect(rrect);
  }

  // 2. Calculate Target Radius (Ellipse Logic)
  // An ellipse is simply a RoundedRect where the corner radii equal half the dimension.
  final double maxRx = rect.width / 2.0;
  final double maxRy = rect.height / 2.0;

  if (t >= 1.0 - 1e-3) {
    return Path()..addOval(rect);
  }

  // 3. Interpolate Radii linearly
  // This creates a clean morph from the user's borderRadius to the full Ellipse.
  Radius lerpToMax(double currentX, double currentY) {
    return Radius.elliptical(
      lerpDouble(currentX, maxRx, t)!,
      lerpDouble(currentY, maxRy, t)!,
    );
  }

  final RRect interpolated = RRect.fromRectAndCorners(
    rect,
    topLeft: lerpToMax(rrect.tlRadiusX, rrect.tlRadiusY),
    topRight: lerpToMax(rrect.trRadiusX, rrect.trRadiusY),
    bottomLeft: lerpToMax(rrect.blRadiusX, rrect.blRadiusY),
    bottomRight: lerpToMax(rrect.brRadiusX, rrect.brRadiusY),
  );

  return Path()..addRRect(interpolated);
}
