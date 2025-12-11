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
// Shape Data stride increased from 6 to 7 floats
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 7];

// Previous Location: 107 -> New Location: 123 (+16 offset)
layout(location = 123) uniform vec4 uBlurHeader;
layout(location = 124) uniform vec4 u_samples[50];

// Touch & Glow
#define MAX_TOUCHES 8
// Previous Location: 308 -> New Location: 324
layout(location = 324) uniform float uTouchCount_f;
layout(location = 325) uniform vec4 uTouches[MAX_TOUCHES];
layout(location = 333) uniform float uTouchOwners[MAX_TOUCHES];

layout(location = 341) uniform vec4 uGlowParams;
layout(location = 342) uniform vec4 uGlowColor;
layout(location = 343) uniform vec4 uGlowOverrides;
layout(location = 344) uniform vec4 uGlowFlags;
layout(location = 345) uniform vec4 uGlowGlass;
layout(location = 346) uniform float uGlobalBlurSigma;
layout(location = 347) uniform float uTouchGlowStrengths[MAX_TOUCHES];

// Previous Location: 339 -> New Location: 355
layout(location = 355) uniform vec2 uBgScale;
// Previous Location: 341 -> New Location: 357
layout(location = 357) uniform vec2 uNormalParams;

// ───────────────────── Projection Uniform ─────────────────────
// Previous Location: 409 -> New Location: 425
layout(location = 425) uniform vec4 uChildProjection;
// Previous Location: 413 -> New Location: 429
layout(location = 429) uniform vec2 uChildSize;

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

  // Scale Logic für Background (separat X/Y)
  vec2 s = max(uBgScale, vec2(1e-4));
  // Updated index stride to 7
  float cx = uShapeData[idx * 7 + 1];
  float cy = uShapeData[idx * 7 + 2];
  vec2 centerScreenPx = sdfToScreenPx(vec2(cx, cy));
  vec2 centerUV = centerScreenPx * invSize;
#ifdef IMPELLER_TARGET_OPENGLES
  centerUV.y = 1.0 - centerUV.y;
#endif

  vec2 scaledUV = centerUV + (screenUV - centerUV) / s;

  // ──────────────── Child UV Projection ────────────────
  vec2 childUVRaw = uChildProjection.xy + childUV; 

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