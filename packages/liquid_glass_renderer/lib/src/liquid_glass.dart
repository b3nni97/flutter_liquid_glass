// ignore_for_file: avoid_setters_without_getters

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_layer.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';
import 'package:meta/meta.dart';

/// A liquid glass shape.
///
/// Kann alleine genutzt werden (eigener Layer) oder als Teil eines
/// gemeinsamen [LiquidGlassLayer] (`LiquidGlass.inLayer`).
class LiquidGlass extends StatelessWidget {
  /// Standalone-Variante: erstellt einen eigenen [LiquidGlassLayer].
  ///
  /// [touches] werden **lokal** für dieses eine Shape genutzt.
  const LiquidGlass({
    required this.child,
    required this.shape,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.restrictThickness = true,
    this.touches = const <TouchPoint>[],
    super.key,
    LiquidGlassSettings settings = const LiquidGlassSettings(),
  }) : _settings = settings;

  /// In-Layer-Variante: erwartet bereits einen übergeordneten [LiquidGlassLayer].
  ///
  /// [touches] gelten **nur** für dieses Shape; der Layer vergibt intern
  /// den passenden Owner-Index.
  const LiquidGlass.inLayer({
    required this.child,
    required this.shape,
    super.key,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.touches = const <TouchPoint>[],
  })  : _settings = null,
        restrictThickness = false;

  /// The child of this widget.
  final Widget child;

  /// The shape of this glass.
  final LiquidShape shape;

  /// Whether this glass should be rendered inside the glass or on top.
  final bool glassContainsChild;

  /// The clip behavior of this glass.
  final Clip clipBehavior;

  /// {@macro liquid_glass_renderer.restrict_thickness}
  final bool restrictThickness;

  /// Touch-Hotspots, immer **per Shape**.
  final List<TouchPoint> touches;

  final LiquidGlassSettings? _settings;

  @override
  Widget build(BuildContext context) {
    switch (_settings) {
      case null:
        // In-Layer: nur Rohform registrieren, Layer liefert Settings/Touch usw.
        return _RawLiquidGlass(
          shape: shape,
          glassContainsChild: glassContainsChild,
          localTouches: touches, // lokale Touches für dieses Shape
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            clipBehavior: clipBehavior,
            child: child,
          ),
        );

      case final settings:
        // Standalone: eigener Layer; Touches **nicht** am Layer,
        // sondern als lokale Touches des einen Shapes.
        return LiquidGlassLayer(
          settings: settings,
          restrictThickness: restrictThickness,
          child: _RawLiquidGlass(
            shape: shape,
            glassContainsChild: glassContainsChild,
            localTouches: touches,
            child: ClipPath(
              clipper: ShapeBorderClipper(shape: shape),
              clipBehavior: clipBehavior,
              child: child,
            ),
          ),
        );
    }
  }
}

class _RawLiquidGlass extends SingleChildRenderObjectWidget {
  const _RawLiquidGlass({
    required super.child,
    required this.shape,
    required this.glassContainsChild,
    required this.localTouches,
  });

  final LiquidShape shape;
  final bool glassContainsChild;

  /// Touches, die **nur** zu diesem Shape gehören.
  final List<TouchPoint> localTouches;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlass(
      shape: shape,
      glassContainsChild: glassContainsChild,
      localTouches: localTouches,
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
      ..localTouches = localTouches;
  }
}

@internal
class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass({
    required LiquidShape shape,
    required bool glassContainsChild,
    List<TouchPoint> localTouches = const <TouchPoint>[],
  })  : _shape = shape,
        _glassContainsChild = glassContainsChild,
        _localTouches = List<TouchPoint>.from(localTouches);

  late LiquidShape _shape;
  LiquidShape get shape => _shape;
  set shape(LiquidShape value) {
    if (_shape == value) return;
    _shape = value;
    markNeedsPaint();
    _updateGlassLink();
  }

  bool _glassContainsChild = true;
  bool get glassContainsChild => _glassContainsChild;
  set glassContainsChild(bool value) {
    if (_glassContainsChild == value) return;
    _glassContainsChild = value;
    markNeedsPaint();
    _updateGlassLink();
  }

  List<TouchPoint> _localTouches;
  List<TouchPoint> get localTouches => _localTouches;
  set localTouches(List<TouchPoint> v) {
    _localTouches = List<TouchPoint>.from(v);
    markNeedsPaint();
    _glassLink?.notifyShapeLayoutChanged(this);
  }

  GlassLink? _glassLink;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registerWithParentLayer();
  }

  @override
  void detach() {
    _unregisterFromParentLayer();
    super.detach();
  }

  void _registerWithParentLayer() {
    var ancestor = parent;
    while (ancestor != null) {
      if (ancestor is RenderLiquidGlassLayer) {
        _glassLink = ancestor.glassLink;
        _glassLink?.registerShape(
          this,
          _shape,
          glassContainsChild: _glassContainsChild,
        );
        break;
      }
      ancestor = ancestor.parent;
    }
  }

  void _unregisterFromParentLayer() {
    _glassLink?.unregisterShape(this);
    _glassLink = null;
  }

  void _updateGlassLink() {
    _glassLink?.updateShape(
      this,
      _shape,
      glassContainsChild: _glassContainsChild,
    );
  }

  @override
  void performLayout() {
    super.performLayout();
    _glassLink?.notifyShapeLayoutChanged(this);
  }

  @override
  void paint(PaintingContext context, Offset offset) {}

  void paintFromLayer(PaintingContext context, Offset offset) {
    super.paint(context, offset);
  }

  void paintBlur(PaintingContext context, Offset offset, double blur) {
    if (blur <= 0) return;

    context.pushClipPath(
      true,
      offset,
      offset & size,
      ShapeBorderClipper(shape: shape).getClip(size),
      (context, offset) {
        context.pushLayer(
          BackdropFilterLayer(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          ),
          (context, offset) {},
          offset,
        );
      },
    );
  }
}
