// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter/foundation.dart';

final String _shadersRoot =
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')
        ? ''
        : 'packages/liquid_glass_renderer/';

@internal
final String liquidGlassShader =
    '${_shadersRoot}lib/assets/shaders/liquid_glass.frag';

@internal
final String gaussian1dBlurShader =
    '${_shadersRoot}lib/assets/shaders/gaussian_1d_blur.frag';

@internal
final String blendMaskShader =
    '${_shadersRoot}lib/assets/shaders/blend_mask.frag';
