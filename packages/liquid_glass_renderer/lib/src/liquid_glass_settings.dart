// liquid_glass_settings.dart
import 'dart:math' show pi;
import 'dart:ui'; // Benötigt für lerpDouble

import 'package:equatable/equatable.dart';

/// Glow-Stil für Hotspot-/Touch-Zonen.
/// - `enabled`: schaltet Glow/Overrides an.
/// - `mix`: 0..1, maximale Stärke der Overrides (am Maskenzentrum).
/// - Optional-Overrides (absolute Zielwerte): wenn `null`, bleibt Basiswert unverändert.
/// - Glow-Parameter: strength/power/tintMode/insideOnly/color.
class GlowStyle with EquatableMixin {
  const GlowStyle({
    this.enabled = false,
    this.mix = 1.0, // max. Blend am Maskenzentrum

    // Visuelle Overrides (optional; absolute Zielwerte)
    this.lightness, // null => unverändert
    this.saturation, // null => unverändert
    this.blur, // null => unverändert (Sigma px)
    this.glassColor, // null => unverändert

    // Glow-spezifische Parameter
    this.strength = 0.0,
    this.power = 2.0,
    this.tintMode = 1, // 0=weiß, 1=Hintergrund-Tint, 2=feste Farbe
    this.insideOnly = true,
    this.color = const Color(0xFFFFFFFF),
  });

  // Overlay-Anteil
  final bool enabled;
  final double mix;
  final double? lightness;
  final double? saturation;
  final double? blur;
  final Color? glassColor;

  // Glow-Anteil
  final double strength;
  final double power;
  final int tintMode;
  final bool insideOnly;
  final Color color;

  GlowStyle copyWith({
    bool? enabled,
    double? mix,
    double? lightness,
    double? saturation,
    double? blur,
    Color? glassColor,
    double? strength,
    double? power,
    int? tintMode,
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
      tintMode: tintMode ?? this.tintMode,
      insideOnly: insideOnly ?? this.insideOnly,
      color: color ?? this.color,
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // NEU: Statische Lerp-Funktion für Animationen
  // ────────────────────────────────────────────────────────────────────────

  /// Interpoliert linear zwischen zwei [GlowStyle]-Objekten.
  static GlowStyle lerp(GlowStyle? a, GlowStyle? b, double t) {
    // Standardwerte verwenden, falls a oder b null sind, um Animationen
    // von/zu null zu ermöglichen.
    a ??= const GlowStyle();
    b ??= const GlowStyle();

    // Bools und Ints können nicht linear interpoliert werden.
    // Wir wechseln sie, wenn die Animation zur Hälfte durch ist.
    final bool useBoolsFromB = t >= 0.5;

    return GlowStyle(
      // Bools
      enabled: useBoolsFromB ? b.enabled : a.enabled,
      insideOnly: useBoolsFromB ? b.insideOnly : a.insideOnly,

      // Ints
      tintMode: useBoolsFromB ? b.tintMode : a.tintMode,

      // Doubles (non-nullable)
      mix: lerpDouble(a.mix, b.mix, t)!,
      strength: lerpDouble(a.strength, b.strength, t)!,
      power: lerpDouble(a.power, b.power, t)!,

      // Doubles (nullable)
      // lerpDouble behandelt null-Werte als 0.0, was für Animationen
      // (z.B. von "kein Blur" zu "Blur: 10.0") meist das gewünschte Verhalten ist.
      lightness: lerpDouble(a.lightness, b.lightness, t),
      saturation: lerpDouble(a.saturation, b.saturation, t),
      blur: lerpDouble(a.blur, b.blur, t),

      // Colors
      glassColor: Color.lerp(a.glassColor, b.glassColor, t),
      color: Color.lerp(a.color, b.color, t)!,
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
        tintMode,
        insideOnly,
        color,
      ];
}

/// Globale Einstellungen für den Liquid-Glass-Effekt.
/// - Basiswerte definieren den Default-Look.
/// - `glow` steuert sowohl Glow als auch optionale per-Bereich-Overrides.
class LiquidGlassSettings with EquatableMixin {
  /// Standard-Konstruktor.
  const LiquidGlassSettings({
    this.glassColor = const Color.fromARGB(0, 255, 255, 255),
    this.thickness = 20,
    this.blur = 0,
    this.chromaticAberration = .01,
    this.blend = 20,
    this.lightAngle = 0.5 * pi,
    this.lightIntensity = .2,
    this.ambientStrength = .01,
    this.refractiveIndex = 1.51,
    this.saturation = 1.0,
    this.lightness = 1.0,
    this.rimWidthPx = 1.5,
    this.rimSharpness = 0.9,

    // Einzige dynamische Overlay-/Hotspot-Option:
    this.glow = const GlowStyle(),
  });

  /// Convenience-Konstruktor im Figma-Stil (0..100 Skalen).
  LiquidGlassSettings.figma(
      {required double refraction, // 0..100
      required double depth, // => thickness
      required double dispersion, // 0..100
      required double frost, // => blur (Sigma)
      double lightIntensity = 50, // 0..100
      double lightAngle = 0.5 * pi,
      double blend = 20,
      Color glassColor = const Color.fromARGB(0, 255, 255, 255),
      double rimWidthPx = 1.5,
      double rimSharpness = 0.89,

      // Optional direkt ein GlowStyle setzen
      GlowStyle glow = const GlowStyle()})
      : this(
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
          glow: glow,
        );

  // ───────── Basis-/Default-Parameter (global) ─────────

  /// Basis-Tint (Alpha = Intensität).
  final Color glassColor;

  /// Dicke der „Flüssigkeit“ (px); beeinflusst Refraction.
  final double thickness;

  /// Basis-Blur (Sigma, px) für Frosting.
  final double blur;

  /// Chromatische Aberration (0..~).
  final double chromaticAberration;

  /// Smooth-Union-Blend (zusätzlicher „Zusammenlauf“ px).
  final double blend;

  /// Lichtrichtung (Radiant).
  final double lightAngle;

  /// Lichtintensität (0..1).
  final double lightIntensity;

  /// Ambient-Anteil (0..1).
  final double ambientStrength;

  /// Refractive Index (z. B. 1.51).
  final double refractiveIndex;

  /// Sättigung für den Hintergrund hinter Glas.
  final double saturation;

  /// Helligkeit für den Hintergrund hinter Glas.
  final double lightness;

  /// Breite des Rim-Highlights (px entlang SDF).
  final double rimWidthPx;

  /// Rim-Schärfe (Falloff).
  final double rimSharpness;

  /// Einziger dynamischer Overlay-/Hotspot-Stil (Glow + optionale Overrides).
  final GlowStyle glow;

  // ───────── Copy & Equatable ─────────

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
    GlowStyle? glow,
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
      glow: glow ?? this.glow,
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // NEU: Statische Lerp-Funktion für Animationen
  // ────────────────────────────────────────────────────────────────────────

  /// Interpoliert linear zwischen zwei [LiquidGlassSettings]-Objekten.
  static LiquidGlassSettings? lerp(
      LiquidGlassSettings? a, LiquidGlassSettings? b, double t) {
    // Standard-Tween-Verhalten: Wenn beide null sind, ist das Ergebnis null.
    if (a == null && b == null) return null;

    // Wenn eines null ist, blenden wir ein oder aus.
    // Wir verwenden einen Standardwert (leere Settings) für die Animation.
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

      // Hier rufen wir die statische lerp-Funktion von GlowStyle auf
      glow: GlowStyle.lerp(a.glow, b.glow, t),
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
        glow,
      ];
}
