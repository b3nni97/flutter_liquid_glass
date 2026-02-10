import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';
import 'package:meta/meta.dart';

/// Defines the geometric category of a shape for the shader.
///
/// These values map directly to the integer types expected by the fragment shader
/// to select the appropriate Signed Distance Field (SDF) function.
@internal
enum RawShapeType {
  /// No shape rendered. Maps to shader type 0.
  none,

  /// A superellipse or "squircle". Maps to shader type 1.
  squircle,

  /// An ellipse or circle. Maps to shader type 2.
  ellipse,

  /// A standard rounded rectangle with circular corners. Maps to shader type 3.
  roundedRectangle,
}

/// An intermediate representation of a shape for shader consumption.
///
/// This class flattens the polymorphic [LiquidShape] hierarchy into a uniform
/// set of properties (center, size, radius, smoothing) that can be easily
/// passed as uniforms to the GPU.
@internal
class RawShape with EquatableMixin {
  /// Creates a raw shape definition.
  const RawShape({
    required this.type,
    required this.center,
    required this.size,
    required this.cornerRadius,
    this.cornerSmoothing,
  });

  /// Converts a high-level [LiquidShape] into a shader-ready [RawShape].
  ///
  /// This factory validates constraints (such as equal x/y radii) and maps
  /// the specific shape properties to the generic storage fields.
  factory RawShape.fromLiquidGlassShape(
    LiquidShape shape, {
    required Offset center,
    required Size size,
    double scale = 1.0,
  }) {
    switch (shape) {
      case LiquidRoundedSuperellipse():
        _validateRadius(shape.borderRadius);
        return RawShape(
          type: RawShapeType.squircle,
          center: center,
          size: size,
          cornerRadius: shape.borderRadius.x * scale,
          cornerSmoothing: shape.cornerSmoothing,
        );

      case LiquidOval():
        return RawShape(
          type: RawShapeType.ellipse,
          center: center,
          size: size,
          cornerRadius: 0,
        );

      case LiquidRoundedRectangle():
        _validateRadius(shape.borderRadius);
        return RawShape(
          type: RawShapeType.roundedRectangle,
          center: center,
          size: size,
          cornerRadius: shape.borderRadius.x * scale,
        );
    }
  }

  /// A placeholder constant representing no shape.
  static const RawShape none = RawShape(
    type: RawShapeType.none,
    center: Offset.zero,
    size: Size.zero,
    cornerRadius: 0,
  );

  /// The geometric type identifier used by the shader branching logic.
  final RawShapeType type;

  /// The center point of the shape in the local coordinate system.
  final Offset center;

  /// The dimensions of the bounding box containing the shape.
  final Size size;

  /// The radius of the corners.
  ///
  /// For [RawShapeType.squircle] and [RawShapeType.roundedRectangle], this
  /// must be uniform (circular). For [RawShapeType.ellipse], this is ignored.
  final double cornerRadius;

  /// The smoothing factor for superellipse corners (0.0 to 1.0).
  final double? cornerSmoothing;

  /// The top-left offset derived from the center and size.
  Offset get topLeft =>
      Offset(center.dx - size.width / 2, center.dy - size.height / 2);

  /// The bounding rectangle derived from the top-left offset and size.
  Rect get rect => topLeft & size;

  /// Validates that the radius is circular (x == y).
  ///
  /// Liquid glass shaders currently support only circular corner radii,
  /// not elliptical corners.
  static void _validateRadius(Radius borderRadius) {
    assert(
      borderRadius.x == borderRadius.y,
      'The radius must have equal x and y values for a liquid glass shape.',
    );
  }

  @override
  List<Object?> get props =>
      [type, center, size, cornerRadius, cornerSmoothing];
}
