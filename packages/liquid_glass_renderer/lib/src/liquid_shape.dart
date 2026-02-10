import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/src/liquid_rounded_superellipse_border.dart';

/// Represents the geometric shape used by the `LiquidGlass` widget.
///
/// This sealed class defines the contract for shapes that can be rendered
/// with the liquid glass effect. It bridges the custom liquid renderer
/// logic with the standard Flutter [ShapeBorder] ecosystem by delegating
/// path generation and painting to an equivalent [OutlinedBorder].
sealed class LiquidShape extends OutlinedBorder with EquatableMixin {
  /// Creates a [LiquidShape] with the specified border side.
  const LiquidShape({super.side});

  /// The standard Flutter [OutlinedBorder] that corresponds to this liquid shape.
  ///
  /// This property is used internally to delegate standard [ShapeBorder] methods
  /// such as path generation and CPU-based painting.
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

/// A liquid shape representing a squircle (superellipse).
///
/// This shape maps to Shader Type 1 in the liquid glass renderer.
/// It supports both Figma-style corner smoothing and standard rounded corners.
class LiquidRoundedSuperellipse extends LiquidShape {
  /// Creates a [LiquidRoundedSuperellipse].
  const LiquidRoundedSuperellipse({
    required this.borderRadius,
    this.cornerSmoothing,
    super.side,
  });

  /// The radius of the corners.
  final Radius borderRadius;

  /// Controls the smoothness of the corner transition.
  ///
  /// * `0.0`: Standard rounded rectangle (straight sides).
  /// * `0.6`: Apple iOS style (continuous curvature).
  /// * `1.0`: Maximum smoothing.
  /// * `null`: Uses legacy auto-calculation logic based on dimensions.
  final double? cornerSmoothing;

  @override
  OutlinedBorder get _equivalentOutlinedBorder {
    return LiquidRoundedSuperellipseBorder(
      borderRadius: BorderRadius.all(borderRadius),
      side: side,
      cornerSmoothing: cornerSmoothing ?? 0,
    );
  }

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
      cornerSmoothing: cornerSmoothing,
    );
  }

  @override
  List<Object?> get props => [
        ...super.props,
        borderRadius,
        cornerSmoothing,
      ];
}

/// A liquid shape representing an ellipse.
///
/// This shape maps to Shader Type 2 in the liquid glass renderer.
/// It behaves identically to an [OvalBorder] for layout purposes.
class LiquidOval extends LiquidShape {
  /// Creates a [LiquidOval].
  const LiquidOval({super.side});

  @override
  OutlinedBorder get _equivalentOutlinedBorder => const OvalBorder();

  @override
  LiquidOval copyWith({BorderSide? side}) {
    return LiquidOval(side: side ?? this.side);
  }

  @override
  ShapeBorder scale(double t) {
    return LiquidOval(side: side.scale(t));
  }
}

/// A liquid shape representing a standard rounded rectangle.
///
/// This shape maps to Shader Type 3 in the liquid glass renderer.
/// It behaves identically to a [RoundedRectangleBorder] for layout purposes.
class LiquidRoundedRectangle extends LiquidShape {
  /// Creates a [LiquidRoundedRectangle].
  const LiquidRoundedRectangle({
    required this.borderRadius,
    super.side,
  });

  /// The radius of the rounded corners.
  final Radius borderRadius;

  @override
  OutlinedBorder get _equivalentOutlinedBorder {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.all(borderRadius),
      side: side,
    );
  }

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
