import 'dart:math' show pi;
import 'dart:ui';

import 'package:equatable/equatable.dart';

// ---------------------------------------------------------------------------
// GlassMaterial — Surface appearance (per-shape overridable)
// ---------------------------------------------------------------------------

/// Defines the surface appearance of the liquid glass material.
///
/// This is the only configuration that can be overridden per-shape via
/// [LiquidGlass.inLayer]. When null on a shape, the layer's global
/// [LiquidGlassSettings.material] is used.
class GlassMaterial with EquatableMixin {
  /// Creates a glass material configuration.
  const GlassMaterial({
    this.tint = const Color(0x00000000),
    this.shade = const Color(0x00FFFFFF),
    this.saturation = 2.5,
    this.lightness = 0.64,
    this.tintBrightness = 0.78,
  });

  /// Creates a tinted glass material with brightness-adaptive highlight tuning.
  ///
  /// [brightnessProgress] controls the tint highlight appearance:
  /// - `0.0` = dark mode (vivid highlights, tintBrightness = 0.82)
  /// - `1.0` = light mode (pastel highlights, tintBrightness = 0.95)
  /// - Values in between produce a smooth transition.
  GlassMaterial.tinted({
    required Color tint,
    double brightnessProgress = 0.0,
    Color shade = const Color(0x00FFFFFF),
    double saturation = 1.0,
    double lightness = 1.0,
  })  : tint = tint,
       shade = shade,
       saturation = saturation,
       lightness = lightness,
       tintBrightness = lerpDouble(0.82, 0.95, brightnessProgress)!;

  /// Linear interpolation between two [GlassMaterial]s.
  static GlassMaterial lerp(GlassMaterial a, GlassMaterial b, double t) {
    return GlassMaterial(
      tint: Color.lerp(a.tint, b.tint, t)!,
      shade: Color.lerp(a.shade, b.shade, t)!,
      saturation: lerpDouble(a.saturation, b.saturation, t)!,
      lightness: lerpDouble(a.lightness, b.lightness, t)!,
      tintBrightness:
          lerpDouble(a.tintBrightness, b.tintBrightness, t)!,
    );
  }

  /// The chromatic tint color applied via Hue-Blend + luminance mixing.
  /// The alpha channel determines the tint intensity.
  final Color tint;

  /// The brightness/shade modifier applied via Multiply/Screen blending.
  /// The alpha channel determines the effect intensity.
  final Color shade;

  /// The saturation multiplier for the background seen through the glass.
  final double saturation;

  /// The brightness multiplier for the background seen through the glass.
  final double lightness;

  /// Controls how bright the [tint] appears on the glass highlights and rim.
  ///
  /// Higher values produce brighter, more pastel highlights.
  /// Lower values produce more vivid, saturated highlights.
  /// - Dark mode: **0.78** (default)
  /// - Light mode: **0.86**
  final double tintBrightness;

  /// Creates a copy with the given fields replaced.
  GlassMaterial copyWith({
    Color? tint,
    Color? shade,
    double? saturation,
    double? lightness,
    double? tintBrightness,
  }) {
    return GlassMaterial(
      tint: tint ?? this.tint,
      shade: shade ?? this.shade,
      saturation: saturation ?? this.saturation,
      lightness: lightness ?? this.lightness,
      tintBrightness: tintBrightness ?? this.tintBrightness,
    );
  }

  @override
  List<Object?> get props => [tint, shade, saturation, lightness, tintBrightness];
}

// ---------------------------------------------------------------------------
// GlassOptics — Physical refraction properties (layer-level only)
// ---------------------------------------------------------------------------

/// Defines the optical/physical properties of the liquid glass.
///
/// These properties control refraction behavior and are shared across all
/// shapes in the layer.
class GlassOptics with EquatableMixin {
  /// Creates an optics configuration.
  const GlassOptics({
    this.thickness = 12.0,
    this.refractiveIndex = 1.7,
    this.chromaticAberration = 0.0,
    this.blur = 0.0,
  });

  /// Linear interpolation between two [GlassOptics].
  static GlassOptics lerp(GlassOptics a, GlassOptics b, double t) {
    return GlassOptics(
      thickness: lerpDouble(a.thickness, b.thickness, t)!,
      refractiveIndex: lerpDouble(a.refractiveIndex, b.refractiveIndex, t)!,
      chromaticAberration:
          lerpDouble(a.chromaticAberration, b.chromaticAberration, t)!,
      blur: lerpDouble(a.blur, b.blur, t)!,
    );
  }

  /// The thickness of the liquid material in pixels. Influences refraction depth.
  final double thickness;

  /// The refractive index of the material (e.g., 1.51 for standard glass).
  final double refractiveIndex;

  /// The strength of the chromatic aberration / spectral dispersion effect.
  final double chromaticAberration;

  /// The standard deviation (sigma) for the background blur (frosting effect).
  final double blur;

  /// Creates a copy with the given fields replaced.
  GlassOptics copyWith({
    double? thickness,
    double? refractiveIndex,
    double? chromaticAberration,
    double? blur,
  }) {
    return GlassOptics(
      thickness: thickness ?? this.thickness,
      refractiveIndex: refractiveIndex ?? this.refractiveIndex,
      chromaticAberration: chromaticAberration ?? this.chromaticAberration,
      blur: blur ?? this.blur,
    );
  }

  @override
  List<Object?> get props => [
        thickness,
        refractiveIndex,
        chromaticAberration,
        blur,
      ];
}

// ---------------------------------------------------------------------------
// GlassLighting — Light source & rim configuration (layer-level only)
// ---------------------------------------------------------------------------

/// Defines the lighting configuration for the liquid glass effect.
///
/// Controls the light source direction, intensity, rim highlights, and
/// background overlay. Shared across all shapes in the layer.
class GlassLighting with EquatableMixin {
  /// Creates a lighting configuration.
  const GlassLighting({
    this.angle = pi / 4,
    this.intensity = 0.25,
    this.ambientStrength = 0.4,
    this.rimWidthPx = 4.0,
    this.rimLightSpread = 0.8,
    this.backgroundOverlay,
  });

  /// Linear interpolation between two [GlassLighting]s.
  static GlassLighting lerp(GlassLighting a, GlassLighting b, double t) {
    return GlassLighting(
      angle: lerpDouble(a.angle, b.angle, t)!,
      intensity: lerpDouble(a.intensity, b.intensity, t)!,
      ambientStrength: lerpDouble(a.ambientStrength, b.ambientStrength, t)!,
      rimWidthPx: lerpDouble(a.rimWidthPx, b.rimWidthPx, t)!,
      rimLightSpread: lerpDouble(a.rimLightSpread, b.rimLightSpread, t)!,
      backgroundOverlay:
          Color.lerp(a.backgroundOverlay, b.backgroundOverlay, t),
    );
  }

  /// The angle of the light source in radians.
  final double angle;

  /// The intensity of the light source (0.0 to 1.0).
  final double intensity;

  /// The intensity of the ambient light (0.0 to 1.0).
  final double ambientStrength;

  /// The width of the rim highlight in pixels, calculated along the SDF.
  final double rimWidthPx;

  /// Controls how wide the dark corners are in the rim lighting.
  ///
  /// This is the exponent for the light-facing calculation. Lower values
  /// (e.g., 0.3) make bright areas wider (smaller dark corners). Higher values
  /// (e.g., 2.0) make bright areas narrower (larger dark corners).
  final double rimLightSpread;

  /// A simple alpha-over color tint applied to the refracted background
  /// before lighting calculations.
  ///
  /// Equivalent to painting a semi-transparent [Container] as a child overlay,
  /// but applied directly in the shader to avoid blur-bleed artifacts.
  /// When null or fully transparent, no overlay is applied.
  final Color? backgroundOverlay;

  /// Creates a copy with the given fields replaced.
  GlassLighting copyWith({
    double? angle,
    double? intensity,
    double? ambientStrength,
    double? rimWidthPx,
    double? rimLightSpread,
    Color? backgroundOverlay,
  }) {
    return GlassLighting(
      angle: angle ?? this.angle,
      intensity: intensity ?? this.intensity,
      ambientStrength: ambientStrength ?? this.ambientStrength,
      rimWidthPx: rimWidthPx ?? this.rimWidthPx,
      rimLightSpread: rimLightSpread ?? this.rimLightSpread,
      backgroundOverlay: backgroundOverlay ?? this.backgroundOverlay,
    );
  }

  @override
  List<Object?> get props => [
        angle,
        intensity,
        ambientStrength,
        rimWidthPx,
        rimLightSpread,
        backgroundOverlay,
      ];
}

// ---------------------------------------------------------------------------
// GlassGeometry — Shape blending & normal map (layer-level only)
// ---------------------------------------------------------------------------

/// Defines the geometry configuration for shape blending and normal maps.
///
/// Shared across all shapes in the layer.
class GlassGeometry with EquatableMixin {
  /// Creates a geometry configuration.
  const GlassGeometry({
    this.blend = 6.0,
    this.normalPlateauWidth = 24.0,
    this.normalSoftness = 1.8,
    this.backgroundScale = const Offset(1.0, 1.0),
  });

  /// Linear interpolation between two [GlassGeometry]s.
  static GlassGeometry lerp(GlassGeometry a, GlassGeometry b, double t) {
    return GlassGeometry(
      blend: lerpDouble(a.blend, b.blend, t)!,
      normalPlateauWidth:
          lerpDouble(a.normalPlateauWidth, b.normalPlateauWidth, t)!,
      normalSoftness: lerpDouble(a.normalSoftness, b.normalSoftness, t)!,
      backgroundScale: Offset.lerp(a.backgroundScale, b.backgroundScale, t)!,
    );
  }

  /// The pixel distance for the smooth union blend between shapes.
  final double blend;

  /// The width of the plateau for the normal map calculation (beveling).
  final double normalPlateauWidth;

  /// The softness exponent for the normal map curve.
  final double normalSoftness;

  /// Scaling factor for the background texture within the shapes.
  ///
  /// `Offset(1, 1)` is unchanged. Values > 1 zoom in, values < 1 zoom out.
  final Offset backgroundScale;

  /// Creates a copy with the given fields replaced.
  GlassGeometry copyWith({
    double? blend,
    double? normalPlateauWidth,
    double? normalSoftness,
    Offset? backgroundScale,
  }) {
    return GlassGeometry(
      blend: blend ?? this.blend,
      normalPlateauWidth: normalPlateauWidth ?? this.normalPlateauWidth,
      normalSoftness: normalSoftness ?? this.normalSoftness,
      backgroundScale: backgroundScale ?? this.backgroundScale,
    );
  }

  @override
  List<Object?> get props => [
        blend,
        normalPlateauWidth,
        normalSoftness,
        backgroundScale,
      ];
}

// ---------------------------------------------------------------------------
// GlowStyle — Interactive glow & hotspot configuration
// ---------------------------------------------------------------------------

/// Defines the visual style for hotspot and touch zone glows.
///
/// Controls both the overlay overrides (modifying the underlying glass
/// parameters like material or blur) and the additive glow effect itself.
class GlowStyle with EquatableMixin {
  /// Creates a configuration for glow and hotspot effects.
  const GlowStyle({
    this.enabled = false,
    this.mix = 1.0,
    this.material,
    this.blur,
    this.strength = 0.0,
    this.power = 2.0,
    this.lightIntensity = 1.0,
    this.color = const Color(0xFFFFFFFF),
  });

  /// Creates a glow style pre-configured for tinted glass.
  ///
  /// Tinted glass requires gentler glow settings than untinted glass because
  /// the tint already provides strong coloration.
  const GlowStyle.tinted({
    this.enabled = true,
    this.mix = 1.0,
    this.material = const GlassMaterial(
      saturation: 1.2,
      lightness: 1.08,
    ),
    this.blur,
    this.strength = 1,
    this.power = 8,
    this.lightIntensity = 2.0,
    this.color = const Color(0x11FFFFFF),
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
      material: _lerpNullableMaterial(a.material, b.material, t),
      blur: lerpDouble(a.blur, b.blur, t),
      strength: lerpDouble(a.strength, b.strength, t)!,
      power: lerpDouble(a.power, b.power, t)!,
      lightIntensity: lerpDouble(a.lightIntensity, b.lightIntensity, t)!,
      color: Color.lerp(a.color, b.color, t)!,
    );
  }

  static GlassMaterial? _lerpNullableMaterial(
    GlassMaterial? a,
    GlassMaterial? b,
    double t,
  ) {
    if (a == null && b == null) return null;
    a ??= const GlassMaterial();
    b ??= const GlassMaterial();
    return GlassMaterial.lerp(a, b, t);
  }

  /// Whether the glow and its associated overrides are active.
  final bool enabled;

  /// The maximum blending strength of the overrides at the center
  /// of the mask (0.0 to 1.0).
  final double mix;

  /// Optional material override during glow interaction.
  ///
  /// Overrides the base material's shade, saturation, and lightness
  /// at the touch hotspot. If null, the base material is preserved.
  final GlassMaterial? material;

  /// Optional override for the background blur (sigma) at the hotspot.
  ///
  /// If null, the base blur is preserved.
  final double? blur;

  /// The intensity of the additive glow effect.
  final double strength;

  /// The exponent for the glow falloff (higher = sharper/smaller glow).
  final double power;

  /// The intensity multiplier for the light source affecting the glow.
  final double lightIntensity;

  /// The base color of the glow effect.
  final Color color;

  /// Creates a copy of this style with the given fields replaced.
  GlowStyle copyWith({
    bool? enabled,
    double? mix,
    GlassMaterial? material,
    double? blur,
    double? strength,
    double? power,
    double? lightIntensity,
    Color? color,
  }) {
    return GlowStyle(
      enabled: enabled ?? this.enabled,
      mix: mix ?? this.mix,
      material: material ?? this.material,
      blur: blur ?? this.blur,
      strength: strength ?? this.strength,
      power: power ?? this.power,
      lightIntensity: lightIntensity ?? this.lightIntensity,
      color: color ?? this.color,
    );
  }

  @override
  List<Object?> get props => [
        enabled,
        mix,
        material,
        blur,
        strength,
        power,
        lightIntensity,
        color,
      ];
}

// ---------------------------------------------------------------------------
// ChildRefractionStyle — Child-specific refraction overrides
// ---------------------------------------------------------------------------

/// Defines child-specific refraction parameters for the liquid glass effect.
///
/// When set on [LiquidGlassSettings], these values override the global
/// refraction for the child texture (icons, text). If a field is null,
/// the corresponding global setting is used.
class ChildRefractionStyle with EquatableMixin {
  /// Creates a child refraction style.
  const ChildRefractionStyle({
    this.thickness,
    this.refractiveIndex,
    this.normalPlateauWidth,
    this.normalSoftness,
    this.caSpread,
  });

  /// Linear interpolation between two [ChildRefractionStyle]s.
  static ChildRefractionStyle? lerp(
      ChildRefractionStyle? a, ChildRefractionStyle? b, double t) {
    if (a == null && b == null) return null;
    a ??= const ChildRefractionStyle();
    b ??= const ChildRefractionStyle();

    return ChildRefractionStyle(
      thickness: _lerpNullable(a.thickness, b.thickness, t),
      refractiveIndex: _lerpNullable(a.refractiveIndex, b.refractiveIndex, t),
      normalPlateauWidth:
          _lerpNullable(a.normalPlateauWidth, b.normalPlateauWidth, t),
      normalSoftness: _lerpNullable(a.normalSoftness, b.normalSoftness, t),
      caSpread: _lerpNullable(a.caSpread, b.caSpread, t),
    );
  }

  static double? _lerpNullable(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    return lerpDouble(a ?? b!, b ?? a!, t);
  }

  /// Overrides [GlassOptics.thickness] for the child texture.
  final double? thickness;

  /// Overrides [GlassOptics.refractiveIndex] for the child texture.
  final double? refractiveIndex;

  /// Overrides [GlassGeometry.normalPlateauWidth] for the child texture.
  final double? normalPlateauWidth;

  /// Overrides [GlassGeometry.normalSoftness] for the child texture.
  final double? normalSoftness;

  /// Multiplier for child CA spread.
  /// 1.0 = same as background. <1 = less spread, >1 = more.
  final double? caSpread;

  /// Creates a copy with the given fields replaced.
  ChildRefractionStyle copyWith({
    double? thickness,
    double? refractiveIndex,
    double? normalPlateauWidth,
    double? normalSoftness,
    double? caSpread,
  }) {
    return ChildRefractionStyle(
      thickness: thickness ?? this.thickness,
      refractiveIndex: refractiveIndex ?? this.refractiveIndex,
      normalPlateauWidth: normalPlateauWidth ?? this.normalPlateauWidth,
      normalSoftness: normalSoftness ?? this.normalSoftness,
      caSpread: caSpread ?? this.caSpread,
    );
  }

  @override
  List<Object?> get props => [
        thickness,
        refractiveIndex,
        normalPlateauWidth,
        normalSoftness,
        caSpread,
      ];
}

// ---------------------------------------------------------------------------
// LiquidGlassSettings — Top-level configuration
// ---------------------------------------------------------------------------

/// Global settings configuration for the Liquid Glass effect.
///
/// Groups all configuration into semantic sub-objects:
/// - [material]: Surface appearance (tint, shade, saturation, lightness)
/// - [optics]: Physical refraction properties
/// - [lighting]: Light source and rim configuration
/// - [geometry]: Shape blending and normal map settings
/// - [glowStyle]: Interactive glow/hotspot configuration
/// - [childRefraction]: Child-specific refraction overrides
class LiquidGlassSettings with EquatableMixin {
  /// Creates a standard liquid glass configuration.
  const LiquidGlassSettings({
    this.material = const GlassMaterial(),
    this.optics = const GlassOptics(),
    this.lighting = const GlassLighting(),
    this.geometry = const GlassGeometry(),
    this.glowStyle = const GlowStyle(),
    this.childRefraction,
  });

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
      material: GlassMaterial.lerp(a.material, b.material, t),
      optics: GlassOptics.lerp(a.optics, b.optics, t),
      lighting: GlassLighting.lerp(a.lighting, b.lighting, t),
      geometry: GlassGeometry.lerp(a.geometry, b.geometry, t),
      glowStyle: GlowStyle.lerp(a.glowStyle, b.glowStyle, t),
      childRefraction:
          ChildRefractionStyle.lerp(a.childRefraction, b.childRefraction, t),
    );
  }

  /// The surface appearance of the glass (tint, shade, saturation, lightness).
  ///
  /// Can be overridden per-shape via [LiquidGlass.inLayer].
  final GlassMaterial material;

  /// The optical/physical properties (thickness, refraction, CA, blur).
  final GlassOptics optics;

  /// The lighting configuration (angle, intensity, rim, background overlay).
  final GlassLighting lighting;

  /// The geometry configuration (blend, normal map, background scale).
  final GlassGeometry geometry;

  /// The interactive glow and hotspot overlay configuration.
  final GlowStyle glowStyle;

  /// Optional child-specific refraction parameters.
  ///
  /// When non-null, the child texture (icons, text) uses these values
  /// instead of the global optics. Individual null fields fall back
  /// to the global value.
  final ChildRefractionStyle? childRefraction;

  /// Creates a copy of these settings with the given fields replaced.
  LiquidGlassSettings copyWith({
    GlassMaterial? material,
    GlassOptics? optics,
    GlassLighting? lighting,
    GlassGeometry? geometry,
    GlowStyle? glowStyle,
    ChildRefractionStyle? childRefraction,
  }) {
    return LiquidGlassSettings(
      material: material ?? this.material,
      optics: optics ?? this.optics,
      lighting: lighting ?? this.lighting,
      geometry: geometry ?? this.geometry,
      glowStyle: glowStyle ?? this.glowStyle,
      childRefraction: childRefraction ?? this.childRefraction,
    );
  }

  @override
  List<Object?> get props => [
        material,
        optics,
        lighting,
        geometry,
        glowStyle,
        childRefraction,
      ];
}
