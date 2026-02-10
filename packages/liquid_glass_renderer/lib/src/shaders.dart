// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter/foundation.dart';

final String _shadersRoot =
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')
        ? ''
        : 'packages/liquid_glass_renderer/';

/// The asset path for the main liquid glass fragment shader.
///
/// This shader handles the refraction, reflection, and specular highlights
/// for the glass effect.
@internal
final String liquidGlassShader =
    '${_shadersRoot}lib/assets/shaders/liquid_glass.frag';

/// The asset path for the 1D Gaussian blur fragment shader.
///
/// This shader is used for the background blur pass (backdrop filter) associated
/// with the glass effect.
@internal
final String gaussian1dBlurShader =
    '${_shadersRoot}lib/assets/shaders/gaussian_1d_blur.frag';
