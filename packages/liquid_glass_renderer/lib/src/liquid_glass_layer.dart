// ignore_for_file: avoid_setters_without_getters

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/raw_shapes.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';
import 'package:meta/meta.dart';

/// A compositing layer that renders multiple [LiquidGlass] shapes which can
/// visually merge and share a single [LiquidGlassSettings] configuration.
///
/// This widget is purely a rendering utility. It does not alter the semantics
/// or layout of its [child]. The [child] is still laid out and painted by the
/// regular Flutter pipeline; this layer only controls how the glass is
/// filtered and composited on top of/under that content.
///
/// Notes:
/// - Requires Impeller (runtime shader + backdrop filter support). If runtime
///   shader filters are not supported, this widget becomes a no-op pass-through
///   and renders [child] directly.
/// - The layer collects all participating [LiquidGlass] render objects via a
///   shared [GlassLink] and renders them using a two-pass, separable blur:
///   horizontal blur in a dedicated shader, then vertical blur and glass in
///   the main fragment shader.
class LiquidGlassLayer extends StatefulWidget {
  const LiquidGlassLayer({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    this.restrictThickness = true,
    super.key,
  });

  /// The subtree that contains [LiquidGlass] shapes and arbitrary content.
  final Widget child;

  /// Rendering parameters for the liquid glass effect shared by all shapes.
  final LiquidGlassSettings settings;

  /// If true, clamps [LiquidGlassSettings.thickness] to the shortest side of
  /// the smallest shape in the layer to avoid artifacts on very thin shapes.
  final bool restrictThickness;

  @override
  State<LiquidGlassLayer> createState() => _LiquidGlassLayerState();
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    // Guard against platforms/backends without shader-filter support.
    if (!ImageFilter.isShaderFilterSupported) {
      assert(
        ImageFilter.isShaderFilterSupported,
        'liquid_glass_renderer requires Impeller with shader filter support. '
        'Enable Impeller or guard rendering with ImageFilter.isShaderFilterSupported.',
      );
      return widget.child;
    }

    // Build the shader pipeline:
    // 1) Load glass shader (liquid_glass.frag)
    // 2) Nest a horizontal 1D Gaussian blur shader (gauss1d_linear.frag)
    // 3) Provide a render object that uploads uniforms and performs both passes
    return ShaderBuilder(
      assetKey: liquidGlassShader, // Main pass (liquid_glass.frag)
      (context, glassShader, child) => ShaderBuilder(
        assetKey: gaussian1dBlurShader, // H-pass (gauss1d_linear.frag)
        (context, blurH, child) => _RawShapes(
          shader: glassShader,
          blurH: blurH,
          settings: widget.settings,
          debugRenderRefractionMap: false,
          restrictThickness: widget.restrictThickness,
          child: child!,
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _RawShapes extends SingleChildRenderObjectWidget {
  const _RawShapes({
    required this.shader,
    required this.blurH,
    required this.settings,
    required this.debugRenderRefractionMap,
    required this.restrictThickness,
    required Widget super.child,
  });

  /// Main glass fragment shader (includes vertical blur + refraction).
  final FragmentShader shader;

  /// Horizontal blur fragment shader (separable blur first pass).
  final FragmentShader blurH;

  /// Shared settings that affect all shapes in this layer.
  final LiquidGlassSettings settings;

  /// When true, paints a debug refraction map instead of the glass effect.
  final bool debugRenderRefractionMap;

  /// See [LiquidGlassLayer.restrictThickness].
  final bool restrictThickness;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlassLayer(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shader: shader,
      blurH: blurH,
      settings: settings,
      debugRenderRefractionMap: debugRenderRefractionMap,
      restrictThickness: restrictThickness,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlassLayer renderObject,
  ) {
    renderObject
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..settings = settings
      ..debugRenderRefractionMap = debugRenderRefractionMap
      ..restrictThickness = restrictThickness
      ..setShaders(shader, blurH);
  }
}

const int _maxShapesPerLayer = 16;

/// Raw kernel entry (work buffer structure).
class _RawS {
  _RawS(this.x, this.w);
  double x; // sample offset (in px)
  double w; // sample weight
}

/// Packed kernel entry forwarded to the GPU.
class _PackedS {
  _PackedS(this.tPx, this.w);
  final double tPx; // sample offset (in px)
  final double w; // sample weight
}

@internal
class RenderLiquidGlassLayer extends RenderProxyBox {
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader,
    required FragmentShader blurH,
    required LiquidGlassSettings settings,
    required bool restrictThickness,
    bool debugRenderRefractionMap = false,
  })  : _devicePixelRatio = devicePixelRatio,
        _shader = shader,
        _blurH = blurH,
        _settings = settings,
        _debugRenderRefractionMap = debugRenderRefractionMap,
        _restrictThickness = restrictThickness,
        _glassLink = GlassLink() {
    _glassLink.addListener(_onGlassLinkChanged);
    _initHBlurInvariants();
  }

  // ───────────────── Uniform layout (sequential float indices) ──────────────
  //  0..1    : uSize (vec2) [set by Flutter]
  //  2..5    : uGlassColor (vec4)
  //  6..9    : uOpticalProps (vec4)
  // 10..13   : uLightConfig (vec4)
  // 14..15   : uColorAdjust (vec2) => [14]=lightness, [15]=numShapes
  // 16..17   : uLightDirection (vec2) => cos,sin
  // 18..33   : uTransform (mat4)
  // 34..129  : uShapeData (float[MAX_SHAPES*6])
  // 130..133 : uBlurHeader (vec4) => dir.x, dir.y, sample_count, tile_mode
  // 134..    : u_samples[0].. (vec4 per sample)
  static const int _idxGlassColor = 2;
  static const int _idxOpticalProps = 6;
  static const int _idxLightConfig = 10;
  static const int _idxColorAdjust = 14; // x: lightness, y: numShapes (@+1)
  static const int _idxLightDir = 16;
  static const int _idxTransform = 18;
  static const int _idxRimParams = 34;

  static const int _shapeDataBaseFloat = 36; // first float of uShapeData
  static const int _blurBaseFloat = 132; // uBlurHeader.x (u_dir_x)
  static const int _blurSamplesFloat = 136; // u_samples[0].x

  static const double _eps = 0.01;

  final GlassLink _glassLink;
  GlassLink get glassLink => _glassLink;
  void _onGlassLinkChanged() => markNeedsPaint();

  double _devicePixelRatio;
  FragmentShader _shader;
  FragmentShader _blurH;
  LiquidGlassSettings _settings;
  bool _debugRenderRefractionMap;
  bool _restrictThickness;

  // Cached kernels and state to minimize uniform uploads.
  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  bool _hInvariantsInitialized = false;

  // BackdropFilter layer handles (one per pass) to enable retained rendering.
  final LayerHandle<BackdropFilterLayer> _hHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _vHandle =
      LayerHandle<BackdropFilterLayer>();

  // —————— Mutators that trigger repaints when state changes ——————

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  set settings(LiquidGlassSettings value) {
    if (identical(_settings, value)) return;
    _settings = value;
    markNeedsPaint();
  }

  set debugRenderRefractionMap(bool value) {
    if (_debugRenderRefractionMap == value) return;
    _debugRenderRefractionMap = value;
    markNeedsPaint();
  }

  set restrictThickness(bool value) {
    if (_restrictThickness == value) return;
    _restrictThickness = value;
    markNeedsPaint();
  }

  /// Swap shaders. This also resets kernel-related caches as necessary.
  void setShaders(FragmentShader glass, FragmentShader blurH) {
    if (!identical(_shader, glass)) {
      _shader = glass;
      _lastKernelCountV = -1;
      _lastShapeCount = -1;
      markNeedsPaint();
    }
    if (!identical(_blurH, blurH)) {
      _blurH = blurH;
      _lastKernelCountH = -1;
      _hInvariantsInitialized = false;
      _initHBlurInvariants();
      markNeedsPaint();
    }
  }

  /// Set invariants for the horizontal blur shader. Only done once per shader
  /// instance to avoid redundant uniform writes.
  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    _blurH
      ..setFloat(2, 1.0) // u_dir.x (H-pass shader)
      ..setFloat(3, 0.0) // u_dir.y
      ..setFloat(5, 0.0); // u_tile_mode (clamp)
    _hInvariantsInitialized = true;
  }

  /// Collects all [RawShape]s participating in this layer, paired with their
  /// [RenderLiquidGlass] owners for transform and painting coordination.
  ///
  /// Throws [UnsupportedError] if more than [_maxShapesPerLayer] shapes are
  /// present to keep uniform buffer usage bounded.
  List<(RenderLiquidGlass, RawShape)> collectShapes() {
    final result = <(RenderLiquidGlass, RawShape)>[];
    final computed = _glassLink.computedShapes;
    if (computed.length > _maxShapesPerLayer) {
      throw UnsupportedError('Only $_maxShapesPerLayer shapes are supported!');
    }

    for (final s in computed) {
      final ro = s.renderObject;
      if (ro is RenderLiquidGlass) {
        final Matrix4 toThis = ro.getTransformTo(this);
        final double scale = _getScaleFromTransform(toThis);
        result.add((
          ro,
          RawShape.fromLiquidGlassShape(
            s.shape,
            center: s.globalBounds.center,
            size: s.globalBounds.size,
            scale: scale,
          ),
        ));
      }
    }
    return result;
  }

  /// Extracts a uniform scale factor from the given transform matrix.
  /// Handles axis-aligned and rotated cases by deriving the geometric mean
  /// of the X/Y scales, which is suitable for isotropic blur parameters.
  double _getScaleFromTransform(Matrix4 transform) {
    final m = transform.storage;
    // Fast-path: no rotation/skew.
    if (m[1] == 0 && m[4] == 0) {
      final sx = m[0].abs();
      final sy = m[5].abs();
      return math.sqrt(sx * sy);
    }
    // General case: derive magnitudes from column vectors.
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final scaleXSq = a * a + b * b;
    final scaleYSq = c * c + d * d;
    return math.sqrt(math.sqrt(scaleXSq * scaleYSq));
  }

  // Impeller constraints and numeric helpers for kernel synthesis.
  static const int _impellerMaxKernel = 50;
  static const double _maxSigma = 500.0;
  static const double _sqrt3 = 1.7320508075688772;

  /// Empirical sigma scaling to better match Impeller blur response.
  double _scaleSigma(double s) {
    final ss = s.clamp(0.0, _maxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    return ss * (c + b * ss + a * ss * ss);
  }

  /// Converts a Gaussian sigma to an effective radius approximation.
  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _sqrt3 : 0.0;
  }

  /// Generates a discrete Gaussian kernel centered around zero with the given
  /// [radius] and [blurSigma]. The optional [step] enables sample decimation.
  List<_RawS> _genRaw(double blurSigma, int radius, {int step = 1}) {
    final out = <_RawS>[];
    int count = ((2 * radius) ~/ step) + 1, xOff = 0;

    // Reduce very large kernels slightly to keep within GPU limits.
    if (radius >= 16) {
      count -= 2;
      xOff = 1;
    }

    double sum = 0.0;
    for (int i = 0; i < count; i++) {
      final x = xOff + (i * step) - radius;
      final c = math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma);
      out.add(_RawS(x.toDouble(), c));
      sum += c;
    }

    if (sum > 0) {
      for (final s in out) {
        s.w /= sum;
      }
    }
    return out;
  }

  /// Compacts the kernel using a linear interpolation trick to halve the
  /// number of taps while preserving the first two moments as closely as
  /// possible. Also enforces Impeller kernel size limits.
  List<_PackedS> _lerpHack(List<_RawS> raw) {
    final n = raw.length, outCount = ((n - 1) ~/ 2) + 1, mid = outCount ~/ 2;
    final out = <_PackedS>[];
    int j = 0;
    for (int i = 0; i < outCount; i++) {
      if (i == mid) {
        final s = raw[j];
        out.add(_PackedS(s.x, s.w));
        j++;
      } else {
        final a = raw[j], b = raw[j + 1];
        final w = a.w + b.w;
        final t = (a.x * a.w + b.x * b.w) / w;
        out.add(_PackedS(t, w));
        j += 2;
      }
      if (out.length >= _impellerMaxKernel) break;
    }
    return out;
  }

  int _sigmaBucket(double sigmaPx) => (sigmaPx * 10).round();

  /// Computes (or fetches) the separable blur kernel for a given sigma in px.
  List<_PackedS> _computeImpellerKernel(double sigmaPx) {
    final scaled = _scaleSigma(sigmaPx);
    final r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedS>[_PackedS(0.0, 1.0)];
    return _lerpHack(_genRaw(scaled, r));
  }

  /// Returns a cached kernel for the given sigma bucket and marks cache state.
  List<_PackedS> _getKernelAndMark(double sigmaPx) {
    final bucket = _sigmaBucket(sigmaPx);
    if (_cachedKernel != null && bucket == _cachedSigmaBucketKernel) {
      return _cachedKernel!;
    }
    final k = _computeImpellerKernel(sigmaPx);
    _cachedKernel = k;
    _cachedSigmaBucketKernel = bucket;
    _lastKernelCountH = -1;
    _lastKernelCountV = -1;
    return k;
  }

  void _updateShapeCountIfNeeded(int shapeCount) {
    if (_lastShapeCount == shapeCount) return;
    _shader.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());
    _lastShapeCount = shapeCount;
  }

  /// Lightweight shape change detection to avoid redundant uniform uploads.
  bool _shapesChanged(List<(RenderLiquidGlass, RawShape)> shapes) {
    final shapeList = shapes.map((e) => e.$2).toList(growable: false);

    if (_lastShapes == null || _lastShapes!.length != shapeList.length) {
      _lastShapes = shapeList;
      return true;
    }

    const eps2 = _eps * _eps;
    for (var i = 0; i < shapeList.length; i++) {
      final a = _lastShapes![i];
      final b = shapeList[i];

      if (a.type != b.type) {
        _lastShapes = shapeList;
        return true;
      }

      final dcx = a.center.dx - b.center.dx;
      final dcy = a.center.dy - b.center.dy;
      if (dcx * dcx + dcy * dcy > eps2) {
        _lastShapes = shapeList;
        return true;
      }

      final dw = a.size.width - b.size.width;
      final dh = a.size.height - b.size.height;
      if (dw * dw + dh * dh > eps2) {
        _lastShapes = shapeList;
        return true;
      }

      if ((a.cornerRadius - b.cornerRadius).abs() > _eps) {
        _lastShapes = shapeList;
        return true;
      }
    }

    return false;
  }

  static final List<double> _identityMat4 = <double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1,
  ];

  /// Uploads all uniforms required for the current frame if settings, shapes,
  /// or kernel configuration have changed. Minimizes driver traffic by
  /// tracking previous values and only updating as needed.
  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape)> shapes,
    int nKernel,
    List<_PackedS> kernel,
  ) {
    final settingsChanged = _lastSettings != _settings;
    final shapesChanged = _shapesChanged(shapes);

    // Optionally clamp thickness to avoid artifacts on very small shapes.
    var thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((a, b) => a < b ? a : b);
      thickness = math.min(thickness, smallest);
    }

    if (settingsChanged || shapesChanged) {
      _shader
        ..setFloat(_idxGlassColor + 0, _settings.glassColor.r)
        ..setFloat(_idxGlassColor + 1, _settings.glassColor.g)
        ..setFloat(_idxGlassColor + 2, _settings.glassColor.b)
        ..setFloat(_idxGlassColor + 3, _settings.glassColor.a)
        ..setFloat(_idxOpticalProps + 0, _settings.refractiveIndex)
        ..setFloat(_idxOpticalProps + 1, _settings.chromaticAberration)
        ..setFloat(_idxOpticalProps + 2, thickness)
        ..setFloat(_idxOpticalProps + 3, _settings.blend * _devicePixelRatio)
        ..setFloat(_idxLightConfig + 0, _settings.lightAngle)
        ..setFloat(_idxLightConfig + 1, _settings.lightIntensity)
        ..setFloat(_idxLightConfig + 2, _settings.ambientStrength)
        ..setFloat(_idxLightConfig + 3, _settings.saturation)
        ..setFloat(_idxColorAdjust + 0, _settings.lightness)
        ..setFloat(_idxColorAdjust + 1, shapeCount.toDouble())
        ..setFloat(_idxLightDir + 0, math.cos(_settings.lightAngle))
        ..setFloat(_idxLightDir + 1, math.sin(_settings.lightAngle))
        ..setFloat(_idxRimParams + 0, _settings.rimWidthPx)
        ..setFloat(_idxRimParams + 1, _settings.rimSharpness);

      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, _identityMat4[i]);
      }

      for (var i = 0; i < shapeCount; i++) {
        final shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
        final base = _shapeDataBaseFloat + (i * 6);
        _shader
          ..setFloat(base + 0, shape.type.index.toDouble())
          ..setFloat(base + 1, shape.center.dx * _devicePixelRatio)
          ..setFloat(base + 2, shape.center.dy * _devicePixelRatio)
          ..setFloat(base + 3, shape.size.width * _devicePixelRatio)
          ..setFloat(base + 4, shape.size.height * _devicePixelRatio)
          ..setFloat(base + 5, shape.cornerRadius * _devicePixelRatio);
      }

      _lastShapeCount = shapeCount;
      _lastSettings = _settings;
    } else {
      _updateShapeCountIfNeeded(shapeCount);
    }

    // Horizontal pass (separate shader).
    _blurH.setFloat(4, nKernel.toDouble());
    if (nKernel != _lastKernelCountH) {
      int base = 6;
      for (int i = 0; i < nKernel; i++) {
        final s = kernel[i];
        _blurH
          ..setFloat(base + i * 4 + 0, s.tPx)
          ..setFloat(base + i * 4 + 1, 0.0)
          ..setFloat(base + i * 4 + 2, s.w)
          ..setFloat(base + i * 4 + 3, 0.0);
      }
      _lastKernelCountH = nKernel;
    }

    // Vertical pass (performed in the glass shader).
    _shader
      ..setFloat(_blurBaseFloat + 0, 0.0) // u_dir_x
      ..setFloat(_blurBaseFloat + 1, 1.0) // u_dir_y
      ..setFloat(_blurBaseFloat + 2, nKernel.toDouble()) // u_sample_count
      ..setFloat(_blurBaseFloat + 3, 0.0); // u_tile_mode = clamp

    if (nKernel != _lastKernelCountV) {
      int baseV = _blurSamplesFloat;
      for (int i = 0; i < nKernel; i++) {
        final s = kernel[i];
        _shader
          ..setFloat(baseV + 0, s.tPx)
          ..setFloat(baseV + 1, 0.0)
          ..setFloat(baseV + 2, s.w)
          ..setFloat(baseV + 3, 0.0);
        baseV += 4;
      }
      _lastKernelCountV = nKernel;
    }
  }

  /// Snap a rectangle to device pixels to avoid half-pixel sampling seams.
  Rect _snapRectToDeviceFull(Rect r) {
    final d = _devicePixelRatio;
    double s(double v) => (v * d).roundToDouble() / d;
    final l = s(r.left), t = s(r.top), rr = s(r.right), bb = s(r.bottom);
    return Rect.fromLTRB(l, t, rr, bb);
  }

  /// Computes a union path of all shapes in local coordinates for clipping.
  Path _computeUnionClipPath(List<(RenderLiquidGlass, RawShape)> shapes) {
    final path = Path();
    for (final (ro, raw) in shapes) {
      final Matrix4 toThis = ro.getTransformTo(this);
      final Rect rectLocal =
          MatrixUtils.transformRect(toThis, Offset.zero & ro.size);
      if (raw.type == RawShapeType.ellipse) {
        path.addOval(rectLocal);
      } else {
        final r = Radius.circular(raw.cornerRadius);
        path.addRRect(
          RRect.fromRectAndCorners(
            rectLocal,
            topLeft: r,
            topRight: r,
            bottomLeft: r,
            bottomRight: r,
          ),
        );
      }
    }
    return path;
  }

  /// Computes a union rectangle of all shapes, inflated by a margin that
  /// accounts for blur sampling radius and glass thickness.
  Rect _computeUnionClipRect(List<(RenderLiquidGlass, RawShape)> shapes) {
    Rect? union;
    for (final (ro, _) in shapes) {
      final transformToThis = ro.getTransformTo(this);
      final rectLocal =
          MatrixUtils.transformRect(transformToThis, Offset.zero & ro.size);
      union = (union == null) ? rectLocal : union!.expandToInclude(rectLocal);
    }
    // 3σ + thickness + safety padding to ensure sufficient sampling range.
    final double margin = (_settings.blur * 3.0) + _settings.thickness + 12.0;
    return (union ?? Rect.zero).inflate(margin);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shapes = collectShapes();

    // Early exit if the effect is disabled or there is nothing to render.
    if (_settings.thickness <= 0 || shapes.isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    final shapeCount = math.min(_maxShapesPerLayer, shapes.length);

    // Kernel generation.
    final double sigmaPx = _settings.blur * _devicePixelRatio;
    final List<_PackedS> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel = math.min(_impellerMaxKernel, kernel.length);

    // Upload all required uniforms (also updates V-pass samples if needed).
    _uploadUniformsIfNeeded(shapeCount, shapes, nKernel, kernel);

    // Paint content that should appear ABOVE the glass first.
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // Compute an exact clip path for shapes and an inflated sampling bounds.
    final Path clipPath = _computeUnionClipPath(shapes);
    if (clipPath.computeMetrics().isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      super.paint(context, offset);
      return;
    }

    final Rect bounds = _snapRectToDeviceFull(_computeUnionClipRect(shapes));

    context.pushClipRect(
      true,
      offset,
      bounds,
      (ctxRect, offRect) {
        // Use a single path clip for both passes so the mask is identical.
        ctxRect.pushClipPath(
          true,
          offRect,
          bounds,
          clipPath,
          (ctx, off) {
            // ---------- PASS 1: Horizontal blur ----------
            if (sigmaPx > 0.0 && nKernel > 0) {
              _blurH.setFloat(4, nKernel.toDouble()); // u_sample_count
              if (nKernel != _lastKernelCountH) {
                int base = 6;
                for (int i = 0; i < nKernel; i++) {
                  final s = kernel[i];
                  _blurH
                    ..setFloat(base + i * 4 + 0, s.tPx)
                    ..setFloat(base + i * 4 + 1, 0.0)
                    ..setFloat(base + i * 4 + 2, s.w)
                    ..setFloat(base + i * 4 + 3, 0.0);
                }
                _lastKernelCountH = nKernel;
              }

              final BackdropFilterLayer hLayer =
                  _hHandle.layer ?? BackdropFilterLayer();
              hLayer..filter = ImageFilter.shader(_blurH);

              ctx.pushLayer(hLayer, (c2, o2) {
                // Draw a tiny rect to trigger the backdrop filter sampling.
                final paint = Paint()..color = const Color(0x01000000);
                c2.canvas.drawRect(bounds.shift(-off), paint);
              }, off);
              _hHandle.layer = hLayer;
            } else {
              _hHandle.layer = null;
            }

            // ---------- PASS 2: Vertical blur + glass ----------
            final int nV = (sigmaPx > 0.0) ? nKernel : 0;

            _shader
              ..setFloat(_blurBaseFloat + 0, 0.0) // dir.x
              ..setFloat(_blurBaseFloat + 1, 1.0) // dir.y
              ..setFloat(_blurBaseFloat + 2, nV.toDouble())
              ..setFloat(_blurBaseFloat + 3, 0.0); // clamp

            if (nV != _lastKernelCountV) {
              int baseV = _blurSamplesFloat;
              for (int i = 0; i < nV; i++) {
                final s = kernel[i];
                _shader
                  ..setFloat(baseV + 0, s.tPx)
                  ..setFloat(baseV + 1, 0.0)
                  ..setFloat(baseV + 2, s.w)
                  ..setFloat(baseV + 3, 0.0);
                baseV += 4;
              }
              _lastKernelCountV = nV;
            }

            final BackdropFilterLayer vLayer =
                _vHandle.layer ?? BackdropFilterLayer();
            vLayer..filter = ImageFilter.shader(_shader);

            ctx.pushLayer(vLayer, (c2, o2) {
              // Draw a tiny rect to trigger the backdrop filter sampling.
              final paint = Paint()..color = const Color(0x01000000);
              c2.canvas.drawRect(bounds.shift(-off), paint);
            }, off);
            _vHandle.layer = vLayer;
          },
          // Matches the behavior of the working reference implementation.
          clipBehavior: Clip.hardEdge,
        );
      },
      clipBehavior: Clip.hardEdge,
    );

    // Finally, paint content that should appear UNDER the glass.
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);

    super.paint(context, offset);
  }

  @override
  void dispose() {
    _glassLink
      ..removeListener(_onGlassLinkChanged)
      ..dispose();
    super.dispose();
  }

  /// Paints either the child content that is inside the glass or the content
  /// outside of it depending on [glassContainsChild]. This preserves z-ordering
  /// relative to the glass effect while delegating actual painting to the
  /// participating [RenderLiquidGlass] instances.
  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlass, RawShape)> shapes, {
    required bool glassContainsChild,
  }) {
    for (final (ro, _) in shapes) {
      if (ro.glassContainsChild == glassContainsChild) {
        // Paint using the child’s local transform relative to this layer.
        final Matrix4 transform = ro.getTransformTo(this);
        context.pushTransform(true, offset, transform, ro.paintFromLayer);
      }
    }
  }
}
