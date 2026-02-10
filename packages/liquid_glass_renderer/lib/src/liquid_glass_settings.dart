import 'dart:math' show pi;
import 'dart:ui';

import 'package:equatable/equatable.dart';

/// Defines the visual style for hotspot and touch zone glows within the liquid glass effect.
///
/// This class controls both the overlay overrides (modifying the underlying glass
/// parameters like lightness or saturation) and the additive glow effect itself.
class GlowStyle with EquatableMixin {
  /// Creates a configuration for glow and hotspot effects.
  const GlowStyle({
    this.enabled = false,
    this.mix = 1.0,
    this.lightness,
    this.saturation,
    this.blur,
    this.glassColor,
    this.strength = 0.0,
    this.power = 2.0,
    this.lightIntensity = 1.0,
    this.insideOnly = true,
    this.color = const Color(0xFFFFFFFF),
  });

  /// Linear interpolation between two [GlowStyle]s.
  static GlowStyle lerp(GlowStyle? a, GlowStyle? b, double t) {
    if (a == null && b == null) return const GlowStyle();
    a ??= const GlowStyle();
    b ??= const GlowStyle();

    final bool useBoolsFromB = t >= 0.5;

    return GlowStyle(
      enabled: useBoolsFromB ? b.enabled : a.enabled,
      mix: lerpDouble(a.mix, b.mix, t)!,
      lightness: lerpDouble(a.lightness, b.lightness, t),
      saturation: lerpDouble(a.saturation, b.saturation, t),
      blur: lerpDouble(a.blur, b.blur, t),
      glassColor: Color.lerp(a.glassColor, b.glassColor, t),
      strength: lerpDouble(a.strength, b.strength, t)!,
      power: lerpDouble(a.power, b.power, t)!,
      lightIntensity: lerpDouble(a.lightIntensity, b.lightIntensity, t)!,
      insideOnly: useBoolsFromB ? b.insideOnly : a.insideOnly,
      color: Color.lerp(a.color, b.color, t)!,
    );
  }

  /// Whether the glow and its associated overrides are active.
  final bool enabled;

  /// The maximum blending strength of the overrides at the center of the mask (0.0 to 1.0).
  final double mix;

  /// Optional override for the lightness of the glass area.
  ///
  /// If null, the base settings are preserved.
  final double? lightness;

  /// Optional override for the saturation of the glass area.
  ///
  /// If null, the base settings are preserved.
  final double? saturation;

  /// Optional override for the background blur (sigma) of the glass area.
  ///
  /// If null, the base settings are preserved.
  final double? blur;

  /// Optional override for the tint color of the glass area.
  ///
  /// If null, the base settings are preserved.
  final Color? glassColor;

  /// The intensity of the additive glow effect.
  final double strength;

  /// The exponent for the glow falloff (higher values mean a sharper/smaller glow).
  final double power;

  /// The intensity multiplier for the light source affecting the glow.
  final double lightIntensity;

  /// Whether the glow should be clipped to the inside of the shape.
  final bool insideOnly;

  /// The base color of the glow effect.
  final Color color;

  /// Creates a copy of this style with the given fields replaced with the new values.
  GlowStyle copyWith({
    bool? enabled,
    double? mix,
    double? lightness,
    double? saturation,
    double? blur,
    Color? glassColor,
    double? strength,
    double? power,
    double? lightIntensity,
    bool? insideOnly,
    Color? color,
  }) {
    return GlowStyle(
      enabled: enabled ?? this.enabled,
      mix: mix ?? this.mix,
      lightness: lightness ?? this.lightness,
      saturation: saturation ?? this.saturation,
      blur: blur ?? this.blur,
      glassColor: glassColor ?? this.glassColor,
      strength: strength ?? this.strength,
      power: power ?? this.power,
      lightIntensity: lightIntensity ?? this.lightIntensity,
      insideOnly: insideOnly ?? this.insideOnly,
      color: color ?? this.color,
    );
  }

  @override
  List<Object?> get props => [
        enabled,
        mix,
        lightness,
        saturation,
        blur,
        glassColor,
        strength,
        power,
        lightIntensity,
        insideOnly,
        color,
      ];
}

/// Global settings configuration for the Liquid Glass effect.
///
/// Controls the optical properties (refraction, blur, chromatic aberration),
/// lighting, and geometry styling of the glass material.
class LiquidGlassSettings with EquatableMixin {
  /// Creates a standard liquid glass configuration.
  const LiquidGlassSettings({
    this.glassColor = const Color(0x00FFFFFF),
    this.thickness = 12.0,
    this.blur = 0.0,
    this.chromaticAberration = 0.0,
    this.blend = 6.0,
    this.lightAngle = pi / 4,
    this.lightIntensity = 0.38,
    this.ambientStrength = 0.4,
    this.refractiveIndex = 1.7,
    this.saturation = 2.5,
    this.lightness = 0.64,
    this.rimWidthPx = 4.0,
    this.rimSharpness = 0.8,
    this.glowStyle = const GlowStyle(),
    this.backgroundScale = const Offset(1.0, 1.0),
    this.normalPlateauWidth = 24.0,
    this.normalSoftness = 1.8,
  });

  /// Creates a liquid glass configuration using Figma-style parameters (0-100 scales).
  ///
  /// This constructor maps Figma design tokens to the internal physics-based
  /// parameters used by the shader.
  const LiquidGlassSettings.figma({
    required double refraction,
    required double depth,
    required double dispersion,
    required double frost,
    double lightIntensity = 50.0,
    double lightAngle = pi / 4,
    double blend = 20.0,
    Color glassColor = const Color(0x00FFFFFF),
    double rimWidthPx = 1.5,
    double rimSharpness = 0.89,
    GlowStyle glow = const GlowStyle(),
  }) : this(
          refractiveIndex: 1 + (refraction / 100) * 0.2,
          thickness: depth,
          chromaticAberration: 4 * (dispersion / 100),
          lightIntensity: lightIntensity / 100,
          blur: frost,
          lightness: 1.08,
          lightAngle: lightAngle,
          ambientStrength: 0.1,
          saturation: 1.05,
          blend: blend,
          glassColor: glassColor,
          rimWidthPx: rimWidthPx,
          rimSharpness: rimSharpness,
          glowStyle: glow,
          backgroundScale: const Offset(1.0, 1.0),
          normalPlateauWidth: 24.0,
          normalSoftness: 1.8,
        );

  /// Linear interpolation between two [LiquidGlassSettings] objects.
  static LiquidGlassSettings? lerp(
    LiquidGlassSettings? a,
    LiquidGlassSettings? b,
    double t,
  ) {
    if (a == null && b == null) return null;
    a ??= const LiquidGlassSettings();
    b ??= const LiquidGlassSettings();

    return LiquidGlassSettings(
      glassColor: Color.lerp(a.glassColor, b.glassColor, t)!,
      thickness: lerpDouble(a.thickness, b.thickness, t)!,
      blur: lerpDouble(a.blur, b.blur, t)!,
      chromaticAberration:
          lerpDouble(a.chromaticAberration, b.chromaticAberration, t)!,
      blend: lerpDouble(a.blend, b.blend, t)!,
      lightAngle: lerpDouble(a.lightAngle, b.lightAngle, t)!,
      lightIntensity: lerpDouble(a.lightIntensity, b.lightIntensity, t)!,
      ambientStrength: lerpDouble(a.ambientStrength, b.ambientStrength, t)!,
      refractiveIndex: lerpDouble(a.refractiveIndex, b.refractiveIndex, t)!,
      saturation: lerpDouble(a.saturation, b.saturation, t)!,
      lightness: lerpDouble(a.lightness, b.lightness, t)!,
      rimWidthPx: lerpDouble(a.rimWidthPx, b.rimWidthPx, t)!,
      rimSharpness: lerpDouble(a.rimSharpness, b.rimSharpness, t)!,
      glowStyle: GlowStyle.lerp(a.glowStyle, b.glowStyle, t),
      backgroundScale: Offset.lerp(a.backgroundScale, b.backgroundScale, t)!,
      normalPlateauWidth:
          lerpDouble(a.normalPlateauWidth, b.normalPlateauWidth, t)!,
      normalSoftness: lerpDouble(a.normalSoftness, b.normalSoftness, t)!,
    );
  }

  /// The base tint color of the glass. The alpha channel determines the tint intensity.
  final Color glassColor;

  /// The thickness of the liquid material in pixels. Influences the refraction depth.
  final double thickness;

  /// The standard deviation (sigma) for the background blur (frosting effect).
  final double blur;

  /// The strength of the chromatic aberration effect.
  final double chromaticAberration;

  /// The pixel distance for the smooth union blend between shapes.
  final double blend;

  /// The angle of the light source in radians.
  final double lightAngle;

  /// The intensity of the light source (0.0 to 1.0).
  final double lightIntensity;

  /// The intensity of the ambient light (0.0 to 1.0).
  final double ambientStrength;

  /// The refractive index of the material (e.g., 1.51 for standard glass).
  final double refractiveIndex;

  /// The saturation multiplier for the background seen through the glass.
  final double saturation;

  /// The brightness multiplier for the background seen through the glass.
  final double lightness;

  /// The width of the rim highlight in pixels, calculated along the SDF.
  final double rimWidthPx;

  /// The sharpness/falloff of the rim highlight.
  final double rimSharpness;

  /// The configuration for the interactive glow and hotspot overlays.
  final GlowStyle glowStyle;

  /// Scaling factor for the background texture within the shapes.
  ///
  /// `Offset(1, 1)` is unchanged. Values > 1 zoom in, values < 1 zoom out.
  final Offset backgroundScale;

  /// The width of the plateau for the normal map calculation (beveling).
  final double normalPlateauWidth;

  /// The softness exponent for the normal map curve.
  final double normalSoftness;

  /// Creates a copy of these settings with the given fields replaced with the new values.
  LiquidGlassSettings copyWith({
    Color? glassColor,
    double? thickness,
    double? blur,
    double? chromaticAberration,
    double? blend,
    double? lightAngle,
    double? lightIntensity,
    double? ambientStrength,
    double? refractiveIndex,
    double? saturation,
    double? lightness,
    double? rimWidthPx,
    double? rimSharpness,
    GlowStyle? glowStyle,
    Offset? backgroundScale,
    double? normalPlateauWidth,
    double? normalSoftness,
  }) {
    return LiquidGlassSettings(
      glassColor: glassColor ?? this.glassColor,
      thickness: thickness ?? this.thickness,
      blur: blur ?? this.blur,
      chromaticAberration: chromaticAberration ?? this.chromaticAberration,
      blend: blend ?? this.blend,
      lightAngle: lightAngle ?? this.lightAngle,
      lightIntensity: lightIntensity ?? this.lightIntensity,
      ambientStrength: ambientStrength ?? this.ambientStrength,
      refractiveIndex: refractiveIndex ?? this.refractiveIndex,
      saturation: saturation ?? this.saturation,
      lightness: lightness ?? this.lightness,
      rimWidthPx: rimWidthPx ?? this.rimWidthPx,
      rimSharpness: rimSharpness ?? this.rimSharpness,
      glowStyle: glowStyle ?? this.glowStyle,
      backgroundScale: backgroundScale ?? this.backgroundScale,
      normalPlateauWidth: normalPlateauWidth ?? this.normalPlateauWidth,
      normalSoftness: normalSoftness ?? this.normalSoftness,
    );
  }

  @override
  List<Object?> get props => [
        glassColor,
        thickness,
        blur,
        chromaticAberration,
        blend,
        lightAngle,
        lightIntensity,
        ambientStrength,
        refractiveIndex,
        saturation,
        lightness,
        rimWidthPx,
        rimSharpness,
        glowStyle,
        backgroundScale,
        normalPlateauWidth,
        normalSoftness,
      ];
}
