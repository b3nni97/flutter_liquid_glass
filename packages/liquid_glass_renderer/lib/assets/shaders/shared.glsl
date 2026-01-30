#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

// Configuration constants with default fallbacks.
#ifndef TAU
#define TAU 6.28318530718
#endif

#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3
#endif

#ifndef LG_CA_OPACITY
#define LG_CA_OPACITY 0.15
#endif

#ifndef LG_CA_LIGHTNESS_BOOST
#define LG_CA_LIGHTNESS_BOOST 2.0
#endif

#ifndef LG_CA_SATURATION_BOOST
#define LG_CA_SATURATION_BOOST 1.5
#endif

#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

#ifndef AGSL_DISPERSION_SCALE
#define AGSL_DISPERSION_SCALE 0.4
#endif

#ifndef LG_CA_NEW_GAIN
#define LG_CA_NEW_GAIN 1.0
#endif

#ifndef LG_REFRACT_AA_RADIUS_PX
#define LG_REFRACT_AA_RADIUS_PX 0.75
#endif

#ifndef LG_REFRACT_AA_STRENGTH
#define LG_REFRACT_AA_STRENGTH 0.85
#endif

#ifndef LG_CA_AA_TAPS
#define LG_CA_AA_TAPS 8
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

#ifndef GLOW_OWNER_FEATHER_PX
#define GLOW_OWNER_FEATHER_PX 1.6
#endif

// Uniform accessor macros.
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

struct RimMasks {
    float band;
    float core;
};

// Generates a pseudo-random float based on a 2D position.
float _hash12(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// NEU: Einfacher Hash für Jitter-Rauschen
float _hashRefr(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Normalizes a vector, handling zero-length cases safely.
vec2 _safeNormalize(vec2 v) {
    float d = max(dot(v, v), LG_EPS);
    return v * inversesqrt(d);
}

// Converts pixel coordinates to UV coordinates.
vec2 _uvFromPx(vec2 px, vec2 sizePx) {
    vec2 uv = px / max(sizePx, vec2(1.0));
    #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
    #endif
    return uv;
}

// Converts UV coordinates to pixel coordinates.
vec2 _pxFromUv(vec2 uv, vec2 sizePx) {
    #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
    #endif
    return uv * sizePx;
}

// Samples a texture with standard clamping.
vec4 _sampleTexture(sampler2D t, vec2 uv) {
    return texture(t, clamp(uv, vec2(0.0), vec2(1.0)));
}

// Simuliert Nearest-Neighbor Sampling (Pixel-Look)
vec4 _sampleNearest(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 pixel = uv * texSize;
    vec2 nearestPixel = floor(pixel) + 0.5;
    vec2 nearestUV = nearestPixel / texSize;
    return texture(tex, clamp(nearestUV, vec2(0.0), vec2(1.0)));
}

// NEU: Multi-Tap Jittered Blur für die Child-Texture
vec4 _blurJitterRefraction(sampler2D tex, vec2 uv, float blurAmount, vec2 sizePx, vec2 seed) {
    if (blurAmount <= 0.05) return _sampleNearest(tex, uv, uChildSize);
    
    vec2 px = 1.0 / sizePx;
    float s = blurAmount * 0.7; 
    
    vec4 col = _sampleNearest(tex, uv + vec2(-s, -s) * px, uChildSize);
    col     += _sampleNearest(tex, uv + vec2( s, -s) * px, uChildSize);
    col     += _sampleNearest(tex, uv + vec2(-s,  s) * px, uChildSize);
    col     += _sampleNearest(tex, uv + vec2( s,  s) * px, uChildSize);
    
    return col * 0.25;
}

// Applies texture wrapping modes (clamp, repeat, mirror).
vec2 _applyTileMode(vec2 uv, vec2 size, float mode) {
    if (mode < 0.5) {
        vec2 eps = 0.5 / size;
        return clamp(uv, eps, vec2(1.0) - eps);
    } else if (mode < 1.5) {
        return fract(uv);
    } else if (mode < 2.5) {
        vec2 m = mod(uv, 2.0);
        return mix(m, 2.0 - m, step(1.0, m));
    }
    return uv;
}

// Determines if chromatic aberration should be applied based on blur direction.
bool _shouldApplyCA() {
    return (abs(u_dir_y) >= abs(u_dir_x));
}

// Decodes shape data from the uniform array.
void _readShapeData(int idx, out float type, out vec2 center, out vec2 size, out float cornerRadius) {
    int base = idx * 7;
    type = uShapeData[base + 0];
    center = vec2(uShapeData[base + 1], uShapeData[base + 2]);
    size = vec2(uShapeData[base + 3], uShapeData[base + 4]);
    cornerRadius = uShapeData[base + 5];
}

// Computes the signed distance for a rounded rectangle.
float _sdRoundedRect(vec2 p, vec2 c, vec2 size, float r) {
    vec2 halfSize = max(size * 0.5, vec2(0.0));
    float rad = clamp(r, 0.0, min(halfSize.x, halfSize.y));
    vec2 q = abs(p - c) - (halfSize - vec2(rad));
    return length(max(q, 0.0)) - rad + min(max(q.x, q.y), 0.0);
}

// Computes an approximate signed distance for an ellipse.
float _sdEllipse(vec2 p, vec2 c, vec2 size) {
    vec2 ab = max(size * 0.5, vec2(1e-4));
    vec2 d = (p - c) / ab;
    float k = length(d) - 1.0;
    return k * min(ab.x, ab.y);
}

// Computes the signed distance to a specific shape index.
float _sdShapeAt(int idx, vec2 p) {
    float type, radius;
    vec2 center, size;
    _readShapeData(idx, type, center, size, radius);
    
    if (type == 2.0) {
        return _sdEllipse(p, center, size);
    }
    return _sdRoundedRect(p, center, size, radius);
}

// Projects a point from SDF space to Screen Pixel space.
vec2 _projectSdfToScreen(vec2 pSdf) {
    mat4 invT = inverse(uTransform);
    vec4 ps4 = invT * vec4(pSdf, 0.0, 1.0);
    float w = max(ps4.w, 1e-6);
    return ps4.xy / w;
}

// Applies a 1D Gaussian blur based on uniform samples.
vec4 _applyGaussianBlur(sampler2D tex, vec2 baseUV) {
    vec2 pixel = vec2(1.0 / uSize.x, 1.0 / uSize.y);
    vec2 stepVec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);
    
    float nRaw = u_sample_count;
    if (nRaw <= 0.5) {
        vec2 eps = vec2(0.5 / uSize.x, 0.5 / uSize.y);
        return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
    }

    vec4 sum = vec4(0.0);
    float wSum = 0.0;
    int nS = int(nRaw + 0.5);

    for (int i = 0; i < 50; ++i) {
        if (i >= nS) break;
        
        float t = u_samples[i].x;
        float w = u_samples[i].z;
        
        if (w <= 1e-6) continue;

        vec2 uvOff = baseUV + stepVec * t;
        vec4 s;
        
        if (u_tile_mode >= 2.5 && (any(lessThan(uvOff, vec2(0.0))) || any(greaterThan(uvOff, vec2(1.0))))) {
            s = vec4(0.0);
        } else {
            vec2 tiled = _applyTileMode(uvOff, uSize, u_tile_mode);
            s = texture(tex, tiled);
        }
        
        sum += w * s;
        wSum += w;
    }

    if (wSum > 1e-6) {
        return sum / wSum;
    }
    return texture(tex, baseUV);
}

// Calculates a highlight color based on background luminance and saturation.
vec3 _computeAdaptiveHighlight(vec3 backgroundColor, float targetBrightness) {
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

    float luminanceFactor = smoothstep(0.0, 0.6, luminance);
    float saturationFactor = smoothstep(0.0, 0.4, saturation);
    float colorInfluence = luminanceFactor * saturationFactor;
    
    vec3 whiteHighlight = vec3(1.0 * targetBrightness);
    return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

// Calculates the virtual height of the liquid at a given signed distance.
float _calculateLiquidHeight(float sd, float thickness) {
    if (sd >= 0.0 || thickness <= 0.0) return 0.0;
    if (sd < -thickness) return thickness;
    
    float x = thickness + sd;
    return sqrt(max(0.0, thickness * thickness - x * x));
}

// Generates masks for rim lighting logic.
RimMasks _calculateRimMasks(float sd, float rimWidthPx, float rimSharpness) {
    vec2 g = vec2(dFdx(sd), dFdy(sd));
    float gMag = max(length(g), 1e-6);
    float wSdf = max(rimWidthPx, 0.0) * gMag;
    
    float edge01 = step(sd, 0.0) * smoothstep(-wSdf, 0.0, sd);
    float gamma = max(rimSharpness, 1e-3);
    
    float band = pow(edge01, 1.0 / gamma);
    float coreExp = mix(3.0, 1.1, clamp(rimWidthPx / 64.0, 0.0, 1.0));
    float core = pow(edge01, coreExp / gamma);
    
    RimMasks m;
    m.band = band;
    m.core = core;
    return m;
}

// Computes Fresnel reflectance using Schlick's approximation.
float _fresnelSchlick(float cosTheta, float f0) {
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}

// Applies a white fringe effect to the edges of the shape.
vec3 _applyRimHighlight(vec3 baseColor, vec3 normal, float sd, float rimWidthPx, float rimSharpness) {
    RimMasks rm = _calculateRimMasks(sd, rimWidthPx, rimSharpness);
    float cosNv = clamp(abs(normal.z), 0.0, 1.0);
    float f = _fresnelSchlick(cosNv, 0.04);
    
    float bandGain = mix(0.25, 0.65, clamp(rimWidthPx / 64.0, 0.0, 1.0));
    float coreGain = mix(0.15, 0.40, clamp(rimWidthPx / 64.0, 0.0, 1.0));
    
    float amt = rm.band * bandGain + rm.core * coreGain;
    amt *= f;
    
    return mix(baseColor, vec3(1.0), clamp(amt, 0.0, 1.0));
}

// Computes anti-aliased coverage for the shape edge.
float _computeCoverageAA(float sd) {
    float w = fwidth(sd);
    return smoothstep(-w, w, -sd);
}

// Samples texture with multi-tap anti-aliasing for chromatic aberration.
vec4 _sampleAberrationAA(sampler2D tex, vec2 uvCenter, vec2 aberrUV, vec2 sizePx) {
    float caLenPx = length(aberrUV * sizePx);
    if (caLenPx < 1e-4) {
        return _sampleTexture(tex, uvCenter);
    }
    
    vec2 px = 1.0 / sizePx;
    vec2 dir = normalize(aberrUV + vec2(1e-6));
    float radiusPx = float(LG_CA_AA_RADIUS_PX);
    float strength = clamp(float(LG_CA_AA_STRENGTH), 0.0, 1.0);
    
    vec2 offPx = dir * radiusPx;
    vec2 offUV = offPx * px;
    
    vec4 c0 = _sampleTexture(tex, uvCenter);
    vec4 c1 = _sampleTexture(tex, uvCenter + offUV);
    vec4 c2 = _sampleTexture(tex, uvCenter - offUV);
    
    #if LG_CA_AA_TAPS == 2
    vec4 avg = 0.5 * (c1 + c2);
    #else
    vec4 avg = (c0 + c1 + c2) / 3.0;
    #endif
    
    return mix(c0, avg, strength);
}

// Performs Rotated Grid Super Sampling (4 taps).
vec4 _sampleRGSS4(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPx, float alongGain) {
    vec2 ortho = vec2(-dir.y, dir.x);
    vec2 o0 = vec2(0.5, 0.5);
    vec2 o1 = vec2(-0.5, 0.5);
    vec2 o2 = vec2(0.5, -0.5);
    vec2 o3 = vec2(-0.5, -0.5);
    
    vec2 a0 = (dir * (o0.x * alongGain) + ortho * o0.y) * radiusPx;
    vec2 a1 = (dir * (o1.x * alongGain) + ortho * o1.y) * radiusPx;
    vec2 a2 = (dir * (o2.x * alongGain) + ortho * o2.y) * radiusPx;
    vec2 a3 = (dir * (o3.x * alongGain) + ortho * o3.y) * radiusPx;
    
    vec4 c0 = _applyGaussianBlur(tex, uv + a0 * px);
    vec4 c1 = _applyGaussianBlur(tex, uv + a1 * px);
    vec4 c2 = _applyGaussianBlur(tex, uv + a2 * px);
    vec4 c3 = _applyGaussianBlur(tex, uv + a3 * px);
    
    return (c0 + c1 + c2 + c3) * 0.25;
}

// Applies anti-aliasing to refracted samples.
vec4 _sampleRefractionAA(sampler2D tex, vec2 uv, vec2 sizePx, vec2 dirUV, float radiusPx, float strength, float alongGain) {
    vec2 px = vec2(1.0 / sizePx.x, 1.0 / sizePx.y);
    vec2 dir = normalize(dirUV + vec2(1e-6));
    
    vec4 avg = _sampleRGSS4(tex, uv, px, dir, radiusPx, alongGain);
    vec4 base = _applyGaussianBlur(tex, uv);
    
    return mix(base, avg, clamp(strength, 0.0, 1.0));
}

// -----------------------------------------------------------------------------
// Helper for Hard Light Blending
// -----------------------------------------------------------------------------
vec3 _blendHardLight(vec3 base, vec3 blend) {
    vec3 t1 = 2.0 * base * blend;
    vec3 t2 = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
    vec3 selection = step(0.5, blend);
    return mix(t1, t2, selection);
}

// MODIFIZIERT: Hybrid-Ansatz -> Original-Optik verstärkt durch Refraction-Stärke
vec3 _resolveDispersion(
    vec2 uvBase,
    vec2 childUVBase,
    vec2 refractionDisplacement,
    vec2 sizePx,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    int currentShapeIdx,
    float ca,
    vec4 baseColor
) {
    float type, radius;
    vec2 cSdf, szSdf;
    _readShapeData(currentShapeIdx, type, cSdf, szSdf, radius);
    
    vec2 centerPx = _projectSdfToScreen(cSdf);
    vec2 centerUV = _uvFromPx(centerPx, sizePx);
    
    vec2 col0 = uTransform[0].xy;
    vec2 col1 = uTransform[1].xy;
    float scaleX = max(length(col0), 1e-6);
    float scaleY = max(length(col1), 1e-6);
    
    float widthScreen = szSdf.x / scaleX;
    float heightScreen = szSdf.y / scaleY;
    float minDimScreen = min(widthScreen, heightScreen);
    
    vec2 distUV = uvBase - centerUV;
    float dispersion = ca * AGSL_DISPERSION_SCALE;
    vec2 minDimOverSize = vec2(minDimScreen / sizePx.x, minDimScreen / sizePx.y);
    vec2 dist3 = distUV * distUV * distUV;
    
    // --- HYBRID LOGIK HIER ---
    // 1. Wir nutzen 'dist3' (Entfernung zur Mitte) für die Form/Richtung (Lens Look).
    // 2. Wir messen 'refractionDisplacement' für die Verzerrungs-Intensität.
    // 3. Wir multiplizieren beides: Die CA ist stark, wo es "außen" ist UND "verzerrt".
    
    float distortMag = length(refractionDisplacement);
    // Faktor 40.0 ist ein Gain, da Displacement in UV-Space sehr klein ist (z.B. 0.005)
    float boost = 1.0 + (distortMag * 100.0);
    
    // Original Formel * Boost
    vec2 aberrUV = (dispersion * dist3 * minDimOverSize) * boost;
    
    vec2 uvR = uvBase - aberrUV;
    vec2 uvG = uvBase;
    vec2 uvB = uvBase + aberrUV;
    
    vec2 pxR = _pxFromUv(uvR, sizePx);
    vec2 pxB = _pxFromUv(uvB, sizePx);
    
    vec2 pR = (uTransform * vec4(pxR, 0.0, 1.0)).xy;
    vec2 pB = (uTransform * vec4(pxB, 0.0, 1.0)).xy;
    
    bool validR = (_sdShapeAt(currentShapeIdx, pR) <= 0.0);
    bool validB = (_sdShapeAt(currentShapeIdx, pB) <= 0.0);
    
    vec4 sGbg = _sampleAberrationAA(backgroundTexture, uvG, aberrUV, sizePx);
    vec4 sRbg = validR ? _sampleAberrationAA(backgroundTexture, uvR, aberrUV, sizePx) : sGbg;
    vec4 sBbg = validB ? _sampleAberrationAA(backgroundTexture, uvB, aberrUV, sizePx) : sGbg;
    
    vec4 sGch = _sampleTexture(childTexture, childUVBase + refractionDisplacement);
    vec4 sRch = _sampleTexture(childTexture, childUVBase + refractionDisplacement - aberrUV);
    vec4 sBch = _sampleTexture(childTexture, childUVBase + refractionDisplacement + aberrUV);
    
    if (!validR) sRch = sGch;
    if (!validB) sBch = sGch;
    
    // Hard Light Blending
    vec3 cR_rgb = (sRch.a > 0.001) ? sRch.rgb / sRch.a : sRch.rgb;
    vec3 cG_rgb = (sGch.a > 0.001) ? sGch.rgb / sGch.a : sGch.rgb;
    vec3 cB_rgb = (sBch.a > 0.001) ? sBch.rgb / sBch.a : sBch.rgb;

    vec3 hl_R = _blendHardLight(sRbg.rgb, cR_rgb);
    float r = mix(sRbg.r, hl_R.r, sRch.a);

    vec3 hl_G = _blendHardLight(sGbg.rgb, cG_rgb);
    float g = mix(sGbg.g, hl_G.g, sGch.a);

    vec3 hl_B = _blendHardLight(sBbg.rgb, cB_rgb);
    float b = mix(sBbg.b, hl_B.b, sBch.a);
    
    vec3 spectralNew = vec3(r, g, b);
    vec3 diff = spectralNew - baseColor.rgb;
    diff *= float(LG_CA_LIGHTNESS_BOOST) * float(LG_CA_NEW_GAIN);
    
    float lumNew = dot(diff, vec3(0.299, 0.587, 0.114));
    return mix(vec3(lumNew), diff, float(LG_CA_SATURATION_BOOST));
}

// Calculates refraction, including anti-aliasing and chromatic aberration.
vec4 _calculateRefractionLayer(
    vec2 screenUV, vec3 normal, float sd, float height, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec2 sizePx, sampler2D backgroundTexture,
    sampler2D childTexture,
    vec2 childUVBase,
    out vec2 refractionDisplacement,
    float rimWidthPx, float rimSharpness,
    vec2 lightDirection, float lightIntensity,
    int currentShapeIdx
) {
    vec3 incident = vec3(0.0, 0.0, -1.0);
    float n = max(refractiveIndex, 1.0001);
    vec3 refr = refract(incident, normal, 1.0 / n);
    
    float baseH = thickness * 8.0;
    float refrL = (height + baseH) / max(0.001, abs(refr.z));
    
    RimMasks rm = _calculateRimMasks(sd, rimWidthPx, rimSharpness);
    vec2 l = lightDirection;
    vec2 nXy = _safeNormalize(normal.xy);
    float facing = abs(dot(nXy, l));
    float lightMask = pow(facing, 0.7) * clamp(lightIntensity, 0.0, 1.0);
    float boost = 1.0 + 0.4 * (rm.band * lightMask);
    
    vec2 dispPx = refr.xy * (refrL * boost);
    refractionDisplacement = dispPx / sizePx;
    
    vec2 uvBase = screenUV + refractionDisplacement;
    vec2 uvChild = childUVBase + refractionDisplacement;

    // Adaptiver Blur Radius für die Child-Texture
    float stretch = length(fwidth(dispPx));
    float blurRadius = clamp(stretch * 0.45, 0.0, 6.0);

    // HINTERGRUND: Gaussian Blur (wie gewünscht)
    vec4 gS = _applyGaussianBlur(backgroundTexture, uvBase);
    
    // CHILD: Jitter Blur (gegen Pixelbildung an Kanten)
    vec4 cS = _blurJitterRefraction(childTexture, uvChild, blurRadius, sizePx, uvChild);
    
    // --- Hard Light Blending ---
    vec3 childRGB = (cS.a > 0.001) ? cS.rgb / cS.a : cS.rgb;
    vec3 blended = _blendHardLight(gS.rgb, childRGB);
    gS.rgb = mix(gS.rgb, blended, cS.a);
    
    float ca = max(chromaticAberration, 0.0);
    
    if (ca <= 1e-4) return gS;

    vec2 dirRefUV = dispPx / sizePx;
    vec4 baseAA = _sampleRefractionAA(
        backgroundTexture, uvBase, sizePx, dirRefUV,
        float(LG_REFRACT_AA_RADIUS_PX),
        float(LG_REFRACT_AA_STRENGTH),
        1.4 
    );
    
    vec3 blendedAA = _blendHardLight(baseAA.rgb, childRGB);
    gS = vec4(mix(baseAA.rgb, blendedAA, cS.a), baseAA.a);

    vec3 diffNew = _resolveDispersion(
        uvBase, childUVBase, refractionDisplacement, sizePx,
        backgroundTexture, childTexture, currentShapeIdx, ca, gS
    );

    float caMixNew = clamp(float(LG_CA_OPACITY), 0.0, 1.0);
    float edgeAA = smoothstep(-float(LG_CA_EDGE_FEATHER_PX) * fwidth(sd), 0.0, -sd);
    caMixNew *= edgeAA;
    
    vec3 finalRGB = clamp(gS.rgb + diffNew * caMixNew, 0.0, 1.0);
    return vec4(finalRGB, gS.a);
}

// Calculates lighting based on normal, rim effects, and ambient light.
vec3 _calculateTotalLighting(
    vec2 uv, vec3 normal, float sd, float thickness, float height,
    vec2 lightDirection, float lightIntensity, float ambientStrength,
    vec3 backgroundColor, float rimWidthPx, float rimSharpness
) {
    float thicknessFactor = smoothstep(5.0, 7.0, thickness);
    if (thicknessFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);
    
    RimMasks rm = _calculateRimMasks(sd, rimWidthPx, rimSharpness);
    vec2 l = lightDirection;
    vec2 nXy = _safeNormalize(normal.xy);
    
    float facing = abs(dot(nXy, l));
    float lightMask = pow(facing, 0.7);
    float rimMask = rm.band * lightMask;
    
    if (rimMask < 1e-3) return vec3(0.0);
    
    float mainL = max(0.0, dot(nXy, l));
    float oppL = max(0.0, dot(nXy, -l));
    float total = mainL + oppL * 0.8;
    
    vec3 hl = _computeAdaptiveHighlight(backgroundColor, 0.7);
    vec3 directionalRim = hl * (total * total) * lightIntensity * 2.0;
    vec3 ambientRim = _computeAdaptiveHighlight(backgroundColor, 0.4) * ambientStrength;
    
    vec3 lighting = (directionalRim + ambientRim);
    float whitePull = 0.55;
    float coreGain = mix(0.16, 0.36, clamp(rimWidthPx / 64.0, 0.0, 1.0));
    
    vec3 towardWhite = mix(lighting, vec3(1.0), whitePull);
    lighting = mix(lighting, towardWhite, rm.core * coreGain);
    
    return lighting * rimMask * thicknessFactor;
}

// Applies saturation and lightness adjustments to a color.
vec3 _adjustColorBalance(vec3 color, float saturation, float lightness) {
    float luminance = dot(color, vec3(0.299, 0.587, 0.114));
    vec3 saturatedColor = mix(vec3(luminance), color, saturation);
    
    vec3 adjustedColor = (lightness > 1.0)
        ? mix(saturatedColor, vec3(1.0), lightness - 1.0)
        : saturatedColor * lightness;
        
    return clamp(adjustedColor, 0.0, 1.0);
}

// Blends the liquid color with the glass tint.
vec4 _blendGlassTint(vec4 liquidColor, vec4 glassColor) {
    vec4 finalColor = liquidColor;
    
    if (glassColor.a > 0.0) {
        float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
        if (glassLuminance < 0.5) {
            vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
            finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
        } else {
            vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
            vec3 invGlass = vec3(1.0) - glassColor.rgb;
            vec3 screened = vec3(1.0) - (invLiquid * invGlass);
            finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
        }
        finalColor.a = liquidColor.a;
    }
    
    return finalColor;
}

// Computes the mask for touch-based glow interactions.
float _computeTouchGlowMask(vec2 pPx, vec2 pSdf, float insideOnly, float sdUnion, int currentShapeIdx) {
    float n = uTouchCount_f;
    if (n <= 0.5 || currentShapeIdx < 0) return 0.0;
    
    float outMask = 0.0;
    for (int i = 0; i < 8; ++i) {
        if (i >= int(n)) break;
        
        int owner = int(floor(uTouchOwners[i] + 0.5));
        int shapeIdx = (owner >= 0) ? owner : currentShapeIdx;
        
        float sdOwner = _sdShapeAt(shapeIdx, pSdf);
        float wAa = max(fwidth(sdOwner), 1e-6) * GLOW_OWNER_FEATHER_PX;
        float inShape = smoothstep(0.0, wAa, -sdOwner);
        
        if (inShape <= 1e-5) continue;
        
        vec4 tp = uTouches[i];
        float d = length(pPx - tp.xy);
        float inner = tp.z;
        float outer = tp.z + max(tp.w, 1e-3);
        float radial = smoothstep(outer, inner, d);
        float s = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
        
        outMask = max(outMask, radial * inShape * s);
    }
    return outMask;
}

// Approximates a Gaussian blur using a 9-tap kernel for glow effects.
vec4 _blurApprox9(sampler2D tex, vec2 uv, float sigmaPx, vec2 sizePx) {
    if (sigmaPx <= 0.01) return _sampleTexture(tex, uv);
    
    vec2 px = 1.0 / sizePx;
    float s = clamp(sigmaPx, 0.0, 6.0);
    float w0 = 0.227027;
    float w1 = 0.194594;
    float w2 = 0.121621;
    
    vec4 c = _sampleTexture(tex, uv) * w0;
    c += _sampleTexture(tex, uv + vec2( px.x,  0.0)) * w1;
    c += _sampleTexture(tex, uv + vec2(-px.x,  0.0)) * w1;
    c += _sampleTexture(tex, uv + vec2( 0.0,  px.y)) * w1;
    c += _sampleTexture(tex, uv + vec2( 0.0, -px.y)) * w1;
    c += _sampleTexture(tex, uv + vec2( px.x,  px.y)) * w2;
    c += _sampleTexture(tex, uv + vec2(-px.x,  px.y)) * w2;
    c += _sampleTexture(tex, uv + vec2( px.x, -px.y)) * w2;
    c += _sampleTexture(tex, uv + vec2(-px.x, -px.y)) * w2;
    
    float t = clamp((s - 1.0) / 5.0, 0.0, 1.0);
    return mix(_sampleTexture(tex, uv), c, t);
}

// Applies dynamic glow effects based on touch input and overrides.
vec4 _applyInteractiveGlow(
    vec4 coloredBase,
    vec4 refractColorBase,
    vec2 screenUV,
    vec2 refractionDisplacement,
    vec2 childUVBase,
    vec2 p,
    float sd,
    int currentShapeIdx,
    vec2 uSizePx,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 lighting,
    float lightness,
    float saturation,
    vec3 backgroundColor
) {
    // Basic Check
    if (currentShapeIdx < 0 || uTouchCount_f <= 0.5) return coloredBase;

    // 1. Daten für dieses Shape aus dem Array lesen
    int baseIdx = currentShapeIdx * 4;
    
    vec4 data0 = uShapeGlowData[baseIdx + 0]; // RGB=Color, W=ColorAlpha (NEU)
    vec4 data1 = uShapeGlowData[baseIdx + 1]; // X=Power, Y=Mix, Z=Blur, W=Inside
    vec4 data2 = uShapeGlowData[baseIdx + 2]; // X=Light, Y=Sat, Z=TintMode, W=Strength (NEU)
    vec4 data3 = uShapeGlowData[baseIdx + 3]; // RGBA=GlowGlassOverride

    // Strength kommt jetzt aus data2.w
    float gStrength = data2.w;
    
    // Early Exit Check
    if (gStrength <= 0.0001) {
        return coloredBase;
    }
    
    float gInside = data1.w;
    float maskRaw = _computeTouchGlowMask(p, p, gInside, sd, currentShapeIdx);
    
    if (maskRaw <= 0.0) {
        return coloredBase;
    }
    
    float gPower = max(data1.x, 0.0001);
    float gMix = clamp(data1.y, 0.0, 1.0);
    
    float shaped = pow(clamp(maskRaw, 0.0, 1.0), gPower) * gStrength * gMix;
    shaped = clamp(shaped, 0.0, 1.0);

    // Overrides prüfen (-1.0 bedeutet "nicht gesetzt")
    float tLight = data2.x;
    float tSatu  = data2.y;
    // Glass Tint Override (Wenn nicht gesetzt, ist es die globale Farbe)
    vec4 tGlass  = data3;

    float effLight = (tLight > -0.5) ? mix(lightness, tLight, shaped) : lightness;
    float effSatu  = (tSatu > -0.5)  ? mix(saturation, tSatu, shaped) : saturation;
    vec4 effGlass  = mix(uGlassColor, tGlass, shaped);

    // Blur Override
    vec4 refractLocal = refractColorBase;
    float tBlur = data1.z;
    float extraSigma = (tBlur > -0.5) ? max(tBlur - uGlobalBlurSigma, 0.0) : 0.0;
    
    if (extraSigma > 0.01) {
        vec2 uvBase = screenUV + refractionDisplacement;
        refractLocal = _blurApprox9(backgroundTexture, uvBase, extraSigma, uSizePx);
        vec4 cC = _sampleTexture(childTexture, childUVBase + refractionDisplacement);
        refractLocal = mix(refractLocal, cC, cC.a);
    }

    vec4 coloredLocal = _blendGlassTint(refractLocal, effGlass);
    coloredLocal.rgb += lighting;
    coloredLocal.rgb = _adjustColorBalance(coloredLocal.rgb, effSatu, effLight);

    // Tint Mode Logic
    float gTintMode = data2.z;
    float colorAlpha = data0.w; // NEU: Alpha kommt jetzt aus data0.w

    vec3 tint;
    if (gTintMode < 0.5) {
        tint = vec3(1.0); // Weiß
    } else if (gTintMode < 1.5) {
        tint = _computeAdaptiveHighlight(backgroundColor, 1.0); // Adaptiv
    } else {
        tint = data0.rgb; // Custom Color
    }
    
    // Tint auftragen. 
    // Wir multiplizieren die Stärke des Effekts (shaped) mit dem Alpha der Farbe.
    vec4 tintGlass = vec4(tint, shaped * colorAlpha); 
    
    coloredLocal = _blendGlassTint(coloredLocal, tintGlass);
    
    return mix(coloredBase, coloredLocal, shaped);
}

// Main rendering function for the Liquid Glass effect.
// Integrates refraction, lighting, glass tinting, and interactive glow.
vec4 renderLiquidGlass(
    vec2 screenUV,
    vec2 childUVBase,
    vec2 p, vec2 uSizePx,
    float sd, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec4 glassColor, vec2 lightDirection, float lightIntensity, float ambientStrength,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 normal, float foregroundAlpha,
    float saturation, float lightness, float rimWidthPx, float rimSharpness,
    int currentShapeIdx
) {
    vec4 backgroundColor = _sampleTexture(backgroundTexture, screenUV);
    
    if (foregroundAlpha < 0.001 || thickness < 0.01) {
        return backgroundColor;
    }

    float height = _calculateLiquidHeight(sd, thickness);
    vec2 refractionDisplacement;

    vec4 refractColorBase = _calculateRefractionLayer(
        screenUV, normal, sd, height, thickness,
        refractiveIndex, chromaticAberration,
        uSizePx, backgroundTexture,
        childTexture, childUVBase,
        refractionDisplacement,
        rimWidthPx, rimSharpness, lightDirection, lightIntensity,
        currentShapeIdx
    );

    refractColorBase.rgb = _applyRimHighlight(refractColorBase.rgb, normal, sd, rimWidthPx, rimSharpness);

    vec3 lighting = _calculateTotalLighting(
        screenUV, normal, sd, thickness, height,
        lightDirection, lightIntensity, ambientStrength,
        backgroundColor.rgb, rimWidthPx, rimSharpness
    );

    vec4 coloredBase = _blendGlassTint(refractColorBase, glassColor);
    coloredBase.rgb += lighting;
    coloredBase.rgb = _adjustColorBalance(coloredBase.rgb, saturation, lightness);

    vec4 outColor = _applyInteractiveGlow(
        coloredBase, refractColorBase, screenUV, refractionDisplacement, childUVBase,
        p, sd, currentShapeIdx, uSizePx, backgroundTexture, childTexture,
        lighting, lightness, saturation, backgroundColor.rgb
    );

    float coverage = _computeCoverageAA(sd);
    float baseA = foregroundAlpha * coverage;
    
    RimMasks rm = _calculateRimMasks(sd, rimWidthPx, rimSharpness);
    float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPx / 64.0, 0.0, 1.0));
    float rimA = rm.band * edgeAlphaGain;
    float mixA = clamp(max(baseA, rimA), 0.0, 1.0);

    return mix(backgroundColor, outColor, mixA);
}

#endif