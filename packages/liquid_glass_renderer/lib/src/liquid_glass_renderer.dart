import 'package:flutter/foundation.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';

/// Manages the initialization and configuration of the Liquid Glass rendering system.
///
/// This class acts as a static utility namespace and cannot be instantiated.
class LiquidGlassRenderer {
  LiquidGlassRenderer._();

  /// Compiles and warms up the fragment shaders required by the renderer.
  ///
  /// This method executes [ShaderBuilder.precacheShader] for all known assets
  /// in parallel. It is intended to be awaited in the `main()` function to ensure
  /// smooth first-frame rendering.
  ///
  /// Errors encountered during shader compilation are reported via [FlutterError.reportError].
  ///
  /// Example:
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await LiquidGlassRenderer.precacheShaders();
  ///   runApp(const MyApp());
  /// }
  /// ```
  static Future<void> precacheShaders() async {
    final List<String> shaderPaths = <String>[
      liquidGlassShader,
      gaussian1dBlurShader,
    ];

    try {
      await Future.wait(
        shaderPaths.map(ShaderBuilder.precacheShader),
      );
    } catch (exception, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stackTrace,
        library: 'liquid_glass_renderer',
        context: ErrorDescription('while precaching shaders'),
      ));
    }
  }
}
