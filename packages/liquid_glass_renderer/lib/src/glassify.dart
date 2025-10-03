// ignore_for_file: avoid_setters_without_getters

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';
import 'package:meta/meta.dart';

/// ────────────────────────── Kernel-Helfer (top-level!) ─────────────────────
class _RawS {
  _RawS(this.x, this.w);
  double x; // diskreter Pixel-Offset (vor Lerp)
  double w; // Gewicht (vor Normierung)
}

class _PackedS {
  const _PackedS(this.tPx, this.w);
  final double tPx; // Offset entlang Achse in PIXELN
  final double w; // Gewicht (normalisiert)
}

/// Glas-Effekt für beliebiges Child (Arbitrary Matte) – mit aggressivem Caching.
@experimental
class Glassify extends StatelessWidget {
  const Glassify({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    super.key,
  });

  final Widget child;
  final LiquidGlassSettings settings;

  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      assert(
        ImageFilter.isShaderFilterSupported,
        'liquid_glass_renderer benötigt Impeller.',
      );
      return child;
    }

    // Beide Shader: V + H
    return ShaderBuilder(
      assetKey: arbitraryShader, // liquid_glass_arbitrary.frag
      (context, glassShader, _) => ShaderBuilder(
        assetKey: gaussian1dBlurShader, // gaussian_1d_blur.frag
        (context, blurH, __) => _RawGlassify(
          shaderV: glassShader,
          shaderH: blurH,
          settings: settings,
          child: child,
        ),
        child: child,
      ),
      child: child,
    );
  }
}

class _RawGlassify extends SingleChildRenderObjectWidget {
  const _RawGlassify({
    required this.shaderV,
    required this.shaderH,
    required this.settings,
    required Widget super.child,
  });

  final FragmentShader shaderV; // liquid_glass_arbitrary.frag
  final FragmentShader shaderH; // gaussian_1d_blur.frag
  final LiquidGlassSettings settings;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderGlassify(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shaderV: shaderV,
      shaderH: shaderH,
      settings: settings,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderGlassify renderObject,
  ) {
    renderObject
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..settings = settings
      ..setShaders(shaderV, shaderH);
  }
}

@internal
class RenderGlassify extends RenderProxyBox {
  RenderGlassify({
    required double devicePixelRatio,
    required FragmentShader shaderV,
    required FragmentShader shaderH,
    required LiquidGlassSettings settings,
  })  : _devicePixelRatio = devicePixelRatio,
        _shaderV = shaderV,
        _shaderH = shaderH,
        _settings = settings;

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  FragmentShader _shaderV; // liquid_glass_arbitrary.frag (V+Glass)
  FragmentShader _shaderH; // gaussian_1d_blur.frag      (H)

  void setShaders(FragmentShader v, FragmentShader h) {
    if (!identical(_shaderV, v)) {
      _shaderV = v;
      markNeedsPaint();
    }
    if (!identical(_shaderH, h)) {
      _shaderH = h;
      markNeedsPaint();
    }
  }

  LiquidGlassSettings _settings;
  set settings(LiquidGlassSettings value) {
    if (identical(_settings, value)) return;
    _settings = value;
    markNeedsPaint();
  }

  @override
  // ignore: library_private_types_in_public_api
  _GlassifyShaderLayer? get layer => super.layer as _GlassifyShaderLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Globaler Offset (Backdrop arbeitet in Screen-Koords)
    var globalOffset = offset;
    try {
      final transform = getTransformTo(null);
      final globalRect =
          MatrixUtils.transformRect(transform, Offset.zero & size);
      globalOffset = globalRect.topLeft;
    } catch (_) {}

    layer ??= _GlassifyShaderLayer(
      offset: offset,
      globalOffset: globalOffset,
      shaderV: _shaderV,
      shaderH: _shaderH,
      settings: _settings,
      devicePixelRatio: _devicePixelRatio,
      layerSize: size,
    );

    layer!
      ..offset = offset
      ..globalOffset = globalOffset
      ..shaderV = _shaderV
      ..shaderH = _shaderH
      ..settings = _settings
      ..devicePixelRatio = _devicePixelRatio
      ..layerSize = size;

    context.pushLayer(
      layer!,
      (context, offset) => super.paint(context, offset),
      offset,
    );
  }
}

/// Layer kapselt 2-Pass (H dann V) und cached aggressive Offscreen-Assets.
class _GlassifyShaderLayer extends OffsetLayer {
  _GlassifyShaderLayer({
    required FragmentShader shaderV,
    required FragmentShader shaderH,
    required LiquidGlassSettings settings,
    required double devicePixelRatio,
    required Size layerSize,
    required super.offset,
    required Offset globalOffset,
  })  : _shaderV = shaderV,
        _shaderH = shaderH,
        _settings = settings,
        _devicePixelRatio = devicePixelRatio,
        _layerSize = layerSize,
        _globalOffset = globalOffset;

  // ── State
  FragmentShader _shaderV;
  FragmentShader get shaderV => _shaderV;
  set shaderV(FragmentShader value) {
    if (_shaderV == value) return;
    _shaderV = value;
    markNeedsAddToScene();
  }

  FragmentShader _shaderH;
  FragmentShader get shaderH => _shaderH;
  set shaderH(FragmentShader value) {
    if (_shaderH == value) return;
    _shaderH = value;
    markNeedsAddToScene();
  }

  LiquidGlassSettings _settings;
  LiquidGlassSettings get settings => _settings;
  set settings(LiquidGlassSettings value) {
    if (_settings == value) return;
    _settings = value;
    _dirtyForSettings(); // invalidate caches if needed
    markNeedsAddToScene();
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    _dirtyAll(); // DPR change invalidates all images
    markNeedsAddToScene();
  }

  Size _layerSize;
  Size get layerSize => _layerSize;
  set layerSize(Size value) {
    if (_layerSize == value) return;
    _layerSize = value;
    _dirtyAll(); // size change → recapture all
    markNeedsAddToScene();
  }

  Offset _globalOffset;
  Offset get globalOffset => _globalOffset;
  set globalOffset(Offset value) {
    if (_globalOffset == value) return;
    _globalOffset = value;
    // globalOffset beeinflusst Sampling → V-Pass uniforms,
    // aber Masken müssen nicht neu gerendert werden:
    markNeedsAddToScene();
  }

  // ── Cached resources
  ui.Image? _childImage; // scharfe Matte
  ui.Image? _childBlurredImage; // geblurrte Matte (für Normal-Reko)
  ui.Image? _hMaskDilated; // dilatierte Matte für H-Pass ShaderMask

  double? _blurredMatteSigmaCache; // für _childBlurredImage
  double? _hMaskInflateLogicalCache; // für _hMaskDilated

  ui.BackdropFilterEngineLayer? _hEngineLayer;
  ui.BackdropFilterEngineLayer? _vEngineLayer;
  ui.ImageFilterEngineLayer? _maskFilterLayer;

  // Coverage picture cache
  ui.Picture? _coveragePic;
  Size? _coveragePicSize;

  // Kernel cache (bucketed)
  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucket = -1;
  static const int _sigmaBucketScale = 10; // 0.1 px Buckets

  // ── Impeller/Skia Kernel-Params
  static const int _kMaxKernel = 50;
  static const double _kMaxSigma = 500.0;
  static const double _kSqrt3 = 1.7320508075688772;

  // ── Dirty helpers
  void _dirtyAll() {
    _disposeImage(ref: _childImage, setNull: () => _childImage = null);
    _disposeImage(
        ref: _childBlurredImage, setNull: () => _childBlurredImage = null);
    _disposeImage(ref: _hMaskDilated, setNull: () => _hMaskDilated = null);
    _blurredMatteSigmaCache = null;
    _hMaskInflateLogicalCache = null;
    _coveragePic?.dispose();
    _coveragePic = null;
    _coveragePicSize = null;
  }

  void _dirtyForSettings() {
    // thickness beeinflusst blurredMatte (Normal-Reko)
    final newMatteSigma = _matteSigma();
    if (_blurredMatteSigmaCache != newMatteSigma) {
      _disposeImage(
          ref: _childBlurredImage, setNull: () => _childBlurredImage = null);
      _blurredMatteSigmaCache = null;
    }
    // blur beeinflusst H-Pass-Maske (Inflation)
    _hMaskInflateLogicalCache = null; // force re-eval
  }

  void _disposeImage({required ui.Image? ref, required VoidCallback setNull}) {
    try {
      ref?.dispose();
    } catch (_) {}
    setNull();
  }

  // ── Kernel math
  double _scaleSigma(double s) {
    final clamped = s.clamp(0.0, _kMaxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    return clamped * (c + b * clamped + a * clamped * clamped);
  }

  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _kSqrt3 : 0.0;
  }

  List<_RawS> _genRaw(double blurSigma, int radius, {int step = 1}) {
    final out = <_RawS>[];
    int count = ((2 * radius) ~/ step) + 1;
    int xOff = 0;
    if (radius >= 16) {
      count -= 2;
      xOff = 1;
    }
    double sum = 0;
    for (int i = 0; i < count; i++) {
      final x = xOff + (i * step) - radius;
      final c = (math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma));
      out.add(_RawS(x.toDouble(), c));
      sum += c;
    }
    if (sum > 0) for (final s in out) s.w /= sum;
    return out;
  }

  List<_PackedS> _lerpHack(List<_RawS> raw) {
    final n = raw.length;
    final outCount = ((n - 1) ~/ 2) + 1;
    final middle = outCount ~/ 2;
    final out = <_PackedS>[];
    int j = 0;
    for (int i = 0; i < outCount; i++) {
      if (i == middle) {
        final s = raw[j++];
        out.add(_PackedS(s.x, s.w));
      } else {
        final a = raw[j], b = raw[j + 1];
        final w = a.w + b.w;
        final t = (a.x * a.w + b.x * b.w) / w;
        out.add(_PackedS(t, w));
        j += 2;
      }
      if (out.length >= _kMaxKernel) break;
    }
    return out;
  }

  List<_PackedS> _computeKernel(double sigmaPx) {
    final scaled = _scaleSigma(sigmaPx);
    final r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedS>[const _PackedS(0.0, 1.0)];
    return _lerpHack(_genRaw(scaled, r));
  }

  List<_PackedS> _getCachedKernel(double sigmaPx) {
    final bucket = (sigmaPx * _sigmaBucketScale).round();
    if (_cachedKernel != null && bucket == _cachedSigmaBucket) {
      return _cachedKernel!;
    }
    final k = _computeKernel(sigmaPx);
    _cachedKernel = k;
    _cachedSigmaBucket = bucket;
    return k;
  }

  // ── Coverage picture (1px alpha) – cached per size
  ui.Picture _coveragePicture(Size size) {
    if (_coveragePic != null && _coveragePicSize == size) return _coveragePic!;
    _coveragePic?.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = const Color(0x01000000);
    canvas.drawRect(Offset.zero & size, paint);
    _coveragePic = recorder.endRecording();
    _coveragePicSize = size;
    return _coveragePic!;
  }

  // ── Helpers
  double _matteSigma() => settings.thickness / 6.0;

  void _ensureChildImages() {
    final bounds = offset & layerSize;
    final imgW = (devicePixelRatio * bounds.width).round().clamp(1, 16384);
    final imgH = (devicePixelRatio * bounds.height).round().clamp(1, 16384);

    // Scharfe Matte
    if (_childImage == null ||
        _childImage!.width != imgW ||
        _childImage!.height != imgH) {
      _disposeImage(ref: _childImage, setNull: () => _childImage = null);
      _childImage = _buildMaskImage();
    }

    // Geblurrte Matte (für Normal-Reko)
    final blurSigma = _matteSigma();
    if (_childBlurredImage == null ||
        _blurredMatteSigmaCache != blurSigma ||
        _childBlurredImage!.width != imgW ||
        _childBlurredImage!.height != imgH) {
      _disposeImage(
          ref: _childBlurredImage, setNull: () => _childBlurredImage = null);
      _childBlurredImage = _buildMaskImage(blurSigma);
      _blurredMatteSigmaCache = blurSigma;
    }
  }

  void _ensureHMaskDilated(double inflateLogicalPx) {
    final bounds = offset & layerSize;
    final imgW = (devicePixelRatio * bounds.width).round().clamp(1, 16384);
    final imgH = (devicePixelRatio * bounds.height).round().clamp(1, 16384);

    if (_hMaskDilated == null ||
        _hMaskInflateLogicalCache != inflateLogicalPx ||
        _hMaskDilated!.width != imgW ||
        _hMaskDilated!.height != imgH) {
      _disposeImage(ref: _hMaskDilated, setNull: () => _hMaskDilated = null);
      _hMaskDilated = _buildMaskImageDilated(inflateLogicalPx);
      _hMaskInflateLogicalCache = inflateLogicalPx;
    }
  }

  // ── Scene capture utilities
  ui.Image _buildMaskImage([double? blurSigma]) {
    final builder = ui.SceneBuilder();
    builder.pushTransform(
      Matrix4.diagonal3Values(devicePixelRatio, devicePixelRatio, 1).storage,
    );
    _addMaskToScene(builder, blurSigma);
    builder.pop();

    final bounds = offset & layerSize;
    return builder.build().toImageSync(
          (devicePixelRatio * bounds.width).round().clamp(1, 16384),
          (devicePixelRatio * bounds.height).round().clamp(1, 16384),
        );
  }

  ui.Image _buildMaskImageDilated(double inflateLogicalPx) {
    final builder = ui.SceneBuilder();
    builder.pushTransform(
      Matrix4.diagonal3Values(devicePixelRatio, devicePixelRatio, 1).storage,
    );

    builder.pushOffset(-offset.dx, -offset.dy);
    final double r = (inflateLogicalPx * devicePixelRatio).clamp(0.0, 4096.0);
    builder.pushImageFilter(ImageFilter.dilate(radiusX: r, radiusY: r));

    addChildrenToScene(builder);

    builder.pop(); // image filter
    builder.pop(); // offset
    builder.pop(); // transform

    final bounds = offset & layerSize;
    return builder.build().toImageSync(
          (devicePixelRatio * bounds.width).round().clamp(1, 16384),
          (devicePixelRatio * bounds.height).round().clamp(1, 16384),
        );
  }

  void _addMaskToScene(ui.SceneBuilder builder, [double? blurSigma]) {
    builder.pushOffset(-offset.dx, -offset.dy);
    if (blurSigma != null && blurSigma > 0) {
      _maskFilterLayer = builder.pushImageFilter(
        ImageFilter.compose(
          outer: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          inner: ImageFilter.erode(radiusX: blurSigma, radiusY: blurSigma),
        ),
        oldLayer: _maskFilterLayer,
      );
    }
    addChildrenToScene(builder);
    if (blurSigma != null && blurSigma > 0) {
      builder.pop();
    }
    builder.pop();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    // Offset-Layer
    final offsetLayer = builder.pushOffset(
      offset.dx,
      offset.dy,
      oldLayer: engineLayer as ui.OffsetEngineLayer?,
    );
    engineLayer = offsetLayer;
    {
      // 1) Caches aktualisieren (nur wenn nötig)
      _ensureChildImages();

      // 2) Blur-Setup
      final Size screenLogical = RendererBinding.instance.renderView.size;
      final Size screenDevice = Size(
        screenLogical.width * devicePixelRatio,
        screenLogical.height * devicePixelRatio,
      );
      final double sigmaPx = settings.blur * devicePixelRatio;

      final kernel = _getCachedKernel(sigmaPx);
      final int n = kernel.length.clamp(1, _kMaxKernel);

      // Clip-Rechtecke (logische px)
      final Rect vClip = Offset.zero & layerSize;
      final double inflateLogical = (sigmaPx * 3.0 + 2.0) / devicePixelRatio;

      // ───────── PASS 1: H (nur wenn sigma>0) ─────────
      if (sigmaPx > 0.0) {
        _shaderH
          ..setFloat(0, screenDevice.width) // u_size.x
          ..setFloat(1, screenDevice.height) // u_size.y
          ..setFloat(2, 1.0) // u_dir.x (H)
          ..setFloat(3, 0.0) // u_dir.y
          ..setFloat(4, n.toDouble()) // u_sample_count
          ..setFloat(5, 0.0); // u_tile_mode = clamp

        int baseH = 6;
        for (int i = 0; i < n; i++) {
          final s = kernel[i];
          _shaderH
            ..setFloat(baseH + i * 4 + 0, s.tPx)
            ..setFloat(baseH + i * 4 + 1, 0.0)
            ..setFloat(baseH + i * 4 + 2, s.w)
            ..setFloat(baseH + i * 4 + 3, 0.0);
        }

        _ensureHMaskDilated(inflateLogical);

        final ui.Shader maskShader = ImageShader(
          _hMaskDilated!,
          TileMode.clamp,
          TileMode.clamp,
          Matrix4.identity().storage,
          filterQuality: FilterQuality.low,
        );

        // Maskiere den H-Pass: Blur findet NUR innerhalb dilatierter Matte statt.
        builder.pushShaderMask(maskShader, vClip, BlendMode.dstIn);

        _hEngineLayer = builder.pushBackdropFilter(
          ImageFilter.shader(_shaderH),
          oldLayer: _hEngineLayer,
        );

        builder.addPicture(Offset.zero, _coveragePicture(layerSize));

        builder.pop(); // H BackdropFilter
        builder.pop(); // ShaderMask
      } else {
        _hEngineLayer = null;
      }

      // ───────── PASS 2: V (Glass + Refraction) ─────────
      _setupVUniforms(screenDevice, kernel); // CHANGED: neue Indizes

      builder.pushClipRect(vClip);
      _vEngineLayer = builder.pushBackdropFilter(
        ImageFilter.shader(_shaderV),
        oldLayer: _vEngineLayer,
      );

      builder.addPicture(Offset.zero, _coveragePicture(layerSize));

      builder.pop(); // V Backdrop
      builder.pop(); // Clip
    }
    builder.pop(); // Offset
  }

  void _setupVUniforms(Size screenDevice, List<_PackedS> kernel) {
    final fgW = layerSize.width * devicePixelRatio;
    final fgH = layerSize.height * devicePixelRatio;

    // Sampler: 0 = uBackgroundTexture (vom Engine), 1/2 setzen wir selbst
    _shaderV
      ..setImageSampler(1, _childImage!) // uForegroundTexture
      ..setImageSampler(2, _childBlurredImage!); // uForegroundBlurredTexture

    // ── Header (2..17) identisch zu liquid_glass.frag
    _shaderV
      ..setFloat(2, settings.glassColor.r)
      ..setFloat(3, settings.glassColor.g)
      ..setFloat(4, settings.glassColor.b)
      ..setFloat(5, settings.glassColor.a)
      ..setFloat(6, settings.refractiveIndex)
      ..setFloat(7, settings.chromaticAberration)
      ..setFloat(8, settings.thickness)
      ..setFloat(9, 0.0) // blend wird in Arbitrary nicht genutzt
      ..setFloat(10, settings.lightAngle)
      ..setFloat(11, settings.lightIntensity)
      ..setFloat(12, settings.ambientStrength)
      ..setFloat(13, settings.saturation)
      ..setFloat(14, settings.lightness)
      ..setFloat(15, 0.0) // numShapes ungenutzt
      ..setFloat(16, math.cos(settings.lightAngle))
      ..setFloat(17, math.sin(settings.lightAngle));

    // ── uTransform (18..33) – hier Identity (CHANGED)
    const List<double> _identityMat4 = <double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ];
    for (int i = 0; i < 16; i++) {
      _shaderV.setFloat(18 + i, _identityMat4[i]); // 18..33
    }

    // ── Matte-Uniforms (CHANGED: 34..37)
    _shaderV
      ..setFloat(34, fgW) // uForegroundSize.x
      ..setFloat(35, fgH) // uForegroundSize.y
      ..setFloat(
          36, globalOffset.dx * devicePixelRatio) // uOffset.x (device px)
      ..setFloat(37, globalOffset.dy * devicePixelRatio); // uOffset.y

    // ── Impeller-Blur (CHANGED: Header 38..41, Samples ab 42)
    final n = kernel.length.clamp(1, _kMaxKernel);
    _shaderV
      ..setFloat(38, 0.0) // dir.x (V)
      ..setFloat(39, 1.0) // dir.y
      ..setFloat(40, n.toDouble()) // sample_count
      ..setFloat(41, 0.0); // tile_mode = clamp

    int base = 42; // u_samples[0]
    for (int i = 0; i < n; i++) {
      final s = kernel[i];
      _shaderV
        ..setFloat(base + i * 4 + 0, s.tPx)
        ..setFloat(base + i * 4 + 1, 0.0)
        ..setFloat(base + i * 4 + 2, s.w)
        ..setFloat(base + i * 4 + 3, 0.0);
    }
  }

  @override
  void dispose() {
    _disposeImage(ref: _childImage, setNull: () => _childImage = null);
    _disposeImage(
        ref: _childBlurredImage, setNull: () => _childBlurredImage = null);
    _disposeImage(ref: _hMaskDilated, setNull: () => _hMaskDilated = null);
    _maskFilterLayer?.dispose();
    _hEngineLayer?.dispose();
    _vEngineLayer?.dispose();
    _coveragePic?.dispose();
    _coveragePic = null;
    super.dispose();
  }
}
