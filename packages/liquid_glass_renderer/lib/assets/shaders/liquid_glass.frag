// liquid_glass.frag — Liquid-Glass mit Kotlin-AA & -Normals (UNION-safe); CA/Dispersion in shared.glsl
#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ───────────────────── Packed header (fixed locations) ─────────────────────
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uGlassColor;
// uOpticalProps = (RI, CA, thickness, blend)
layout(location = 2) uniform vec4 uOpticalProps;
// uLightConfig = (angle, intensity, ambient, saturation)
layout(location = 3) uniform vec4 uLightConfig;
// uColorAdjust = (lightness, numShapes)
layout(location = 4) uniform vec2 uColorAdjust;
// vorcomputete Lichtrichtung: (cos, sin)
layout(location = 5) uniform vec2 uLightDirection;
// Transform vor SDF
layout(location = 6) uniform mat4 uTransform;
// Rim: (widthPx, sharpness)
layout(location = 10) uniform vec2 uRimParams;

// ───────────────────── Shapes (max 16; fixed location) ─────────────────────
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 6];

// ───────────────────── Blur uniforms (unchanged) ───────────────────────────
layout(location = 107) uniform vec4 uBlurHeader;
layout(location = 108) uniform vec4 u_samples[50];

// ───────────────────── Touch / Glow (unchanged) ────────────────────────────
#define MAX_TOUCHES 8
layout(location = 308) uniform float uTouchCount_f;
layout(location = 309) uniform vec4  uTouches[MAX_TOUCHES];
layout(location = 317) uniform float uTouchOwners[MAX_TOUCHES];

layout(location = 325) uniform vec4 uGlowParams;
layout(location = 326) uniform vec4 uGlowColor;
layout(location = 327) uniform vec4 uGlowOverrides;
layout(location = 328) uniform vec4 uGlowFlags;
layout(location = 329) uniform vec4 uGlowGlass;
layout(location = 330) uniform float uGlobalBlurSigma;
layout(location = 331) uniform float uTouchGlowStrengths[MAX_TOUCHES];

layout(location = 339) uniform float uBgScale;
layout(location = 340) uniform vec2  uNormalParams;

// ───────────────────── Textures / Output ───────────────────────────────────
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ───────────────────── Aliases ─────────────────────────────────────────────
float uRefractiveIndex     = uOpticalProps.x;
float uChromaticAberration = uOpticalProps.y;
float uThickness           = uOpticalProps.z;
float uBlend               = uOpticalProps.w;

float uLightIntensity      = uLightConfig.y;
float uAmbientStrength     = uLightConfig.z;
float uSaturation          = uLightConfig.w;

float uLightness           = uColorAdjust.x;
float uNumShapes           = uColorAdjust.y;

float rimWidthPx           = uRimParams.x;
float rimSharpness         = uRimParams.y;

// Z-Krümmung: Tunable Soft (wie bei dir)
float uNormalPlateauWidth  = uNormalParams.x;
float uNormalSoftness      = uNormalParams.y;

// ───────────────────── Includes ────────────────────────────────────────────
#include "shared.glsl"
#include "lg_union_sdf.glsl"

// ───────────────────── Kotlin-Style: AA & Union-Normals ────────────────────
#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

// Unnormalisierter Union-Gradient (wie „alt“), aber auf sdUnion
vec2 _unionGrad2_df(float sdUnion){
  // kein Vor-Normalisieren! |∇sdUnion| trägt die weiche Dämpfung im Blend.
  return vec2(dFdx(sdUnion), dFdy(sdUnion));
}

// 3D-Normale: XY aus *unnormalisiertem* ∇sdUnion; Z via Tunable-Soft
vec3 _buildNormal3_fromUnion(float sdUnion, vec2 grad2){
  float plateauWidth = uNormalPlateauWidth;
  float softness     = uNormalSoftness;
  float fullRange    = uThickness + plateauWidth;
  float t            = max(fullRange + sdUnion, 0.0) / max(fullRange, 1e-6);
  float n_cos        = pow(t, softness);
  float n_sin        = sqrt(max(0.0, 1.0 - n_cos * n_cos));

  // wie „alt“: erst am Ende 3D-normalisieren (behält |∇sd| als XY-Gewicht)
  return normalize(vec3(grad2 * n_cos, n_sin));
}

void main(){
  // Screen-Koords + UV (Impeller GLES-Flip)
  vec2 pScreen = FlutterFragCoord().xy;
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 screenUV = pScreen * invSize;
#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

  // Transformierte SDF-Koords
  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

  // UNION-SDF + aktiver Index
  int   idx;
  float sdUnion = sceneSDF_withIndex_fast(p, idx);

  // Kotlin-AA (~1px) auf Union-SDF
  float foregroundAlpha = smoothstep(0.0, AGSL_AA_WIDTH_PX,
                                     clamp(-sdUnion, 0.0, AGSL_AA_WIDTH_PX));
  if (foregroundAlpha < 0.01){
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  // Hintergrund-UV relativ zum Shape-Zentrum skalieren
  float s = max(uBgScale, 1e-4);
  vec2 centerUV = vec2(uShapeData[idx*6 + 1], uShapeData[idx*6 + 2]) * invSize;
#ifdef IMPELLER_TARGET_OPENGLES
  centerUV.y = 1.0 - centerUV.y;
#endif
  vec2 scaledUV = centerUV + (screenUV - centerUV) / s;

  // Normale: unnormalisierter Union-Gradient wie „alt“
  vec2 grad2 = _unionGrad2_df(sdUnion);
  vec3 normal = _buildNormal3_fromUnion(sdUnion, grad2);

  // Liquid-Glass-Pipeline (Dispersion/CA im shared.glsl)
  fragColor = renderLiquidGlass(
      scaledUV, p, uSize,
      sdUnion, uThickness,
      uRefractiveIndex, uChromaticAberration,
      uGlassColor, uLightDirection, uLightIntensity, uAmbientStrength,
      uBackgroundTexture, normal, foregroundAlpha,
      uSaturation, uLightness, rimWidthPx, rimSharpness,
      idx
  );
}
