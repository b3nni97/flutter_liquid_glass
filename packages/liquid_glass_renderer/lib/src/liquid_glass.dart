// liquid_glass.dart

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_layer.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';
import 'package:meta/meta.dart';

/// A widget that applies a liquid glass effect to its child.
///
/// This widget can be used in two modes:
/// 1. **Standalone:** It creates its own rendering layer. This is useful for
///    isolated effects.
/// 2. **In-Layer:** It participates in an ancestor [LiquidGlassLayer]. This allows
///    multiple shapes to share the same refraction/reflection context and merge
///    visually.
class LiquidGlass extends StatelessWidget {
  /// Creates a standalone liquid glass effect.
  ///
  /// This creates an internal [LiquidGlassLayer]. The [touches] provided are
  /// local to this specific shape.
  const LiquidGlass({
    required this.child,
    required this.shape,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.restrictThickness = true,
    this.touches = const <TouchPoint>[],
    this.settings = const LiquidGlassSettings(),
    super.key,
  })  : _isStandalone = true,
        glowStyle = null;

  /// Creates a liquid glass shape that joins an existing [LiquidGlassLayer].
  ///
  /// This widget must be a descendant of a [LiquidGlassLayer]. The [touches]
  /// are local to this shape, but the visual settings are controlled by the
  /// ancestor layer.
  const LiquidGlass.inLayer({
    required this.child,
    required this.shape,
    super.key,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.touches = const <TouchPoint>[],
    this.glowStyle,
  })  : _isStandalone = false,
        settings = null,
        restrictThickness = false;

  /// The widget below this widget in the tree.
  final Widget child;

  /// The geometric shape of the glass.
  final LiquidShape shape;

  /// Whether the child content is rendered inside the glass (refracted) or
  /// drawn on top of the glass.
  final bool glassContainsChild;

  /// {@macro flutter.material.Material.clipBehavior}
  final Clip clipBehavior;

  /// Whether to limit the thickness based on the shape's dimensions.
  final bool restrictThickness;

  /// Touch interactions specific to this shape.
  final List<TouchPoint> touches;

  /// Configuration settings. Only used in standalone mode.
  final LiquidGlassSettings? settings;

  /// Optional glow style specific to this shape (only used in InLayer mode).
  /// If null, the global glow style from the layer's settings will be used.
  final GlowStyle? glowStyle;

  final bool _isStandalone;

  @override
  Widget build(BuildContext context) {
    // 1. Prepare the content: A widget that creates the RenderObject.
    // We wrap it in a builder to defer looking up the GlassScope until
    // we are sure it exists in the context.
    Widget buildShape(BuildContext context) {
      return _LiquidGlassShapeWidget(
        shape: shape,
        glassContainsChild: glassContainsChild,
        localTouches: touches,
        glow: glowStyle,
        link: GlassScope.of(context),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          clipBehavior: clipBehavior,
          child: child,
        ),
      );
    }

    if (_isStandalone) {
      // Standalone Mode: We must create the layer that provides the GlassScope.
      return LiquidGlassLayer(
        settings: settings!,
        restrictThickness: restrictThickness,
        // We use a Builder here because LiquidGlassLayer inserts the GlassScope.
        // The child context needs to be *under* that Scope to find it.
        child: Builder(builder: buildShape),
      );
    } else {
      // In-Layer Mode: We assume GlassScope exists in the ancestry.
      return buildShape(context);
    }
  }
}

// -----------------------------------------------------------------------------
// Internal Implementation
// -----------------------------------------------------------------------------

/// The glue between the Widget tree and the RenderObject tree.
class _LiquidGlassShapeWidget extends SingleChildRenderObjectWidget {
  const _LiquidGlassShapeWidget({
    required super.child,
    required this.shape,
    required this.glassContainsChild,
    required this.localTouches,
    required this.glow, // <--- NEU: Parameter hinzufügen
    required this.link,
  });

  final LiquidShape shape;
  final bool glassContainsChild;
  final List<TouchPoint> localTouches;
  final GlowStyle? glow; // <--- NEU: Feld hinzufügen
  final GlassLink link;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlass(
      shape: shape,
      glassContainsChild: glassContainsChild,
      localTouches: localTouches,
      glow: glow, // <--- NEU: Weitergeben an RenderObject
      link: link,
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
      ..glow = glow // <--- NEU: Update setzen
      ..link = link;
  }
}

/// A RenderProxyBox that registers itself with a [GlassLink].
@internal
class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass({
    required LiquidShape shape,
    required bool glassContainsChild,
    required GlassLink link,
    List<TouchPoint> localTouches = const <TouchPoint>[],
    GlowStyle? glow, // <--- NEU: Optionaler Parameter
  })  : _shape = shape,
        _glassContainsChild = glassContainsChild,
        _localTouches = List<TouchPoint>.from(localTouches),
        _glow = glow, // <--- NEU: Initialisieren
        _link = link {
    // Register immediately upon creation.
    _register();
  }

  // --- Properties ---

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

  // --- NEU: Glow Property ---
  GlowStyle? _glow;
  GlowStyle? get glow => _glow;
  set glow(GlowStyle? value) {
    if (_glow == value) return;
    _glow = value;

    // WICHTIG: Wir müssen dem Layer Bescheid geben, dass sich "Daten" geändert haben,
    // damit er die Uniforms für dieses Shape neu in den Shader lädt.
    _link.notifyShapeLayoutChanged(this);
    // Wir müssen neu malen, damit der Effekt sichtbar wird.
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

  // --- Registration Logic ---

  void _register() {
    _link.registerShape(
      this,
      _shape,
      glassContainsChild: _glassContainsChild,
    );
  }

  void _unregister() {
    _link.unregisterShape(this);
  }

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

  // --- Layout & Painting ---

  @override
  void performLayout() {
    super.performLayout();
    // Notify the layer that our geometry has changed.
    _link.notifyShapeLayoutChanged(this);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // No-op.
    // We do NOT paint in the standard pass. We are painted by the
    // LiquidGlassLayer via `paintFromLayer`.
  }

  /// Called by the [RenderLiquidGlassLayer] to paint the child content.
  void paintFromLayer(PaintingContext context, Offset offset) {
    // Standard RenderProxyBox painting of the child.
    super.paint(context, offset);
  }
}
