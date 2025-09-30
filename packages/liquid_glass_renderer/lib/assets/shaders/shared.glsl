// ======================== shared.glsl (LIBRARY ONLY) ========================
#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

// ---------- Config ----------
#ifndef TAU
#define TAU 6.28318530718
#endif
#ifndef SAMPLER_CLAMP
#define SAMPLER_CLAMP 1   // 1 = clamp 0..1, 0 = mirror
#endif
#ifndef MAX_VSAMPLES
#define MAX_VSAMPLES 64
#endif

// ---------- Small utils ----------
float hash12(vec2 p){
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

// ---------- sRGB helpers (define once) ----------
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

// ---------- tiling helpers ----------
float mirror1(float x){ float m = mod(x, 2.0); return (m <= 1.0) ? m : 2.0 - m; }
vec2  mirror01(vec2 uv){ return vec2(mirror1(uv.x), mirror1(uv.y)); }

#if SAMPLER_CLAMP
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, clamp(uv, vec2(0.0), vec2(1.0))); }
#else
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, mirror01(uv)); }
#endif

// ---------- Impeller-Identisches Tiling (für Gaussian 1D) ----------
// HINWEIS: Die hier verwendeten Uniforms (u_size_x, u_size_y, u_dir_*, u_samples, …)
// müssen im Host-Shader (liquid_glass.frag) VOR dem include deklariert sein.
vec2 tile_uv_mode(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    // clamp-with-epsilon wie Impeller
    vec2 eps = 0.5 / size;
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv);
  } else if (mode < 2.5) {
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    // decal: uv bleibt roh, OOB wird separat 0
    return uv;
  }
}
vec4 sample_uv_mode(sampler2D tex, vec2 uv, vec2 size, float mode){
  if (mode >= 2.5) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
      return vec4(0.0);
    }
  }
  return texture(tex, tile_uv_mode(uv, size, mode));
}

// ────────────────────────────────────────────────────────────────────────────
//  EXAKTER Gaussian 1D nach Referenzshader (liest Impeller-Uniforms)
// ────────────────────────────────────────────────────────────────────────────
vec4 applyGaussian1D_Impeller(sampler2D tex, vec2 baseUV){
  // Diese Uniforms sind im Host deklariert (liquid_glass.frag)
  // und beim Include schon bekannt.
  //   uniform float u_size_x, u_size_y;
  //   uniform float u_dir_x,  u_dir_y;
  //   uniform float u_sample_count, u_tile_mode;
  //   uniform vec4  u_samples[50];

  vec2 pixel    = vec2(1.0 / u_size_x, 1.0 / u_size_y);
  vec2 step_vec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);

  vec4 sum  = vec4(0.0);
  float wsum = 0.0;

  float nRaw = u_sample_count;
  if ((nRaw == nRaw) && (nRaw > 0.5)) {
    int nS = int(nRaw + 0.5);
    for (int i = 0; i < 50; ++i) {
      if (i >= nS) break;
      float t = u_samples[i].x;  // Offset in Pixeln entlang der Achse
      float w = u_samples[i].z;  // Gewicht
      if (!(w > 1e-6)) continue;

      vec2 uvOff = baseUV + step_vec * t;
      vec4 s = sample_uv_mode(tex, uvOff, vec2(u_size_x, u_size_y), u_tile_mode);
      sum  += w * s;
      wsum += w;
    }
  }

  if (wsum > 1e-6) return sum / wsum;

  // Fallback (clamp with epsilon)
  vec2 eps = vec2(0.5 / u_size_x, 0.5 / u_size_y);
  return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting / Color (wie vorher)
// ────────────────────────────────────────────────────────────────────────────
vec3 getHighlightColor(vec3 backgroundColor, float targetBrightness) {
  float Y = dot(backgroundColor, vec3(0.299, 0.587, 0.114));
  float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float S = (maxC > 0.0) ? (maxC - minC) / maxC : 0.0;

  vec3 colored = (Y > 0.001) ? (backgroundColor / max(Y, 1e-6)) * targetBrightness
                             : vec3(targetBrightness);
  vec3 gray = vec3(dot(colored, vec3(0.299, 0.587, 0.114)));
  colored = min(mix(gray, colored, 1.3), vec3(1.0));

  float luminanceFactor  = smoothstep(0.0, 0.6, Y);
  float saturationFactor = smoothstep(0.0, 0.4, S);
  float colorInfluence   = luminanceFactor * saturationFactor;

  vec3 white = vec3(targetBrightness);
  return mix(white, colored, colorInfluence);
}

float getHeight(float sd, float thickness){
  if (sd >= 0.0 || thickness <= 0.0) return 0.0;
  if (sd < -thickness) return thickness;
  float x = thickness + sd;
  return sqrt(max(0.0, thickness*thickness - x*x));
}

float calculateDispersiveIndex(float baseIndex, float chromaticAberration, float wavelength) {
  if (chromaticAberration < 0.001) return baseIndex;
  float w2 = wavelength * wavelength;
  float w4 = w2 * w2;
  float B = chromaticAberration * 0.08  * (baseIndex - 1.0);
  float C = chromaticAberration * 0.003 * (baseIndex - 1.0);
  return baseIndex + B / w2 + C / w4;
}

vec3 applySaturationLightness(vec3 color, float saturation, float lightness){
  float Y = dot(color, vec3(0.299, 0.587, 0.114));
  vec3 saturated  = mix(vec3(Y), color, saturation);
  vec3 adjusted   = saturated * lightness;
  return clamp(adjusted, 0.0, 1.0);
}

vec4 applyGlassColor(vec4 liquidColor, vec4 glassColor){
  vec4 finalColor = liquidColor;
  if (glassColor.a > 0.0) {
    float Lg = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
    if (Lg < 0.5) {
      vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
      finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
    } else {
      vec3 invL = vec3(1.0) - liquidColor.rgb;
      vec3 invG = vec3(1.0) - glassColor.rgb;
      vec3 screened = vec3(1.0) - (invL * invG);
      finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
    }
  }
  return finalColor;
}

// dezentes Rim-/Gegenlicht wie zuvor
vec3 calculateLighting(
  vec2 uv, vec3 normal, float sd, float thickness,
  float lightAngle, float lightIntensity, float ambientStrength,
  vec3 backgroundColor
){
  float height = getHeight(sd, thickness);
  float normalizedHeight = (thickness > 0.0) ? (height / thickness) : 0.0;
  float shape = smoothstep(0.0, 0.9, 1.0 - normalizedHeight);
  if (shape < 0.01) return vec3(0.0);

  float thicknessFactor = smoothstep(5.0, 7.0, thickness);
  if (thicknessFactor < 0.01) return vec3(0.0);

  float rimWidth  = 3.0;
  float rimFactor = exp(-sd * sd / (2.0 * rimWidth * rimWidth));

  vec2 L = vec2(cos(lightAngle), sin(lightAngle));
  float mainL = max(0.0, dot(normalize(normal.xy),  L));
  float oppL  = max(0.0, dot(normalize(normal.xy), -L));
  float total = mainL + oppL * 0.8;

  vec3 hl = getHighlightColor(backgroundColor, 0.7);
  vec3 directionalRim = hl * pow(total, 2.0) * lightIntensity * 2.0;
  vec3 ambientRim     = getHighlightColor(backgroundColor, 0.4) * ambientStrength;

  return (directionalRim + ambientRim) * rimFactor * thicknessFactor * shape;
}

// ────────────────────────────────────────────────────────────────────────────
// Refraction: nutzt den exakten Impeller-1D-Blur (V-Pass). Dispersion optional.
// ────────────────────────────────────────────────────────────────────────────
vec4 calculateRefraction(
  vec2 screenUV, vec3 normal, float height, float thickness,
  float refractiveIndex, float chromaticAberration, // chroma aktuell ungenutzt
  vec2  sizePx, sampler2D backgroundTexture,
  out vec2 refractionDisplacement
){
  vec3 incident    = vec3(0.0, 0.0, -1.0);
  float n          = max(refractiveIndex, 1.0001);
  vec3 refr        = refract(incident, normal, 1.0 / n);
  float baseHeight = thickness * 8.0;
  float refrL      = (height + baseHeight) / max(0.001, abs(refr.z));

  vec2 dispPx = refr.xy * refrL;
  refractionDisplacement = dispPx / sizePx;

  // 1D Gaussian identisch zu gaussian_1d_blur.frag
  return applyGaussian1D_Impeller(backgroundTexture, screenUV + refractionDisplacement);
}

// ────────────────────────────────────────────────────────────────────────────
/* PUBLIC API — kompatible Signatur
   gaussianBlurSigmaPx/kawaseSteps werden ignoriert, da der Blur über
   die Impeller-Uniforms erfolgt (u_dir/u_samples etc.).
*/
vec4 renderLiquidGlass(
  vec2 screenUV, vec2 p, vec2 uSizePx,
  float sd, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec4  glassColor, float lightAngle, float lightIntensity, float ambientStrength,
  sampler2D backgroundTexture, vec3 normal, float foregroundAlpha,
  float gaussianBlurSigmaPx, float kawaseSteps,
  float saturation, float lightness
){
  if (foregroundAlpha < 0.001 || thickness < 0.01) {
    return texScreen(backgroundTexture, screenUV);
  }

  float height = getHeight(sd, thickness);

  vec2 refractionDisplacement;
  vec4 refractColor = calculateRefraction(
    screenUV, normal, height, thickness, refractiveIndex, chromaticAberration,
    uSizePx, backgroundTexture, refractionDisplacement
  );

  vec4 backgroundColor = texScreen(backgroundTexture, screenUV);
  vec3 lighting = calculateLighting(
    screenUV, normal, sd, thickness,
    lightAngle, lightIntensity, ambientStrength,
    backgroundColor.rgb
  );

  vec4 finalColor = applyGlassColor(refractColor, glassColor);
  finalColor.rgb += lighting;
  finalColor.rgb  = applySaturationLightness(finalColor.rgb, saturation, lightness);

  return mix(backgroundColor, finalColor, foregroundAlpha);
}

#endif // LIQUID_GLASS_SHARED_GLSL
