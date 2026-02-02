// gaussian_1d_blur.frag — FINAL (Updated for 7-float stride)
// H/V 1D Blur (index-stabil, liquid_glass.frag-kompatibel)

#version 320 es
#include <flutter/runtime_effect.glsl>
precision mediump float;
precision mediump int;

// ───────────────────── Header ────────────────────────────────────────────────
layout(location = 0)  uniform vec2 uSize;
layout(location = 1)  uniform vec4 uGlassColor;
layout(location = 2)  uniform vec4 uOpticalProps; // x=RI, y=CA, z=thickness, w=blend
layout(location = 3)  uniform vec4 uLightConfig;
layout(location = 4)  uniform vec2 uColorAdjust;  // x=lightness, y=numShapes
layout(location = 5)  uniform vec2 uLightDirection;
layout(location = 6)  uniform mat4 uTransform;    // Wird ignoriert (Identity)
layout(location = 10) uniform vec2 uRimParams;

#define MAX_SHAPES 16
// UPDATE: Stride is now 7 floats
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 7];

// ───────────────────── Blur Header ───────────────────────────────────────────
// UPDATE: Shifted location 107 -> 123 (+16)
layout(location = 123) uniform vec4 uBlurHeader;
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

layout(location = 124) uniform vec4 u_samples[50];

// ───────────────────── Texture / Output ────────────────────────────────────
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

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

// Verhindert DCE (Dead Code Elimination) für ungenutzte Uniforms
void _preserve_header_uniforms(vec2 uv){
  if (uGlassColor.w > 2e9) fragColor += 0.001;
  // uTransform anfassen, damit es nicht wegoptimiert wird
  if (uTransform[0][0] > 2e9) fragColor += 0.001; 
  if (uBlurHeader.w > 2e9) fragColor += 0.001;
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
  for (int i = 0; i < 50; ++i) {
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

  _preserve_header_uniforms(uv);

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