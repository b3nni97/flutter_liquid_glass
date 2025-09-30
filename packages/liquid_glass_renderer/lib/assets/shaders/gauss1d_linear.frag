#version 320 es
precision highp float;
#include <flutter/runtime_effect.glsl>

// =================== Tunables ===================
#ifndef STRICT_H_ONLY
#define STRICT_H_ONLY 0        // 1 = force horizontal only (du = (du.x, 0))
#endif
#ifndef SAMPLER_CLAMP
#define SAMPLER_CLAMP 1        // 1 = clamp 0..1, 0 = mirror
#endif
#ifndef ENABLE_BILATERAL
#define ENABLE_BILATERAL 0     // 1 = edge-aware weighting
#endif
#ifndef BILATERAL_RANGE_SIGMA
#define BILATERAL_RANGE_SIGMA 0.18 // ~0.12..0.25 for UI text
#endif
#ifndef MAX_SAMPLES
#define MAX_SAMPLES 64
#endif
#ifndef DEBUG_DRAW
#define DEBUG_DRAW 0           // 1 = magenta Kreuz & Border einblenden
#endif
// =================================================

// ---- Uniform layout (Screen-UV / SCREEN SIZE IN PIXELS) ---------------
// 0: uSizeW (screen width  in pixels matching FlutterFragCoord space)
// 1: uSizeH (screen height in pixels matching FlutterFragCoord space)
// 2: uSampleCount
// 3: uOriginX (reserved / optional)
// 4: uOriginY (reserved / optional)
// 5..: uKernel[i] = vec3(dx_uv, dy_uv, weight)  -- dx_uv,dy_uv in SCREEN-UV
layout(location=0) uniform float uSizeW;
layout(location=1) uniform float uSizeH;
layout(location=2) uniform float uSampleCount;
layout(location=3) uniform float uOriginX; // currently unused
layout(location=4) uniform float uOriginY; // currently unused
layout(location=5) uniform vec3  uKernel[MAX_SAMPLES];

uniform sampler2D uBackgroundTexture;
layout(location=0) out vec4 fragColor;

// ---------------- helpers ----------------
vec3  toLin(vec3 s){ return pow(max(s, vec3(0.0)), vec3(2.2)); }
vec3  toSR (vec3 l){ return pow(max(l, vec3(0.0)), vec3(1.0/2.2)); }
float lumaLin(vec3 l){ return dot(l, vec3(0.2126, 0.7152, 0.0722)); }

vec2 clamp01(vec2 uv){ return clamp(uv, vec2(0.0), vec2(1.0)); }
float mirror1(float x){ float m = mod(x, 2.0); return (m <= 1.0) ? m : 2.0 - m; }
vec2 mirror01(vec2 uv){ return vec2(mirror1(uv.x), mirror1(uv.y)); }

#if SAMPLER_CLAMP
  vec4 texSample(sampler2D t, vec2 uv){ return texture(t, clamp01(uv)); }
#else
  vec4 texSample(sampler2D t, vec2 uv){ return texture(t, mirror01(uv)); }
#endif

void main() {
  // Screen-UV with pixel center and GLES y-flip
  vec2 screen = vec2(uSizeW, uSizeH);
  vec2 uv = (FlutterFragCoord().xy + vec2(0.5)) / screen;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // Center sample (for bilateral reference only)
  vec3 centerLin = toLin(texSample(uBackgroundTexture, uv).rgb);

  int   sampleCount = int(uSampleCount + 0.5);
  vec3  acc  = vec3(0.0);
  float wsum = 0.0;

#if ENABLE_BILATERAL
  // precompute bilateral factor denom
  float inv2Range = 0.5 / (BILATERAL_RANGE_SIGMA * BILATERAL_RANGE_SIGMA);
  float centerY   = lumaLin(centerLin);
#endif

  // Accumulate H-pass (includes center as uKernel[0])
  for (int i=0; i<MAX_SAMPLES; ++i) {
    if (i >= sampleCount) break;

    vec3 k = uKernel[i];
    vec2 du = k.xy;
#if STRICT_H_ONLY
    du = vec2(du.x, 0.0);
#endif
    float w = k.z;
    if (w <= 1e-6) continue;

    vec3 sLin = toLin(texSample(uBackgroundTexture, uv + du).rgb);

#if ENABLE_BILATERAL
    float dl = lumaLin(sLin) - centerY;        // luminance difference (linear)
    float wr = exp( - (dl*dl) * inv2Range );   // range weight
    float wEff = w * wr;
#else
    float wEff = w;
#endif

    acc  += sLin * wEff;
    wsum += wEff;
  }

  vec3 outLin = (wsum > 1e-6) ? (acc / wsum) : centerLin;
  fragColor = vec4(toSR(outLin), 1.0);

#if DEBUG_DRAW
  // Magenta-Kreuz + Rahmen als Overlay (nur visuelles Debug)
  float w = 0.003; // line thickness in UV
  float vLine  = step(abs(uv.x - 0.5), w);
  float hLine  = step(abs(uv.y - 0.5), w);
  float border = float(uv.x < 0.01 || uv.x > 0.99 || uv.y < 0.01 || uv.y > 0.99);
  float mask   = clamp(vLine + hLine + border, 0.0, 1.0);
  fragColor = mix(fragColor, vec4(1.0, 0.0, 0.8, 1.0), mask);
#endif
}
