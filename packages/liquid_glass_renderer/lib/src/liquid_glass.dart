import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_layer.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';

/// A widget that applies a liquid glass effect to its child.
///
/// This widget functions in two modes:
/// 1. Standalone: Creates its own rendering layer for isolated effects.
/// 2. In-Layer: Participates in an ancestor [LiquidGlassLayer], allowing
///    multiple shapes to share refraction and reflection contexts.
class LiquidGlass extends StatelessWidget {
  /// Creates a standalone liquid glass effect with its own rendering layer.
  const LiquidGlass({
    required this.shape,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.restrictThickness = true,
    this.touches = const <TouchPoint>[],
    this.settings = const LiquidGlassSettings(),
    super.key,
    required this.child,
  })  : _isStandalone = true,
        glowStyle = null,
        material = null;

  /// Creates a liquid glass shape that joins an existing [LiquidGlassLayer].
  const LiquidGlass.inLayer({
    required this.shape,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.touches = const <TouchPoint>[],
    this.glowStyle,
    this.material,
    super.key,
    required this.child,
  })  : _isStandalone = false,
        settings = null,
        restrictThickness = false;

  /// The geometric shape of the glass.
  final LiquidShape shape;

  /// Determines if the child is rendered inside the glass (refracted) or atop it.
  final bool glassContainsChild;

  /// {@macro flutter.material.Material.clipBehavior}
  final Clip clipBehavior;

  /// Limits thickness based on shape dimensions. Used only in standalone mode.
  final bool restrictThickness;

  /// A list of touch interactions specific to this shape.
  final List<TouchPoint> touches;

  /// Configuration settings for the glass effect. Used only in standalone mode.
  final LiquidGlassSettings? settings;

  /// Optional glow style for this specific shape.
  ///
  /// If null in [LiquidGlass.inLayer], the layer's global settings are used.
  final GlowStyle? glowStyle;

  /// Optional material override for this specific shape.
  ///
  /// If null, the layer's global [LiquidGlassSettings.material] is used.
  /// Overrides tint, shade, saturation, and lightness for this shape only.
  final GlassMaterial? material;

  /// The widget below this widget in the tree.
  final Widget child;

  /// Indicates whether this widget creates its own rendering layer.
  final bool _isStandalone;

  @override
  Widget build(BuildContext context) {
    Widget buildShape(BuildContext context) {
      return _LiquidGlassShapeWidget(
        shape: shape,
        glassContainsChild: glassContainsChild,
        localTouches: touches,
        glow: glowStyle,
        material: material,
        link: GlassScope.of(context),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          clipBehavior: clipBehavior,
          child: child,
        ),
      );
    }

    if (_isStandalone) {
      return LiquidGlassLayer(
        settings: settings!,
        restrictThickness: restrictThickness,
        child: Builder(builder: buildShape),
      );
    }

    return buildShape(context);
  }
}

/// Bridges the [LiquidGlass] widget configuration to the [RenderLiquidGlass].
class _LiquidGlassShapeWidget extends SingleChildRenderObjectWidget {
  const _LiquidGlassShapeWidget({
    required this.shape,
    required this.glassContainsChild,
    required this.localTouches,
    required this.glow,
    required this.material,
    required this.link,
    required super.child,
  });

  /// The geometric shape of the glass used for rendering calculations.
  final LiquidShape shape;

  /// Controls whether the child is drawn within the refraction pass.
  final bool glassContainsChild;

  /// Touch points local to this specific shape.
  final List<TouchPoint> localTouches;

  /// Optional specific glow configuration for this shape.
  final GlowStyle? glow;

  /// Optional material override for this shape.
  final GlassMaterial? material;

  /// The link to the parent [LiquidGlassLayer] for coordination.
  final GlassLink link;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlass(
      shape: shape,
      glassContainsChild: glassContainsChild,
      link: link,
      localTouches: localTouches,
      glow: glow,
      material: material,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlass renderObject,
  ) {
    renderObject
      ..shape = shape
      ..glassContainsChild = glassContainsChild
      ..localTouches = localTouches
      ..glow = glow
      ..material = material
      ..link = link;
  }
}

/// A render object that registers its geometry with a [LiquidGlassLayer].
///
/// This object does not paint itself during the standard paint phase. Instead,
/// it registers with a [GlassLink], which allows the ancestor layer to paint
/// this object as part of a unified glass shader effect.
@internal
class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass({
    required LiquidShape shape,
    required bool glassContainsChild,
    required GlassLink link,
    List<TouchPoint> localTouches = const <TouchPoint>[],
    GlowStyle? glow,
    GlassMaterial? material,
  })  : _shape = shape,
        _glassContainsChild = glassContainsChild,
        _localTouches = List<TouchPoint>.from(localTouches),
        _glow = glow,
        _material = material,
        _link = link {
    _register();
  }

  LiquidShape _shape;
  LiquidShape get shape => _shape;
  set shape(LiquidShape value) {
    if (_shape == value) return;
    _shape = value;
    _updateRegistration();
    markNeedsPaint();
  }

  bool _glassContainsChild;
  bool get glassContainsChild => _glassContainsChild;
  set glassContainsChild(bool value) {
    if (_glassContainsChild == value) return;
    _glassContainsChild = value;
    _updateRegistration();
    markNeedsPaint();
  }

  List<TouchPoint> _localTouches;
  List<TouchPoint> get localTouches => _localTouches;
  set localTouches(List<TouchPoint> value) {
    if (listEquals(_localTouches, value)) return;
    _localTouches = List<TouchPoint>.from(value);
    _link.notifyShapeLayoutChanged(this);
    markNeedsPaint();
  }

  GlowStyle? _glow;
  GlowStyle? get glow => _glow;
  set glow(GlowStyle? value) {
    if (_glow == value) return;
    _glow = value;
    _link.notifyShapeLayoutChanged(this);
    markNeedsPaint();
  }

  GlassMaterial? _material;
  GlassMaterial? get material => _material;
  set material(GlassMaterial? value) {
    if (_material == value) return;
    _material = value;
    _link.notifyShapeLayoutChanged(this);
    markNeedsPaint();
  }

  GlassLink _link;
  set link(GlassLink value) {
    if (identical(_link, value)) return;
    _unregister();
    _link = value;
    _register();
    markNeedsPaint();
  }

  /// Registers this shape with the current [GlassLink].
  void _register() {
    _link.registerShape(
      this,
      _shape,
      glassContainsChild: _glassContainsChild,
    );
  }

  /// Removes this shape from the current [GlassLink].
  void _unregister() {
    _link.unregisterShape(this);
  }

  /// Updates the existing registration with the current [GlassLink].
  void _updateRegistration() {
    _link.updateShape(
      this,
      _shape,
      glassContainsChild: _glassContainsChild,
    );
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  @override
  void performLayout() {
    super.performLayout();
    _link.notifyShapeLayoutChanged(this);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Intentionally empty.
    // This render object is painted via `paintFromLayer` when the
    // LiquidGlassLayer processes the scene.
  }

  /// Paints the child content at the specified offset.
  ///
  /// Called by the [RenderLiquidGlassLayer] during the glass composition pass.
  void paintFromLayer(PaintingContext context, Offset offset) {
    super.paint(context, offset);
  }
}
