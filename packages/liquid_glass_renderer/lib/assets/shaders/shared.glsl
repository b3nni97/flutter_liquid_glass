// ======================== shared.glsl (LIBRARY ONLY) ========================
#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

// ---------- Configuration ----------
#ifndef TAU
#define TAU 6.28318530718
#endif
#ifndef SAMPLER_CLAMP
#define SAMPLER_CLAMP 1   // 1 = clamp to [0,1], 0 = mirror repeat
#endif
#ifndef MAX_VSAMPLES
#define MAX_VSAMPLES 64
#endif

// ==== Alte-CA-Regler / Defaults (wie in der alten Datei) ====
#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3
#endif
#ifndef LG_USE_EXPLICIT_LOD
#define LG_USE_EXPLICIT_LOD 0
#endif
#ifndef LG_LOD_BIAS_SCALE
#define LG_LOD_BIAS_SCALE 0.75
#endif
#ifndef LG_CA_OPACITY
#define LG_CA_OPACITY 0.15 // Deckkraft des CA-Effekts (0.0 - 1.0)
#endif
#ifndef LG_CA_QUALITY_SAMPLES
#define LG_CA_QUALITY_SAMPLES 5 // 3 = Standard (R,G,B), 5 = High Quality (R,Y,G,C,B)
#endif
#ifndef LG_CA_LIGHTNESS_BOOST
#define LG_CA_LIGHTNESS_BOOST 2.0 // (1.0 = keine Änderung)
#endif
#ifndef LG_CA_SATURATION_BOOST
#define LG_CA_SATURATION_BOOST 1.5 // (1.0 = keine Änderung)
#endif
#ifndef LG_CA_PASS_MODE
// 0 = both passes, 1 = vertical only (|u_dir_y| >= |u_dir_x|), 2 = horizontal only
#define LG_CA_PASS_MODE 1
#endif

#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

// ===== Neuer Kram (NEW-CA) ====
// Kotlin/AGSL-Dispersion (NEW-CA)
#ifndef AGSL_DISPERSION_SCALE
#define AGSL_DISPERSION_SCALE 0.4   // FIX: wie gewünscht
#endif
#ifndef AGSL_CA_USE_BLUR_SAMPLER
#define AGSL_CA_USE_BLUR_SAMPLER 1
#endif

// Optionaler Gain nur für NEW-CA (falls du noch mehr „Lines“ willst)
#ifndef LG_CA_NEW_GAIN
#define LG_CA_NEW_GAIN 1.0
#endif

// Refraktions-AA (Basis-Sample – auch wenn CA>0)
#ifndef LG_REFRACT_AA
#define LG_REFRACT_AA 1
#endif
#ifndef LG_REFRACT_AA_TAPS
#define LG_REFRACT_AA_TAPS 4   // 4 oder 8 (RGSS)
#endif
#ifndef LG_REFRACT_AA_RADIUS_PX
#define LG_REFRACT_AA_RADIUS_PX 0.75
#endif
#ifndef LG_REFRACT_AA_STRENGTH
#define LG_REFRACT_AA_STRENGTH 0.85
#endif
#ifndef LG_REFRACT_AA_ALONG_CA
#define LG_REFRACT_AA_ALONG_CA 0.5
#endif

// CA-spezifisches Extra-Smoothing
#ifndef LG_CA_AA_TAPS
#define LG_CA_AA_TAPS 8       // 4, 8 – oder 2, wenn du im caSampleAA auf 2-Tap gehst
#endif
#ifndef LG_CA_AA_RADIUS_PX
#define LG_CA_AA_RADIUS_PX 1.15
#endif
#ifndef LG_CA_AA_STRENGTH
#define LG_CA_AA_STRENGTH 0.9
#endif
#ifndef LG_CA_EDGE_FEATHER_PX
#define LG_CA_EDGE_FEATHER_PX 1.5
#endif

// ==== OLD-CA: AA-Enable + Defaults zeigen auf NEW-CA-Parameter ====
#ifndef LG_CA_OLD_USE_AA
#define LG_CA_OLD_USE_AA 1
#endif
#ifndef LG_CA_OLD_AA_RADIUS_PX
#define LG_CA_OLD_AA_RADIUS_PX LG_CA_AA_RADIUS_PX
#endif
#ifndef LG_CA_OLD_AA_STRENGTH
#define LG_CA_OLD_AA_STRENGTH LG_CA_AA_STRENGTH
#endif

// Kombination Alt+Neu
#ifndef LG_CA_COMBINE_MODE
#define LG_CA_COMBINE_MODE 0  // 0=new, 1=old, 2=both
#endif
#ifndef LG_CA_BLEND
#define LG_CA_BLEND 0.5
#endif
// *** WICHTIG: alter CA nur 1/50 der externen chromaticAberration ***
#ifndef LG_CA_OLD_SCALE
#define LG_CA_OLD_SCALE 0.008
#endif

// ---------- Host-provided uniforms (declared in main .frag) ----------
//
// uniform float uTouchCount_f;
// uniform vec4  uTouches[8];
// uniform float uTouchOwners[8];
// uniform float uTouchGlowStrengths[8];
// uniform vec4  uGlowParams;
// uniform vec4  uGlowColor;
// uniform vec4  uGlowOverrides;
// uniform vec4  uGlowFlags;
// uniform vec4  uGlowGlass;
// uniform float uGlobalBlurSigma;
//
// uniform vec2  uSize;
// uniform vec4  uBlurHeader;  // dir.x, dir.y, sample_count, tile_mode
// uniform vec4  u_samples[50];
// uniform float uShapeData[16*6];
// uniform mat4  uTransform;

#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

// ---------- Small utilities ----------
float hash12(vec2 p){
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}
vec2 lg_norm2(vec2 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}
vec3 lg_norm3(vec3 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

// Pixel<->UV (Impeller GLES-Flip)
vec2 _uv_from_px(vec2 px, vec2 sizePx){
  vec2 uv = px / max(sizePx, vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}
vec2 _px_from_uv(vec2 uv, vec2 sizePx){
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv * sizePx;
}

// ---------- sRGB helpers ----------
#ifndef LG_SRGB_HELPERS_DEFINED
#define LG_SRGB_HELPERS_DEFINED 1
#ifndef USE_EXACT_SRGB
#define USE_EXACT_SRGB 0
#endif
#if USE_EXACT_SRGB
float _srgb_to_linear(float c){
  return (c <= 0.04045) ? (c/12.92) : pow((c+0.055)/1.055, 2.4);
}
float _linear_to_srgb(float c){
  return (c <= 0.0031308) ? (c*12.92) : (1.055*pow(c,1.0/2.4)-0.055);
}
vec3 toLin(vec3 s){ return vec3(_srgb_to_linear(s.r), _srgb_to_linear(s.g), _srgb_to_linear(s.b)); }
vec3 toSR (vec3 l){ return vec3(_linear_to_srgb(l.r), _linear_to_srgb(l.g), _linear_to_srgb(l.b)); }
#else
vec3 toLin(vec3 s){ return pow(max(s, vec3(0.0)), vec3(2.2)); }
vec3 toSR (vec3 l){ return pow(max(l, vec3(0.0)), vec3(1.0/2.2)); }
#endif
#endif // LG_SRGB_HELPERS_DEFINED

// ---------- Tiling helpers ----------
float mirror1(float x){ float m = mod(x, 2.0); return (m <= 1.0) ? m : 2.0 - m; }
vec2  mirror01(vec2 uv){ return vec2(mirror1(uv.x), mirror1(uv.y)); }

#if SAMPLER_CLAMP
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, clamp(uv, vec2(0.0), vec2(1.0))); }
#else
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, mirror01(uv)); }
#endif

vec2 tile_uv_mode(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    vec2 eps = 0.5 / size;
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv);
  } else if (mode < 2.5) {
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    return uv; // decal
  }
}

// ────────────────────────────────────────────────────────────────────────────
// CA-pass gating (wie alt)
bool _shouldApplyCA(){
#if LG_CA_PASS_MODE == 0
  return true;
#elif LG_CA_PASS_MODE == 1
  return (abs(u_dir_y) >= abs(u_dir_x));
#else
  return (abs(u_dir_x) > abs(u_dir_y));
#endif
}

// ────────────────────────────────────────────────────────────────────────────
// 1) Exakter Basis-SDF der Shape
void _readShapeRaw(int idx, out float st, out vec2 c, out vec2 sz, out float cr){
  int base = idx * 6;
  st = uShapeData[base + 0];
  c  = vec2(uShapeData[base + 1], uShapeData[base + 2]);
  sz = vec2(uShapeData[base + 3], uShapeData[base + 4]);
  cr = uShapeData[base + 5];
}
float _sdRRectCore(vec2 p, vec2 c, vec2 size, float r){
  vec2 halfSize = max(size * 0.5, vec2(0.0));
  float rad = clamp(r, 0.0, min(halfSize.x, halfSize.y));
  vec2 q = abs(p - c) - (halfSize - vec2(rad));
  return length(max(q, 0.0)) - rad + min(max(q.x, q.y), 0.0);
}
float _sdEllipseApprox(vec2 p, vec2 c, vec2 size){
  vec2 ab = max(size * 0.5, vec2(1e-4));
  vec2 d  = (p - c) / ab;
  float k = length(d) - 1.0;
  return k * min(ab.x, ab.y);
}
float sdShapeCoreAt(int idx, vec2 p){
  float st, cr; vec2 c, sz;
  _readShapeRaw(idx, st, c, sz, cr);
  if (st == 2.0) { return _sdEllipseApprox(p, c, sz); }
  else { return _sdRRectCore(p, c, sz, cr); }
}

// ────────────────────────────────────────────────────────────────────────────
// 1b) Helper: SDF-Space → Screen-Pixel (invertiert uTransform)
vec2 sdfToScreenPx(vec2 pSdf){
  // uTransform mappt: pSdf = uTransform * vec4(pScreen, 0, 1)
  mat4 invT = inverse(uTransform);
  vec4 ps4  = invT * vec4(pSdf, 0.0, 1.0);
  float w   = max(ps4.w, 1e-6);
  return ps4.xy / w;
}

// ────────────────────────────────────────────────────────────────────────────
// 2) Impeller 1D Gaussian
vec4 applyGaussian1D_Impeller(sampler2D tex, vec2 baseUV){
  vec2 pixel    = vec2(1.0 / uSize.x, 1.0 / uSize.y);
  vec2 step_vec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);
  vec4 sum  = vec4(0.0);
  float wsum = 0.0;

  float nRaw = u_sample_count;
  if ((nRaw == nRaw) && (nRaw > 0.5)) {
    int nS = int(nRaw + 0.5);
    for (int i = 0; i < 50; ++i) {
      if (i >= nS) break;
      float t = u_samples[i].x;
      float w = u_samples[i].z;
      if (!(w > 1e-6)) continue;

      vec2 uvOff = baseUV + step_vec * t;
      vec4 s;
      if (u_tile_mode >= 2.5 &&
          (any(lessThan(uvOff, vec2(0.0))) || any(greaterThan(uvOff, vec2(1.0))))) {
        s = vec4(0.0);
      } else {
        vec2 tiled = tile_uv_mode(uvOff, uSize, u_tile_mode);
        s = texture(tex, tiled);
      }
      sum  += w * s;
      wsum += w;
    }
  }
  if (wsum > 1e-6) return sum / wsum;

  vec2 eps = vec2(0.5 / uSize.x, 0.5 / uSize.y);
  return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting / Color helpers
vec3 getHighlightColor(vec3 backgroundColor, float targetBrightness) {
  float luminance = dot(backgroundColor, vec3(0.299, 0.587, 0.114));
  float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float saturation = maxC > 0.0 ? (maxC - minC) / maxC : 0.0;

  vec3 coloredHighlight = vec3(targetBrightness);
  if (luminance > 0.001) {
    vec3 normalizedBackground = backgroundColor / max(luminance, 1e-6);
    coloredHighlight = normalizedBackground * targetBrightness;
    float saturationBoost = 1.3;
    vec3 gray = vec3(dot(coloredHighlight, vec3(0.299, 0.587, 0.114)));
    coloredHighlight = mix(gray, coloredHighlight, saturationBoost);
    coloredHighlight = min(coloredHighlight, vec3(1.0));
  }

  float luminanceFactor  = smoothstep(0.0, 0.6, luminance);
  float saturationFactor = smoothstep(0.0, 0.4, saturation);
  float colorInfluence   = luminanceFactor * saturationFactor;

  vec3 whiteHighlight = vec3(1.0 * targetBrightness);
  return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

float getHeight(float sd, float thickness){
  if (sd >= 0.0 || thickness <= 0.0) return 0.0;
  if (sd < -thickness) return thickness;
  float x = thickness + sd;
  return sqrt(max(0.0, thickness*thickness - x*x));
}

struct RimMasks { float band; float core; };

RimMasks rimMasksInner(float sd, float rimWidthPx, float rimSharpness){
  vec2  g    = vec2(dFdx(sd), dFdy(sd));
  float gmag = max(length(g), 1e-6);
  float wSDF = max(rimWidthPx, 0.0) * gmag;

  float edge01 = step(sd, 0.0) * smoothstep(-wSDF, 0.0, sd);

  float gamma  = max(rimSharpness, 1e-3);
  float band   = pow(edge01, 1.0 / gamma);

  float coreExp = mix(3.0, 1.1, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float core    = pow(edge01, coreExp / gamma);

  RimMasks m; m.band = band; m.core = core; return m;
}

float fresnelSchlick(float cosTheta, float F0){
  return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
vec3 applyWhiteFringe(vec3 baseColor, vec3 normal, float sd, float rimWidthPx, float rimSharpness){
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);
  float cosNV = clamp(abs(normal.z), 0.0, 1.0);
  float F = fresnelSchlick(cosNV, 0.04);
  float bandGain = mix(0.25, 0.65, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float coreGain = mix(0.15, 0.40, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float amt = rm.band * bandGain + rm.core * coreGain;
  amt *= F;
  return mix(baseColor, vec3(1.0), clamp(amt, 0.0, 1.0));
}

// ---------- NEUES Shape-Coverage-AA basierend auf SDF ----------
float shapeCoverageAA(float sd){
  float w = fwidth(sd);
  return smoothstep(-w, w, -sd); // innen (sd<0) -> 1, außen (sd>0) -> 0
}

// ---------- Helper: AA-Sampling für CA ohne teuren Blur-Kernel ----------
vec4 sampleForAA(sampler2D tex, vec2 uv){
#if 1
  // Für CA-AA-Taps: nur normales Texture-Fetch, kein zusätzlicher 1D-Gauss
  return texScreen(tex, uv);
#else
  // Falls du testen willst, dass CA-AA-Taps auch den Blur-Kernel benutzen:
  return applyGaussian1D_Impeller(tex, uv);
#endif
}

// ---------- CA-spezifisches AA entlang der Aberration ----------
vec4 caSampleAA(
  sampler2D tex,
  vec2 uvCenter,
  vec2 aberrUV,
  vec2 sizePx
){
  float caLenPx = length(aberrUV * sizePx);
  if (caLenPx < 1e-4) {
    // Kleiner als ein Subpixel → keine sichtbare CA → 1 Sample reicht
    return sampleForAA(tex, uvCenter);
  }

  vec2 px  = 1.0 / sizePx;
  vec2 dir = normalize(aberrUV + vec2(1e-6));

  float radiusPx = float(LG_CA_AA_RADIUS_PX);
  float strength = clamp(float(LG_CA_AA_STRENGTH), 0.0, 1.0);

  vec2 offPx = dir * radiusPx;
  vec2 offUV = offPx * px;

  vec4 c0 = sampleForAA(tex, uvCenter);
  vec4 c1 = sampleForAA(tex, uvCenter + offUV);
  vec4 c2 = sampleForAA(tex, uvCenter - offUV);

#if LG_CA_AA_TAPS == 2
  vec4 avg = 0.5 * (c1 + c2);
#else
  vec4 avg = (c0 + c1 + c2) / 3.0;
#endif

  return mix(c0, avg, strength);
}

// ---------- Refraktions-AA: RGSS ----------
vec4 _rgss_sample4(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPx, float alongGain){
  vec2 ortho = vec2(-dir.y, dir.x);
  vec2 o0 = vec2( 0.5,  0.5), o1 = vec2(-0.5,  0.5), o2 = vec2( 0.5, -0.5), o3 = vec2(-0.5, -0.5);
  vec2 a0 = (dir * (o0.x * alongGain) + ortho * o0.y) * radiusPx;
  vec2 a1 = (dir * (o1.x * alongGain) + ortho * o1.y) * radiusPx;
  vec2 a2 = (dir * (o2.x * alongGain) + ortho * o2.y) * radiusPx;
  vec2 a3 = (dir * (o3.x * alongGain) + ortho * o3.y) * radiusPx;

  vec4 c0 = applyGaussian1D_Impeller(tex, uv + a0 * px);
  vec4 c1 = applyGaussian1D_Impeller(tex, uv + a1 * px);
  vec4 c2 = applyGaussian1D_Impeller(tex, uv + a2 * px);
  vec4 c3 = applyGaussian1D_Impeller(tex, uv + a3 * px);
  return (c0 + c1 + c2 + c3) * 0.25;
}
vec4 _rgss_sample8(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPx, float alongGain){
  vec2 ortho = vec2(-dir.y, dir.x);
  vec2 offs[8] = vec2[8](
    vec2( 0.5,  0.5), vec2(-0.5,  0.5), vec2( 0.5, -0.5), vec2(-0.5, -0.5),
    vec2( 1.5,  0.0), vec2(-1.5,  0.0), vec2( 0.0,  1.5), vec2( 0.0, -1.5)
  );
  vec4 acc = vec4(0.0);
  for (int i=0;i<8;i++){
    vec2 o = offs[i];
    vec2 a = (dir * (o.x * alongGain) + ortho * o.y) * radiusPx;
    acc += applyGaussian1D_Impeller(tex, uv + a * px);
  }
  return acc * (1.0/8.0);
}

vec4 _refractAA(sampler2D tex, vec2 uv, vec2 sizePx, vec2 dirUV, float radiusPx, float strength, float alongGain){
  vec2 px = vec2(1.0/sizePx.x, 1.0/sizePx.y);
  vec2 dir = normalize(dirUV + vec2(1e-6));
#if LG_REFRACT_AA_TAPS == 8
  vec4 avg = _rgss_sample8(tex, uv, px, dir, radiusPx, alongGain);
#else
  vec4 avg = _rgss_sample4(tex, uv, px, dir, radiusPx, alongGain);
#endif
  vec4 base = applyGaussian1D_Impeller(tex, uv);
  return mix(base, avg, clamp(strength, 0.0, 1.0));
}

// CA-spezifisches AA (für OLD-CA, falls aktiv)
vec4 _refractAA_CA(sampler2D tex, vec2 uv, vec2 sizePx, vec2 dirUV, float radiusPx, float strength, float alongGain){
  vec2 px = vec2(1.0/sizePx.x, 1.0/sizePx.y);
  vec2 dir = normalize(dirUV + vec2(1e-6));
#if LG_CA_AA_TAPS == 8
  vec4 avg = _rgss_sample8(tex, uv, px, dir, radiusPx, alongGain);
#else
  vec4 avg = _rgss_sample4(tex, uv, px, dir, radiusPx, alongGain);
#endif
  vec4 base = applyGaussian1D_Impeller(tex, uv);
  return mix(base, avg, clamp(strength, 0.0, 1.0));
}

// ===== OLD-CA: vormals "blurred" AA → bleibt geblurrt =====
vec4 _refractAA_CA_OLD_BLURRED(sampler2D tex, vec2 uv, vec2 sizePx, vec2 dirUV, float radiusPx, float strength, float alongGain){
  return _refractAA_CA(tex, uv, sizePx, dirUV, radiusPx, strength, alongGain);
}

// ────────────────────────────────────────────────────────────────────────────
// Refraction + NEW-CA (distUV^3 um Shape-Center) + optional OLD-CA
vec4 calculateRefraction(
  vec2 screenUV, vec3 normal, float sd, float height, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec2 sizePx, sampler2D backgroundTexture,
  out vec2 refractionDisplacement,
  float rimWidthPx, float rimSharpness,
  vec2 lightDirection, float lightIntensity,
  int   currentShapeIdx
){
  vec3 incident = vec3(0.0, 0.0, -1.0);
  float n       = max(refractiveIndex, 1.0001);
  vec3 refr     = refract(incident, normal, 1.0 / n);
  float baseH   = thickness * 8.0;
  float refrL   = (height + baseH) / max(0.001, abs(refr.z));

  RimMasks rm     = rimMasksInner(sd, rimWidthPx, rimSharpness);
  vec2  L         = lightDirection;
  vec2  nxy       = lg_norm2(normal.xy);
  float facing    = abs(dot(nxy, L));
  float lightMask = pow(facing, 0.7) * clamp(lightIntensity, 0.0, 1.0);
  float boost     = 1.0 + 0.4 * (rm.band * lightMask);

  vec2 dispPx = refr.xy * (refrL * boost);
  refractionDisplacement = dispPx / sizePx;
  vec2 uvBase = screenUV + refractionDisplacement;

  // Basis (G-Anker) mit 1D-Blur
  vec4 gS = applyGaussian1D_Impeller(backgroundTexture, uvBase);

  // CA-Wert aus Uniform
  float ca = max(chromaticAberration, 0.0);

  // WICHTIG:
  // Wenn CA ~ 0 → kein CA, kein Refract-AA → nur Blur, maximal billig.
  if (ca <= 1e-4) {
    return gS;
  }

#if LG_REFRACT_AA
  // Refraktions-AA nur aktiv, wenn CA > 0 (weil teuer)
  vec2 dirRefUV = dispPx / sizePx;
  gS = _refractAA(backgroundTexture, uvBase, sizePx, dirRefUV,
                  float(LG_REFRACT_AA_RADIUS_PX), float(LG_REFRACT_AA_STRENGTH),
                  mix(1.0, 1.8, clamp(float(LG_REFRACT_AA_ALONG_CA), 0.0, 1.0)));
#endif

  // ---------- NEW-CA (AGSL, relativ zum Shape-Zentrum im Screen-Space) ----------
  vec3 diff_new = vec3(0.0);
#if (LG_CA_COMBINE_MODE != 1)   // nicht "old only"
  {
    float st, cr; vec2 cSdf, szSdf;
    _readShapeRaw(currentShapeIdx, st, cSdf, szSdf, cr);

    // SDF-Center → Screen-Pixel → UV
    vec2 centerPx = sdfToScreenPx(cSdf);
    vec2 centerUV = _uv_from_px(centerPx, sizePx);

    // Shape-Größe von SDF-Space in Screen-Pixel umrechnen
    vec2 col0 = uTransform[0].xy;
    vec2 col1 = uTransform[1].xy;
    float scaleX = max(length(col0), 1e-6); // SDF-units pro Screen-Pixel-X
    float scaleY = max(length(col1), 1e-6); // SDF-units pro Screen-Pixel-Y

    float widthScreen  = szSdf.x / scaleX;
    float heightScreen = szSdf.y / scaleY;
    float minDimScreen = min(widthScreen, heightScreen);

    vec2 distUV = uvBase - centerUV;           // in UV
    float dispersion = ca * AGSL_DISPERSION_SCALE;

    // Normierung mit minDimScreen / size
    vec2 minDimOverSize = vec2(minDimScreen / sizePx.x, minDimScreen / sizePx.y);

    // per-Komponente kubisch wie Kotlin-Variante
    vec2 dist3   = distUV * distUV * distUV;
    vec2 aberrUV = dispersion * dist3 * minDimOverSize;

    vec2 uvR = uvBase - aberrUV;
    vec2 uvG = uvBase;
    vec2 uvB = uvBase + aberrUV;

    // Guard: R/B nur innerhalb Shape (SDF-Space-Check)
    vec2 pxR = _px_from_uv(uvR, sizePx);
    vec2 pxB = _px_from_uv(uvB, sizePx);
    vec2 pR  = (uTransform * vec4(pxR, 0.0, 1.0)).xy;
    vec2 pB  = (uTransform * vec4(pxB, 0.0, 1.0)).xy;
    bool validR = (sdShapeCoreAt(currentShapeIdx, pR) <= 0.0);
    bool validB = (sdShapeCoreAt(currentShapeIdx, pB) <= 0.0);

    // CA-AA nur mit leichten texScreen-Taps (sampleForAA)
    vec4 sG_new = caSampleAA(backgroundTexture, uvG, aberrUV, sizePx);
    vec4 sR_new = validR ? caSampleAA(backgroundTexture, uvR, aberrUV, sizePx) : sG_new;
    vec4 sB_new = validB ? caSampleAA(backgroundTexture, uvB, aberrUV, sizePx) : sG_new;

    vec3 spectral_new = vec3(sR_new.r, sG_new.g, sB_new.b);
    diff_new = spectral_new - gS.rgb;
    diff_new *= float(LG_CA_LIGHTNESS_BOOST) * float(LG_CA_NEW_GAIN);
    float lum_new = dot(diff_new, vec3(0.299,0.587,0.114));
    diff_new = mix(vec3(lum_new), diff_new, float(LG_CA_SATURATION_BOOST));
  }
#endif // NEW-CA

  // ---------- OLD-CA (linear entlang Refraktion) ----------
  vec3 diff_old = vec3(0.0);
#if (LG_CA_COMBINE_MODE != 0)   // nicht "new only"
  {
    vec2 invUSize = 1.0 / sizePx;
    float ca_old = ca * float(LG_CA_OLD_SCALE);
    float dispLenPx = length(dispPx);

    if ((ca_old * dispLenPx >= float(LG_CA_VIS_THRESHOLD)) && _shouldApplyCA()){
      float dispersionStrength = ca_old * 0.4;

#if LG_CA_QUALITY_SAMPLES == 5
      vec2 dR = dispPx * (1.0 + dispersionStrength)       * invUSize;
      vec2 dY = dispPx * (1.0 + dispersionStrength * 0.5) * invUSize;
      vec2 dC = dispPx * (1.0 - dispersionStrength * 0.5) * invUSize;
      vec2 dB = dispPx * (1.0 - dispersionStrength)       * invUSize;

#if LG_CA_OLD_USE_AA
      vec2 dirCAA_old = normalize((dispPx/sizePx) + vec2(1e-6));
      float radOld    = float(LG_CA_OLD_AA_RADIUS_PX);
      float strOld    = float(LG_CA_OLD_AA_STRENGTH);
      float alongOld  = mix(1.0, 1.8, clamp(float(LG_REFRACT_AA_ALONG_CA), 0.0, 1.0));

      vec4 sR = _refractAA_CA_OLD_BLURRED(backgroundTexture, screenUV + dR, sizePx, dirCAA_old, radOld, strOld, alongOld);
      vec4 sY = _refractAA_CA_OLD_BLURRED(backgroundTexture, screenUV + dY, sizePx, dirCAA_old, radOld, strOld, alongOld);
      vec4 sC = _refractAA_CA_OLD_BLURRED(backgroundTexture, screenUV + dC, sizePx, dirCAA_old, radOld, strOld, alongOld);
      vec4 sB = _refractAA_CA_OLD_BLURRED(backgroundTexture, screenUV + dB, sizePx, dirCAA_old, radOld, strOld, alongOld);

      vec3 spectral_old;
      spectral_old.r = 0.5 * (sR.r + sY.r);
      spectral_old.g = 0.5 * (sY.g + sC.g);
      spectral_old.b = 0.5 * (sC.b + sB.b);
#else
      vec4 sR = texScreen(backgroundTexture, screenUV + dR);
      vec4 sY = texScreen(backgroundTexture, screenUV + dY);
      vec4 sC = texScreen(backgroundTexture, screenUV + dC);
      vec4 sB = texScreen(backgroundTexture, screenUV + dB);
      vec3 spectral_old;
      spectral_old.r = 0.5 * (sR.r + sY.r);
      spectral_old.g = 0.5 * (sY.g + sC.g);
      spectral_old.b = 0.5 * (sC.b + sB.b);
#endif // LG_CA_OLD_USE_AA

#else
      vec2 redUV  = screenUV + dispPx * (1.0 + dispersionStrength) * invUSize;
      vec2 blueUV = screenUV + dispPx * (1.0 - dispersionStrength) * invUSize;

#if LG_CA_OLD_USE_AA
      vec2 dirCAA_old = normalize((dispPx/sizePx) + vec2(1e-6));
      float radOld    = float(LG_CA_OLD_AA_RADIUS_PX);
      float strOld    = float(LG_CA_OLD_AA_STRENGTH);
      float alongOld  = mix(1.0, 1.8, clamp(float(LG_REFRACT_AA_ALONG_CA), 0.0, 1.0));
      vec4 sR_aa  = _refractAA_CA_OLD_BLURRED(backgroundTexture, redUV,  sizePx, dirCAA_old, radOld, strOld, alongOld);
      vec4 sB_aa  = _refractAA_CA_OLD_BLURRED(backgroundTexture, blueUV, sizePx, dirCAA_old, radOld, strOld, alongOld);
      vec3 spectral_old = vec3(sR_aa.r, gS.g, sB_aa.b);
#else
      float red  = texScreen(backgroundTexture, redUV ).r;
      float blue = texScreen(backgroundTexture, blueUV).b;
      vec3 spectral_old = vec3(red, gS.g, blue);
#endif // LG_CA_OLD_USE_AA
#endif // LG_CA_QUALITY_SAMPLES

      diff_old  = spectral_old - gS.rgb;
      diff_old *= float(LG_CA_LIGHTNESS_BOOST);
      float lum_old = dot(diff_old, vec3(0.299,0.587,0.114));
      diff_old = mix(vec3(lum_old), diff_old, float(LG_CA_SATURATION_BOOST));
    }
  }
#endif // LG_CA_COMBINE_MODE != 0

  // Kombination
  float caMixNew = clamp(float(LG_CA_OPACITY), 0.0, 1.0);
  float caMixOld = clamp(float(LG_CA_OPACITY), 0.0, 1.0);

  // Feather nur für NEW-CA
  float edgeAA = smoothstep(-float(LG_CA_EDGE_FEATHER_PX) * fwidth(sd), 0.0, -sd);
  caMixNew *= edgeAA;

  vec3 finalRGB;
#if LG_CA_COMBINE_MODE == 1
  finalRGB = clamp(gS.rgb + diff_old * caMixOld, 0.0, 1.0);
#elif LG_CA_COMBINE_MODE == 0
  finalRGB = clamp(gS.rgb + diff_new * caMixNew, 0.0, 1.0);
#else
  finalRGB = clamp(gS.rgb + diff_new * caMixNew + diff_old * caMixOld, 0.0, 1.0);
#endif

  return vec4(finalRGB, gS.a);
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting
vec3 calculateLighting(
  vec2 uv, vec3 normal, float sd, float thickness, float height,
  vec2 lightDirection, float lightIntensity, float ambientStrength,
  vec3 backgroundColor, float rimWidthPx, float rimSharpness
){
  float thicknessFactor = smoothstep(5.0, 7.0, thickness);
  if (thicknessFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);

  RimMasks rm   = rimMasksInner(sd, rimWidthPx, rimSharpness);
  vec2  L       = lightDirection;
  vec2  nxy     = lg_norm2(normal.xy);
  float facing  = abs(dot(nxy, L));
  float lightMask= pow(facing, 0.7);
  float rimMask = rm.band * lightMask;
  if (rimMask < 1e-3) return vec3(0.0);

  float mainL = max(0.0, dot(nxy,  L));
  float oppL  = max(0.0, dot(nxy, -L));
  float total = mainL + oppL * 0.8;

  vec3 hl             = getHighlightColor(backgroundColor, 0.7);
  vec3 directionalRim = hl * (total * total) * lightIntensity * 2.0;
  vec3 ambientRim     = getHighlightColor(backgroundColor, 0.4) * ambientStrength;

  vec3 lighting = (directionalRim + ambientRim);

  float whitePull  = 0.55;
  float coreGain   = mix(0.16, 0.36, clamp(rimWidthPx/64.0, 0.0, 1.0));
  vec3  towardWhite= mix(lighting, vec3(1.0), whitePull);
  lighting = mix(lighting, towardWhite, rm.core * coreGain);

  return lighting * rimMask * thicknessFactor;
}

// ────────────────────────────────────────────────────────────────────────────
/* Post color ops */
vec3 applySaturationLightness(vec3 color, float saturation, float lightness){
  float luminance = dot(color, vec3(0.299, 0.587, 0.114));
  vec3 saturatedColor = mix(vec3(luminance), color, saturation);
  vec3 adjustedColor = (lightness > 1.0)
                       ? mix(saturatedColor, vec3(1.0), lightness - 1.0)
                       : saturatedColor * lightness;
  return clamp(adjustedColor, 0.0, 1.0);
}

vec4 applyGlassColor(vec4 liquidColor, vec4 glassColor){
  vec4 finalColor = liquidColor;
  if (glassColor.a > 0.0) {
    float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
    if (glassLuminance < 0.5) {
      vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
      finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
    } else {
      vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
      vec3 invGlass  = vec3(1.0) - glassColor.rgb;
      vec3 screened  = vec3(1.0) - (invLiquid * invGlass);
      finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
    }
    finalColor.a = liquidColor.a;
  }
  return finalColor;
}

// ────────────────────────────────────────────────────────────────────────────
// Glow helpers & lokaler Zusatz-Blur (unverändert)
#ifndef GLOW_OWNER_FEATHER_PX
#define GLOW_OWNER_FEATHER_PX 1.6
#endif

float glowTouchMask(vec2 pPx, vec2 pSdf, float /*insideOnly*/, float /*sdUnion*/, int currentShapeIdx){
  float n = uTouchCount_f;
  if (!(n > 0.5) || currentShapeIdx < 0) return 0.0;

  float outMask = 0.0;
  for (int i=0; i<8; ++i){
    if (i >= int(n)) break;
    int owner    = int(floor(uTouchOwners[i] + 0.5));
    int shapeIdx = (owner >= 0) ? owner : currentShapeIdx;
    float sdOwner = sdShapeCoreAt(shapeIdx, pSdf);

    float wAA     = max(fwidth(sdOwner), 1e-6) * GLOW_OWNER_FEATHER_PX;
    float inShape = smoothstep(0.0, wAA, -sdOwner);
    if (inShape <= 1e-5) continue;

    vec4  tp    = uTouches[i]; // (x_px, y_px, r_px, fade_px)
    float d     = length(pPx - tp.xy);
    float inner = tp.z;
    float outer = tp.z + max(tp.w, 1e-3);
    float radial = smoothstep(outer, inner, d);

    float s = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
    outMask = max(outMask, radial * inShape * s);
  }
  return outMask;
}

vec4 gaussianApprox9(sampler2D tex, vec2 uv, float sigmaPx, vec2 sizePx){
  if (sigmaPx <= 0.01) return texScreen(tex, uv);
  vec2 px = 1.0 / sizePx;
  float s = clamp(sigmaPx, 0.0, 6.0);

  float w0 = 0.227027; // center
  float w1 = 0.194594;
  float w2 = 0.121621;

  vec4 c  = texScreen(tex, uv) * w0;
  c += texScreen(tex, uv + vec2(px.x, 0.0)) * w1;
  c += texScreen(tex, uv - vec2(px.x, 0.0)) * w1;
  c += texScreen(tex, uv + vec2(0.0, px.y)) * w1;
  c += texScreen(tex, uv - vec2(0.0, px.y)) * w1;

  c += texScreen(tex, uv + vec2(px.x, px.y)) * w2;
  c += texScreen(tex, uv + vec2(-px.x, px.y)) * w2;
  c += texScreen(tex, uv + vec2(px.x, -px.y)) * w2;
  c += texScreen(tex, uv + vec2(-px.x, -px.y)) * w2;

  float t = clamp((s - 1.0) / 5.0, 0.0, 1.0);
  return mix(texScreen(tex, uv), c, t);
}

// ────────────────────────────────────────────────────────────────────────────
// PUBLIC API
vec4 renderLiquidGlass(
  vec2 screenUV, vec2 p, vec2 uSizePx,
  float sd, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec4  glassColor, vec2 lightDirection, float lightIntensity, float ambientStrength,
  sampler2D backgroundTexture, vec3 normal, float foregroundAlpha,
  float saturation, float lightness, float rimWidthPx, float rimSharpness,
  int   currentShapeIdx
){
  vec4 backgroundColor = texScreen(backgroundTexture, screenUV);
  if (foregroundAlpha < 0.001) return backgroundColor;
  if (thickness < 0.01)       return backgroundColor;

  float height = getHeight(sd, thickness);

  vec2 refractionDisplacement;
  vec4 refractColorBase = calculateRefraction(
    screenUV, normal, sd, height, thickness,
    refractiveIndex, chromaticAberration,
    uSizePx, backgroundTexture, refractionDisplacement,
    rimWidthPx, rimSharpness, lightDirection, lightIntensity,
    currentShapeIdx
  );

  refractColorBase.rgb = applyWhiteFringe(refractColorBase.rgb, normal, sd, rimWidthPx, rimSharpness);

  vec3 lighting = calculateLighting(
    screenUV, normal, sd, thickness, height,
    lightDirection, lightIntensity, ambientStrength,
    backgroundColor.rgb, rimWidthPx, rimSharpness
  );

  vec4 coloredBase = applyGlassColor(refractColorBase, glassColor);
  coloredBase.rgb += lighting;
  coloredBase.rgb  = applySaturationLightness(coloredBase.rgb, saturation, lightness);

  float gStrength  = uGlowParams.x;
  float gPower     = max(uGlowParams.y, 0.0001);
  float gTintMode  = uGlowParams.z;
  float gInside    = uGlowParams.w;

  float hasL = uGlowFlags.x;
  float hasS = uGlowFlags.y;
  float hasB = uGlowFlags.z;
  float hasG = uGlowFlags.w;

  float oLight = uGlowOverrides.x;
  float oSatu  = uGlowOverrides.y;
  float oBlur  = uGlowOverrides.z;
  float oMix   = clamp(uGlowOverrides.w, 0.0, 1.0);

  vec2 uvBase = screenUV + refractionDisplacement;

  vec4 outColor = coloredBase;

  if (gStrength > 0.0001 && uTouchCount_f > 0.5){
    vec2 pPx = screenUV * uSizePx;
    float maskRaw = glowTouchMask(pPx, p, gInside, sd, currentShapeIdx);
    if (maskRaw > 0.0){
      float shaped = pow(clamp(maskRaw, 0.0, 1.0), gPower) * gStrength * oMix;
      shaped = clamp(shaped, 0.0, 1.0);

      float tLight = (hasL > 0.5) ? oLight : lightness;
      float tSatu  = (hasS > 0.5) ? oSatu  : saturation;
      vec4  tGlass = (hasG > 0.5) ? uGlowGlass : glassColor;

      float effLight = mix(lightness, tLight, shaped);
      float effSatu  = mix(saturation, tSatu, shaped);
      vec4  effGlass = mix(glassColor, tGlass, shaped);

      float extraSigma = 0.0;
      if (hasB > 0.5) {
        extraSigma = max(oBlur - uGlobalBlurSigma, 0.0);
      }

      vec4 refractLocal = refractColorBase;
      if (extraSigma > 0.01){
        refractLocal = gaussianApprox9(backgroundTexture, uvBase, extraSigma, uSizePx);
      }

      vec4 coloredLocal = applyGlassColor(refractLocal, effGlass);
      coloredLocal.rgb += lighting;
      coloredLocal.rgb  = applySaturationLightness(coloredLocal.rgb, effSatu, effLight);

      vec3 tint;
      if (gTintMode < 0.5) {
        tint = vec3(1.0);
      } else if (gTintMode < 1.5) {
        tint = getHighlightColor(backgroundColor.rgb, 1.0);
      } else {
        tint = uGlowColor.rgb;
      }
      vec4 tintGlass = vec4(tint, clamp(uGlowColor.a, 0.0, 1.0) * shaped);
      coloredLocal = applyGlassColor(coloredLocal, tintGlass);

      outColor = mix(coloredBase, coloredLocal, shaped);
    }
  }

  // Finaler Alpha-Mix mit Shape-Coverage-AA (Silhouette super smooth)
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);

  // 1) AA-Coverage aus SDF (Silhouette-AA)
  float coverage = shapeCoverageAA(sd);

  // 2) Basisalpha: Material-Alpha * Coverage
  float baseA = foregroundAlpha * coverage;

  // 3) Rim-Boost beibehalten
  float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPx/64.0, 0.0, 1.0));
  float rimA = rm.band * edgeAlphaGain;

  // 4) Kombiniert
  float mixA = clamp(max(baseA, rimA), 0.0, 1.0);

  return mix(backgroundColor, outColor, mixA);
}

// Optional: Normalen-Debug
vec4 debugNormals(vec4 originalColor, vec3 normal, bool enableDebug) {
  if (enableDebug) {
    vec3 normalColor = (normal + 1.0) * 0.5;
    return mix(originalColor, vec4(normalColor, 1.0), 0.99);
  }
  return originalColor;
}

#endif // LIQUID_GLASS_SHARED_GLSL
