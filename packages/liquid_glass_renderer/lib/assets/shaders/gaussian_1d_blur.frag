#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;
precision mediump int;

// ─── 1. Essential Properties (Compact Layout) ───
uniform vec2 uSize;           // Index 0
uniform vec4 uOpticalProps;   // Index 2 (Thickness, Blend für SDF nötig)
uniform vec2 uColorAdjust;    // Index 6 (NumShapes für SDF nötig)

// Indizes 10, 12, 14, ... entfallen hier (Licht, Farbe etc.)

// ─── 2. Shape Data ───
#define MAX_SHAPES 8
// Start: Index 24 (8 + 16)
uniform float uShapeData[MAX_SHAPES * 7];

// ─── 3. Blur Settings ───
// Start: Index 80 (24 + 56)
uniform vec4 uBlurHeader;   

#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)
// Start: Index 84
uniform vec4 u_samples[24];   

// ─── Samplers ───
uniform sampler2D uBackgroundTexture;

out vec4 fragColor;

// ───────────────────── DEFINES (Fix für Includes) ────────────────────────────
// WICHTIG: #define statt float, damit das Include die Werte sieht.
#define uThickness (uOpticalProps.z)
#define uBlend     (uOpticalProps.w)
#define uNumShapes (uColorAdjust.y)

// ───────────────────── Helper ────────────────────────────────────────────────
vec2 _mirror01(vec2 uv){
  vec2 m = mod(uv, 2.0);
  return mix(m, 2.0 - m, step(1.0, m));
}

vec4 _sample_screen_clamped(vec2 uv) {
    // Berechne Epsilon basierend auf Pixelgröße, um Kantenflimmern zu vermeiden
    vec2 eps = vec2(0.5) / max(uSize, vec2(1.0));
    vec2 clampedUV = clamp(uv, eps, vec2(1.0) - eps);
    return texture(uBackgroundTexture, clampedUV);
}


// ───────────────────── 1D Blur Logic ───────────────────────────────────────
vec4 _blur1D(vec2 baseUV){
  vec2 invSize  = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 step_vec = vec2(u_dir_x * invSize.x, u_dir_y * invSize.y);

  if (!(u_sample_count > 0.5)) {
    return _sample_screen_clamped(baseUV);
  }
  int nS = int(u_sample_count + 0.5);

  vec4 sum = vec4(0.0);
  
  // UNROLL FRIENDLY LOOP
  for (int i = 0; i < 24; ++i) {
    if (i >= nS) break;
    float t = u_samples[i].x;
    float w = u_samples[i].z;
    
    // Einfach Sample + Weight. Kein If, kein TileMode Call.
    sum += w * _sample_screen_clamped(baseUV + step_vec * t);
  }
  return sum;
}
// ───────────────────── SDF Include ─────────────────────────────────────────
#include "lg_union_sdf.glsl"

// ───────────────────── Main ────────────────────────────────────────────────
void main(){
  vec2 pScreen = FlutterFragCoord().xy;
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 uv = pScreen * invSize;

  #ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
  #endif

  vec2 p = pScreen; 

  int dummyIdx;
  float sd = sceneSDF_withIndex_fast(p, dummyIdx);
  float mask = lg_foreground_alpha(sd);

  vec4 src = _sample_screen_clamped(uv);

  if (mask < 0.001) {
    fragColor = src;
    return;
  }

  vec4 blurred = _blur1D(uv);
  fragColor = mix(src, blurred, mask);
}