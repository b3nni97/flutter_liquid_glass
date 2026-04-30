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

  /// Number of angular samples for tracing the superellipse boundary.
  /// 64 samples (≈5.6° apart) with cubic Bézier interpolation provide
  /// sub-pixel accuracy for typical shape sizes.
  static const int _kSamples = 64;

  /// Generates the path for the morphed shape.
  ///
  /// Traces the zero contour of the mixed SDF that interpolates between a
  /// rounded rectangle and a superellipse, exactly matching the shader's
  /// `calculateSquircleSDF` function in `lg_union_sdf.glsl`.
  Path _computeMorphPath(RRect rrect, double smoothing) {
    final Rect rect = rrect.outerRect;
    final double t = smoothing.clamp(0.0, 1.0);

    if (t <= 1e-3) {
      return Path()..addRRect(rrect);
    }

    if (t >= 1.0 - 1e-3) {
      return Path()..addOval(rect);
    }

    final double halfW = rect.width / 2.0;
    final double halfH = rect.height / 2.0;
    final double cx = rect.center.dx;
    final double cy = rect.center.dy;
    final double shortSide = math.min(halfW, halfH);
    final double r = math.max(rrect.tlRadiusX, 0.001);
    final double n = (2.0 * shortSide / r).clamp(2.0, 40.0);
    final double maxDist = math.sqrt(halfW * halfW + halfH * halfH);

    // Trace the zero contour via bisection along rays from the center.
    final List<Offset> pts = List<Offset>.filled(_kSamples, Offset.zero);
    for (int i = 0; i < _kSamples; i++) {
      final double theta = (i / _kSamples) * 2.0 * math.pi;
      final double dx = math.cos(theta);
      final double dy = math.sin(theta);
      double lo = 0.0, hi = maxDist;
      for (int j = 0; j < 20; j++) {
        final double mid = (lo + hi) * 0.5;
        if (_mixedSDF(dx * mid, dy * mid, halfW, halfH, shortSide, r, n, t) <
            0.0) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final double d = (lo + hi) * 0.5;
      pts[i] = Offset(cx + dx * d, cy + dy * d);
    }

    // Build a smooth closed path via Catmull-Rom → cubic Bézier conversion.
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 0; i < _kSamples; i++) {
      final Offset p0 = pts[(i - 1 + _kSamples) % _kSamples];
      final Offset p1 = pts[i];
      final Offset p2 = pts[(i + 1) % _kSamples];
      final Offset p3 = pts[(i + 2) % _kSamples];
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6.0,
        p1.dy + (p2.dy - p0.dy) / 6.0,
        p2.dx - (p3.dx - p1.dx) / 6.0,
        p2.dy - (p3.dy - p1.dy) / 6.0,
        p2.dx,
        p2.dy,
      );
    }
    path.close();
    return path;
  }

  /// The mixed SDF matching the shader's `calculateSquircleSDF`.
  /// Returns `mix(roundedRectSDF, superellipseSDF, t)`.
  static double _mixedSDF(
    double px,
    double py,
    double halfW,
    double halfH,
    double shortSide,
    double radius,
    double n,
    double t,
  ) {
    // Rounded rectangle SDF.
    final double limit = math.min(halfW, halfH);
    final double er = math.min(radius, limit);
    final double qx = px.abs() - halfW + er;
    final double qy = py.abs() - halfH + er;
    final double rrSDF = math.min(math.max(qx, qy), 0.0) +
        math.sqrt(
          math.max(qx, 0.0) * math.max(qx, 0.0) +
              math.max(qy, 0.0) * math.max(qy, 0.0),
        ) -
        er;

    // Superellipse SDF.
    final double nx = (px.abs() / halfW);
    final double ny = (py.abs() / halfH);
    final double raw = math.pow(
      math.pow(nx, n).toDouble() + math.pow(ny, n).toDouble(),
      1.0 / n,
    ).toDouble();
    final double seSDF = (raw - 1.0) * shortSide;

    return rrSDF * (1.0 - t) + seSDF * t;
  }
}
