#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;
precision mediump int;

// ─── 1. Basic Properties ───
// Indizes werden implizit durch Reihenfolge bestimmt (Start: 0)
uniform vec2 uSize;           // 2 Floats
uniform vec4 uGlassColor;     // 4 Floats
uniform vec4 uOpticalProps;   // 4 Floats
uniform vec4 uLightConfig;    // 4 Floats
uniform vec2 uColorAdjust;    // 2 Floats
uniform vec2 uLightDirection; // 2 Floats
uniform mat4 uTransform;      // 16 Floats (4x4 Matrix)
uniform vec2 uRimParams;      // 2 Floats

// ─── 2. Shape Data ───
#define MAX_SHAPES 16
// float array[112] (16 * 7)
uniform float uShapeData[MAX_SHAPES * 7];

// ─── 3. Blur Settings ───
uniform vec4 uBlurHeader;     // 4 Floats
// vec4 array[24] -> 24 * 4 = 96 Floats
uniform vec4 u_samples[24];   

// ─── 4. Touch Handling ───
#define MAX_TOUCHES 8
uniform float uTouchCount_f;             // 1 Float
uniform vec4 uTouches[MAX_TOUCHES];      // 8 * 4 = 32 Floats
uniform float uTouchOwners[MAX_TOUCHES]; // 8 * 1 = 8 Floats

// ─── 5. Glow & Overrides ───
uniform float uGlobalBlurSigma;                     // 1 Float
uniform float uTouchGlowStrengths[MAX_TOUCHES];     // 8 * 1 = 8 Floats
// vec4 array[64] -> 16 * 4 = 64 vec4s -> 256 Floats
uniform vec4 uShapeGlowData[MAX_SHAPES * 4]; 

// ─── 6. Projection & Environment ───
uniform vec2 uBgScale;         // 2 Floats
uniform vec2 uNormalParams;    // 2 Floats
uniform vec4 uChildProjection; // 4 Floats
uniform vec2 uChildSize;       // 2 Floats

// ─── Samplers (Zählen NICHT in die Float-Indizes) ───
uniform sampler2D uBackgroundTexture;      // Index 0 für setImageSampler
uniform sampler2D uBackgroundChildTexture; // Index 1 für setImageSampler

out vec4 fragColor;

// -----------------------------------------------------------------------------
// Optimization: Zero-Cost Macros instead of Variables
// -----------------------------------------------------------------------------
// Dies spart Register, da keine neuen Variablen angelegt werden müssen.

#define uRefractiveIndex      uOpticalProps.x
#define uChromaticAberration  uOpticalProps.y
#define uThickness            uOpticalProps.z
#define uBlend                uOpticalProps.w

#define uLightIntensity       uLightConfig.y
#define uAmbientStrength      uLightConfig.z
#define uSaturation           uLightConfig.w

#define uLightness            uColorAdjust.x
#define uNumShapes            uColorAdjust.y

#define rimWidthPx            uRimParams.x
#define rimSharpness          uRimParams.y

#define uNormalPlateauWidth   uNormalParams.x
#define uNormalSoftness       uNormalParams.y

#include "shared.glsl"
#include "lg_union_sdf.glsl"

#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

vec2 _computeSdfGradient(float dist) {
    return vec2(dFdx(dist), dFdy(dist));
}

vec3 _computeSurfaceNormal(float dist, vec2 grad, float thickness, float plateauWidth, float softness) {
    // Optimierung: max(..., 1e-6) verhindert Division durch Null ohne Branching
    float fullRange = thickness + plateauWidth;
    float t = max(fullRange + dist, 0.0) / max(fullRange, 1.0e-6);
    
    // Pow ist teuer, aber hier notwendig für den Look. 
    // Wenn softness oft 1.0 ist, könnte man optimieren, aber so ist es sicher.
    float nCos = pow(t, softness);
    float nSin = sqrt(max(0.0, 1.0 - nCos * nCos));
    return normalize(vec3(grad * nCos, nSin));
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

void main() {
    // 1. Coordinate Setup (Minimal set for SDF)
    vec2 pScreen = FlutterFragCoord().xy;
    
    // Optimierung: Multiplikation ist schneller als Division. Inverse berechnen.
    // max(..., 1.0) schützt vor Division durch Null.
    vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0)); 
    vec2 screenUV = pScreen * invSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    screenUV.y = 1.0 - screenUV.y;
    #endif

    // Transform berechnen
    // Hinweis: vec4 Konstruktor ist billig, Matrix-Mult ist hier notwendig.
    vec2 p = (uTransform * vec4(pScreen, 0.0, 1.0)).xy;

    // 2. SDF Calculation (Expensive Loop)
    int idx;
    float sdUnion = sceneSDF_withIndex_fast(p, idx);

    // 3. Alpha Calculation
    // AGSL_AA_WIDTH_PX ist Konstante, cast ist free.
    float foregroundAlpha = smoothstep(
        0.0,
        float(AGSL_AA_WIDTH_PX),
        clamp(-sdUnion, 0.0, float(AGSL_AA_WIDTH_PX))
    );

    // -------------------------------------------------------------------------
    // EARLY EXIT
    // -------------------------------------------------------------------------
    if (foregroundAlpha < 0.01) {
        fragColor = _sampleTexture(uBackgroundTexture, screenUV);
        return;
    }

    // -------------------------------------------------------------------------
    // HEAVY LIFTING (Nur ausführen, wenn wir wirklich Glas rendern)
    // -------------------------------------------------------------------------

    // Child Coordinates (Erst hier berechnen)
    vec2 invChildSize = vec2(1.0) / max(uChildSize, vec2(1.0));
    vec2 childUV = pScreen * invChildSize;
    
    #ifdef IMPELLER_TARGET_OPENGLES
    childUV.y = 1.0 - childUV.y;
    #endif

    // --- Dynamic Background Scaling ---
    vec2 targetScale = max(uBgScale, vec2(1.0e-4));
    float scaleRampWidth = max(uNormalSoftness, 1.0);
    
    // Scale Weight Berechnung
    float scaleWeight = smoothstep(0.0, scaleRampWidth, -sdUnion);
    vec2 dynamicS = mix(vec2(1.0), targetScale, scaleWeight);

    // Center Berechnung für den aktiven Shape
    // Indexzugriff auf Uniform-Arrays ist in ES 3.0+ schnell, aber wir machen es nur 1x.
    int baseIdx = idx * 7;
    float cx = uShapeData[baseIdx + 1];
    float cy = uShapeData[baseIdx + 2];

    vec2 centerScreenPx = _projectSdfToScreen(vec2(cx, cy));
    vec2 centerUV = centerScreenPx * invSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    centerUV.y = 1.0 - centerUV.y;
    #endif

    // Apply Scaling
    vec2 scaledUV = centerUV + (screenUV - centerUV) / dynamicS;
    vec2 childUVRaw = uChildProjection.xy + childUV;

    // Normal Calculation
    // Gradienten basieren auf Screen-Space, müssen also hier berechnet werden
    vec2 gradient = _computeSdfGradient(sdUnion);
    vec3 normal = _computeSurfaceNormal(sdUnion, gradient, uThickness, uNormalPlateauWidth, uNormalSoftness);

    // 4. Final Composite
    fragColor = renderLiquidGlass(
        scaledUV, 
        childUVRaw,
        p,
        uSize,
        sdUnion,
        uThickness,
        uRefractiveIndex,
        uChromaticAberration,
        uGlassColor,
        uLightDirection,
        uLightIntensity,
        uAmbientStrength,
        uBackgroundTexture,
        uBackgroundChildTexture,
        normal,
        foregroundAlpha,
        uSaturation,
        uLightness,
        rimWidthPx,
        rimSharpness,
        idx
    );
}