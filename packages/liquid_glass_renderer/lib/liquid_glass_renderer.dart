/// A high-fidelity liquid glass rendering library for Flutter.
///
/// This library provides widgets and rendering logic to create realistic
/// 'Liquid Glass' effects.
library liquid_glass_renderer;

export 'src/background_child_sampler.dart'
    show LiquidGlassBackgroundChildBuilder, LiquidGlassBackgroundInterface;
export 'src/liquid_glass.dart' show LiquidGlass;
export 'src/liquid_glass_backdrop_scope.dart' show LiquidGlassBackdropScope;
export 'src/liquid_glass_layer.dart' show LiquidGlassLayer, TouchPoint;
export 'src/liquid_glass_opacity.dart'
    show GlassOpacityScope, LiquidGlassAnimatedOpacity, LiquidGlassOpacity;
export 'src/liquid_glass_renderer.dart';
export 'src/liquid_glass_settings.dart'
    show
        ChildRefractionStyle,
        GlassGeometry,
        GlassLighting,
        GlassMaterial,
        GlassOptics,
        GlowStyle,
        LiquidGlassSettings;
export 'src/liquid_rounded_superellipse_border.dart'
    show LiquidRoundedSuperellipseBorder;
export 'src/liquid_shape.dart';
