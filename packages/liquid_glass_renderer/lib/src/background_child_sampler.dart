// resolution_aware_animated_sampler.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A callback for the [BackgroundChildSampler] widget.
typedef SamplerBuilder = void Function(ui.Image image);

/// A builder that returns a [LiquidGlassBackgroundInterface].
typedef LiquidGlassBackgroundChildBuilder = LiquidGlassBackgroundInterface
    Function(BuildContext context);

/// Interface for widgets that provide a specific texture size for sampling.
abstract class LiquidGlassBackgroundInterface implements Widget {
  /// The target size of the texture to be generated.
  Size get textureSize;
}

/// A specialized sampler that captures its child as a texture while handling
/// resolution scaling and viewport expansion.
///
/// This widget captures the child into a [ui.Image] passed to [sampler],
/// while also painting the child to the screen using a cached [ui.Picture].
class BackgroundChildSampler extends StatelessWidget {
  /// Create a new [BackgroundChildSampler].
  const BackgroundChildSampler(
    this.sampler, {
    required this.builder,
    super.key,
    this.enabled = true,
  });

  /// A callback used by this widget to provide the children captured in
  /// a texture.
  final SamplerBuilder sampler;

  /// Whether the children should be captured in a texture.
  final bool enabled;

  /// The child widget builder.
  final LiquidGlassBackgroundChildBuilder builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return _ShaderSamplerBuilder(
          sampler: sampler,
          enabled: enabled,
          child: builder(context),
        );
      },
    );
  }
}

class _ShaderSamplerBuilder extends SingleChildRenderObjectWidget {
  const _ShaderSamplerBuilder({
    required this.sampler,
    required this.enabled,
    required LiquidGlassBackgroundInterface super.child,
  });

  final SamplerBuilder sampler;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) {
    final LiquidGlassBackgroundInterface interfaceChild =
        child as LiquidGlassBackgroundInterface;
    return _RenderShaderSamplerBuilderWidget(
      devicePixelRatio: MediaQuery.of(context).devicePixelRatio,
      sampler: sampler,
      enabled: enabled,
      textureSize: interfaceChild.textureSize,
    );
  }

  @override
  void updateRenderObject(BuildContext context,
      covariant _RenderShaderSamplerBuilderWidget renderObject) {
    final LiquidGlassBackgroundInterface interfaceChild =
        child as LiquidGlassBackgroundInterface;
    renderObject
      ..devicePixelRatio = MediaQuery.of(context).devicePixelRatio
      ..sampler = sampler
      ..enabled = enabled
      ..textureSize = interfaceChild.textureSize;
  }
}

class _RenderShaderSamplerBuilderWidget extends RenderProxyBox {
  _RenderShaderSamplerBuilderWidget({
    required double devicePixelRatio,
    required SamplerBuilder sampler,
    required bool enabled,
    required Size textureSize,
  })  : _devicePixelRatio = devicePixelRatio,
        _sampler = sampler,
        _enabled = enabled,
        _textureSize = textureSize;

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsCompositedLayerUpdate();
  }

  SamplerBuilder _sampler;
  SamplerBuilder get sampler => _sampler;
  set sampler(SamplerBuilder value) {
    if (_sampler == value) {
      return;
    }
    _sampler = value;
    markNeedsCompositedLayerUpdate();
  }

  bool _enabled;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    markNeedsPaint();
    markNeedsCompositingBitsUpdate();
  }

  Size _textureSize;
  Size get textureSize => _textureSize;
  set textureSize(Size value) {
    if (_textureSize == value) {
      return;
    }
    _textureSize = value;
    markNeedsCompositedLayerUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => enabled;

  @override
  bool get isRepaintBoundary => alwaysNeedsCompositing;

  @override
  OffsetLayer updateCompositedLayer(
      {required covariant _ShaderSamplerBuilderLayer? oldLayer}) {
    final _ShaderSamplerBuilderLayer layer =
        oldLayer ?? _ShaderSamplerBuilderLayer(sampler);
    layer
      ..callback = sampler
      ..size = size
      ..devicePixelRatio = devicePixelRatio
      ..textureSize = textureSize;
    return layer;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      return;
    }
    assert(!_enabled || offset == Offset.zero);
    super.paint(context, offset);
  }
}

/// A layer that creates a [ui.Picture] for the scene and a [ui.Image] for the sampler.
class _ShaderSamplerBuilderLayer extends OffsetLayer {
  _ShaderSamplerBuilderLayer(this._callback);

  SamplerBuilder _callback;
  SamplerBuilder get callback => _callback;
  set callback(SamplerBuilder value) {
    if (_callback == value) {
      return;
    }
    _callback = value;
    markNeedsAddToScene();
  }

  Size _size = Size.zero;
  Size get size => _size;
  set size(Size value) {
    if (_size == value) {
      return;
    }
    _size = value;
    markNeedsAddToScene();
  }

  double _devicePixelRatio = 1.0;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsAddToScene();
  }

  Size _textureSize = Size.zero;
  Size get textureSize => _textureSize;
  set textureSize(Size value) {
    if (_textureSize == value) {
      return;
    }
    _textureSize = value;
    markNeedsAddToScene();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (size.isEmpty) {
      return;
    }

    final ui.Image image = _buildChildImage();

    try {
      // Pass the captured image to the consumer (Shader).
      // The Shader typically maps UVs based on the virtual size vs texture size.
      callback(image);
    } finally {
      image.dispose();
    }
  }

  ui.Image _buildChildImage() {
    final ui.SceneBuilder sceneBuilder = ui.SceneBuilder();

    // Scale logic: The transform maps the logical bounds to the physical texture.
    // We use the devicePixelRatio directly to ensure 1:1 pixel matching for the
    // drawn content, relying on the textureSize to provide the bounds.
    final Matrix4 effectiveTransform = Matrix4.diagonal3Values(
      devicePixelRatio,
      devicePixelRatio,
      1.0,
    );

    sceneBuilder.pushTransform(effectiveTransform.storage);
    addChildrenToScene(sceneBuilder);
    sceneBuilder.pop();

    // The image is created with the precise integer size defined by the interface.
    // This prevents jitter as the size is stable regardless of minor scale fluctuations.

    final physicalWidth = (textureSize.width * devicePixelRatio).ceilToDouble();
    final physicalHeight =
        (textureSize.height * devicePixelRatio).ceilToDouble();

    return sceneBuilder.build().toImageSync(
          physicalWidth.toInt(),
          physicalHeight.toInt(),
        );
  }
}
