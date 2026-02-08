#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

#ifndef TAU
#define TAU 6.28318530718
#endif

// Constants maintained
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

#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

struct RimMasks {
    float band;
    float core;
};

// Utilities
float _hashRefraction(vec2 position) {
    return fract(sin(dot(position, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 _safeNormalize(vec2 v) {
    float lengthSquared = max(dot(v, v), LG_EPS);
    return v * inversesqrt(lengthSquared);
}

vec2 _uvFromPx(vec2 pixel, vec2 sizePixels) {
    vec2 uv = pixel / max(sizePixels, vec2(1.0));
    #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
    #endif
    return uv;
}

vec4 _sampleTexture(sampler2D t, vec2 uv) {
    return texture(t, clamp(uv, vec2(0.0), vec2(1.0)));
}

vec4 _sampleNearest(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 pixel = uv * texSize;
    vec2 nearestPixel = floor(pixel) + 0.5;
    vec2 nearestUV = nearestPixel / texSize;
    return texture(tex, clamp(nearestUV, vec2(0.0), vec2(1.0)));
}

void _readShapeData(int shapeIndex, out float type, out vec2 center, out vec2 size, out float cornerRadius) {
    int baseIndex = shapeIndex * 7;
    type = uShapeData[baseIndex + 0];
    center = vec2(uShapeData[baseIndex + 1], uShapeData[baseIndex + 2]);
    size = vec2(uShapeData[baseIndex + 3], uShapeData[baseIndex + 4]);
    cornerRadius = uShapeData[baseIndex + 5];
}

float _sdRoundedRect(vec2 position, vec2 center, vec2 size, float radius) {
    vec2 halfSize = max(size * 0.5, vec2(0.0));
    float clampedRadius = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    vec2 q = abs(position - center) - (halfSize - vec2(clampedRadius));
    return length(max(q, 0.0)) - clampedRadius + min(max(q.x, q.y), 0.0);
}

float _sdEllipse(vec2 position, vec2 center, vec2 size) {
    vec2 ab = max(size * 0.5, vec2(1e-4));
    vec2 d = (position - center) / ab;
    float k = length(d) - 1.0;
    return k * min(ab.x, ab.y);
}

float _sdShapeAt(int shapeIndex, vec2 position) {
    float type, radius;
    vec2 center, size;
    _readShapeData(shapeIndex, type, center, size, radius);
    if (type == 2.0) return _sdEllipse(position, center, size);
    return _sdRoundedRect(position, center, size, radius);
}

vec2 _projectSdfToScreen(vec2 positionSdf) {
    mat4 inverseTransform = inverse(uTransform);
    vec4 positionScreen = inverseTransform * vec4(positionSdf, 0.0, 1.0);
    float w = max(positionScreen.w, 1e-6);
    return positionScreen.xy / w;
}

vec4 _blurJitterRefraction(sampler2D tex, vec2 uv, float blurAmount, vec2 sizePixels, vec2 seed) {
    if (blurAmount <= 0.1) return _sampleTexture(tex, uv); 
    
    vec2 pixelSize = 1.0 / sizePixels;
    if (blurAmount < 1.0) {
        float r = _hashRefraction(seed) - 0.5; 
        vec2 jitter = vec2(r, -r) * blurAmount * pixelSize;
        return _sampleTexture(tex, uv + jitter);
    }
    
    float spread = blurAmount * 0.7; 
    vec4 color = _sampleNearest(tex, uv + vec2(-spread, -spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2( spread, -spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2(-spread,  spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2( spread,  spread) * pixelSize, sizePixels);
    return color * 0.25;
}

vec4 _applyGaussianBlur(sampler2D tex, vec2 baseUV) {
    vec2 pixel = vec2(1.0 / uSize.x, 1.0 / uSize.y);
    vec2 stepVec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);
    float sampleCountRaw = u_sample_count;
    
    vec2 eps = vec2(0.5) / max(uSize, vec2(1.0));
    vec2 minUV = eps;
    vec2 maxUV = vec2(1.0) - eps;

    if (sampleCountRaw <= 0.5) {
        return texture(tex, clamp(baseUV, minUV, maxUV));
    }

    vec4 sum = vec4(0.0);
    float weightSum = 0.0;
    int sampleCount = int(sampleCountRaw + 0.5);

    // UNROLLED LOGIC / BRANCH REMOVAL
    for (int i = 0; i < 24; ++i) {
        if (i >= sampleCount) break;
        
        float t = u_samples[i].x;
        float weight = u_samples[i].z;
        
        vec2 offsetUV = baseUV + stepVec * t;
        vec2 clampedUV = clamp(offsetUV, minUV, maxUV);
        
        sum += weight * texture(tex, clampedUV);
        weightSum += weight;
    }

    if (weightSum > 1e-6) return sum / weightSum;
    return texture(tex, clamp(baseUV, minUV, maxUV));
}

vec4 _blurApprox9(sampler2D tex, vec2 uv, float sigmaPixels, vec2 sizePixels) {
    if (sigmaPixels <= 0.01) return _sampleTexture(tex, uv);
    
    vec2 px = 1.0 / sizePixels;
    float spread = clamp(sigmaPixels, 0.0, 6.0);
    
    float weightCenter = 0.227027;
    float weightNear = 0.194594;
    float weightFar = 0.121621;
    
    vec4 centerCol = _sampleTexture(tex, uv);
    vec4 color = centerCol * weightCenter;
    
    color += _sampleTexture(tex, uv + vec2( px.x,  0.0)) * weightNear;
    color += _sampleTexture(tex, uv + vec2(-px.x,  0.0)) * weightNear;
    color += _sampleTexture(tex, uv + vec2( 0.0,  px.y)) * weightNear;
    color += _sampleTexture(tex, uv + vec2( 0.0, -px.y)) * weightNear;
    
    color += _sampleTexture(tex, uv + vec2( px.x,  px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2(-px.x,  px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2( px.x, -px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2(-px.x, -px.y)) * weightFar;
    
    float t = clamp((spread - 1.0) / 5.0, 0.0, 1.0);
    return mix(centerCol, color, t);
}

vec4 _sampleAberrationAA(sampler2D tex, vec2 uvCenter, vec2 aberrationUV, vec2 sizePixels) {
    float lengthPixels = length(aberrationUV * sizePixels);
    if (lengthPixels < 1e-4) return _sampleTexture(tex, uvCenter);
    
    vec2 px = 1.0 / sizePixels;
    vec2 dir = normalize(aberrationUV + vec2(1e-6));
    float radiusPixels = float(LG_CA_AA_RADIUS_PX);
    float strength = clamp(float(LG_CA_AA_STRENGTH), 0.0, 1.0);
    
    vec2 offsetUV = dir * radiusPixels * px;
    vec4 c0 = _sampleTexture(tex, uvCenter);
    vec4 c1 = _sampleTexture(tex, uvCenter + offsetUV);
    vec4 c2 = _sampleTexture(tex, uvCenter - offsetUV);
    
    #if LG_CA_AA_TAPS == 2
    vec4 average = 0.5 * (c1 + c2);
    #else
    vec4 average = (c0 + c1 + c2) / 3.0;
    #endif
    return mix(c0, average, strength);
}

vec4 _sampleRGSS4(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPixels, float gain) {
    vec2 ortho = vec2(-dir.y, dir.x);
    vec2 o0 = vec2(0.5, 0.5);
    vec2 o1 = vec2(-0.5, 0.5);
    vec2 o2 = vec2(0.5, -0.5);
    vec2 o3 = vec2(-0.5, -0.5);
    
    vec2 a0 = (dir * (o0.x * gain) + ortho * o0.y) * radiusPixels;
    vec2 a1 = (dir * (o1.x * gain) + ortho * o1.y) * radiusPixels;
    vec2 a2 = (dir * (o2.x * gain) + ortho * o2.y) * radiusPixels;
    vec2 a3 = (dir * (o3.x * gain) + ortho * o3.y) * radiusPixels;
    
    vec4 c0 = _applyGaussianBlur(tex, uv + a0 * px);
    vec4 c1 = _applyGaussianBlur(tex, uv + a1 * px);
    vec4 c2 = _applyGaussianBlur(tex, uv + a2 * px);
    vec4 c3 = _applyGaussianBlur(tex, uv + a3 * px);
    
    return (c0 + c1 + c2 + c3) * 0.25;
}

vec4 _sampleRefractionAA(sampler2D tex, vec2 uv, vec2 sizePixels, vec2 directionUV, float radiusPixels, float strength, float gain) {
    vec2 px = vec2(1.0 / sizePixels.x, 1.0 / sizePixels.y);
    vec2 dir = normalize(directionUV + vec2(1e-6));
    
    vec4 average = _sampleRGSS4(tex, uv, px, dir, radiusPixels, gain);
    vec4 base = _applyGaussianBlur(tex, uv);
    
    return mix(base, average, clamp(strength, 0.0, 1.0));
}

vec3 _computeAdaptiveHighlight(vec3 backgroundColor, float targetBrightness) {
    float luminance = dot(backgroundColor, vec3(0.299, 0.587, 0.114));
    
    // Branchless replacement for "if (luminance > 0.001)"
    vec3 normalizedBackground = backgroundColor / max(luminance, 1e-6);
    vec3 coloredHighlight = normalizedBackground * targetBrightness;
    
    float saturationBoost = 1.3;
    vec3 gray = vec3(dot(coloredHighlight, vec3(0.299, 0.587, 0.114)));
    coloredHighlight = mix(gray, coloredHighlight, saturationBoost);
    coloredHighlight = min(coloredHighlight, vec3(1.0));

    // Smooth transition handles the "branch"
    float luminanceFactor = smoothstep(0.0, 0.6, luminance);
    
    float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
    float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
    float saturation = (maxC > 1e-6) ? (maxC - minC) / maxC : 0.0;
    
    float saturationFactor = smoothstep(0.0, 0.4, saturation);
    float colorInfluence = luminanceFactor * saturationFactor;
    
    vec3 whiteHighlight = vec3(1.0 * targetBrightness);
    return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

// FIX: renamed 'uThickness' to 'thickness' to avoid macro collision
float _calculateLiquidHeight(float signedDistance, float thickness) {
    if (signedDistance >= 0.0) return 0.0;
    if (thickness <= 0.0) return 0.0;
    if (signedDistance < -thickness) return thickness;
    
    float x = thickness + signedDistance;
    return sqrt(max(0.0, thickness * thickness - x * x));
}

// FIX: renamed params to avoid macro collision
RimMasks _calculateRimMasks(float signedDistance, float rimWidthPixels, float rimSharp) {
    vec2 gradient = vec2(dFdx(signedDistance), dFdy(signedDistance));
    float gradientMagnitude = max(length(gradient), 1e-6);
    float widthSdf = max(rimWidthPixels, 0.0) * gradientMagnitude;
    
    float edge01 = step(signedDistance, 0.0) * smoothstep(-widthSdf, 0.0, signedDistance);
    float gamma = max(rimSharp, 1e-3);
    
    float band = pow(edge01, 1.0 / gamma);
    float coreExponent = mix(3.0, 1.1, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    float core = pow(edge01, coreExponent / gamma);
    
    RimMasks masks;
    masks.band = band;
    masks.core = core;
    return masks;
}

float _fresnelSchlick(float cosTheta, float f0) {
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}

vec4 _blendGlassTint(vec4 liquidColor, vec4 glassColor) {
    vec4 finalColor = liquidColor;
    if (glassColor.a > 0.0) {
        float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
        float isDark = step(glassLuminance, 0.5);
        
        vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
        vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
        vec3 invGlass = vec3(1.0) - glassColor.rgb;
        vec3 screened = vec3(1.0) - (invLiquid * invGlass);
        
        vec3 targetRGB = mix(screened, darkened, isDark);
        finalColor.rgb = mix(liquidColor.rgb, targetRGB, glassColor.a);
        finalColor.a = liquidColor.a;
    }
    return finalColor;
}

vec3 _adjustColorBalance(vec3 color, float saturation, float lightness) {
    float luminance = dot(color, vec3(0.299, 0.587, 0.114));
    vec3 saturatedColor = mix(vec3(luminance), color, saturation);
    
    vec3 lightBoost = mix(saturatedColor, vec3(1.0), lightness - 1.0);
    vec3 lightDim = saturatedColor * lightness;
    
    vec3 adjustedColor = mix(lightDim, lightBoost, step(1.0, lightness));
    return clamp(adjustedColor, 0.0, 1.0);
}

// Computes anti-aliased coverage for the shape edge.
float _computeCoverageAA(float sd) {
    float w = fwidth(sd);
    return smoothstep(-w, w, -sd);
}



// vec3 _blendHardLight(vec3 base, vec3 blend) {
//     vec3 t1 = 2.0 * base * blend;
//     vec3 t2 = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
//     vec3 selection = step(0.5, blend);
//     return mix(t1, t2, selection);
// }

vec3 _blendHardLight(vec3 base, vec3 blend) {
   // ---------------------------------------------------------
    // WERKSTATT 1: DARK MODE (Bleibt 100% gleich)
    // ---------------------------------------------------------
    vec3 darkBlend = blend;

    float greenIntensity = smoothstep(0.3, 1.0, base.g);
    float greenFactor = mix(1.0, 0.71, greenIntensity); 
    darkBlend.g = blend.g * greenFactor;

    // Dieser Boost hier gilt nur für den Dark Mode (Screen-Formel)
    float redIntensityDark = smoothstep(0.7, 0.95, base.r); 
    darkBlend.r = mix(darkBlend.r, 1.0, redIntensityDark);

    float greenBgStrong = smoothstep(0.5, 1.0, base.g);
    darkBlend.r = darkBlend.r * mix(1.0, 0.96, greenBgStrong);


    // ---------------------------------------------------------
    // WERKSTATT 2: LIGHT MODE (Smarter Fix)
    // ---------------------------------------------------------
    vec3 lightBlend = blend;

    // WICHTIG: Neue Erkennung! 
    // Wir prüfen: Ist Rot dominanter als Grün?
    // Orange HG: R=1.0, G=0.6 -> Diff 0.4 -> Boost Aktiv
    // Grauer HG: R=0.9, G=0.9 -> Diff 0.0 -> Boost Inaktiv
    float isRedBackground = smoothstep(0.1, 0.3, base.r - base.g);

    // Wir boosten Rot um 10-15%, aber NUR wenn es wirklich ein roter Hintergrund ist.
    float lightRedBoost = mix(1.0, 1.08, isRedBackground); 
    lightBlend.r = lightBlend.r * lightRedBoost;


    // ---------------------------------------------------------
    // BERECHNUNG
    // ---------------------------------------------------------
    vec3 t1 = 2.0 * base * lightBlend;
    vec3 t2 = 1.0 - 2.0 * (1.0 - base) * (1.0 - darkBlend);
    
    vec3 selection = step(0.5, blend);
    return mix(t1, t2, selection);
}


// FIX: renamed params uGlassColor -> glassColor, uSaturation -> saturation, uLightness -> lightness
vec3 _resolveDispersion(
    vec2 uvBase,
    vec2 childUVBase,
    vec2 refractionDisplacement,
    vec2 sizePixels,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    int shapeIndex,
    float aberrationStrength,
    vec4 baseColor, 
    float saturation,
    float lightness,
    vec4 glassColor,
    float isIcon // <--- NEU
) {
    float type, radius;
    vec2 centerSdf, sizeSdf;
    _readShapeData(shapeIndex, type, centerSdf, sizeSdf, radius);
    
    vec2 centerPx = _projectSdfToScreen(centerSdf);
    vec2 centerUV = _uvFromPx(centerPx, sizePixels);
    
    vec2 col0 = uTransform[0].xy;
    vec2 col1 = uTransform[1].xy;
    float scaleX = max(length(col0), 1e-6);
    float scaleY = max(length(col1), 1e-6);
    
    float widthScreen = sizeSdf.x / scaleX;
    float heightScreen = sizeSdf.y / scaleY;
    float minDimensionScreen = min(widthScreen, heightScreen);
    
    vec2 distUV = uvBase - centerUV;
    float dispersion = aberrationStrength * AGSL_DISPERSION_SCALE;
    vec2 minDimOverSize = vec2(minDimensionScreen / sizePixels.x, minDimensionScreen / sizePixels.y);
    vec2 distCubed = distUV * distUV * distUV;
    
    float distortMagnitude = length(refractionDisplacement);
    float boost = 1.0 + (distortMagnitude * 60.0);
    vec2 aberrationUV = (dispersion * distCubed * minDimOverSize) * boost;
    
    vec2 halfPx = (1.0 / sizePixels) * 0.5;
    vec2 uvRed = uvBase - aberrationUV + halfPx;
    vec2 uvBlue = uvBase + aberrationUV + halfPx;
    
    vec4 sampleRedBg = _sampleTexture(backgroundTexture, uvRed);
    vec4 sampleBlueBg = _sampleTexture(backgroundTexture, uvBlue);
    
    vec4 sampleRedChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement - aberrationUV);
    vec4 sampleBlueChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement + aberrationUV);
    vec4 sampleGreenChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement); 

    sampleRedBg = _blendGlassTint(sampleRedBg, glassColor);
    sampleRedBg.rgb = _adjustColorBalance(sampleRedBg.rgb, saturation, lightness);
    
    sampleBlueBg = _blendGlassTint(sampleBlueBg, glassColor);
    sampleBlueBg.rgb = _adjustColorBalance(sampleBlueBg.rgb, saturation, lightness);

    if (sampleRedChild.a <= 0.001) sampleRedChild = sampleGreenChild;
    if (sampleBlueChild.a <= 0.001) sampleBlueChild = sampleGreenChild;

    // Un-Premultiply (sicher)
    vec3 colorRed = (sampleRedChild.a > 0.001) ? sampleRedChild.rgb / sampleRedChild.a : sampleRedChild.rgb;
    vec3 colorBlue = (sampleBlueChild.a > 0.001) ? sampleBlueChild.rgb / sampleBlueChild.a : sampleBlueChild.rgb;
    
    // --- RED CHANNEL ---
    vec3 hardLightRed = _blendHardLight(sampleRedBg.rgb, colorRed);
    // Wenn Foto -> nimm colorRed (Original). Wenn Icon -> nimm hardLightRed (Glas).
    vec3 targetRed = mix(colorRed, hardLightRed, isIcon);
    
    float redComponent = mix(sampleRedBg.r, targetRed.r, sampleRedChild.a);

    // --- BLUE CHANNEL ---
    vec3 hardLightBlue = _blendHardLight(sampleBlueBg.rgb, colorBlue);
    // Wenn Foto -> nimm colorBlue (Original). Wenn Icon -> nimm hardLightBlue (Glas).
    vec3 targetBlue = mix(colorBlue, hardLightBlue, isIcon);
    
    float blueComponent = mix(sampleBlueBg.b, targetBlue.b, sampleBlueChild.a);

    // Green bleibt Base (Mitte)
    float greenComponent = baseColor.g; 

    vec3 spectralNew = vec3(redComponent, greenComponent, blueComponent);
    vec3 diff = spectralNew - baseColor.rgb;
    diff *= float(LG_CA_LIGHTNESS_BOOST) * float(LG_CA_NEW_GAIN);
    
    float luminanceNew = dot(diff, vec3(0.299, 0.587, 0.114));
    return mix(vec3(luminanceNew), diff, float(LG_CA_SATURATION_BOOST));
}

// FIX: Renamed params to avoid macro collision (uThickness->thickness, etc)
vec4 _calculateRefractionLayer(
    vec2 screenUV, vec3 normal, float signedDistance, float height, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec2 sizePixels, sampler2D backgroundTexture,
    sampler2D childTexture,
    vec2 childUVBase,
    vec3 keyColor,
    out vec2 outRefractionDisplacement,
    out vec4 outRawTexture,
    int shapeIndex,
    float saturation,
    float lightness,
    vec4 glassColor, vec3 lighting
) {
    vec3 incident = vec3(0.0, 0.0, -1.0);
    // max() verhindert Division durch 0 bei Brechungsindex, ohne Branching
    float n = max(refractiveIndex, 1.0001);
    vec3 refractVec = refract(incident, normal, 1.0 / n);
    
    float baseHeight = thickness * 8.0;
    // abs() ist sehr schnell auf GPUs
    float refractLength = (height + baseHeight) / max(0.001, abs(refractVec.z));
    
    vec2 displacementPixels = refractVec.xy * refractLength;
    outRefractionDisplacement = displacementPixels / sizePixels;
    
    vec2 uvBase = screenUV + outRefractionDisplacement;
    vec2 uvChild = childUVBase + outRefractionDisplacement;

    // fwidth ist Hardware-implementiert und sehr schnell
    float stretch = length(fwidth(displacementPixels));
    float blurRadius = clamp(stretch * 0.45, 0.0, 6.0);

    // 1. Base Background Sample
    vec4 backgroundSample = _applyGaussianBlur(backgroundTexture, uvBase);
    outRawTexture = backgroundSample;

    backgroundSample = _blendGlassTint(backgroundSample, glassColor);
    backgroundSample.rgb += lighting;
    backgroundSample.rgb = _adjustColorBalance(backgroundSample.rgb, saturation, lightness);
    
    // -------------------------------------------------------------------------
    // 2. Child Sample & COLOR KEYING (Optimized)
    // -------------------------------------------------------------------------
    
    vec4 childSample = _blurJitterRefraction(childTexture, uvChild, blurRadius, sizePixels, uvChild);
    
    // OPTIMIERUNG: Branchless Un-Premultiply
    // Anstatt if/else nutzen wir max(), um Division durch 0 zu verhindern.
    // Das ist ein konstanter Rechenpfad für die GPU.
    vec3 childRGB = childSample.rgb / max(childSample.a, 1.0e-4);

    // --- KEYING LOGIC (Vectorized) ---
    // abs() auf vec3 ist sehr effizient (Single Cycle)
    vec3 diffVec = abs(childRGB - keyColor);
    // max() Kette ist billig
    float diff = max(diffVec.r, max(diffVec.g, diffVec.b));
    
    // smoothstep wird auf der GPU in Hardware berechnet -> sehr schnell
    // Ergebnis: 1.0 = Icon (Glas), 0.0 = Bild (Normal)
    float isIcon = 1.0 - smoothstep(0.01, 0.04, diff);

    // vec3 debugColor = mix(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), isIcon);
    
    // // Alpha auf 1.0 setzen, damit wir es deutlich sehen, 
    // // oder childSample.a nutzen um die Form beizubehalten.
    // return vec4(debugColor, 1.0); 
    
    // ---------------------------------

    // Wir berechnen den Glas-Blend immer (kein 'if'), da Pipelining schneller ist als Branching
    vec3 blendedRGB = _blendHardLight(backgroundSample.rgb, childRGB);
    
    // mix() (Linear Interpolation) ist extrem optimiert auf GPUs
    vec3 finalBlend = mix(childRGB, blendedRGB, isIcon);
    
    // In den Hintergrund mischen
    backgroundSample.rgb = mix(backgroundSample.rgb, finalBlend, childSample.a);
    
    // -------------------------------------------------------------------------

    float ca = max(chromaticAberration, 0.0);
    
    // Dieser Branch ist okay, da er oft kohärent für den ganzen Screen ist
    if (ca <= 0.005) {
        return vec4(clamp(backgroundSample.rgb, 0.0, 1.0), backgroundSample.a);
    }

    vec2 dirRefUV = displacementPixels / sizePixels;
    
    vec4 baseAA = _sampleRefractionAA(
        backgroundTexture, uvBase, sizePixels, dirRefUV,
        float(LG_REFRACT_AA_RADIUS_PX),
        float(LG_REFRACT_AA_STRENGTH),
        1.4 
    );
    
    baseAA = _blendGlassTint(baseAA, glassColor);
    baseAA.rgb += lighting;
    baseAA.rgb = _adjustColorBalance(baseAA.rgb, saturation, lightness);
    
    // Auch im CA Pfad: Keying Logik anwenden (Code Reuse durch GPU Compiler)
    vec3 glassAA = _blendHardLight(baseAA.rgb, childRGB);
    vec3 finalAA = mix(childRGB, glassAA, isIcon);

    backgroundSample = vec4(mix(baseAA.rgb, finalAA, childSample.a), baseAA.a);

    vec3 diffNew = _resolveDispersion(
        uvBase, childUVBase, outRefractionDisplacement, sizePixels,
        backgroundTexture, childTexture, shapeIndex, ca, backgroundSample,
        saturation, lightness, glassColor, isIcon
    );

    float caMixNew = clamp(float(LG_CA_OPACITY), 0.0, 1.0);
    
    // fwidth ist hier wichtig für Anti-Aliasing am Rand
    float edgeAA = smoothstep(-float(LG_CA_EDGE_FEATHER_PX) * fwidth(signedDistance), 0.0, -signedDistance);
    caMixNew *= edgeAA;
    
    vec3 finalRGB = clamp(backgroundSample.rgb + diffNew * caMixNew, 0.0, 1.0);
    return vec4(finalRGB, backgroundSample.a);
}

// FIX: Renamed params uThickness->thickness, uLightDirection->lightDirection, etc.
vec3 _calculateTotalLighting(
    float signedDistance, float thickness,
    vec2 lightDirection, float lightIntensity, float ambientStrength,
    vec3 backgroundColor, float rimWidthPixels,
    RimMasks masks,       // <-- Cached
    vec2 nXyNormalized    // <-- Cached
) {
    float thicknessFactor = smoothstep(5.0, 7.0, thickness);
    if (thicknessFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);
    
    float facing = abs(dot(nXyNormalized, lightDirection));
    float lightMask = pow(facing, 0.7);
    float rimMask = masks.band * lightMask;
    
    if (rimMask < 1e-3) return vec3(0.0);
    
    float mainLight = max(0.0, dot(nXyNormalized, lightDirection));
    float oppositeLight = max(0.0, dot(nXyNormalized, -lightDirection));
    float totalLight = mainLight + oppositeLight * 0.8;
    
    vec3 highlight = _computeAdaptiveHighlight(backgroundColor, 0.7);
    vec3 directionalRim = highlight * (totalLight * totalLight) * lightIntensity * 2.0;
    vec3 ambientRim = _computeAdaptiveHighlight(backgroundColor, 0.4) * ambientStrength;
    
    vec3 lighting = (directionalRim + ambientRim);
    float whitePull = 0.55;
    float coreGain = mix(0.16, 0.36, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    
    vec3 towardWhite = mix(lighting, vec3(1.0), whitePull);
    lighting = mix(lighting, towardWhite, masks.core * coreGain);
    
    return lighting * rimMask * thicknessFactor;
}

float _computeTouchGlowMask(vec2 positionPixels, vec2 positionSdf, float insideOnly, float sdUnion, int shapeIndex) {
    float count = uTouchCount_f;
    if (count <= 0.5 || shapeIndex < 0) return 0.0;
    
    float outMask = 0.0;
    for (int i = 0; i < 8; ++i) {
        if (i >= int(count)) break;
        
        int owner = int(floor(uTouchOwners[i] + 0.5));
        int targetShape = (owner >= 0) ? owner : shapeIndex;
        
        float sdOwner = _sdShapeAt(targetShape, positionSdf);
        float widthAa = max(fwidth(sdOwner), 1e-6) * GLOW_OWNER_FEATHER_PX;
        float inShape = smoothstep(0.0, widthAa, -sdOwner);
        
        if (inShape <= 1e-5) continue;
        
        vec4 touchParams = uTouches[i];
        float dist = length(positionPixels - touchParams.xy);
        float inner = touchParams.z;
        float outer = touchParams.z + max(touchParams.w, 1e-3);
        float radial = smoothstep(outer, inner, dist);
        float strength = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
        
        outMask = max(outMask, radial * inShape * strength);
    }
    return outMask;
}

// FIX: Renamed params uSizePx->size, etc.
vec4 _applyInteractiveGlow(
    vec4 coloredBase,
    vec4 refractColorBase,
    vec2 screenUV,
    vec2 refractionDisplacement,
    vec2 childUVBase,
    vec2 position,
    float signedDistance,
    int shapeIndex,
    vec2 size,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 lighting,
    float lightness,
    float saturation,
    vec3 backgroundColor
) {
    if (shapeIndex < 0 || uTouchCount_f <= 0.5) return coloredBase;

    int baseIndex = shapeIndex * 4;
    
    vec4 data0 = uShapeGlowData[baseIndex + 0];
    vec4 data1 = uShapeGlowData[baseIndex + 1];
    vec4 data2 = uShapeGlowData[baseIndex + 2];
    vec4 data3 = uShapeGlowData[baseIndex + 3];

    float glowStrength = data2.w;
    if (glowStrength <= 0.0001) return coloredBase;
    
    float glowInside = data1.w;
    float maskRaw = _computeTouchGlowMask(position, position, glowInside, signedDistance, shapeIndex);
    
    if (maskRaw <= 0.0) return coloredBase;
    
    float glowPower = max(data1.x, 0.0001);
    float glowMix = clamp(data1.y, 0.0, 1.0);
    
    float shaped = pow(clamp(maskRaw, 0.0, 1.0), glowPower) * glowStrength * glowMix;
    shaped = clamp(shaped, 0.0, 1.0);

    float tLight = data2.x;
    float tSat = data2.y;
    vec4 tGlass = data3;

    float effectiveLight = (tLight > -0.5) ? mix(lightness, tLight, shaped) : lightness;
    float effectiveSat = (tSat > -0.5)  ? mix(saturation, tSat, shaped) : saturation;
    // ACHTUNG: uGlassColor hier ist ein Uniform und kollidiert mit der main definition,
    // aber wir sind in einer Funktion. Wenn uGlassColor nicht als Parameter übergeben wurde,
    // greift es auf das globale Uniform zu (was OK ist, solange kein #define uGlassColor... aktiv ist).
    // ABER: Im main shader haben wir #define uGlassColor... NICHT gemacht (es ist ein vec4 Uniform).
    // Warte, uGlassColor ist layout(location=1). Das ist kein Makro. Das ist sicher.
    vec4 effectiveGlass = mix(uGlassColor, tGlass, shaped);

    vec4 refractLocal = refractColorBase;
    float tBlur = data1.z;
    float extraSigma = (tBlur > -0.5) ? max(tBlur - uGlobalBlurSigma, 0.0) : 0.0;
    
    if (extraSigma > 0.01) {
        vec2 uvBase = screenUV + refractionDisplacement;
        refractLocal = _blurApprox9(backgroundTexture, uvBase, extraSigma, size);
        vec4 childColor = _sampleTexture(childTexture, childUVBase + refractionDisplacement);
        refractLocal = mix(refractLocal, childColor, childColor.a);
    }

    vec4 coloredLocal = _blendGlassTint(refractLocal, effectiveGlass);
    coloredLocal.rgb += lighting;
    coloredLocal.rgb = _adjustColorBalance(coloredLocal.rgb, effectiveSat, effectiveLight);

    float glowTintMode = data2.z;
    float colorAlpha = data0.w;

    vec3 tint;
    if (glowTintMode < 0.5) {
        tint = vec3(1.0);
    } else if (glowTintMode < 1.5) {
        tint = _computeAdaptiveHighlight(backgroundColor, 1.0);
    } else {
        tint = data0.rgb;
    }
    
    vec4 tintGlass = vec4(tint, shaped * colorAlpha); 
    coloredLocal = _blendGlassTint(coloredLocal, tintGlass);
    
    return mix(coloredBase, coloredLocal, shaped);
}

// FIX: Renamed ALL params to avoid collision with Macros in Main Shader
vec4 renderLiquidGlass(
    vec2 screenUV,              
    vec2 childUVBase,           
    vec2 position,              
    vec2 size,                  
    float signedDistance,       
    float thickness,            
    float refractiveIndex,      
    float chromaticAberration,  
    vec4 glassColor,            
    vec2 lightDirection,        
    float lightIntensity,       
    float ambientStrength,
    vec3 keyColor,      
    sampler2D backgroundTexture,
    sampler2D childTexture,     
    vec3 normal,
    float foregroundAlpha,
    float saturation,           
    float lightness,            
    float rimWidthPixels,       
    float rimSharp,         
    int shapeIndex
) {
    // 1. Background Sample
    vec4 backgroundColor = _sampleTexture(backgroundTexture, screenUV);
    
    // 2. Early Exit (Safety)
    if (foregroundAlpha < 0.001 || thickness < 0.01) {
        return backgroundColor;
    }

    // --- GEOMETRY PRE-CALCULATION ---
    float height = _calculateLiquidHeight(signedDistance, thickness);
    
    // Rim Masks einmal berechnen (Performance)
    RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels, rimSharp);
    
    // Normalisierung für Lighting cachen
    vec2 nXyNormalized = _safeNormalize(normal.xy);
    
    // 3. Lighting Calculation
    vec3 lighting = _calculateTotalLighting(
        signedDistance, thickness,
        lightDirection, lightIntensity, ambientStrength,
        backgroundColor.rgb, rimWidthPixels, 
        masks, nXyNormalized 
    );

    // 4. Refraction Layer
    vec2 refractionDisplacement;
    vec4 rawRefractionTexture;
    
    vec4 refractColorBase = _calculateRefractionLayer(
        screenUV, normal, signedDistance, height, thickness,
        refractiveIndex, chromaticAberration,
        size, backgroundTexture,
        childTexture, childUVBase, keyColor,
        refractionDisplacement, rawRefractionTexture,
        shapeIndex,
        saturation, lightness, glassColor, lighting
    );

    // 5. Interactive Glow & Compositing
    vec4 outColor = _applyInteractiveGlow(
        refractColorBase, rawRefractionTexture, screenUV, refractionDisplacement, childUVBase,
        position, signedDistance, shapeIndex, size, backgroundTexture, childTexture,
        lighting, lightness, saturation, backgroundColor.rgb
    );

    // 6. Alpha & Edge Blending
    float coverage = _computeCoverageAA(signedDistance);
    float baseAlpha = foregroundAlpha * coverage;
    
    float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    float rimAlpha = masks.band * edgeAlphaGain;
    
    float mixAlpha = clamp(max(baseAlpha, rimAlpha), 0.0, 1.0);

    return mix(backgroundColor, outColor, mixAlpha);
}
#endif