// gaussian_1d_blur.frag — H/V 1D Blur (index-stabil, liquid_glass.frag-kompatibel)
// - Gleiche Uniform-Präambel + Reihenfolge wie liquid_glass.frag bis uShapeData.
// - Präambel-Uniforms werden minimal „verbraucht“, damit sie nicht wegoptimiert werden.
// - Danach: uBlurHeader @107, u_samples @108 → Dart-Indizes 132/136 bleiben korrekt.
// - Keine Abhängigkeit zu shared.glsl; Tiling + 1D-Gauss lokal implementiert.
// - Maske kommt aus lg_union_sdf.glsl und wird für weiches Mischen genutzt.
//
// LG_DEBUG_MODE: 0=normal (Maske + Blur), 1=Panel, 2=Single-Check (LG_CHECK)

#version 320 es
#include <flutter/runtime_effect.glsl>
precision mediump float;
precision mediump int;

#ifndef LG_DEBUG_MODE
#define LG_DEBUG_MODE 0
#endif
#ifndef LG_CHECK
#define LG_CHECK 0
#endif

// ───────────────────── Packed header (1:1 zu liquid_glass.frag) ────────────
layout(location = 0)  uniform vec2 uSize;
layout(location = 1)  uniform vec4 uGlassColor;
layout(location = 2)  uniform vec4 uOpticalProps;     // x=RI,y=CA,z=thickness,w=blend
layout(location = 3)  uniform vec4 uLightConfig;       // x=angle,y=intensity,z=ambient,w=saturation
layout(location = 4)  uniform vec2 uColorAdjust;       // x=lightness,y=numShapes
layout(location = 5)  uniform vec2 uLightDirection;    // cos,sin
layout(location = 6)  uniform mat4 uTransform;
layout(location = 10) uniform vec2 uRimParams;         // width, sharpness

#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 6]; // 96 floats → 11..106

// ───────────────────── Blur header & Samples (wie im Main) ─────────────────
layout(location = 107) uniform vec4 uBlurHeader;
// x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

layout(location = 108) uniform vec4 u_samples[50];

// ───────────────────── Texture / Output ────────────────────────────────────
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ───────────────────── Aliases (wie im Main-Shader) ────────────────────────
// lg_union_sdf.glsl greift auf diese Namen zu:
float uThickness = uOpticalProps.z;
float uBlend     = uOpticalProps.w;
float uNumShapes = uColorAdjust.y;

// ───────────────────── Helpers ─────────────────────────────────────────────
vec2 _mirror01(vec2 uv){
  vec2 m = mod(uv, 2.0);
  return mix(m, 2.0 - m, step(1.0, m));
}
vec2 _tile_uv(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    vec2 eps = 0.5 / max(size, vec2(1.0));
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv);
  } else if (mode < 2.5) {
    return _mirror01(uv);
  } else {
    return uv; // decal
  }
}
vec4 _sample_screen(vec2 uv){
  if (u_tile_mode >= 2.5) { // decal: OOB → transparent
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
      return vec4(0.0);
    }
  }
  return texture(uBackgroundTexture, _tile_uv(uv, uSize, u_tile_mode));
}

// Minimale Nutzung der Präambel-Uniforms, damit sie nicht wegoptimiert werden.
void _preserve_header_uniforms(vec2 uv){
  if (uGlassColor.w > 2e9) {
    fragColor.rgb += uGlassColor.rgb * 0.0;
  }
  if (uOpticalProps.x > 2e9) {
    fragColor.rg += vec2(uOpticalProps.z, uOpticalProps.w) * 0.0;
  }
  if (uLightConfig.y > 2e9) {
    fragColor.b += uLightConfig.x * 0.0 + uColorAdjust.x * 0.0 + uLightDirection.x * 0.0;
  }
  if (uRimParams.x > 2e9) {
    fragColor.g += (uTransform[0][0] + uRimParams.y) * 0.0;
  }
  float firstShape = uShapeData[0];
  fragColor.r += firstShape * (uv.x - uv.x); // no-op, aber verhindert DCE
}

// ───────────────────── 1D Gaussian (host-normalisierte Gewichte) ───────────
vec4 _blur1D(vec2 baseUV){
  vec2 invSize  = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 step_vec = vec2(u_dir_x * invSize.x, u_dir_y * invSize.y);

  if (!(u_sample_count > 0.5)) {
    return _sample_screen(baseUV);
  }
  int nS = int(u_sample_count + 0.5);

  vec4 sum = vec4(0.0);
  for (int i = 0; i < 50; ++i) {
    if (i >= nS) break;
    float t = u_samples[i].x;  // Offset (px) entlang Achse
    float w = u_samples[i].z;  // Gewicht (host-normalisiert)
    sum += w * _sample_screen(baseUV + step_vec * t);
  }
  return sum; // Keine Division nötig, Gewichte sind normalisiert
}

// ───────────────────── Diagnose (optional) ─────────────────────────────────
bool _finite(float v){ return !(isnan(v) || isinf(v)); }
bool _finite2(vec2 v){ return _finite(v.x) && _finite(v.y); }
bool _finite4(vec4 v){ return _finite(v.x)&&_finite(v.y)&&_finite(v.z)&&_finite(v.w); }
bool _finiteMat4(mat4 m){
  return _finite4(m[0]) && _finite4(m[1]) && _finite4(m[2]) && _finite4(m[3]);
}
float _kernelSum(){
  if (!(u_sample_count > 0.5)) return 0.0;
  int nS = int(u_sample_count + 0.5);
  float s = 0.0;
  for (int i = 0; i < 50; ++i) {
    if (i >= nS) break;
    s += u_samples[i].z;
  }
  return s;
}
vec3 okC()   { return vec3(0.180, 0.800, 0.250); } // grün
vec3 warnC() { return vec3(0.980, 0.800, 0.120); } // gelb
vec3 badC()  { return vec3(0.900, 0.150, 0.150); } // rot
vec3 _diagnosticColor(int idx){
  if (idx == 0) { bool ok = _finite2(uSize) && all(greaterThan(uSize, vec2(0.5))); return ok?okC():badC(); }
  if (idx == 1) { float mag = abs(u_dir_x)+abs(u_dir_y); return (mag>0.0)?okC():badC(); }
  if (idx == 2) { return (u_sample_count>0.5)?okC():badC(); }
  if (idx == 3) { float ks=_kernelSum(); if(ks==0.0)return badC(); if(ks>0.5&&ks<1.5)return okC(); return warnC(); }
  if (idx == 4) { bool ok=(u_tile_mode>=-0.5)&&(u_tile_mode<=3.5); return ok?okC():badC(); }
  if (idx == 5) { return _finiteMat4(uTransform)?okC():badC(); }
  if (idx == 6) { vec4 s=_sample_screen(vec2(0.5)); float l=dot(s.rgb,vec3(0.299,0.587,0.114))+s.a; return (l>0.001)?okC():badC(); }
  if (idx == 7) { vec2 inv=vec2(1.0)/max(uSize,vec2(1.0)); vec2 st=vec2(u_dir_x*inv.x,u_dir_y*inv.y); float m=abs(st.x)+abs(st.y); return (m>0.0)?okC():badC(); }
  if (idx == 8) { return _finite(uColorAdjust.y)?okC():badC(); } // numShapes steckt hier
  return warnC();
}

// ───────────────────── SDF / Smooth-Union (Maske) ──────────────────────────
#include "lg_union_sdf.glsl"

// ───────────────────── Main ────────────────────────────────────────────────
void main(){
  // Device-space Pixel +0.5 (wie im Main-Pass)
  vec2 pScreen = FlutterFragCoord().xy + vec2(0.5);
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 uv = pScreen * invSize;

#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // Präambel-Uniforms konservieren (verhindert DCE/Indexverschiebung)
  _preserve_header_uniforms(uv);

#if LG_DEBUG_MODE == 2
  fragColor = vec4(_diagnosticColor(LG_CHECK), 1.0);
  return;
#elif LG_DEBUG_MODE == 1
  float split = 0.33;
  if (uv.x < split) {
    int idx = int(floor(clamp(uv.y, 0.0, 0.999) * 9.0));
    fragColor = vec4(_diagnosticColor(idx), 1.0);
    return;
  }
  vec2 uvR = vec2((uv.x - split) / (1.0 - split), uv.y);
  // oben Original, unten reiner 1D-Blur (ohne Maske) zum Vergleichen
  if (uvR.y < 0.5) fragColor = _sample_screen(vec2(uvR.x, uvR.y * 2.0));
  else             fragColor = _blur1D(vec2(uvR.x, (uvR.y - 0.5) * 2.0));
  return;
#endif

  // ── Normale Ausgabe: Blur innerhalb der weichen Maske ─────────────────────
  // Transformierte Koordinate für SDF (wie im Main-Pass).
  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

  int dummyIdx;
  float sd = sceneSDF_withIndex_fast(p, dummyIdx);
  float mask = lg_foreground_alpha(sd);

  if (mask < 0.001) {
    // Außerhalb → unverändert
    fragColor = _sample_screen(uv);
    return;
  }

  vec4 src     = _sample_screen(uv);
  vec4 blurred = _blur1D(uv);            // H- oder V-Pass je nach u_dir_*

  fragColor = mix(src, blurred, mask);   // weiches Einblenden (wie Glas-Shader)
}
