// liquid_glass.frag — Packed locations; blur uniforms moved after uShapeData (106/107)
#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ───────────────────── Packed header (fixed locations) ─────────────────────
// Set by Flutter: logical device size in device pixels (width, height).
layout(location = 0) uniform vec2 uSize;
// RGBA tint applied to the glass.
layout(location = 1) uniform vec4 uGlassColor;
// Optical properties: refractive index (RI), chromatic aberration (CA),
// effective thickness (px), and blend factor for shape unions.
layout(location = 2) uniform vec4 uOpticalProps;
// Lighting configuration: light angle (rad), intensity, ambient strength,
// and color saturation multiplier.
layout(location = 3) uniform vec4 uLightConfig;
// Color adjustments: lightness and number of shapes (as float).
layout(location = 4) uniform vec2 uColorAdjust;
// Precomputed light direction: cos(angle), sin(angle).
layout(location = 5) uniform vec2 uLightDirection;
// Transform applied to FragCoord before SDF evaluation.
layout(location = 6) uniform mat4 uTransform;
// Rim configuration: rim width and rim sharpness.
layout(location = 10) uniform vec2 uRimParams;

// ───────────────────── Shapes (max 16; fixed location) ─────────────────────
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 6];
// Layout per shape: (type, centerX, centerY, sizeW, sizeH, cornerRadius)
// Consumes 96 floats for 16 shapes → locations 11..106

// ───────────────────── Blur uniforms (after uShapeData) ────────────────────
// Next free location is 106
layout(location = 107) uniform vec4 uBlurHeader;
// x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

// Samples start at 108 (50 * vec4 → locations 108..307)
layout(location = 108) uniform vec4 u_samples[50];

// ───────────────────── Touch / Glow (after samples; fixed) ─────────────────
#define MAX_TOUCHES 8
// float-Count (wird zu int gecastet)
layout(location = 308) uniform float uTouchCount_f;
// uTouches[i] = (x_px, y_px, radius_px, fade_px)
layout(location = 309) uniform vec4  uTouches[MAX_TOUCHES];
// NEU: pro-Touch Owner-Index (-1 = global, sonst Shape-Index)
layout(location = 317) uniform float uTouchOwners[MAX_TOUCHES];

// Glow: x=strength, y=power, z=tintMode(0=weiß,1=hintergrund,2=festeFarbe), w=insideOnly(0/1)
layout(location = 325) uniform vec4 uGlowParams;
// Optional (nur wenn tintMode==2) – A enthält hier die Tint-Intensität
layout(location = 326) uniform vec4 uGlowColor;

// ──────── NEU: Overrides aus GlowStyle (passen zu shared.glsl) ─────────────
// (lightness, saturation, blurSigmaPx, mix)
layout(location = 327) uniform vec4 uGlowOverrides;
// (hasLightness, hasSaturation, hasBlur, hasGlassColor) → 0.0/1.0
layout(location = 328) uniform vec4 uGlowFlags;
// lokale Glasfarbe für den Glow-Bereich
layout(location = 329) uniform vec4 uGlowGlass;
// globaler Basis-Blur (Sigma, px) – wird für Delta-Blur in shared.glsl genutzt
layout(location = 330) uniform float uGlobalBlurSigma;

// NEU: per-touch Glow-Multiplikatoren (0..1)
layout(location = 331) uniform float uTouchGlowStrengths[MAX_TOUCHES];

// ───────────────────── Textures / Output ───────────────────────────────────
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ───────────────────── Aliases extracted from packed vectors ───────────────
float uRefractiveIndex     = uOpticalProps.x;
float uChromaticAberration = uOpticalProps.y;
float uThickness           = uOpticalProps.z;
float uBlend               = uOpticalProps.w;

float uLightAngle          = uLightConfig.x;
float uLightIntensity      = uLightConfig.y;
float uAmbientStrength     = uLightConfig.z;
float uSaturation          = uLightConfig.w;

float uLightness           = uColorAdjust.x;
float uNumShapes           = uColorAdjust.y;

float rimWidthPx           = uRimParams.x;
float rimSharpness         = uRimParams.y;

// ───────────────────── Include shared helpers *after* uniforms ─────────────
#include "shared.glsl"
// ↓↓↓ NEU: SDF/Smooth-Union + sceneSDF aus ausgelagerter Library
#include "lg_union_sdf.glsl"

// ============================================================================
// Small performance-related defines
// ============================================================================
#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

#ifdef NORMAL_MODE
#undef NORMAL_MODE
#endif
#define NORMAL_MODE 0

// Fast normalizers (avoid sqrt where possible).
vec2 fastNormalize2(vec2 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}
vec3 fastNormalize3(vec3 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

// ============================================================================
// Normals — fast path
// ============================================================================
// MODIFIED: Replaced heuristic logic with the blend-safe "Tunable Soft" method.
vec3 getNormal(float sd, float thickness, int idx){
  // This version is safe for smooth unions and produces a soft, adjustable curve.
  float dx = dFdx(sd);
  float dy = dFdy(sd);

  // Tuned values from your final configuration for the desired look.
  const float plateauWidth = 24.0;
  const float softness = 1.8;

  // Calculate the normal's curvature with a central plateau.
  float fullRange = thickness + plateauWidth;
  float t = max(fullRange + sd, 0.0) / max(fullRange, 1e-6);
  float n_cos = pow(t, softness);
  float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
  
  return normalize(vec3(dx * n_cos, dy * n_cos, n_sin));
}

void main(){
  vec2 pScreen = FlutterFragCoord().xy + vec2(0.5);
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 screenUV = pScreen * invSize;

#ifdef IMPELLER_TARGET_OPENGLES
  // OpenGLES uses inverted Y; flip to match texture space.
  screenUV.y = 1.0 - screenUV.y;
#endif

  // Transform the coordinate space before SDF evaluation.
  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

  int   idx;
  float sd  = sceneSDF_withIndex_fast(p, idx);

  // Foreground matte coverage from signed distance.
  float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
  if (foregroundAlpha < 0.01){
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  vec3 normal = getNormal(sd, uThickness, idx);

  // Final shaded/refraction color – volle Logik (inkl. Glow/Overrides) liegt in shared.glsl
  fragColor = renderLiquidGlass(
      screenUV, p, uSize,
      sd, uThickness,
      uRefractiveIndex, uChromaticAberration,
      uGlassColor, uLightDirection, uLightIntensity, uAmbientStrength,
      uBackgroundTexture, normal, foregroundAlpha,
      uSaturation, uLightness, rimWidthPx, rimSharpness,
      idx // <- NEU: aktiver Shape-Index für per-Shape Touch-Ownership
  );
}