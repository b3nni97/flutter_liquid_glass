import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';

/// Öffentliche API: ein BackdropFilter, der den nativen Flutter-Blur
/// optisch und algorithmisch reproduziert (2-Pass, separabel).
class GaussianBackdropBlur extends StatefulWidget {
  const GaussianBackdropBlur({
    super.key,
    required this.sigmaX,
    required this.sigmaY,
    this.tileMode = TileMode.clamp,
    this.child,
    this.useComposeFallbackStack = true, // s.u. für Compose-Bug-Fallback
  });

  final double sigmaX;
  final double sigmaY;
  final TileMode tileMode;
  final Widget? child;

  /// Falls deine Flutter-Version den Compose-Bug hat (siehe README),
  /// wird bei true automatisch auf zwei verschachtelte BackdropFilter
  /// ausgewichen.
  final bool useComposeFallbackStack;

  @override
  State<GaussianBackdropBlur> createState() => _GaussianBackdropBlurState();
}

class _GaussianBackdropBlurState extends State<GaussianBackdropBlur> {
  static const int _kMaxKernel = 50;
  static const double _kMaxSigma = 500.0;
  static const double _kSqrt3 = 1.7320508075688772;

  ui.FragmentProgram? _program;

  late ui.FragmentShader _shaderH;
  late ui.FragmentShader _shaderV;

  late ui.ImageFilter _filterH;
  late ui.ImageFilter _filterV;
  ui.ImageFilter? _composed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    assert(ui.ImageFilter.isShaderFilterSupported,
        'ImageFilter.shader erfordert Impeller.'); // nur Info zur Laufzeit
    _program ??= await ui.FragmentProgram.fromAsset(gaussian1dBlurShader);

    _shaderH = _program!.fragmentShader();
    _shaderV = _program!.fragmentShader();

    _rebuildFilters();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant GaussianBackdropBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_program != null &&
        (oldWidget.sigmaX != widget.sigmaX ||
            oldWidget.sigmaY != widget.sigmaY ||
            oldWidget.tileMode != widget.tileMode)) {
      _rebuildFilters();
      setState(() {});
    }
  }

  // ----------------- Impeller-äquivalente Kernelfunktionen -----------------

  // Polynomial aus Flutter Engine (ScaleSigma): clamp auf 500, dann a*s^2 + b*s + c.
  double _scaleSigma(double sigma) {
    final s = sigma.clamp(0.0, _kMaxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    final scalar = c + b * s + a * s * s;
    return s * scalar;
  }

  // Sigma -> Radius nach Impeller/Skia: (sigma > 0.5 ? (sigma - 0.5) * sqrt(3) : 0)
  // (siehe impeller/geometry/sigma.cc)
  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _kSqrt3 : 0.0;
  }

  // Rohkernel pro 1D-Pass (vor Lerp-Hack).
  List<_RawSample> _generateRaw(double blurSigma, int radius, {int step = 1}) {
    int sampleCount = ((2 * radius) ~/ step) + 1;
    int xOffset = 0;
    if (radius >= 16) {
      // wie Engine: 2 Samples am Ende entfernen, Offsets verschieben
      sampleCount -= 2;
      xOffset = 1;
    }
    final out = <_RawSample>[];
    double tally = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final int x = xOffset + (i * step) - radius;
      final double coeff = math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma);
      out.add(_RawSample(x.toDouble(), coeff));
      tally += coeff;
    }
    // normalisieren
    for (final s in out) {
      s.coeff /= tally;
    }
    return out;
  }

  // Lerp-Hack: Paare zusammenfassen (Position = gewichteter Mittelwert),
  // Mitte bleibt einzeln. Ergibt ca. halbe Sampleanzahl bei identischem Ergebnis.
  List<_PackedSample> _lerpHack(List<_RawSample> raw) {
    final n = raw.length;
    final outCount = ((n - 1) ~/ 2) + 1;
    final middle = outCount ~/ 2;
    final out = <_PackedSample>[];
    int j = 0;
    for (int i = 0; i < outCount; i++) {
      if (i == middle) {
        final s = raw[j];
        out.add(_PackedSample(t: s.x, w: s.coeff));
        j++;
      } else {
        final a = raw[j];
        final b = raw[j + 1];
        final w = a.coeff + b.coeff;
        final t = (a.x * a.coeff + b.x * b.coeff) / w; // in "Pixeln"
        out.add(_PackedSample(t: t, w: w));
        j += 2;
      }
      if (out.length >= _kMaxKernel) break; // Safety wie Engine
    }
    return out;
  }

  List<_PackedSample> _computeKernel(double sigma) {
    final scaled = _scaleSigma(sigma);
    final radius = _sigmaToRadius(scaled);
    final r = radius.round();
    if (r <= 0) {
      return [const _PackedSample(t: 0.0, w: 1.0)];
    }
    final raw = _generateRaw(scaled, r);
    final packed = _lerpHack(raw);
    return packed;
  }

  int _tileModeToIndex(TileMode m) {
    switch (m) {
      case TileMode.clamp:
        return 0;
      case TileMode.repeated:
        return 1;
      case TileMode.mirror:
        return 2;
      case TileMode.decal:
        return 3;
    }
  }

  // Uniform-Belegung: (Float-Indizes ohne Sampler)
  // 0..1: u_size (Engine setzt das)
  // 2..3: u_dir
  // 4:    u_sample_count
  // 5:    u_tile_mode
  // 6.. : u_samples[i] (vec4 = x,y,z,w) => [t, 0, w, 0]
  void _setPassUniforms(
    ui.FragmentShader shader, {
    required bool horizontal,
    required List<_PackedSample> kernel,
    required TileMode tileMode,
  }) {
    shader.setFloat(2, horizontal ? 1.0 : 0.0);
    shader.setFloat(3, horizontal ? 0.0 : 1.0);
    shader.setFloat(4, kernel.length.toDouble());
    shader.setFloat(5, _tileModeToIndex(tileMode).toDouble());

    int base = 6;
    for (int i = 0; i < kernel.length; i++) {
      final s = kernel[i];
      shader.setFloat(base + i * 4 + 0, s.t); // t
      shader.setFloat(base + i * 4 + 1, 0.0); // (unused)
      shader.setFloat(base + i * 4 + 2, s.w); // weight
      shader.setFloat(base + i * 4 + 3, 0.0); // (unused)
    }
  }

  void _rebuildFilters() {
    final kH = _computeKernel(widget.sigmaX);
    final kV = _computeKernel(widget.sigmaY);

    _setPassUniforms(_shaderH,
        horizontal: true, kernel: kH, tileMode: widget.tileMode);
    _setPassUniforms(_shaderV,
        horizontal: false, kernel: kV, tileMode: widget.tileMode);

    _filterH = ui.ImageFilter.shader(_shaderH);
    _filterV = ui.ImageFilter.shader(_shaderV);

    // Hauptweg: compose(outer: H, inner: V) => H(V(source))
    // (auf einigen Versionen gab es einen Bug, siehe Fallback unten)
    _composed = ui.ImageFilter.compose(outer: _filterH, inner: _filterV);
  }

  @override
  Widget build(BuildContext context) {
    if (_program == null) {
      return widget.child ?? const SizedBox.shrink();
    }

    final child = widget.child ?? const SizedBox.expand();

    // Fallback-Pfad bei Compose-Inkompatibilitäten:
    // Zwei BackdropFilter übereinander (V dann H).
    if (_composed == null && widget.useComposeFallbackStack) {
      return ClipRect(
        child: BackdropFilter(
          filter: _filterV,
          child: BackdropFilter(
            filter: _filterH,
            child: child,
          ),
        ),
      );
    }

    return ClipRect(
      child: BackdropFilter(
        filter: _composed!,
        child: child,
      ),
    );
  }
}

class _RawSample {
  _RawSample(this.x, this.coeff);
  double x;
  double coeff;
}

class _PackedSample {
  const _PackedSample({required this.t, required this.w});
  final double t; // Offset entlang Achse in Pixeln
  final double w; // Gewicht
}
