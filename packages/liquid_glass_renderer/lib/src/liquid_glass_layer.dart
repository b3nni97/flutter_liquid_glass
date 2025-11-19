// liquid_glass_layer.dart
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
/// Notes:
/// - Requires Impeller (runtime shader + backdrop filter support). If runtime
///   shader filters are not supported, this widget becomes a no-op pass-through.
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

// DTO for touch points in logical pixels (will be scaled by DPR before upload)
@immutable
class TouchPoint {
  const TouchPoint(
    this.position, {
    this.radiusPx = 60,
    this.fadePx = 40,
    this.glowStrength = 1.0, // 0..1 Multiplier pro Touch
  });

  final Offset position; // logical pixels
  final double radiusPx; // logical px
  final double fadePx; // logical px
  final double glowStrength; // 0..1
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
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

  final FragmentShader shader; // Main glass shader (includes V-pass)
  final FragmentShader blurH; // Horizontal blur shader (H-pass)

  final LiquidGlassSettings settings;
  final bool debugRenderRefractionMap;
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
  // 34..35   : uRimParams (vec2)
  // 36..131  : uShapeData (float[MAX_SHAPES*6])
  // 132..135 : uBlurHeader (vec4) => dir.x, dir.y, sample_count, tile_mode
  // 136..335 : u_samples[0..49] (vec4 per sample → 50 * 4 = 200 floats)
  // 336      : uTouchCount_f (float)
  // 337..368 : uTouches[8] (8 * vec4)
  // 369..376 : uTouchOwners[8] (8 * float)
  // 377..380 : uGlowParams (vec4)
  // 381..384 : uGlowColor  (vec4)
  // 385..388 : uGlowOverrides (vec4)
  // 389..392 : uGlowFlags (vec4)
  // 393..396 : uGlowGlass (vec4)
  // 397      : uGlobalBlurSigma (float)
  // 398..405 : uTouchGlowStrengths[8] (8 * float)
  // 406      : uBgScale (float)
  // 407..408 : uNormalParams (vec2) -> plateauWidth, softness
  static const int _idxGlassColor = 2;
  static const int _idxOpticalProps = 6;
  static const int _idxLightConfig = 10;
  static const int _idxColorAdjust = 14; // x: lightness, y: numShapes
  static const int _idxLightDir = 16;
  static const int _idxTransform = 18;
  static const int _idxRimParams = 34;

  static const int _shapeDataBaseFloat = 36; // first float of uShapeData
  static const int _blurBaseFloat = 132; // uBlurHeader.x (u_dir_x)
  static const int _blurSamplesFloat = 136; // u_samples[0].x

  // Touch/Glow indices (match liquid_glass.frag layout ordering)
  static const int _idxTouchCount = 336;
  static const int _idxTouches = 337; // 8 * vec4 → 32 floats
  static const int _idxTouchOwners = 369;
  static const int _idxGlowParams = 377; // vec4
  static const int _idxGlowColor = 381; // vec4
  static const int _idxGlowOverrides = 385; // vec4
  static const int _idxGlowFlags = 389; // vec4
  static const int _idxGlowGlass = 393; // vec4
  static const int _idxGlobalBlurSigma = 397; // float
  static const int _idxTouchGlowStrengths = 398; // floats[8]

  // Hintergrund-Skalierung (nur im Main-Pass genutzt)
  static const int _idxBgScale = 406; // float

  // Parameter für Normalen/Abschrägung (vec2)
  static const int _idxNormalParams = 407; // float

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

  // --- Setters ---
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
  // ------------------------------------

  // Cached kernels and state to minimize uniform uploads.
  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  bool _hInvariantsInitialized = false;

  // UPDATED: Nur noch ein Handle für den kombinierten BackdropFilter.
  final LayerHandle<BackdropFilterLayer> _backdropHandle =
      LayerHandle<BackdropFilterLayer>();

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

  /// Set invariants for the horizontal blur shader. Only done once per shader.
  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    // uBlurHeader: x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
    _blurH
      ..setFloat(_blurBaseFloat + 0, 1.0) // dir.x (H-pass)
      ..setFloat(_blurBaseFloat + 1, 0.0) // dir.y
      ..setFloat(_blurBaseFloat + 3, 0.0); // tile_mode = clamp
    _hInvariantsInitialized = true;
  }

  /// Collects all [RawShape]s participating in this layer + lokale Touches je Shape.
  List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> collectShapes() {
    final result = <(RenderLiquidGlass, RawShape, List<TouchPoint>)>[];
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
          ro.localTouches, // ← lokale Touches des Shapes (implizit)
        ));
      }
    }
    return result;
  }

  /// Extracts a uniform scale factor from the given transform matrix.
  double _getScaleFromTransform(Matrix4 transform) {
    final m = transform.storage;
    // Fast-path: no rotation/skew.
    if (m[1] == 0 && m[4] == 0) {
      final sx = m[0].abs();
      final sy = m[5].abs();
      return math.sqrt(sx * sy);
    }
    // General case.
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final scaleXSq = a * a + b * b;
    final scaleYSq = c * c + d * d;
    return math.sqrt(math.sqrt(scaleXSq * scaleYSq));
  }

  // Impeller constraints and numeric helpers for kernel synthesis.
  static const int _impellerMaxKernel = 50;
  static const double _maxSigma = 500.0;
  static const double _sqrt3 = 1.7320508075688772;

  double _scaleSigma(double s) {
    final ss = s.clamp(0.0, _maxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    return ss * (c + b * ss + a * ss * ss);
  }

  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _sqrt3 : 0.0;
  }

  List<_RawS> _genRaw(double blurSigma, int radius, {int step = 1}) {
    final out = <_RawS>[];
    int count = ((2 * radius) ~/ step) + 1, xOff = 0;

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

  List<_PackedS> _computeImpellerKernel(double sigmaPx) {
    final scaled = _scaleSigma(sigmaPx);
    final r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedS>[_PackedS(0.0, 1.0)];
    return _lerpHack(_genRaw(scaled, r));
  }

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

  bool _shapesChanged(
      List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes) {
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

  /// Interne Struktur: Touch + Owner-Index.
  List<_OwnedTouch> _combineTouches(
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
  ) {
    final combined = <_OwnedTouch>[];
    for (var i = 0; i < shapes.length; i++) {
      final local = shapes[i].$3;
      if (local.isEmpty) continue;
      for (final lt in local) {
        combined.add(_OwnedTouch(
          position: lt.position,
          radiusPx: lt.radiusPx,
          fadePx: lt.fadePx,
          glowStrength: lt.glowStrength,
          ownerIndex: i, // dieser Touch gehört Shape i
        ));
      }
    }
    return combined;
  }

  /// Uploads all uniforms required for the current frame if settings, shapes,
  /// or kernel configuration have changed.
  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
    int nKernel,
    List<_PackedS> kernel,
    List<_OwnedTouch> ownedTouches,
    Rect bounds, // ← NEU
    Offset offset, // ← NEU
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

    // --- Transform für Screen → SDF (global) ---
    final double dpr = _devicePixelRatio;
    final double theoreticalGlobalLeft = offset.dx + bounds.left;
    final double theoreticalGlobalTop = offset.dy + bounds.top;
    final double actualGlobalLeft = math.max(0.0, theoreticalGlobalLeft);
    final double actualGlobalTop = math.max(0.0, theoreticalGlobalTop);
    final double tx = actualGlobalLeft * dpr;
    final double ty = actualGlobalTop * dpr;
    final Matrix4 transform = Matrix4.translationValues(tx, ty, 0);

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
        ..setFloat(_idxRimParams + 1, _settings.rimSharpness)
        // Skalierung des Hintergrunds im Shape
        ..setFloat(_idxBgScale, _settings.backgroundScale)
        // Normalen-Parameter
        ..setFloat(_idxNormalParams + 0, _settings.normalPlateauWidth)
        ..setFloat(_idxNormalParams + 1, _settings.normalSoftness);

      // uTransform (Screen → SDF): Translation in Device-Pixeln
      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, transform.storage[i]);
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

      // ── Spiegel die relevanten Uniforms in den H-Pass ────────────────────
      _blurH
        ..setFloat(_idxOpticalProps + 0, _settings.refractiveIndex)
        ..setFloat(_idxOpticalProps + 1, _settings.chromaticAberration)
        ..setFloat(_idxOpticalProps + 2, thickness)
        ..setFloat(_idxOpticalProps + 3, _settings.blend * _devicePixelRatio)
        // WICHTIG: uColorAdjust.x = lightness, uColorAdjust.y = numShapes
        ..setFloat(_idxColorAdjust + 0, _settings.lightness)
        ..setFloat(_idxColorAdjust + 1, shapeCount.toDouble());

      for (int i = 0; i < 16; i++) {
        _blurH.setFloat(_idxTransform + i, transform.storage[i]);
      }

      for (var i = 0; i < shapeCount; i++) {
        final shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
        final base = _shapeDataBaseFloat + (i * 6);
        _blurH
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
      // H-Pass: nur die Shape-Anzahl (uColorAdjust.y) updaten.
      _blurH.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());

      // Transform kann sich durch Offset/Bounds trotzdem ändern → nachziehen.
      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, transform.storage[i]);
        _blurH.setFloat(_idxTransform + i, transform.storage[i]);
      }
    }

    // Horizontal pass (separate shader).
    _blurH.setFloat(_blurBaseFloat + 2, nKernel.toDouble()); // sample_count
    if (nKernel != _lastKernelCountH) {
      int base = _blurSamplesFloat;
      for (int i = 0; i < nKernel; i++) {
        final s = kernel[i];
        _blurH
          ..setFloat(base + 0, s.tPx)
          ..setFloat(base + 1, 0.0)
          ..setFloat(base + 2, s.w)
          ..setFloat(base + 3, 0.0);
        base += 4;
      }
      _lastKernelCountH = nKernel;
    }

    // Vertical pass (performed in the glass shader).
    _shader
      ..setFloat(_blurBaseFloat + 0, 0.0) // u_dir_x
      ..setFloat(_blurBaseFloat + 1, 1.0) // u_dir_y
      ..setFloat(_blurBaseFloat + 2, nKernel.toDouble())
      ..setFloat(_blurBaseFloat + 3, 0.0); // clamp

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

    // ───────────────────── Touches & Glow ────────────────────
    final int nTouches = ownedTouches.length.clamp(0, 8);
    _shader.setFloat(_idxTouchCount, nTouches.toDouble());
    for (int i = 0; i < 8; i++) {
      final base = _idxTouches + i * 4;
      if (i < nTouches) {
        final tp = ownedTouches[i];
        _shader
          ..setFloat(base + 0, tp.position.dx * _devicePixelRatio)
          ..setFloat(base + 1, tp.position.dy * _devicePixelRatio)
          ..setFloat(base + 2, tp.radiusPx * _devicePixelRatio)
          ..setFloat(base + 3, tp.fadePx * _devicePixelRatio);
      } else {
        _shader
          ..setFloat(base + 0, -99999.0)
          ..setFloat(base + 1, -99999.0)
          ..setFloat(base + 2, 0.0)
          ..setFloat(base + 3, 0.0);
      }
    }

    for (int i = 0; i < 8; i++) {
      final double owner =
          (i < nTouches) ? ownedTouches[i].ownerIndex.toDouble() : -1.0;
      _shader.setFloat(_idxTouchOwners + i, owner);
    }

    for (int i = 0; i < 8; i++) {
      final double s =
          (i < nTouches) ? ownedTouches[i].glowStrength.clamp(0.0, 1.0) : 0.0;
      _shader.setFloat(_idxTouchGlowStrengths + i, s);
    }

    final glow = _settings.glow;
    final bool glowOn = glow.enabled;

    _shader
      ..setFloat(_idxGlowParams + 0, glowOn ? glow.strength : 0.0)
      ..setFloat(_idxGlowParams + 1, glow.power)
      ..setFloat(_idxGlowParams + 2, glow.tintMode.toDouble())
      ..setFloat(_idxGlowParams + 3, glow.insideOnly ? 1.0 : 0.0);

    _shader
      ..setFloat(_idxGlowColor + 0, glow.color.red / 255.0)
      ..setFloat(_idxGlowColor + 1, glow.color.green / 255.0)
      ..setFloat(_idxGlowColor + 2, glow.color.blue / 255.0)
      ..setFloat(_idxGlowColor + 3, glow.color.alpha / 255.0);

    final double mix = glowOn ? glow.mix : 0.0;
    final double targetLightness = glow.lightness ?? _settings.lightness;
    final double targetSaturation = glow.saturation ?? _settings.saturation;
    final double targetBlurSigmaPx =
        (glow.blur ?? _settings.blur) * _devicePixelRatio;
    _shader
      ..setFloat(_idxGlowOverrides + 0, targetLightness)
      ..setFloat(_idxGlowOverrides + 1, targetSaturation)
      ..setFloat(_idxGlowOverrides + 2, targetBlurSigmaPx)
      ..setFloat(_idxGlowOverrides + 3, mix);

    double f(bool cond) => (glowOn && cond) ? 1.0 : 0.0;
    _shader
      ..setFloat(_idxGlowFlags + 0, f(glow.lightness != null))
      ..setFloat(_idxGlowFlags + 1, f(glow.saturation != null))
      ..setFloat(_idxGlowFlags + 2, f(glow.blur != null))
      ..setFloat(_idxGlowFlags + 3, f(glow.glassColor != null));

    final Color gg = glow.glassColor ?? const Color(0x00000000);
    _shader
      ..setFloat(_idxGlowGlass + 0, gg.red / 255.0)
      ..setFloat(_idxGlowGlass + 1, gg.green / 255.0)
      ..setFloat(_idxGlowGlass + 2, gg.blue / 255.0)
      ..setFloat(_idxGlowGlass + 3, gg.alpha / 255.0);

    _shader.setFloat(
      _idxGlobalBlurSigma,
      _settings.blur * _devicePixelRatio,
    );
  }

  /// Snap a rectangle to device pixels to avoid half-pixel sampling seams.
  Rect _snapRectToDeviceFull(Rect r) {
    final d = _devicePixelRatio;
    double f(double v) => (v * d).floorToDouble() / d;
    double c(double v) => (v * d).ceilToDouble() / d;
    return Rect.fromLTRB(f(r.left), f(r.top), c(r.right), c(r.bottom));
  }

  Path _computeUnionClipPath(
      List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes) {
    final path = Path();
    for (final (ro, raw, _) in shapes) {
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

  Rect _computeUnionClipRect(
      List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes) {
    Rect? union;
    for (final (ro, _, __) in shapes) {
      final transformToThis = ro.getTransformTo(this);
      final rectLocal =
          MatrixUtils.transformRect(transformToThis, Offset.zero & ro.size);
      union = (union == null) ? rectLocal : union!.expandToInclude(rectLocal);
    }
    final double margin = (_settings.blur * 3.0) + _settings.thickness + 12.0;
    return (union ?? Rect.zero).inflate(margin);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shapes = collectShapes();

    // Early exit if the effect is disabled or there is nothing to render.
    if (_settings.thickness <= 0 || shapes.isEmpty) {
      _backdropHandle.layer = null; // Clear single handle
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    final shapeCount = math.min(_maxShapesPerLayer, shapes.length);

    // Kernel generation for the separable blur.
    final double sigmaPx = _settings.blur * _devicePixelRatio;
    final List<_PackedS> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel = math.min(_impellerMaxKernel, kernel.length);

    final ownedTouches = _combineTouches(shapes);

    // Bounds werden vor Uniform-Upload berechnet und übergeben.
    final Rect bounds = _snapRectToDeviceFull(_computeUnionClipRect(shapes));

    _uploadUniformsIfNeeded(
      shapeCount,
      shapes,
      nKernel,
      kernel,
      ownedTouches,
      bounds,
      offset,
    );

    // ABOVE the glass first.
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // UPDATED: Use ImageFilter.compose with a single LayerHandle
    // "inner" (blurH) wird zuerst ausgeführt, dann "outer" (shader/glass) auf das Ergebnis.
    // Das garantiert, dass der horizontale Pass nicht verschluckt wird.
    ImageFilter? composedFilter;

    if (sigmaPx > 0.01 && nKernel > 0) {
      composedFilter = ImageFilter.compose(
        outer: ImageFilter.shader(_shader), // V-Pass + Effects
        inner: ImageFilter.shader(_blurH), // H-Pass (Blur only)
      );
    } else {
      // Kein Blur nötig, nur der Glass-Shader
      composedFilter = ImageFilter.shader(_shader);
    }

    final BackdropFilterLayer backdropLayer =
        _backdropHandle.layer ?? BackdropFilterLayer();
    backdropLayer.filter = composedFilter;

    context.pushClipRect(
      true,
      offset,
      bounds,
      (ctxRect, offRect) {
        ctxRect.pushLayer(backdropLayer, (childCtx, childOff) {
          // Ein transparenter Rect reicht, um den Filter anzuwenden.
          childCtx.canvas.drawRect(
            bounds.shift(-childOff),
            Paint()..color = const Color(0x00000000),
          );
        }, offRect);
      },
      clipBehavior: Clip.hardEdge,
    );
    _backdropHandle.layer = backdropLayer;

    // UNDER the glass.
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);

    super.paint(context, offset);
  }

  @override
  void dispose() {
    _glassLink
      ..removeListener(_onGlassLinkChanged)
      ..dispose();
    _backdropHandle.layer = null; // Dispose single handle
    super.dispose();
  }

  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes, {
    required bool glassContainsChild,
  }) {
    for (final (ro, _, __) in shapes) {
      if (ro.glassContainsChild == glassContainsChild) {
        final Matrix4 transform = ro.getTransformTo(this);
        context.pushTransform(true, offset, transform, ro.paintFromLayer);
      }
    }
  }
}

class _OwnedTouch {
  _OwnedTouch({
    required this.position,
    required this.radiusPx,
    required this.fadePx,
    required this.glowStrength,
    required this.ownerIndex,
  });

  final Offset position;
  final double radiusPx;
  final double fadePx;
  final double glowStrength;
  final int ownerIndex; // 0..N-1
}
