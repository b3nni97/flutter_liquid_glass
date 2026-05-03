#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

#ifndef TAU
#define TAU 6.28318530718
#endif

#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3
#endif

#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

#ifndef LG_REFRACT_AA_RADIUS_PX
#define LG_REFRACT_AA_RADIUS_PX 0.75
#endif

#ifndef LG_REFRACT_AA_STRENGTH
#define LG_REFRACT_AA_STRENGTH 0.85
#endif

#ifndef LG_CA_AA_TAPS
#define LG_CA_AA_TAPS 8
#endif

#ifndef LG_CA_AA_RADIUS_PX
#define LG_CA_AA_RADIUS_PX 1.15
#endif

#ifndef LG_CA_AA_STRENGTH
#define LG_CA_AA_STRENGTH 0.9
#endif

#ifndef LG_CA_EDGE_FEATHER_PX
#define LG_CA_EDGE_FEATHER_PX 1.0
#endif

#ifndef GLOW_OWNER_FEATHER_PX
#define GLOW_OWNER_FEATHER_PX 4.0
#endif

#ifndef LG_RIM_TOP_HIGHLIGHT_STRENGTH
#define LG_RIM_TOP_HIGHLIGHT_STRENGTH 0.0
#endif

#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

/// Holds the rim lighting mask values for edge detection.
struct RimMasks {
  float band;
  float core;
};

/// Holds the aggregated parameters for the strongest active glow effect.
struct GlowParams {
  float strength;
  float power;
  float mixFactor;
  float lightMix;
  float satMix;
  float lightIntensity;
  float colorAlpha;
  float blurSigma;
  vec3 tintColor;
  vec4 glassTarget;
};

/// Calculates a pseudo-random value based on the input position.
float _hashRefraction(vec2 position) {
  return fract(sin(dot(position, vec2(12.9898, 78.233))) * 43758.5453);
}

/// Normalizes a vector safely, returning a zero vector if the length is negligible.
vec2 _safeNormalize(vec2 v) {
  float lengthSquared = max(dot(v, v), LG_EPS);
  return v * inversesqrt(lengthSquared);
}

/// Converts pixel coordinates to UV space, handling target-specific coordinate flips.
vec2 _uvFromPx(vec2 pixel, vec2 sizePixels) {
  vec2 uv = pixel / max(sizePixels, vec2(1.0));
  #ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
  #endif
  return uv;
}

/// Samples a texture with clamping to the [0, 1] range.
vec4 _sampleTexture(sampler2D t, vec2 uv) {
  return texture(t, clamp(uv, vec2(0.0), vec2(1.0)));
}

/// Samples a texture using explicit nearest-neighbor interpolation.
vec4 _sampleNearest(sampler2D tex, vec2 uv, vec2 texSize) {
  vec2 pixel = uv * texSize;
  vec2 nearestPixel = floor(pixel) + 0.5;
  vec2 nearestUV = nearestPixel / texSize;
  return texture(tex, clamp(nearestUV, vec2(0.0), vec2(1.0)));
}

/// Reads shape geometry data from the packed uniform array.
void _readShapeData(int shapeIndex, out float type, out vec2 center, out vec2 size, out float cornerRadius) {
  int baseIndex = shapeIndex * 7;
  type = uShapeData[baseIndex + 0];
  center = vec2(uShapeData[baseIndex + 1], uShapeData[baseIndex + 2]);
  size = vec2(uShapeData[baseIndex + 3], uShapeData[baseIndex + 4]);
  cornerRadius = uShapeData[baseIndex + 5];
}

/// Computes the signed distance to a rounded rectangle.
float _sdRoundedRect(vec2 position, vec2 center, vec2 size, float radius) {
  vec2 halfSize = max(size * 0.5, vec2(0.0));
  float clampedRadius = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
  vec2 q = abs(position - center) - (halfSize - vec2(clampedRadius));
  return length(max(q, 0.0)) - clampedRadius + min(max(q.x, q.y), 0.0);
}

/// Computes the signed distance to an ellipse.
float _sdEllipse(vec2 position, vec2 center, vec2 size) {
  vec2 ab = max(size * 0.5, vec2(1e-4));
  vec2 d = (position - center) / ab;
  float k = length(d) - 1.0;
  return k * min(ab.x, ab.y);
}

/// Dispatches the correct SDF calculation based on the shape type index.
float _sdShapeAt(int shapeIndex, vec2 position) {
  float type, radius;
  vec2 center, size;
  _readShapeData(shapeIndex, type, center, size, radius);

  if (type == 2.0) {
    return _sdEllipse(position, center, size);
  }
  return _sdRoundedRect(position, center, size, radius);
}

/// Projects a point from SDF space back to screen space using the inverse transform.
vec2 _projectSdfToScreen(vec2 positionSdf) {
  mat4 inverseTransform = inverse(uTransform);
  vec4 positionScreen = inverseTransform * vec4(positionSdf, 0.0, 1.0);
  float w = max(positionScreen.w, 1e-6);
  return positionScreen.xy / w;
}

/// Applies a jittered blur for refraction approximation.
vec4 _blurJitterRefraction(sampler2D tex, vec2 uv, float blurAmount, vec2 sizePixels, vec2 seed) {
  if (blurAmount <= 0.1) {
    return _sampleTexture(tex, uv);
  }

  vec2 pixelSize = 1.0 / sizePixels;
  if (blurAmount < 1.0) {
    float r = _hashRefraction(seed) - 0.5;
    vec2 jitter = vec2(r, -r) * blurAmount * pixelSize;
    return _sampleTexture(tex, uv + jitter);
  }

  float spread = blurAmount * 0.7;
  vec4 color = _sampleNearest(tex, uv + vec2(-spread, -spread) * pixelSize, sizePixels);
  color += _sampleNearest(tex, uv + vec2(spread, -spread) * pixelSize, sizePixels);
  color += _sampleNearest(tex, uv + vec2(-spread, spread) * pixelSize, sizePixels);
  color += _sampleNearest(tex, uv + vec2(spread, spread) * pixelSize, sizePixels);
  return color * 0.25;
}

/// Applies a Gaussian blur using pre-computed weights from the uniform buffer.
vec4 _applyGaussianBlur(sampler2D tex, vec2 baseUV) {
  vec2 pixel = vec2(1.0 / uSize.x, 1.0 / uSize.y);
  vec2 stepVec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);
  float sampleCountRaw = u_sample_count;

  vec2 eps = vec2(0.5) / max(uSize, vec2(1.0));
  vec2 minUV = eps;
  vec2 maxUV = vec2(1.0) - eps;

  if (sampleCountRaw <= 0.5) {
    vec2 cuv = clamp(baseUV, minUV, maxUV);

    // When background scaling is active, use manual bilinear interpolation
    // to guarantee correct sub-texel sampling regardless of hardware sampler
    // filter mode.  This produces sharp (not blurry) anti-aliased edges.
    // Cost: +3 extra texture reads when scaling is active.
    float scaleDelta = abs(uBgScale.x - 1.0) + abs(uBgScale.y - 1.0);
    if (scaleDelta > 0.001) {
      vec2 texelCoord = cuv * uSize - 0.5;
      vec2 f = fract(texelCoord);
      vec2 base = (floor(texelCoord) + 0.5) / uSize;

      vec4 tl = texture(tex, clamp(base,                     minUV, maxUV));
      vec4 tr = texture(tex, clamp(base + vec2(pixel.x, 0.0), minUV, maxUV));
      vec4 bl = texture(tex, clamp(base + vec2(0.0, pixel.y), minUV, maxUV));
      vec4 br = texture(tex, clamp(base + pixel,              minUV, maxUV));

      return mix(mix(tl, tr, f.x), mix(bl, br, f.x), f.y);
    }

    return texture(tex, cuv);
  }

  vec4 sum = vec4(0.0);
  float weightSum = 0.0;
  int sampleCount = int(sampleCountRaw + 0.5);

  for (int i = 0; i < 24; ++i) {
    if (i >= sampleCount) break;

    float t = u_samples[i].x;
    float weight = u_samples[i].z;

    vec2 offsetUV = baseUV + stepVec * t;
    vec2 clampedUV = clamp(offsetUV, minUV, maxUV);

    sum += weight * texture(tex, clampedUV);
    weightSum += weight;
  }

  if (weightSum > 1e-6) {
    return sum / weightSum;
  }
  return texture(tex, clamp(baseUV, minUV, maxUV));
}

/// Approximates a blur using a 9-tap box filter pattern.
vec4 _blurApprox9(sampler2D tex, vec2 uv, float sigmaPixels, vec2 sizePixels) {
  if (sigmaPixels <= 0.01) {
    return _sampleTexture(tex, uv);
  }

  vec2 px = 1.0 / sizePixels;
  float spread = clamp(sigmaPixels, 0.0, 6.0);

  float weightCenter = 0.227027;
  float weightNear = 0.194594;
  float weightFar = 0.121621;

  vec4 centerCol = _sampleTexture(tex, uv);
  vec4 color = centerCol * weightCenter;

  color += _sampleTexture(tex, uv + vec2(px.x, 0.0)) * weightNear;
  color += _sampleTexture(tex, uv + vec2(-px.x, 0.0)) * weightNear;
  color += _sampleTexture(tex, uv + vec2(0.0, px.y)) * weightNear;
  color += _sampleTexture(tex, uv + vec2(0.0, -px.y)) * weightNear;

  color += _sampleTexture(tex, uv + vec2(px.x, px.y)) * weightFar;
  color += _sampleTexture(tex, uv + vec2(-px.x, px.y)) * weightFar;
  color += _sampleTexture(tex, uv + vec2(px.x, -px.y)) * weightFar;
  color += _sampleTexture(tex, uv + vec2(-px.x, -px.y)) * weightFar;

  float t = clamp((spread - 1.0) / 5.0, 0.0, 1.0);
  return mix(centerCol, color, t);
}

/// Samples the texture with chromatic aberration anti-aliasing.
vec4 _sampleAberrationAA(sampler2D tex, vec2 uvCenter, vec2 aberrationUV, vec2 sizePixels) {
  float lengthPixels = length(aberrationUV * sizePixels);
  if (lengthPixels < 1e-4) {
    return _sampleTexture(tex, uvCenter);
  }

  vec2 px = 1.0 / sizePixels;
  vec2 dir = normalize(aberrationUV + vec2(1e-6));
  float radiusPixels = float(LG_CA_AA_RADIUS_PX);
  float strength = clamp(float(LG_CA_AA_STRENGTH), 0.0, 1.0);

  vec2 offsetUV = dir * radiusPixels * px;
  vec4 c0 = _sampleTexture(tex, uvCenter);
  vec4 c1 = _sampleTexture(tex, uvCenter + offsetUV);
  vec4 c2 = _sampleTexture(tex, uvCenter - offsetUV);

  #if LG_CA_AA_TAPS == 2
  vec4 average = 0.5 * (c1 + c2);
  #else
  vec4 average = (c0 + c1 + c2) / 3.0;
  #endif
  return mix(c0, average, strength);
}

/// Samples the texture using Rotated Grid Super Sampling (4 taps).
vec4 _sampleRGSS4(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPixels, float gain) {
  vec2 ortho = vec2(-dir.y, dir.x);
  vec2 o0 = vec2(0.5, 0.5);
  vec2 o1 = vec2(-0.5, 0.5);
  vec2 o2 = vec2(0.5, -0.5);
  vec2 o3 = vec2(-0.5, -0.5);

  vec2 a0 = (dir * (o0.x * gain) + ortho * o0.y) * radiusPixels;
  vec2 a1 = (dir * (o1.x * gain) + ortho * o1.y) * radiusPixels;
  vec2 a2 = (dir * (o2.x * gain) + ortho * o2.y) * radiusPixels;
  vec2 a3 = (dir * (o3.x * gain) + ortho * o3.y) * radiusPixels;

  vec4 c0 = _applyGaussianBlur(tex, uv + a0 * px);
  vec4 c1 = _applyGaussianBlur(tex, uv + a1 * px);
  vec4 c2 = _applyGaussianBlur(tex, uv + a2 * px);
  vec4 c3 = _applyGaussianBlur(tex, uv + a3 * px);

  return (c0 + c1 + c2 + c3) * 0.25;
}

/// Samples the texture with refraction anti-aliasing blending.
vec4 _sampleRefractionAA(sampler2D tex, vec2 uv, vec2 sizePixels, vec2 directionUV, float radiusPixels, float strength, float gain) {
  vec2 px = vec2(1.0 / sizePixels.x, 1.0 / sizePixels.y);
  vec2 dir = normalize(directionUV + vec2(1e-6));

  vec4 average = _sampleRGSS4(tex, uv, px, dir, radiusPixels, gain);
  vec4 base = _applyGaussianBlur(tex, uv);

  return mix(base, average, clamp(strength, 0.0, 1.0));
}

/// Computes a highlight color adapted to the background luminance to prevent washout.
vec3 _computeAdaptiveHighlight(vec3 backgroundColor, float targetBrightness) {
  float luminance = dot(backgroundColor, vec3(0.299, 0.587, 0.114));

  vec3 normalizedBackground = backgroundColor / max(luminance, 1e-6);
  vec3 coloredHighlight = normalizedBackground * targetBrightness;

  float saturationBoost = 1.3;
  vec3 gray = vec3(dot(coloredHighlight, vec3(0.299, 0.587, 0.114)));
  coloredHighlight = mix(gray, coloredHighlight, saturationBoost);
  coloredHighlight = min(coloredHighlight, vec3(1.0));

  float luminanceFactor = smoothstep(0.0, 0.6, luminance);

  float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float saturation = (maxC > 1e-6) ? (maxC - minC) / maxC : 0.0;

  float saturationFactor = smoothstep(0.0, 0.4, saturation);
  float colorInfluence = luminanceFactor * saturationFactor;

  vec3 whiteHighlight = vec3(1.0 * targetBrightness);
  return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

/// Calculates the physical height of the liquid at a given point based on its signed distance.
float _calculateLiquidHeight(float signedDistance, float thickness) {
  if (signedDistance >= 0.0) return 0.0;
  if (thickness <= 0.0) return 0.0;
  if (signedDistance < -thickness) return thickness;

  float x = thickness + signedDistance;
  return sqrt(max(0.0, thickness * thickness - x * x));
}

/// Computes intensity masks for the rim lighting effect using gradient analysis.
RimMasks _calculateRimMasks(float signedDistance, float rimWidthPixels) {
  vec2 gradient = vec2(dFdx(signedDistance), dFdy(signedDistance));
  float gradientMagnitude = max(length(gradient), 1e-6);

  float widthSdf = max(rimWidthPixels, 0.0) * gradientMagnitude;

  // Inner fade: squared smoothstep centered at -widthSdf.
  float innerFw = max(fwidth(signedDistance), 1e-6);
  float band = smoothstep(-widthSdf - innerFw, -widthSdf + innerFw, signedDistance);
  band *= band;

  // Outer edge: rim at 0.25 at sd=0.
  float outerFw = max(fwidth(signedDistance), 1e-6);
  float outerEdgeFade = smoothstep(outerFw, -outerFw, signedDistance);
  outerEdgeFade *= outerEdgeFade; // 0.25 at sd=0
  band *= outerEdgeFade;

  RimMasks masks;
  masks.band = band;
  masks.core = pow(band, 3.0);
  return masks;
}

/// Blends a tint color into the liquid surface based on glass opacity.
vec4 _blendGlassTint(vec4 liquidColor, vec4 glassColor) {
  vec4 finalColor = liquidColor;
  if (glassColor.a > 0.0) {
    float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
    float isDark = step(glassLuminance, 0.5);

    vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
    vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
    vec3 invGlass = vec3(1.0) - glassColor.rgb;
    vec3 screened = vec3(1.0) - (invLiquid * invGlass);

    vec3 targetRGB = mix(screened, darkened, isDark);
    finalColor.rgb = mix(liquidColor.rgb, targetRGB, glassColor.a);
    finalColor.a = liquidColor.a;
  }
  return finalColor;
}

/// Adjusts the saturation and lightness of a color vector.
vec3 _adjustColorBalance(vec3 color, float saturation, float lightness) {
  float luminance = dot(color, vec3(0.299, 0.587, 0.114));
  vec3 saturatedColor = mix(vec3(luminance), color, saturation);

  vec3 lightBoost = mix(saturatedColor, vec3(1.0), lightness - 1.0);
  vec3 lightDim = saturatedColor * lightness;

  vec3 adjustedColor = mix(lightDim, lightBoost, step(1.0, lightness));
  return clamp(adjustedColor, 0.0, 1.0);
}


/// Computes a hard light blend adapted for specific background color conditions.
vec3 _blendHardLight(vec3 base, vec3 blend) {
  vec3 darkBlend = blend;

  float greenIntensity = smoothstep(0.3, 1.0, base.g);
  float greenFactor = mix(1.0, 0.71, greenIntensity);
  darkBlend.g = blend.g * greenFactor;

  float redIntensityDark = smoothstep(0.7, 0.95, base.r);
  darkBlend.r = mix(darkBlend.r, 1.0, redIntensityDark);

  float greenBgStrong = smoothstep(0.5, 1.0, base.g);
  darkBlend.r = darkBlend.r * mix(1.0, 0.96, greenBgStrong);

  vec3 lightBlend = blend;
  float isRedBackground = smoothstep(0.1, 0.3, base.r - base.g);
  float lightRedBoost = mix(1.0, 1.08, isRedBackground);
  lightBlend.r = lightBlend.r * lightRedBoost;

  vec3 t1 = 2.0 * base * lightBlend;
  vec3 t2 = 1.0 - 2.0 * (1.0 - base) * (1.0 - darkBlend);

  vec3 selection = step(0.5, blend);
  return mix(t1, t2, selection);
}

/// Determines if the current pixel belongs to an icon or a background based on color keying.
float _calculateIconMask(vec3 childRGB, vec3 keyColor) {
  vec3 diffVec = abs(childRGB - keyColor);
  float diff = max(diffVec.r, max(diffVec.g, diffVec.b));
  return 1.0 - smoothstep(0.01, 0.04, diff);
}

/// Composites child texture onto a background sample using hard-light blending.
vec3 _compositeChildOnBg(
    vec4 bgSample,
    sampler2D childTexture,
    vec2 childUV,
    vec3 keyColor,
    vec4 glassColor,
    float saturation,
    float lightness
) {
  bgSample = _blendGlassTint(bgSample, glassColor);
  bgSample.rgb = _adjustColorBalance(bgSample.rgb, saturation, lightness);

  vec4 childSample = _sampleTexture(childTexture, childUV);
  if (childSample.a <= 0.001) {
    return bgSample.rgb;
  }
  vec3 childRGB = childSample.rgb / max(childSample.a, 1e-4);
  float isIcon = _calculateIconMask(childRGB, keyColor);
  vec3 blended = _blendHardLight(bgSample.rgb, childRGB);
  vec3 final_ = mix(childRGB, blended, isIcon);
  return mix(bgSample.rgb, final_, childSample.a);
}

/// Resolves chromatic aberration using Android-style 7-band spectral dispersion.
/// Returns the final composited color (direct replacement, not a diff).
vec4 _resolveDispersion(
    vec2 refractedUV,
    vec2 childUVRefracted,
    vec2 refractionDisplacement,
    vec2 sizePixels,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    int shapeIndex,
    float aberrationStrength,
    vec3 keyColor,
    float saturation,
    float lightness,
    vec4 glassColor,
    float signedDistance,
    vec3 normal,
    float thickness,
    float refractiveIndex
) {
  // Scale factor to convert screen UV offsets to child UV space, with spread control
  vec2 childCaScale = (sizePixels / max(uChildSize, vec2(1.0))) * uChildCaSpread;

  // --- Compute shape center and half-size in UV space ---
  float type, radius;
  vec2 centerSdf, sizeSdf;
  _readShapeData(shapeIndex, type, centerSdf, sizeSdf, radius);

  vec2 centerPx = _projectSdfToScreen(centerSdf);
  vec2 centerUV = _uvFromPx(centerPx, sizePixels);

  vec2 col0 = uTransform[0].xy;
  vec2 col1 = uTransform[1].xy;
  float scaleX = max(length(col0), 1e-6);
  float scaleY = max(length(col1), 1e-6);

  vec2 halfSizeUV = (sizeSdf / vec2(scaleX, scaleY)) * 0.5 / sizePixels;

  vec2 centeredUV = refractedUV - centerUV;
  vec2 p = centeredUV / max(halfSizeUV, vec2(1e-6)); // normalized [-1,1]
  vec2 absp = abs(p);

  // Corner proximity using polar angle — allows sliding the boost around the arc
  // sin(2θ) peaks at 45° (diagonal), equivalent to 2·px·py/r² · r²
  float theta = atan(absp.y, max(absp.x, 1e-6)); // 0 to π/2
  float r2 = absp.x * absp.x + absp.y * absp.y;

  // Convert pixel inset to angular shift along the corner arc
  float halfMinPx = min(halfSizeUV.x * sizePixels.x, halfSizeUV.y * sizePixels.y);
  float angularShift = uDispersionInset / max(halfMinPx, 1.0) * 1.5708; // π/2

  // Rotate the boost peak: starts later horizontally, extends further vertically
  float shifted = max(sin(2.0 * (theta - angularShift)), 0.0);
  float cornerness = clamp(shifted * r2 * 0.5, 0.0, 1.0);
  // Pass 1 curvature factors
  float curvatureFactor = 1.0 + cornerness * uCurvatureBoostP1;
  float curvatureFactorNeg = 1.0 + cornerness * uCurvatureBoostNegP1;
  // Pass 2 curvature factors — remapped cornerness with raised threshold
  // cornernessP2 stays 0 until cornerness exceeds uP2CornernessMin, then ramps to 1
  float cornernessP2 = smoothstep(uP2CornernessMin, 1.0, cornerness);
  float curvatureFactorP2 = 1.0 + cornernessP2 * uCurvatureBoostP2;
  float curvatureFactorNegP2 = 1.0 + cornernessP2 * uCurvatureBoostNegP2;

  // Android original: dispersion along refraction direction, x*y intensity
  vec2 shearedUV = vec2(
      centeredUV.x - centeredUV.y * uDispersionFlipAngle,
      centeredUV.y - centeredUV.x * uDispersionFlipAngleV
  );
  float rawProduct = (shearedUV.x * shearedUV.y) / max(halfSizeUV.x * halfSizeUV.y, 1e-8);

  // Separate sheared UV for Pass 2 (inner CA) with independent flip angles
  vec2 shearedUVP2 = vec2(
      centeredUV.x - centeredUV.y * uDispersionFlipAngleP2,
      centeredUV.y - centeredUV.x * uDispersionFlipAngleVP2
  );
  float rawProductP2 = (shearedUVP2.x * shearedUVP2.y) / max(halfSizeUV.x * halfSizeUV.y, 1e-8);

  // flipT: smooth 0→1 — 0=negative quadrant, 1=positive quadrant
  // --- Pass 1: Edge CA mask (curvature-adaptive depth) ---
  float flipZone = 0.08;
  float flipT = smoothstep(-flipZone, flipZone, rawProduct);
  // Mask depth: flat vs corner, from uniform
  float maskDepthPx = mix(uMaskFlatPx, uMaskCornerPx, cornerness);
  // Convert to SDF units using gradient magnitude
  float gradMag = max(length(vec2(dFdx(signedDistance), dFdy(signedDistance))), 1e-6);
  float maskDepthSdf = maskDepthPx * gradMag;
  // Mask transition in SDF units
  float transW = uMaskTransitionPx * gradMag;
  float edgeMask = smoothstep(-maskDepthSdf - transW, -maskDepthSdf, signedDistance);

  float innerMask = 1.0 - edgeMask; // Pass 2: starts where edge zone ends

  // === PASS 1: Edge CA (no mask, uses refractionDisplacement) ===
  // Positive quadrant dispersion (uses uCurvatureBoost)
  float dispersionIntensity = aberrationStrength * abs(rawProduct);
  dispersionIntensity *= curvatureFactor;
  dispersionIntensity = max(dispersionIntensity, aberrationStrength * uDispersionFloor);
  vec2 dispersedUV = refractionDisplacement * dispersionIntensity;
  float disperseLen = length(dispersedUV * sizePixels);
  if (disperseLen > 0.001) {
    float softLen = tanh(disperseLen / uDispersionClamp) * uDispersionClamp;
    dispersedUV *= softLen / disperseLen;
  }

  // Negative quadrant dispersion (uses uCurvatureBoostNeg)
  float dispIntNeg = aberrationStrength * abs(rawProduct);
  dispIntNeg *= curvatureFactorNeg;
  dispIntNeg = max(dispIntNeg, aberrationStrength * uDispersionFloor);
  vec2 dispersedUVNeg = refractionDisplacement * dispIntNeg;
  float dLenNeg = length(dispersedUVNeg * sizePixels);
  if (dLenNeg > 0.001) {
    float softLenNeg = tanh(dLenNeg / uDispersionClamp) * uDispersionClamp;
    dispersedUVNeg *= softLenNeg / dLenNeg;
  }

  // --- Edge dispersion minimum: ensure CA in the narrow rim strip ---
  // rimEdgeDispersionMin is a minimum dispersion *intensity factor* in the rim zone.
  // It multiplies refractionDisplacement (which is strong at the edge), so small
  // values like 0.5 already produce visible color fringing.
  float rimGradMag = max(length(vec2(dFdx(signedDistance), dFdy(signedDistance))), 1e-6);
  float rimDepthSdf = rimWidthPx * rimGradMag;
  float rimZone = smoothstep(-rimDepthSdf, 0.0, signedDistance);
  if (rimZone > 0.001 && rimEdgeDispersionMin > 0.001) {
    float edgeMinIntensity = rimEdgeDispersionMin * rimZone;
    // Use refraction direction (normalized), falling back to surface normal at the edge
    // where refractionDisplacement is near zero.
    float refLen = length(refractionDisplacement);
    vec2 refDir = refLen > 1e-6
        ? refractionDisplacement / refLen
        : (length(normal.xy) > 1e-6 ? normalize(normal.xy) : vec2(1.0, 0.0));
    // Convert edgeMinIntensity from pixel units to UV offset
    vec2 minOffsetUV = refDir * edgeMinIntensity / sizePixels;
    // Boost positive dispersion
    if (length(dispersedUV) < length(minOffsetUV)) {
      dispersedUV = minOffsetUV;
    }
    // Boost negative dispersion
    if (length(dispersedUVNeg) < length(minOffsetUV)) {
      dispersedUVNeg = minOffsetUV;
    }
    // Limit how far outside the shape (past sd=0) samples can go: max 16px overshoot.
    // Inward direction is unrestricted.
    float edgeDistPx = max(-signedDistance / rimGradMag, 0.0);
    float maxOutwardPx = edgeDistPx + 16.0;
    float posPx = length(dispersedUV * sizePixels);
    if (posPx > maxOutwardPx) {
      dispersedUV *= maxOutwardPx / posPx;
    }
    float negPx = length(dispersedUVNeg * sizePixels);
    if (negPx > maxOutwardPx) {
      dispersedUVNeg *= maxOutwardPx / negPx;
    }
  }


  // === PASS 2: Inner CA (stretched SDF, inverted colors, masked) ===
  // Recompute normal with stretched SDF so tilt persists 30% deeper
  float caSD = signedDistance * 0.77;
  float caFullRange = thickness + uNormalPlateauWidth;
  float caT = max(caFullRange + caSD, 0.0) / max(caFullRange, 1e-6);
  float caCos = pow(caT, uNormalSoftness);
  float caSin = sqrt(max(0.0, 1.0 - caCos * caCos));
  vec2 nxyDir = length(normal.xy) > 1e-6 ? normalize(normal.xy) : vec2(0.0);
  vec3 caNormal = normalize(vec3(nxyDir * caCos, caSin));
  float caHeight = _calculateLiquidHeight(caSD, thickness);
  vec3 caIncident = vec3(0.0, 0.0, -1.0);
  float caRI = max(refractiveIndex, 1.0001);
  vec3 caRefractVec = refract(caIncident, caNormal, 1.0 / caRI);
  float caRefractLen = (caHeight + thickness * 8.0) / max(0.001, abs(caRefractVec.z));
  vec2 caDisplacement = (caRefractVec.xy * caRefractLen) / sizePixels;
  // Min CA that fades to 0 where the stretched refraction naturally ends
  float caLenPx = length(caDisplacement * sizePixels);
  float minFade = smoothstep(0.0, 2.0, caLenPx); // 1.0 where stretched refract is strong, 0.0 where it ends
  float effectiveMinPx = 4.0 * minFade;
  if (caLenPx < effectiveMinPx && caLenPx > 0.01) {
    caDisplacement *= effectiveMinPx / caLenPx;
  }

  // Pass 2 dispersion vectors
  float dispIntP2 = aberrationStrength * abs(rawProductP2) * curvatureFactorP2;
  dispIntP2 = max(dispIntP2, aberrationStrength * uDispersionFloor);
  vec2 dispersedP2 = caDisplacement * dispIntP2;
  float dLenP2 = length(dispersedP2 * sizePixels);
  if (dLenP2 > 0.001) {
    dispersedP2 *= tanh(dLenP2 / uDispersionClamp) * uDispersionClamp / dLenP2;
  }



  // --- PASS 1 sampling: POSITIVE direction ---
  vec3 colorPos = vec3(0.0);
  {
    vec3 p0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUV*1.1),
        childTexture, childUVRefracted + dispersedUV*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
    vec3 p1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUV*0.75),
        childTexture, childUVRefracted + dispersedUV*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
    vec3 p2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUV*0.25),
        childTexture, childUVRefracted + dispersedUV*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
    vec3 p4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUV*0.8),
        childTexture, childUVRefracted - dispersedUV*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
    vec3 p5 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUV*1.1),
        childTexture, childUVRefracted - dispersedUV*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
    colorPos.r = p0.r * 0.50 + p1.r * 0.50;
    colorPos.g = p2.g;
    colorPos.b = p4.b * 0.50 + p5.b * 0.50;
  }

  // --- PASS 1: resolve direction blend ---
  vec3 pass1Color;
  if (flipT > 0.999) {
    pass1Color = colorPos;
  } else if (flipT < 0.001) {
    vec3 n0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUVNeg*1.1),
        childTexture, childUVRefracted - dispersedUVNeg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
    vec3 n1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUVNeg*0.75),
        childTexture, childUVRefracted - dispersedUVNeg*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
    vec3 n2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*0.25),
        childTexture, childUVRefracted + dispersedUVNeg*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
    vec3 n4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*0.8),
        childTexture, childUVRefracted + dispersedUVNeg*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
    vec3 n5 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*1.1),
        childTexture, childUVRefracted + dispersedUVNeg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
    vec3 colorNeg = vec3(0.0);
    colorNeg.r = n0.r * 0.50 + n1.r * 0.50;
    colorNeg.g = n2.g;
    colorNeg.b = n4.b * 0.50 + n5.b * 0.50;
    pass1Color = colorNeg;
  } else {
    vec3 colorNeg = vec3(0.0);
    {
      vec3 n0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUVNeg*1.1),
          childTexture, childUVRefracted - dispersedUVNeg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 n1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedUVNeg*0.75),
          childTexture, childUVRefracted - dispersedUVNeg*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
      vec3 n2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*0.25),
          childTexture, childUVRefracted + dispersedUVNeg*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
      vec3 n4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*0.8),
          childTexture, childUVRefracted + dispersedUVNeg*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
      vec3 n5 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedUVNeg*1.1),
          childTexture, childUVRefracted + dispersedUVNeg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      colorNeg.r = n0.r * 0.50 + n1.r * 0.50;
      colorNeg.g = n2.g;
      colorNeg.b = n4.b * 0.50 + n5.b * 0.50;
    }
    pass1Color = mix(colorNeg, colorPos, flipT);
  }

  // --- PASS 2 sampling: 7 bands with stretched displacement, INVERTED R↔B, with FLIP ---
  // Also compute a negative-direction Pass 2 dispersion vector
  float dispIntP2Neg = aberrationStrength * abs(rawProductP2) * curvatureFactorNegP2;
  dispIntP2Neg = max(dispIntP2Neg, aberrationStrength * uDispersionFloor);
  vec2 dispersedP2Neg = caDisplacement * dispIntP2Neg;
  float dLenP2Neg = length(dispersedP2Neg * sizePixels);
  if (dLenP2Neg > 0.001) {
    dispersedP2Neg *= tanh(dLenP2Neg / uDispersionClamp) * uDispersionClamp / dLenP2Neg;
  }

  vec3 pass2Color = pass1Color; // fallback
  if (innerMask > 0.001) {
    // Pass 2 POSITIVE direction (inverted R↔B, 5-tap)
    vec3 p2Pos = vec3(0.0);
    {
      vec3 q0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2*1.1),
          childTexture, childUVRefracted + dispersedP2*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 q1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2*0.75),
          childTexture, childUVRefracted + dispersedP2*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
      vec3 q2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2*0.25),
          childTexture, childUVRefracted + dispersedP2*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
      vec3 q3 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2*0.8),
          childTexture, childUVRefracted - dispersedP2*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
      vec3 q4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2*1.1),
          childTexture, childUVRefracted - dispersedP2*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      p2Pos.b = q0.b * 0.50 + q1.b * 0.50;
      p2Pos.g = q2.g;
      p2Pos.r = q3.r * 0.50 + q4.r * 0.50;
    }

    if (flipT > 0.999) {
      pass2Color = p2Pos;
    } else if (flipT < 0.001) {
      // Pass 2 NEGATIVE direction (inverted R↔B, 5-tap)
      vec3 q0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2Neg*1.1),
          childTexture, childUVRefracted - dispersedP2Neg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 q1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2Neg*0.75),
          childTexture, childUVRefracted - dispersedP2Neg*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
      vec3 q2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*0.25),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
      vec3 q3 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*0.8),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
      vec3 q4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*1.1),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 p2Neg = vec3(0.0);
      p2Neg.b = q0.b * 0.50 + q1.b * 0.50;
      p2Neg.g = q2.g;
      p2Neg.r = q3.r * 0.50 + q4.r * 0.50;
      pass2Color = p2Neg;
    } else {
      // Transition: compute negative and blend (5-tap)
      vec3 q0 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2Neg*1.1),
          childTexture, childUVRefracted - dispersedP2Neg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 q1 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV - dispersedP2Neg*0.75),
          childTexture, childUVRefracted - dispersedP2Neg*childCaScale*0.75, keyColor, glassColor, saturation, lightness);
      vec3 q2 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*0.25),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*0.25, keyColor, glassColor, saturation, lightness);
      vec3 q3 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*0.8),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*0.8, keyColor, glassColor, saturation, lightness);
      vec3 q4 = _compositeChildOnBg(_sampleTexture(backgroundTexture, refractedUV + dispersedP2Neg*1.1),
          childTexture, childUVRefracted + dispersedP2Neg*childCaScale*1.1, keyColor, glassColor, saturation, lightness);
      vec3 p2Neg = vec3(0.0);
      p2Neg.b = q0.b * 0.50 + q1.b * 0.50;
      p2Neg.g = q2.g;
      p2Neg.r = q3.r * 0.50 + q4.r * 0.50;
      pass2Color = mix(p2Neg, p2Pos, flipT);
    }
  }

  // Pass 2 (inverted) is base layer; Pass 1 (original CA) overpaints via edgeMask
  // edgeMask = 1 near edge → Pass 1 visible, edgeMask = 0 inside → Pass 2 visible
  // Pass 2 smooths via its mask (innerMask → 3px transition), Pass 1 has NO mask
  // Pass 2 at configurable opacity
  vec3 finalColor = mix(pass2Color, pass1Color, edgeMask);
  finalColor = mix(pass1Color, finalColor, uPass2Opacity);
  return vec4(finalColor, 1.0);
}


/// Computes the base refraction layer including background blending and texture displacement.
vec4 _calculateRefractionLayer(
    vec2 screenUV, vec3 normal, float signedDistance, float height, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec2 sizePixels, sampler2D backgroundTexture,
    sampler2D childTexture,
    vec2 childUVBase,
    vec3 keyColor,
    out vec2 outRefractionDisplacement,
    out vec4 outRawTexture,
    vec2 childRefractionDisplacement,
    int shapeIndex,
    float saturation,
    float lightness,
    vec4 glassColor,
    vec4 bgOverlay
) {
  vec3 incident = vec3(0.0, 0.0, -1.0);
  float n = max(refractiveIndex, 1.0001);
  vec3 refractVec = refract(incident, normal, 1.0 / n);

  float baseHeight = thickness * 8.0;
  float refractLength = (height + baseHeight) / max(0.001, abs(refractVec.z));

  // Optical uses full displacement (edgeFade in compositing handles the visual blending).
  vec2 opticalDisp = refractVec.xy * refractLength;

  // CA fade: 1.5px range — gives spectral samples enough spread at the edge.
  float refractFw = max(fwidth(signedDistance), 1e-6);
  float caFade = smoothstep(0.0, -1.5 * refractFw, signedDistance); // sd=-0.5→0.26, sd=-1.5→1.0
  float caLength = refractLength * caFade;
  vec2 caDisp = refractVec.xy * caLength;

  // No sub-pixel gate on optical — edgeFade handles the visual transition.
  outRefractionDisplacement = opticalDisp / sizePixels;

  // Kill sub-pixel refraction on CA path only.
  float caDispMag = length(caDisp);
  float caDispGate = smoothstep(0.0, 2.0, caDispMag);
  caDisp *= caDispGate;
  vec2 caRefractionDisplacement = caDisp / sizePixels;

  vec2 uvBase = screenUV + outRefractionDisplacement;
  vec2 uvChild = childUVBase + childRefractionDisplacement;

  float stretch = length(fwidth(opticalDisp));
  float blurRadius = clamp(stretch * 0.45, 0.0, 6.0);

  vec4 backgroundSample = _applyGaussianBlur(backgroundTexture, uvBase);
  outRawTexture = backgroundSample;

  // Apply background overlay before any tinting or color adjustment.
  if (bgOverlay.a > 0.001) {
    backgroundSample.rgb = mix(backgroundSample.rgb, bgOverlay.rgb, bgOverlay.a);
  }

  backgroundSample = _blendGlassTint(backgroundSample, glassColor);
  backgroundSample.rgb = _adjustColorBalance(backgroundSample.rgb, saturation, lightness);

  vec4 childSample = _blurJitterRefraction(childTexture, uvChild, blurRadius, sizePixels, uvChild);
  vec3 childRGB = childSample.rgb / max(childSample.a, 1.0e-4);

  float isIcon = _calculateIconMask(childRGB, keyColor);

  vec3 blendedRGB = _blendHardLight(backgroundSample.rgb, childRGB);
  vec3 finalBlend = mix(childRGB, blendedRGB, isIcon);

  backgroundSample.rgb = mix(backgroundSample.rgb, finalBlend, childSample.a);

  float ca = max(chromaticAberration, 0.0);
  float caIntensity = smoothstep(0.0, 1.0, ca); // smooth fade for CA on/off

  if (ca <= 0.001) {
    return vec4(clamp(backgroundSample.rgb, 0.0, 1.0), backgroundSample.a);
  }

  // Android-style 7-band spectral dispersion — uses CA displacement for more spread at edge.
  vec2 caUvBase = screenUV + caRefractionDisplacement;
  vec4 spectralColor = _resolveDispersion(
      caUvBase, uvChild, caRefractionDisplacement,
      sizePixels,
      backgroundTexture, childTexture, shapeIndex, ca,
      keyColor, saturation, lightness, glassColor,
      signedDistance, normal, thickness, refractiveIndex
  );

  // Edge feather: fade CA in with squared smoothstep.
  // 0.0 at sd=0, 0.26 at sd=-0.5, 1.0 at sd=-1.5.
  float caFw = max(fwidth(signedDistance), 1e-6);
  float edgeAA = smoothstep(0.0, -1.5 * caFw, signedDistance);

  // Boost the CA band colors (diff from background) + soft compressor
  vec3 caDiff = spectralColor.rgb - backgroundSample.rgb;
  float greenDom = 0.0; // disabled
  // Blue band brightening: boost intensity where blue is dominant (no color shift)
  float blueDom = smoothstep(0.0, 0.01, caDiff.b - max(caDiff.r, caDiff.g));
  caDiff *= mix(1.0, 1.15, blueDom);
  float hasCAThere = 0.0;
  vec3 biasDiff = vec3(0.0);

  // Soft compression: tanh compression + min range lift
  {
    float diffLen = length(caDiff);
    float maxR = max(uDispersionMaxRange, 0.001);
    float compressed = tanh(diffLen / maxR) * maxR;
    float lifted = max(compressed, min(diffLen, uDispersionMinRange));
    caDiff *= (diffLen > 0.001) ? (lifted / diffLen) : 0.0;
  }

  // --- Rim CA boost: brighten and saturate CA bands in the rim zone ---
  float rimGradCA = max(length(vec2(dFdx(signedDistance), dFdy(signedDistance))), 1e-6);
  float rimDepthCA = rimWidthPx * rimGradCA;
  float rimPadCA = 1.0 * rimGradCA;
  float rimZoneCA = smoothstep(-rimDepthCA, -rimPadCA, signedDistance);

  // Rim boost: noise gate
  if (rimZoneCA > 0.001) {
    float noiseThreshold = 0.008;
    float noiseGate = smoothstep(0.0, noiseThreshold, length(caDiff));
    caDiff *= noiseGate;
  }

  // Green spectral bias — band with smooth in/out fades
  float rimZoneGreen = 0.0;
  {
    float rimDepthGreen = (rimWidthPx + 3.0) * rimGradCA;

    // Outer fade in: 0.25 at sd=0, 0.71 at sd=-0.5, 1.0 at sd=-1
    float greenOuter = smoothstep(rimGradCA, -rimGradCA, signedDistance);
    greenOuter *= greenOuter;

    // Inner fade out: 0.25 at sd=-rimDepthGreen, 1.0 at sd=-rimDepthGreen+1
    float greenInner = smoothstep(-rimDepthGreen - rimGradCA, -rimDepthGreen + rimGradCA, signedDistance);
    greenInner *= greenInner;

    rimZoneGreen = greenOuter * greenInner;
    if (rimZoneGreen > 0.001 && rimCAGreenBias > 0.001) {
      float greenOnly = max(rimZoneGreen - rimZoneCA, 0.0);
      if (greenOnly > 0.001) {
        float noiseThreshG = 0.008 * max(rimCABrightness, 1.0);
        float noiseGateG = smoothstep(0.0, noiseThreshG, length(caDiff));
        caDiff *= mix(1.0, noiseGateG, greenOnly);
      }
      float caStrength = length(caDiff);
      float caDeficit = max(1.0 - caStrength * 20.0, 0.0);

      float _bType, _bRadius;
      vec2 _bCenterSdf, _bSizeSdf;
      _readShapeData(shapeIndex, _bType, _bCenterSdf, _bSizeSdf, _bRadius);
      vec2 _bCenterPx = _projectSdfToScreen(_bCenterSdf);
      vec2 _bCenterUV = _uvFromPx(_bCenterPx, sizePixels);
      vec2 _bCol0 = uTransform[0].xy;
      vec2 _bCol1 = uTransform[1].xy;
      float _bScaleX = max(length(_bCol0), 1e-6);
      float _bScaleY = max(length(_bCol1), 1e-6);
      vec2 _bHalfSizeUV = (_bSizeSdf / vec2(_bScaleX, _bScaleY)) * 0.5 / sizePixels;

      vec2 cUV = uvBase - _bCenterUV;
      vec2 sUV = vec2(
        cUV.x - cUV.y * uBiasFlipAngle,
        cUV.y - cUV.x * uBiasFlipAngleV
      );
      float rp = (sUV.x * sUV.y) / max(_bHalfSizeUV.x * _bHalfSizeUV.y, 1e-8);
      float biasFlip = smoothstep(-uBiasFlipBlend, uBiasFlipBlend, rp);
      float effectiveProbeDepth = max(uBiasProbeDepth, 6.0);
      float probeSD = -effectiveProbeDepth * rimGradCA;
      float probeHeight = _calculateLiquidHeight(probeSD, thickness);
      float probeRefractLen = (probeHeight + baseHeight) / max(0.001, abs(refractVec.z));
      vec2 probeRefrDisp = refractVec.xy * probeRefractLen / sizePixels;

      float currentDepthPx = -signedDistance / max(rimGradCA, 1e-6);
      float extraInwardPx = max(effectiveProbeDepth - currentDepthPx, 0.0);
      vec2 sdfGrad = vec2(dFdx(signedDistance), dFdy(signedDistance));
      vec2 probeInwardDir = -normalize(sdfGrad + vec2(1e-6));
      vec2 probeScreenPos = screenUV + probeInwardDir * extraInwardPx / sizePixels;
      vec2 probeUVBase = probeScreenPos + probeRefrDisp;

      float probeRefrLen2D = length(probeRefrDisp);
      vec2 probeDispDir;
      if (probeRefrLen2D > 1e-6) {
        probeDispDir = probeRefrDisp / probeRefrLen2D;
      } else {
        vec2 sdfGrad2 = vec2(dFdx(signedDistance), dFdy(signedDistance));
        probeDispDir = normalize(sdfGrad2 + vec2(1e-6));
      }
      float probeDispMag = probeRefractLen * chromaticAberration * 0.5 / length(sizePixels);
      vec2 probeDispersion = probeDispDir * probeDispMag;

      vec3 probeBgRed  = texture(backgroundTexture, probeUVBase + probeDispersion).rgb;
      vec3 probeBgBlue = texture(backgroundTexture, probeUVBase - probeDispersion).rgb;
      float probeCASignal = length(probeBgRed - probeBgBlue);
      hasCAThere = smoothstep(uBiasThreshLow, uBiasThreshHigh, probeCASignal);
      float greenAmount = rimZoneCA * hasCAThere;
      biasDiff.g += greenAmount * (biasFlip * 0.70 + (1.0 - biasFlip) * 0.30);
      biasDiff.b += greenAmount * ((1.0 - biasFlip) * 0.70 + biasFlip * 0.07);
      biasDiff.r -= greenAmount * (biasFlip * 0.30 + (1.0 - biasFlip) * 0.28);
    }
  }

  // Dispersion saturation + lift
  vec3 boostedSpectral = backgroundSample.rgb + caDiff * uDispersionSaturation;
  boostedSpectral += abs(caDiff) * uDispersionLift;

  // E: Soft min/max clamps
  // Soft min/max brightness/saturation clamps
  if (rimZoneCA > 0.001) {
    float specLum = dot(boostedSpectral, vec3(0.299, 0.587, 0.114));
    vec3 specChroma = boostedSpectral - vec3(specLum);
    float specChromaLen = length(specChroma);
    float minB = mix(0.0, rimCAMinBrightness, rimZoneCA) * hasCAThere;
    float maxB = rimCAMaxBrightness;
    float pullUp = smoothstep(minB, 0.0, specLum);
    specLum = mix(specLum, minB, pullUp);
    float kneeB = maxB * 0.8;
    if (specLum > kneeB) {
      float excess = specLum - kneeB;
      float range = maxB - kneeB;
      specLum = kneeB + range * tanh(excess / max(range, 0.001));
    }
    float minS = mix(0.0, rimCAMinSaturation, rimZoneCA) * hasCAThere;
    float maxS = rimCAMaxSaturation;
    float chromaPullUp = smoothstep(minS, 0.0, specChromaLen);
    float softChroma = mix(specChromaLen, minS, chromaPullUp);
    float kneeS = maxS * 0.8;
    if (softChroma > kneeS) {
      float excessS = softChroma - kneeS;
      float rangeS = maxS - kneeS;
      softChroma = kneeS + rangeS * tanh(excessS / max(rangeS, 0.001));
    }
    if (specChromaLen > 0.0001) {
      specChroma *= softChroma / specChromaLen;
    }
    boostedSpectral = vec3(specLum) + specChroma;
  }

  // Blend between non-CA result and spectral result at edge
  vec3 finalRGB = mix(backgroundSample.rgb, boostedSpectral, edgeAA * caIntensity * uCAOpacity);

  // Apply spectral bias — blended between dark/lit based on light facing
  float biasEdgeAA = smoothstep(0.0, 1.5 * rimGradCA, -signedDistance); // 0 at edge, full ~1.5px inside
  vec2 biasNDir = length(normal.xy) > 1e-6 ? normalize(normal.xy) : vec2(0.0);
  float biasFacingRaw = abs(dot(biasNDir, normalize(uLightDirection)));
  float biasFacing = smoothstep(uBiasDarkThreshLow, uBiasDarkThreshHigh, biasFacingRaw);
  float effectiveGreenBias = mix(rimCAGreenBiasDark, rimCAGreenBias, biasFacing);
  // Blend parameters between lit and dark based on facing
  float effectiveBright = mix(rimCABrightnessDark, rimCABrightness, biasFacing);
  float effectiveSat = mix(rimCASaturationDark, rimCASaturation, biasFacing);
  float biasOpacity = effectiveGreenBias * biasEdgeAA;
  float biasVis = smoothstep(uBiasVisLow, uBiasVisHigh, hasCAThere);
  biasOpacity *= biasVis;
  // Apply brightness and saturation to bias
  vec3 scaledBias = biasDiff * effectiveBright;
  float biasLum = dot(scaledBias, vec3(0.299, 0.587, 0.114));
  vec3 biasChroma = scaledBias - vec3(biasLum);
  scaledBias = vec3(biasLum) + biasChroma * effectiveSat;
  // Dark side hue shift: only on green-dominant side → warmer green, keep blue intact
  float isGreenSide = step(abs(scaledBias.b), abs(scaledBias.g)); // 1 if G > B
  float darkShift = isGreenSide * (1.0 - biasFacing); // only green side + dark
  scaledBias.b *= mix(1.0, 0.1, darkShift);
  scaledBias.r *= mix(1.0, 0.3, darkShift);
  // Dark side blue: reduce oversaturation
  float blueDarkShift = (1.0 - isGreenSide) * (1.0 - biasFacing);
  float blLum = dot(scaledBias, vec3(0.299, 0.587, 0.114));
  scaledBias = mix(scaledBias, vec3(blLum), blueDarkShift * 0.78);
  // Soft Light blend: darken background before adding bias
  float darkAmount = darkShift * rimZoneCA * biasVis;

  vec3 biasColor = vec3(0.0, rimCABrightnessDark, rimCABrightnessDark * 0.3);
  vec3 softDark = 2.0 * finalRGB * biasColor;
  vec3 softLight = 1.0 - 2.0 * (1.0 - finalRGB) * (1.0 - biasColor);
  vec3 softResult = mix(softDark, softLight, step(vec3(0.5), finalRGB));
  finalRGB = mix(finalRGB, softResult, darkAmount);
  // 2. Then add bias on top (stays vibrant)
  finalRGB = mix(finalRGB, finalRGB + scaledBias, biasOpacity);



  return vec4(clamp(finalRGB, 0.0, 1.0), backgroundSample.a);
}

/// Calculates the combined lighting effect including rim, ambient, and core highlight components.
vec3 _calculateTotalLighting(
    float signedDistance, float thickness,
    vec2 lightDirection, float lightIntensity, float ambientStrength,
    vec3 backgroundColor, float rimWidthPixels,
    RimMasks masks, vec2 nXyNormalized, float rimLightSpread
) {
  float thicknessFactor = smoothstep(5.0, 7.0, thickness);
  float effectiveIntensity = lightIntensity * lightIntensity;

  if (thicknessFactor < 0.01 || effectiveIntensity < 0.001) {
    return vec3(0.0);
  }

  float facingAmbient = abs(dot(nXyNormalized, lightDirection));
  float maskAmbient = masks.band * pow(facingAmbient, rimLightSpread);

  float facingTop = abs(nXyNormalized.y);
  float maskTop = masks.band * pow(facingTop, rimLightSpread);

  float verticalAlign = -nXyNormalized.y;
  float t = clamp(verticalAlign * 0.5 + 0.5, 0.0, 1.0);
  float highlightGradient = smoothstep(0.9, 1.0, t) * float(LG_RIM_TOP_HIGHLIGHT_STRENGTH);

  vec3 highlightColor = _computeAdaptiveHighlight(backgroundColor, 0.7);

  vec3 directionalRim = highlightColor * highlightGradient * effectiveIntensity;
  directionalRim *= maskTop;

  float ambientAlign = dot(nXyNormalized, -normalize(lightDirection));
  float tAmb = ambientAlign * 0.5 + 0.5;
  float ambientGrad = mix(0.92, 1.0, tAmb);

  vec3 ambientRimColor = _computeAdaptiveHighlight(backgroundColor, 0.4);
  vec3 ambientRim = ambientRimColor * ambientStrength * ambientGrad;
  ambientRim *= maskAmbient;

  vec3 lighting = (directionalRim + ambientRim);

  float whitePull = 0.55;
  float coreGain = mix(0.16, 0.36, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
  float effectiveCoreGain = masks.core * coreGain * effectiveIntensity * highlightGradient;

  vec3 towardWhite = mix(lighting, vec3(1.0), whitePull);
  lighting = mix(lighting, towardWhite, effectiveCoreGain);

  return lighting * thicknessFactor;
}

/// Identifies the optimal glow parameters for the current pixel based on active touch inputs.
bool _findBestGlowParams(
    vec2 positionSdf,
    int currentShapeIndex,
    out float outShapedValue,
    out GlowParams outParams
) {
  float bestShapedValue = 0.0;
  int bestDataIndex = -1;

  int count = int(uTouchCount_f);

  for (int i = 0; i < 8; ++i) {
    if (i >= count) break;

    int owner = int(floor(uTouchOwners[i] + 0.5));
    int dataSourceIndex = (owner >= 0) ? owner : currentShapeIndex;

    int baseIdx = dataSourceIndex * 4;
    vec4 d0 = uShapeGlowData[baseIdx + 0];
    vec4 d1 = uShapeGlowData[baseIdx + 1];
    vec4 d2 = uShapeGlowData[baseIdx + 2];
    vec4 d3 = uShapeGlowData[baseIdx + 3];

    float currentGlowStrength = d2.w;
    if (currentGlowStrength <= 0.0001) continue;

    int targetShape = (owner >= 0) ? owner : currentShapeIndex;
    float sdOwner = _sdShapeAt(targetShape, positionSdf);

    float widthAa = max(fwidth(sdOwner), 1e-6) * GLOW_OWNER_FEATHER_PX;
    float inShape = smoothstep(0.0, widthAa, -sdOwner + 0.67 * widthAa); // ~0.75 at sd=0

    if (inShape <= 1e-5) continue;

    vec4 touchParams = uTouches[i];
    float dist = length(positionSdf - touchParams.xy);
    float inner = touchParams.z;
    float outer = touchParams.z + max(touchParams.w, 1e-3);

    float radial = smoothstep(outer, inner, dist);
    float inputStrength = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
    float maskRaw = radial * inShape * inputStrength;

    if (maskRaw <= 0.0001) continue;

    float glowPower = max(d1.x, 0.0001);
    float glowMix = clamp(d1.y, 0.0, 1.0);

    float shaped = pow(maskRaw, glowPower) * currentGlowStrength * glowMix;
    shaped = clamp(shaped, 0.0, 1.0);

    if (shaped > bestShapedValue) {
      bestShapedValue = shaped;
      bestDataIndex = dataSourceIndex;

      outParams.strength = currentGlowStrength;
      outParams.power = glowPower;
      outParams.mixFactor = glowMix;
      outParams.lightMix = d2.x;
      outParams.satMix = d2.y;
      outParams.lightIntensity = d2.z;
      outParams.colorAlpha = d0.w;
      outParams.blurSigma = d1.z;
      outParams.tintColor = d0.rgb;
      outParams.glassTarget = d3;

    }
  }

  outShapedValue = bestShapedValue;
  return bestDataIndex != -1 && bestShapedValue > 0.001;
}

/// Applies interactive glow effects to the base color using touch interaction data.
vec4 _applyInteractiveGlow(
    vec4 coloredBase,
    vec4 refractColorBase,
    vec2 screenUV,
    vec2 refractionDisplacement,
    vec2 childUVBase,
    vec2 positionSdf,
    float signedDistance,
    int shapeIndex,
    vec2 size,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 lighting,
    float lightness,
    float saturation,
    vec3 backgroundColor
) {

  if (shapeIndex < 0 || uTouchCount_f <= 0.5) {
    return coloredBase;
  }

  float bestShapedValue;
  GlowParams params;

  if (!_findBestGlowParams(positionSdf, shapeIndex, bestShapedValue, params)) {
    return coloredBase;
  }


  float effectiveLight = (params.lightMix > -0.5) ? mix(lightness, params.lightMix, bestShapedValue) : lightness;
  float effectiveSat = (params.satMix > -0.5) ? mix(saturation, params.satMix, bestShapedValue) : saturation;
  vec4 effectiveGlass = mix(uGlassColor, params.glassTarget, bestShapedValue);

  vec4 refractLocal = refractColorBase;
  float extraSigma = (params.blurSigma > -0.5) ? max(params.blurSigma - uGlobalBlurSigma, 0.0) : 0.0;

  if (extraSigma > 0.01) {
    vec2 uvBase = screenUV + refractionDisplacement;
    refractLocal = _blurApprox9(backgroundTexture, uvBase, extraSigma, size);
    vec4 childColor = _sampleTexture(childTexture, childUVBase + refractionDisplacement);
    refractLocal = mix(refractLocal, childColor, childColor.a);
  }

  vec4 coloredLocal = _blendGlassTint(refractLocal, effectiveGlass);
  coloredLocal.rgb = _adjustColorBalance(coloredLocal.rgb, effectiveSat, effectiveLight);

  vec3 tint = _computeAdaptiveHighlight(backgroundColor, 1.0);
  vec4 tintGlass = vec4(tint, bestShapedValue * params.colorAlpha);
  coloredLocal = _blendGlassTint(coloredLocal, tintGlass);

  // Fade glow lighting boost at edge: no extra intensity at sd=0.
  float glowEdgeFw = max(fwidth(signedDistance), 1e-6);
  float glowLightFade = smoothstep(0.0, -2.0 * glowEdgeFw, signedDistance); // 0.0 at sd=0
  float fadedIntensity = mix(1.0, params.lightIntensity, glowLightFade);
  coloredLocal.rgb += lighting * fadedIntensity;

  return mix(coloredBase, coloredLocal, bestShapedValue);
}

/// Renders the complete liquid glass effect, composing refraction, lighting, and glow layers.
vec4 renderLiquidGlass(
    vec2 screenUV,
    vec2 childUVBase,
    vec2 position,
    vec2 size,
    float signedDistance,
    float thickness,
    float refractiveIndex,
    float chromaticAberration,
    vec4 glassColor,
    vec2 lightDirection,
    float lightIntensity,
    float ambientStrength,
    vec3 keyColor,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 normal,
    float foregroundAlpha,
    float saturation,
    float lightness,
    float rimWidthPixels,
    float rimLightSpread,

    int shapeIndex,
    float opacity,
    float childThickness,
    float childRefractiveIndex,
    vec3 childNormal,
    vec4 bgOverlay
) {
  vec4 backgroundColor = _sampleTexture(backgroundTexture, screenUV);

  if (foregroundAlpha < 0.001 || thickness < 0.01 || opacity < 0.001) {
    return backgroundColor;
  }

  float height = _calculateLiquidHeight(signedDistance, thickness);
  RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels);
  vec2 nXyNormalized = _safeNormalize(normal.xy);
  vec3 lighting = _calculateTotalLighting(
      signedDistance, thickness,
      lightDirection, lightIntensity, ambientStrength,
      backgroundColor.rgb, rimWidthPixels,
      masks, nXyNormalized,
      rimLightSpread
  );

  // Compute child-specific refraction displacement
  vec2 childRefractionDisplacement;
  {
    vec3 incident = vec3(0.0, 0.0, -1.0);
    float nChild = max(childRefractiveIndex, 1.0001);
    vec3 childRefractVec = refract(incident, childNormal, 1.0 / nChild);
    float childHeight = _calculateLiquidHeight(signedDistance, childThickness);
    float childBaseHeight = childThickness * 8.0;
    float childRefractLength = (childHeight + childBaseHeight) / max(0.001, abs(childRefractVec.z));
    vec2 childDispPx = childRefractVec.xy * childRefractLength;
    childRefractionDisplacement = childDispPx / size;
  }

  vec2 refractionDisplacement;
  vec4 rawRefractionTexture;

  vec4 refractColorBase = _calculateRefractionLayer(
      screenUV, normal, signedDistance, height, thickness,
      refractiveIndex, chromaticAberration,
      size, backgroundTexture,
      childTexture, childUVBase, keyColor,
      refractionDisplacement, rawRefractionTexture,
      childRefractionDisplacement,
      shapeIndex,
      saturation, lightness, glassColor,
      bgOverlay
  );

  // Fade glass modifications (tint, color balance, refraction) to backgroundColor at the edge.
  // Applied before lighting so the rim highlight is NOT faded.
  float edgeFw = max(fwidth(signedDistance), 1e-6);
  float edgeFade = smoothstep(-0.25 * edgeFw, -1.75 * edgeFw, signedDistance); // sd=-0.25→0, sd=-1→0.5, sd=-1.75→1.0
  refractColorBase.rgb = mix(backgroundColor.rgb, refractColorBase.rgb, edgeFade);

  refractColorBase.rgb += lighting;

  vec4 outColor = _applyInteractiveGlow(
      refractColorBase, rawRefractionTexture, screenUV, refractionDisplacement, childUVBase,
      position, signedDistance, shapeIndex, size, backgroundTexture, childTexture,
      lighting, lightness, saturation, backgroundColor.rgb
  );

  float baseAlpha = foregroundAlpha;
  float rimAlpha = masks.band;
  float mixAlpha = clamp(max(baseAlpha, rimAlpha), 0.0, 1.0) * opacity;

  return mix(backgroundColor, outColor, mixAlpha);
}
#endif