import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// A custom border shape that morphs between a standard rounded rectangle and a
/// perfect ellipse (oval).
///
/// This class interpolates the corner radii of a [RoundedRectangleBorder] towards
/// the maximum possible radius (half the rectangle's shortest side), creating a
/// "liquid" transition effect. It effectively simulates a superellipse-like shape
/// by manipulating standard [RRect] properties rather than computing complex
/// superellipse equations.
class LiquidRoundedSuperellipseBorder extends OutlinedBorder {
  /// Creates a border that interpolates between a rounded rectangle and an ellipse.
  const LiquidRoundedSuperellipseBorder({
    super.side,
    this.borderRadius = BorderRadius.zero,
    this.cornerSmoothing = 0.0,
  });

  /// The base radius for each corner.
  ///
  /// This value is used fully when [cornerSmoothing] is 0.0. As smoothing increases,
  /// these radii are interpolated towards the maximum possible radius (half the
  /// dimensions of the bounding box).
  final BorderRadiusGeometry borderRadius;

  /// The interpolation factor for the shape morphing.
  ///
  /// * 0.0: Standard [RoundedRectangleBorder] using [borderRadius].
  /// * 1.0: Perfect Ellipse (radii equal to half the width/height).
  /// * 0.0 < value < 1.0: Linearly interpolates the radii.
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
    return _computeMorphPath(adjusted, cornerSmoothing);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final RRect borderRect = borderRadius.resolve(textDirection).toRRect(rect);
    return _computeMorphPath(borderRect, cornerSmoothing);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;

    final RRect borderRect = borderRadius.resolve(textDirection).toRRect(rect);

    // Deflate to the center of the stroke to ensure accurate rendering width.
    final double halfWidth = side.width / 2.0;
    final RRect adjusted =
        borderRect.deflate(math.min(halfWidth, borderRect.shortestSide / 2.0));

    final Path path = _computeMorphPath(adjusted, cornerSmoothing);
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
    if (identical(this, other)) return true;
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

  /// Generates the path for the morphed shape.
  ///
  /// Interpolates the radii of the [rrect] towards the maximum possible radii
  /// (width/2, height/2) based on the [smoothing] factor.
  Path _computeMorphPath(RRect rrect, double smoothing) {
    final Rect rect = rrect.outerRect;
    final double t = smoothing.clamp(0.0, 1.0);

    // Optimization: Return standard RRect for 0.0 smoothing.
    if (t <= 1e-3) {
      return Path()..addRRect(rrect);
    }

    // Optimization: Return oval for 1.0 smoothing.
    if (t >= 1.0 - 1e-3) {
      return Path()..addOval(rect);
    }

    final double maxRx = rect.width / 2.0;
    final double maxRy = rect.height / 2.0;

    // Helper to interpolate a specific radius towards the max dimensions.
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
}
