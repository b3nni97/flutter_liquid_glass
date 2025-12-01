#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ───────────────────── Header ─────────────────────
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uGlassColor;
layout(location = 2) uniform vec4 uOpticalProps;
layout(location = 3) uniform vec4 uLightConfig;
layout(location = 4) uniform vec2 uColorAdjust;
layout(location = 5) uniform vec2 uLightDirection;
layout(location = 6) uniform mat4 uTransform;
layout(location = 10) uniform vec2 uRimParams;

// Shapes & Blur
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 6];
layout(location = 107) uniform vec4 uBlurHeader;
layout(location = 108) uniform vec4 u_samples[50];

// Touch & Glow
#define MAX_TOUCHES 8
layout(location = 308) uniform float uTouchCount_f;
layout(location = 309) uniform vec4 uTouches[MAX_TOUCHES];
layout(location = 317) uniform float uTouchOwners[MAX_TOUCHES];

layout(location = 325) uniform vec4 uGlowParams;
layout(location = 326) uniform vec4 uGlowColor;
layout(location = 327) uniform vec4 uGlowOverrides;
layout(location = 328) uniform vec4 uGlowFlags;
layout(location = 329) uniform vec4 uGlowGlass;
layout(location = 330) uniform float uGlobalBlurSigma;
layout(location = 331) uniform float uTouchGlowStrengths[MAX_TOUCHES];

layout(location = 339) uniform float uBgScale;
layout(location = 340) uniform vec2 uNormalParams;

// ───────────────────── Projection Uniform ─────────────────────
// xy = Offset (0..1), zw = Scale (⚠ wird in Dart so gesetzt,
//     dass screenUV in PIXELN hereinkommt)
layout(location = 409) uniform vec4 uChildProjection;
layout(location = 413) uniform vec2 uChildSize;

// ───────────────────── Textures ─────────────────────
uniform sampler2D uBackgroundTexture;
uniform sampler2D uBackgroundChildTexture;

layout(location = 0) out vec4 fragColor;

// ───────────────────── Aliases & Includes ─────────────────────
float uRefractiveIndex        = uOpticalProps.x;
float uChromaticAberration    = uOpticalProps.y;
float uThickness              = uOpticalProps.z;
float uBlend                  = uOpticalProps.w;
float uLightIntensity         = uLightConfig.y;
float uAmbientStrength        = uLightConfig.z;
float uSaturation             = uLightConfig.w;
float uLightness              = uColorAdjust.x;
float uNumShapes              = uColorAdjust.y;
float rimWidthPx              = uRimParams.x;
float rimSharpness            = uRimParams.y;
float uNormalPlateauWidth     = uNormalParams.x;
float uNormalSoftness         = uNormalParams.y;

#include "shared.glsl"
#include "lg_union_sdf.glsl"

#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

vec2 _unionGrad2_df(float sdUnion) {
  return vec2(dFdx(sdUnion), dFdy(sdUnion));
}

vec3 _buildNormal3_fromUnion(float sdUnion, vec2 grad2) {
  float plateauWidth = uNormalPlateauWidth;
  float softness = uNormalSoftness;
  float fullRange = uThickness + plateauWidth;
  float t = max(fullRange + sdUnion, 0.0) / max(fullRange, 1e-6);
  float n_cos = pow(t, softness);
  float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
  return normalize(vec3(grad2 * n_cos, n_sin));
}

void main() {
  // Lokale Fragment-Koordinate im ClipRect (in Device-Pixeln)
  vec2 pScreen = FlutterFragCoord().xy;

  // WICHTIG:
  // In deinem bisherigen Setup ist uSize anscheinend entweder 0 oder identisch
  // mit der Clip-Größe, so dass:
  //   invSize = 1.0
  // → screenUV == pScreen (Pixel-Koordinaten)
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 screenUV = pScreen * invSize;

  vec2 invChildSize = vec2(1.0) / max(uChildSize, vec2(1.0));
  vec2 childUV = pScreen * invChildSize;

#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
  childUV.y = 1.0 - childUV.y;
#endif

  // p: globale Device-Pixel-Koordinate relativ zum Layer-Ursprung
  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

  // Signed Distance Field im globalen SDF-Space (Device-Pixel)
  int idx;
  float sdUnion = sceneSDF_withIndex_fast(p, idx);

  float foregroundAlpha = smoothstep(
    0.0,
    AGSL_AA_WIDTH_PX,
    clamp(-sdUnion, 0.0, AGSL_AA_WIDTH_PX)
  );

  // Hintergrund-Sampling
  vec4 src = texScreen(uBackgroundTexture, screenUV);
  if (foregroundAlpha < 0.01) {
    fragColor = src;
    return;
  }

  // Scale Logic für Background
  float s = max(uBgScale, 1e-4);
  float cx = uShapeData[idx * 6 + 1];
  float cy = uShapeData[idx * 6 + 2];
  vec2 centerScreenPx = sdfToScreenPx(vec2(cx, cy));
  vec2 centerUV = centerScreenPx * invSize;
#ifdef IMPELLER_TARGET_OPENGLES
  centerUV.y = 1.0 - centerUV.y;
#endif

  vec2 scaledUV = centerUV + (screenUV - centerUV) / s;

  // ──────────────── Child UV Projection ────────────────
  // screenUV ist hier (effektiv) in PIXELN.
  // uChildProjection wird in Dart so gesetzt, dass:
  //   childUVRaw = (bounds.left / layerW, bounds.top / layerH)
  //              + screenUV * (1 / layerW, 1 / layerH)
  // → also globale Layer-UVs (0..1) für das backgroundChild.
vec2 childUVRaw =  uChildProjection.xy + childUV;// * uChildProjection.zw;


  vec2 grad2 = _unionGrad2_df(sdUnion);
  vec3 normal = _buildNormal3_fromUnion(sdUnion, grad2);

  fragColor = renderLiquidGlass(
    scaledUV,       // UV für Background (gezoomt)
    childUVRaw,     // UV für backgroundChild
    p,
    uSize,
    sdUnion,
    uThickness,
    uRefractiveIndex,
    uChromaticAberration,
    uGlassColor,
    uLightDirection,
    uLightIntensity,
    uAmbientStrength,
    uBackgroundTexture,
    uBackgroundChildTexture,
    normal,
    foregroundAlpha,
    uSaturation,
    uLightness,
    rimWidthPx,
    rimSharpness,
    idx
  );
}
