// ignore_for_file: avoid_setters_without_getters

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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

/// Widget: glasiger Effekt für ein beliebiges Child (Arbitrary Matte)
@experimental
class Glassify extends StatefulWidget {
  const Glassify({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    super.key,
  });

  final Widget child;
  final LiquidGlassSettings settings;

  @override
  State<Glassify> createState() => _GlassifyState();
}

class _GlassifyState extends State<Glassify>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      assert(
        ImageFilter.isShaderFilterSupported,
        'liquid_glass_renderer benötigt Impeller.',
      );
      return widget.child;
    }

    // Wir brauchen BEIDE Shader: V-Pass (arbitrary) UND H-Pass (gaussian_1d)
    return ShaderBuilder(
      assetKey: arbitraryShader, // liquid_glass_arbitrary.frag
      (context, glassShader, child) => ShaderBuilder(
        assetKey: gaussian1dBlurShader, // gaussian_1d_blur.frag (H-Pass)
        (context, blurH, child) => _RawGlassify(
          shaderV: glassShader,
          shaderH: blurH,
          settings: widget.settings,
          debugRenderRefractionMap: false,
          vsync: this,
          child: child!,
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _RawGlassify extends SingleChildRenderObjectWidget {
  const _RawGlassify({
    required this.shaderV,
    required this.shaderH,
    required this.settings,
    required this.debugRenderRefractionMap,
    required this.vsync,
    required Widget super.child,
  });

  final FragmentShader shaderV; // liquid_glass_arbitrary.frag
  final FragmentShader shaderH; // gaussian_1d_blur.frag
  final LiquidGlassSettings settings;
  final bool debugRenderRefractionMap;
  final TickerProvider vsync;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderGlassify(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shaderV: shaderV,
      shaderH: shaderH,
      settings: settings,
      debugRenderRefractionMap: debugRenderRefractionMap,
      ticker: vsync,
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
      ..ticker = vsync
      ..debugRenderRefractionMap = debugRenderRefractionMap
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
    required TickerProvider ticker,
    bool debugRenderRefractionMap = false,
  })  : _devicePixelRatio = devicePixelRatio,
        _shaderV = shaderV,
        _shaderH = shaderH,
        _settings = settings,
        _tickerProvider = ticker,
        _debugRenderRefractionMap = debugRenderRefractionMap {
    _ticker = _tickerProvider.createTicker((_) => markNeedsPaint());
  }

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

  bool _debugRenderRefractionMap;
  set debugRenderRefractionMap(bool value) {
    if (_debugRenderRefractionMap == value) return;
    _debugRenderRefractionMap = value;
    markNeedsPaint();
  }

  TickerProvider _tickerProvider;
  set ticker(TickerProvider value) {
    if (identical(_tickerProvider, value)) return;
    _tickerProvider = value;
    markNeedsPaint();
  }

  Ticker? _ticker;

  @override
  // ignore: library_private_types_in_public_api
  _GlassifyShaderLayer? get layer => super.layer as _GlassifyShaderLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Globaler Offset ermitteln (Backdrop läuft in globalen Koords)
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

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
}

/// Custom-Layer, der den 2-Pass Backdrop (H dann V) kapselt
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

  FragmentShader _shaderV; // V-Pass (arbitrary)
  FragmentShader get shaderV => _shaderV;
  set shaderV(FragmentShader value) {
    if (_shaderV == value) return;
    _shaderV = value;
    markNeedsAddToScene();
  }

  FragmentShader _shaderH; // H-Pass
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
    markNeedsAddToScene();
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsAddToScene();
  }

  Size _layerSize;
  Size get layerSize => _layerSize;
  set layerSize(Size value) {
    if (_layerSize == value) return;
    _layerSize = value;
    markNeedsAddToScene();
  }

  Offset _globalOffset;
  Offset get globalOffset => _globalOffset;
  set globalOffset(Offset value) {
    if (_globalOffset == value) return;
    _globalOffset = value;
    markNeedsAddToScene();
  }

  ui.Image? childImage;
  ui.Image? childBlurredImage;

  ui.BackdropFilterEngineLayer? _hEngineLayer;
  ui.BackdropFilterEngineLayer? _vEngineLayer;
  ui.ImageFilterEngineLayer? _imageFilterLayer;

  // ── Impeller/Skia Kernel-Params
  static const int _kMaxKernel = 50;
  static const double _kMaxSigma = 500.0;
  static const double _kSqrt3 = 1.7320508075688772;

  double _scaleSigma(double sigma) {
    final s = sigma.clamp(0.0, _kMaxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    return s * (c + b * s + a * s * s);
  }

  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _kSqrt3 : 0.0;
  }

  List<_RawS> _genRaw(double blurSigma, int radius, {int step = 1}) {
    final out = <_RawS>[];
    int sampleCount = ((2 * radius) ~/ step) + 1;
    int xOffset = 0;
    if (radius >= 16) {
      sampleCount -= 2;
      xOffset = 1;
    }
    double tally = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final int x = xOffset + (i * step) - radius;
      final double coeff = (math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma));
      out.add(_RawS(x.toDouble(), coeff));
      tally += coeff;
    }
    if (tally > 0) {
      for (final s in out) {
        s.w /= tally;
      }
    }
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
      _captureChildLayer();
      _captureChildBlurredLayer();

      // Größen in DEVICE-Pixeln
      final screenLogical = RendererBinding.instance.renderView.size;
      final screenDevice = Size(
        screenLogical.width * devicePixelRatio,
        screenLogical.height * devicePixelRatio,
      );

      // σ in DEVICE-Pixeln
      final double sigmaPx = settings.blur * devicePixelRatio;

      // Kernel (V-Pass immer; bei sigma==0 → 1 Sample @ 0 mit w=1)
      final kernel = _computeKernel(sigmaPx);
      final int n = kernel.length.clamp(1, _kMaxKernel);

      bool hIsOpen = false;

      // ───────── PASS 1: H (gaussian_1d_blur.frag) — NUR wenn sigma>0 ─────────
      if (sigmaPx > 0.0) {
        _shaderH
          ..setFloat(0, screenDevice.width) // u_size.x
          ..setFloat(1, screenDevice.height) // u_size.y
          ..setFloat(2, 1.0) // u_dir.x (H)
          ..setFloat(3, 0.0) // u_dir.y
          ..setFloat(4, n.toDouble()) // u_sample_count
          ..setFloat(5, 0.0); // u_tile_mode (clamp)

        int baseH = 6;
        for (int i = 0; i < n; i++) {
          final s = kernel[i];
          _shaderH
            ..setFloat(baseH + i * 4 + 0, s.tPx)
            ..setFloat(baseH + i * 4 + 1, 0.0)
            ..setFloat(baseH + i * 4 + 2, s.w)
            ..setFloat(baseH + i * 4 + 3, 0.0);
        }

        _hEngineLayer = builder.pushBackdropFilter(
          ImageFilter.shader(_shaderH),
          oldLayer: _hEngineLayer,
        );
        hIsOpen = true;
      } else {
        _hEngineLayer = null;
      }

      // ───────── PASS 2: V (arbitrary + Refraction + Lighting) — IMMER ─────────
      _setupVUniforms(screenDevice, kernel);

      _vEngineLayer = builder.pushBackdropFilter(
        ImageFilter.shader(_shaderV),
        oldLayer: _vEngineLayer,
      );

      // Coverage EINMAL innen
      _addCoverageQuad(builder);

      // Pop V
      builder.pop();

      // Pop H (falls offen)
      if (hIsOpen) {
        builder.pop();
      }
    }
    // Pop Offset
    builder.pop();
  }

  void _setupVUniforms(Size screenDevice, List<_PackedS> kernel) {
    final fgW = layerSize.width * devicePixelRatio;
    final fgH = layerSize.height * devicePixelRatio;

    // Sampler binden: 0 = Backdrop (automatisch vom BackdropFilter),
    // 1 = uForegroundTexture, 2 = uForegroundBlurredTexture
    _shaderV
      ..setImageSampler(1, childImage!)
      ..setImageSampler(2, childBlurredImage!);

    // ── HEADER (identisch zu liquid_glass.frag) ───────────────────────────────
    // layout(location = 0) vec2 uSize;           // wird von Flutter gesetzt → NICHT setzen
    // layout(location = 1) vec4 uGlassColor;     // slots  2..5
    _shaderV
      ..setFloat(2, settings.glassColor.r)
      ..setFloat(3, settings.glassColor.g)
      ..setFloat(4, settings.glassColor.b)
      ..setFloat(5, settings.glassColor.a);

    // layout(location = 2) vec4 uOpticalProps;   // slots  6..9
    _shaderV
      ..setFloat(6, settings.refractiveIndex)
      ..setFloat(7, settings.chromaticAberration)
      ..setFloat(8, settings.thickness)
      ..setFloat(9, 0.0); // blend ist bei Arbitrary egal

    // layout(location = 3) vec4 uLightConfig;    // slots 10..13
    _shaderV
      ..setFloat(10, settings.lightAngle) // legacy; Richtung kommt unten
      ..setFloat(11, settings.lightIntensity)
      ..setFloat(12, settings.ambientStrength)
      ..setFloat(13, settings.saturation);

    // layout(location = 4) vec2 uColorAdjust;    // slots 14..15
    _shaderV
      ..setFloat(14, settings.lightness)
      ..setFloat(15, 0.0); // numShapes ungenutzt

    // layout(location = 5) vec2 uLightDirection; // slots 16..17
    final lx = math.cos(settings.lightAngle);
    final ly = math.sin(settings.lightAngle);
    _shaderV
      ..setFloat(16, lx)
      ..setFloat(17, ly);

    // ── MATTE-UNIFORMS direkt hinter dem Header ───────────────────────────────
    // layout(location = 6) vec2 uForegroundSize; // slots 18..19
    _shaderV
      ..setFloat(18, fgW)
      ..setFloat(19, fgH);

    // layout(location = 7) vec2 uOffset;         // slots 20..21
    _shaderV
      ..setFloat(20, globalOffset.dx * devicePixelRatio)
      ..setFloat(21, globalOffset.dy * devicePixelRatio);

    // ── IMPeller-Blur-Uniforms (NACH HINTEN, wie im Shader) ───────────────────
    final n = kernel.length.clamp(1, _kMaxKernel);

    // layout(location = 102..105): skalare
    _shaderV
      ..setFloat(102, 0.0) // u_dir_x  (V)
      ..setFloat(103, 1.0) // u_dir_y
      ..setFloat(104, n.toDouble()) // u_sample_count
      ..setFloat(105, 0.0); // u_tile_mode = clamp

    // layout(location = 106) u_samples[50] (vec4 je Sample)
    int base = 106;
    for (int i = 0; i < n; i++) {
      final s = kernel[i];
      _shaderV
        ..setFloat(base + i * 4 + 0, s.tPx) // x = Offset (Pixel)
        ..setFloat(base + i * 4 + 1, 0.0)
        ..setFloat(base + i * 4 + 2, s.w) // z = Gewicht
        ..setFloat(base + i * 4 + 3, 0.0);
    }
  }

  // ── Matte fangen (scharf + geblurrt für Normal-Reko)
  void _captureChildLayer() {
    childImage?.dispose();
    childImage = _buildMaskImage();
  }

  void _captureChildBlurredLayer() {
    childBlurredImage?.dispose();
    final matteBlur = settings.thickness / 6.0;
    childBlurredImage = _buildMaskImage(matteBlur);
  }

  ui.Image _buildMaskImage([double? blur]) {
    final builder = ui.SceneBuilder();
    final transform =
        Matrix4.diagonal3Values(devicePixelRatio, devicePixelRatio, 1);
    final bounds = offset & layerSize;

    builder.pushTransform(transform.storage);
    _addMaskToScene(builder, blur);
    builder.pop();

    return builder.build().toImageSync(
          (devicePixelRatio * bounds.width).floor(),
          (devicePixelRatio * bounds.height).floor(),
        );
  }

  ui.ImageFilterEngineLayer? _maskFilterLayer;

  void _addMaskToScene(ui.SceneBuilder builder, [double? blur]) {
    final mask = firstChild;

    builder.pushOffset(-offset.dx, -offset.dy);

    if (blur != null) {
      _maskFilterLayer = builder.pushImageFilter(
        ImageFilter.compose(
          outer: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          inner: ImageFilter.erode(radiusX: blur, radiusY: blur),
        ),
        oldLayer: _maskFilterLayer,
      );
    }

    mask?.addToScene(builder);

    if (blur != null) {
      builder.pop();
    }

    builder.pop();
  }

  ui.Picture _buildCoveragePicture(Size size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = const Color(0x01000000); // 1/255 alpha
    canvas.drawRect(Offset.zero & size, paint);
    return recorder.endRecording();
  }

  void _addCoverageQuad(ui.SceneBuilder builder) {
    final pic = _buildCoveragePicture(layerSize);
    builder.addPicture(Offset.zero, pic);
    pic.dispose();
  }

  @override
  void dispose() {
    childImage?.dispose();
    childBlurredImage?.dispose();
    _maskFilterLayer?.dispose();
    _hEngineLayer?.dispose();
    _vEngineLayer?.dispose();
    super.dispose();
  }
}
