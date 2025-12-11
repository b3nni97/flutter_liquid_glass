import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:liquid_glass_renderer/src/liquid_rounded_superellipse_border.dart';

/// Represents a shape that can be used by a [LiquidGlass] widget.
sealed class LiquidShape extends OutlinedBorder with EquatableMixin {
  const LiquidShape({super.side = BorderSide.none});

  @protected
  OutlinedBorder get _equivalentOutlinedBorder;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return _equivalentOutlinedBorder.getInnerPath(
      rect,
      textDirection: textDirection,
    );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return _equivalentOutlinedBorder.getOuterPath(
      rect,
      textDirection: textDirection,
    );
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    _equivalentOutlinedBorder.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  List<Object?> get props => [side];
}

/// Represents a squircle shape that can be used by a [LiquidGlass] widget.
///
/// This maps to Shader Type 1.
///
/// * If [cornerSmoothing] is provided (0.0 - 1.0), it uses the Figma-style
///   smoothing logic (Apple organic look).
/// * If [cornerSmoothing] is null, it uses the legacy auto-calculation logic
///   based on dimensions.
class LiquidRoundedSuperellipse extends LiquidShape {
  /// Creates a new [LiquidRoundedSuperellipse].
  const LiquidRoundedSuperellipse({
    required this.borderRadius,
    this.cornerSmoothing,
    super.side = BorderSide.none,
  });

  /// The radius of the squircle corners.
  final Radius borderRadius;

  /// Controls the smoothness of the corner transition (Figma Style).
  ///
  /// * `0.0`: Standard rounded rectangle (straight sides).
  /// * `0.6`: Apple iOS style (continuous curvature).
  /// * `1.0`: Maximum smoothing.
  /// * `null`: Use legacy auto-calculation (Flutter standard).
  final double? cornerSmoothing;

  @override
  // Fallback for CPU rendering: RoundedSuperellipseBorder is the closest approximation.
  OutlinedBorder get _equivalentOutlinedBorder =>
      LiquidRoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(borderRadius),
        side: side,
        cornerSmoothing: cornerSmoothing ?? 0,
      );

  @override
  LiquidRoundedSuperellipse copyWith({
    BorderSide? side,
    Radius? borderRadius,
    double? cornerSmoothing,
  }) {
    return LiquidRoundedSuperellipse(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
      cornerSmoothing: cornerSmoothing ?? this.cornerSmoothing,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return LiquidRoundedSuperellipse(
      borderRadius: borderRadius * t,
      side: side.scale(t),
      cornerSmoothing: cornerSmoothing, // Smoothing factor doesn't scale
    );
  }

  @override
  List<Object?> get props => [...super.props, borderRadius, cornerSmoothing];
}

/// Represents an ellipse shape that can be used by a [LiquidGlass] widget.
///
/// Works like an [OvalBorder].
/// This maps to Shader Type 2.
class LiquidOval extends LiquidShape {
  /// Creates a new [LiquidOval] with the given [side].
  const LiquidOval({super.side = BorderSide.none});

  @override
  OutlinedBorder get _equivalentOutlinedBorder => const OvalBorder();

  @override
  OutlinedBorder copyWith({BorderSide? side}) {
    return LiquidOval(
      side: side ?? this.side,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return LiquidOval(
      side: side.scale(t),
    );
  }
}

/// Represents a rounded rectangle shape that can be used by a [LiquidGlass]
/// widget.
///
/// Works like a [RoundedRectangleBorder].
/// This maps to Shader Type 3.
class LiquidRoundedRectangle extends LiquidShape {
  /// Creates a new [LiquidRoundedRectangle] with the given [borderRadius].
  const LiquidRoundedRectangle({
    required this.borderRadius,
    super.side = BorderSide.none,
  });

  /// The radius of the rounded rectangle.
  ///
  /// This is the radius of the corners of the rounded rectangle.
  final Radius borderRadius;

  @override
  OutlinedBorder get _equivalentOutlinedBorder => RoundedRectangleBorder(
        borderRadius: BorderRadius.all(borderRadius),
        side: side,
      );

  @override
  LiquidRoundedRectangle copyWith({
    BorderSide? side,
    Radius? borderRadius,
  }) {
    return LiquidRoundedRectangle(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return LiquidRoundedRectangle(
      borderRadius: borderRadius * t,
      side: side.scale(t),
    );
  }

  @override
  List<Object?> get props => [...super.props, borderRadius];
}
