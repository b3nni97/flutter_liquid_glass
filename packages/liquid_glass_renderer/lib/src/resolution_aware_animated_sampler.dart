import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A callback for the [AnimatedSamplerBuilder] widget.
typedef AnimatedSamplerBuilder = void Function(
  ui.Image image,
  Size size,
  ui.Canvas canvas,
);

/// Eine angepasste Version von AnimatedSampler, die einen [resolutionScale] als [Offset] akzeptiert.
/// Damit kann die Auflösung des generierten Bildes dynamisch und anisotrop (unterschiedlich für X/Y)
/// erhöht werden, ohne das Layout (die logische Größe) des Widgets zu verändern.
class ResolutionAwareAnimatedSampler extends StatelessWidget {
  const ResolutionAwareAnimatedSampler(
    this.builder, {
    required this.child,
    super.key,
    this.enabled = true,
    this.resolutionScale = const Offset(1.0, 1.0), // NEU: Offset statt double
  });

  final AnimatedSamplerBuilder builder;
  final bool enabled;
  final Widget child;

  /// Multiplikator für die Auflösung in X und Y Richtung.
  /// Offset(1.0, 1.0) = Standard Device Pixel Ratio.
  /// Offset(2.0, 1.0) = Doppelte Auflösung in der Breite.
  final Offset resolutionScale;

  @override
  Widget build(BuildContext context) {
    return _ShaderSamplerBuilder(
      builder,
      enabled: enabled,
      resolutionScale: resolutionScale,
      child: child,
    );
  }
}

class _ShaderSamplerBuilder extends SingleChildRenderObjectWidget {
  const _ShaderSamplerBuilder(
    this.builder, {
    super.child,
    required this.enabled,
    required this.resolutionScale,
  });

  final AnimatedSamplerBuilder builder;
  final bool enabled;
  final Offset resolutionScale;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderShaderSamplerBuilderWidget(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      builder: builder,
      enabled: enabled,
      resolutionScale: resolutionScale,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderShaderSamplerBuilderWidget)
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..builder = builder
      ..enabled = enabled
      ..resolutionScale = resolutionScale;
  }
}

class _RenderShaderSamplerBuilderWidget extends RenderProxyBox {
  _RenderShaderSamplerBuilderWidget({
    required double devicePixelRatio,
    required AnimatedSamplerBuilder builder,
    required bool enabled,
    required Offset resolutionScale,
  })  : _devicePixelRatio = devicePixelRatio,
        _builder = builder,
        _enabled = enabled,
        _resolutionScale = resolutionScale;

  @override
  OffsetLayer updateCompositedLayer(
      {required covariant _ShaderSamplerBuilderLayer? oldLayer}) {
    final _ShaderSamplerBuilderLayer layer =
        oldLayer ?? _ShaderSamplerBuilderLayer(builder);

    // Wir berechnen die effektive Pixeldichte für X und Y getrennt.
    // effectiveX = DPR * ScaleX
    // effectiveY = DPR * ScaleY
    final effectivePixelRatio = Offset(
      devicePixelRatio * resolutionScale.dx,
      devicePixelRatio * resolutionScale.dy,
    );

    layer
      ..callback = builder
      ..size = size
      ..effectivePixelRatio = effectivePixelRatio;

    return layer;
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsCompositedLayerUpdate();
  }

  Offset get resolutionScale => _resolutionScale;
  Offset _resolutionScale;
  set resolutionScale(Offset value) {
    if (value == _resolutionScale) return;
    _resolutionScale = value;
    markNeedsCompositedLayerUpdate();
  }

  AnimatedSamplerBuilder get builder => _builder;
  AnimatedSamplerBuilder _builder;
  set builder(AnimatedSamplerBuilder value) {
    if (value == _builder) return;
    _builder = value;
    markNeedsCompositedLayerUpdate();
  }

  bool get enabled => _enabled;
  bool _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsPaint();
    markNeedsCompositingBitsUpdate();
  }

  @override
  bool get isRepaintBoundary => alwaysNeedsCompositing;

  @override
  bool get alwaysNeedsCompositing => enabled;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    assert(!_enabled || offset == Offset.zero);
    return super.paint(context, offset);
  }
}

class _ShaderSamplerBuilderLayer extends OffsetLayer {
  _ShaderSamplerBuilderLayer(this._callback);

  ui.Picture? _lastPicture;

  Size get size => _size;
  Size _size = Size.zero;
  set size(Size value) {
    if (value == _size) return;
    _size = value;
    markNeedsAddToScene();
  }

  // Wir speichern hier direkt das kombinierte PixelRatio (DPR * Scale) als Offset
  Offset get effectivePixelRatio => _effectivePixelRatio;
  Offset _effectivePixelRatio = const Offset(1.0, 1.0);
  set effectivePixelRatio(Offset value) {
    if (value == _effectivePixelRatio) return;
    _effectivePixelRatio = value;
    markNeedsAddToScene();
  }

  AnimatedSamplerBuilder get callback => _callback;
  AnimatedSamplerBuilder _callback;
  set callback(AnimatedSamplerBuilder value) {
    if (value == _callback) return;
    _callback = value;
    markNeedsAddToScene();
  }

  ui.Image _buildChildScene(Rect bounds, Offset pixelRatio) {
    final ui.SceneBuilder builder = ui.SceneBuilder();

    // WICHTIG: Hier wird anisotrop skaliert (X und Y getrennt)
    final Matrix4 transform = Matrix4.diagonal3Values(
      pixelRatio.dx,
      pixelRatio.dy,
      1.0,
    );

    builder.pushTransform(transform.storage);
    addChildrenToScene(builder);
    builder.pop();

    // Die Bildgröße richtet sich nun exakt nach den jeweiligen Faktoren
    return builder.build().toImageSync(
          (pixelRatio.dx * bounds.width).ceil(),
          (pixelRatio.dy * bounds.height).ceil(),
        );
  }

  @override
  void dispose() {
    _lastPicture?.dispose();
    super.dispose();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (size.isEmpty) return;

    final ui.Image image = _buildChildScene(
      offset & size,
      effectivePixelRatio,
    );

    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    try {
      callback(image, size, canvas);
    } finally {
      image.dispose();
    }
    final ui.Picture picture = pictureRecorder.endRecording();
    _lastPicture?.dispose();
    _lastPicture = picture;
    builder.addPicture(offset, picture);
  }
}
