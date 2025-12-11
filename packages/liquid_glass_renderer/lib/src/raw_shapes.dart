// ignore_for_file: dead_code, deprecated_member_use_from_same_package

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';
import 'package:meta/meta.dart';

@internal
enum RawShapeType {
  none, // 0
  squircle, // 1 (Figma Style & Legacy Auto)
  ellipse, // 2
  roundedRectangle, // 3
}

@internal
class RawShape with EquatableMixin {
  const RawShape({
    required this.type,
    required this.center,
    required this.size,
    required this.cornerRadius,
    this.cornerSmoothing,
  });

  factory RawShape.fromLiquidGlassShape(
    LiquidShape shape, {
    required Offset center,
    required Size size,
    double scale = 1.0,
  }) {
    switch (shape) {
      // Konsolidierter Squircle (Type 1)
      // Behandelt sowohl den Auto-Modus (cornerSmoothing == null)
      // als auch den Figma-Modus (cornerSmoothing != null).
      case LiquidRoundedSuperellipse():
        _assertSameRadius(shape.borderRadius);
        return RawShape(
          type: RawShapeType.squircle,
          center: center,
          size: size,
          cornerRadius: shape.borderRadius.x * scale,
          // Wir reichen den Wert einfach durch.
          // null -> Shader nutzt Auto-Logic (-1.0).
          // 0.0-1.0 -> Shader nutzt Figma-Logic.
          cornerSmoothing: shape.cornerSmoothing,
        );

      case LiquidOval():
        return RawShape(
          type: RawShapeType.ellipse, // Type 2
          center: center,
          size: size,
          cornerRadius: 0,
        );

      case LiquidRoundedRectangle():
        _assertSameRadius(shape.borderRadius);
        return RawShape(
          type: RawShapeType.roundedRectangle, // Type 3
          center: center,
          size: size,
          cornerRadius: shape.borderRadius.x * scale,
        );
    }
  }

  static const none = RawShape(
    type: RawShapeType.none,
    center: Offset.zero,
    size: Size.zero,
    cornerRadius: 0,
  );

  final RawShapeType type;
  final Offset center;
  final Size size;
  final double cornerRadius;

  /// Controls the smoothness (0.0 - 1.0).
  /// If null, the shader uses the legacy auto-calculation logic (-1.0).
  final double? cornerSmoothing;

  Offset get topLeft =>
      Offset(center.dx - size.width / 2, center.dy - size.height / 2);

  Rect get rect => topLeft & size;

  @override
  List<Object?> get props =>
      [type, center, size, cornerRadius, cornerSmoothing];
}

void _assertSameRadius(Radius borderRadius) {
  assert(
    borderRadius.x == borderRadius.y,
    'The radius must have equal x and y values for a liquid glass shape.',
  );
}
