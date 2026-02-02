#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// -----------------------------------------------------------------------------
// Uniform Layouts
// -----------------------------------------------------------------------------

// Basic Props
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uGlassColor;
layout(location = 2) uniform vec4 uOpticalProps;
layout(location = 3) uniform vec4 uLightConfig;
layout(location = 4) uniform vec2 uColorAdjust;
layout(location = 5) uniform vec2 uLightDirection;
layout(location = 6) uniform mat4 uTransform;
layout(location = 10) uniform vec2 uRimParams;

// Shapes
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 7]; // Ends ~122

// Blur
layout(location = 123) uniform vec4 uBlurHeader;
layout(location = 124) uniform vec4 u_samples[50]; // Ends ~174

// Touches
#define MAX_TOUCHES 8
layout(location = 324) uniform float uTouchCount_f;
layout(location = 325) uniform vec4 uTouches[MAX_TOUCHES]; // Ends 332
layout(location = 333) uniform float uTouchOwners[MAX_TOUCHES]; // Ends 340

// --- NEU: Glow & Overrides ---
// Reihenfolge muss exakt match Dart sein!

// 1. Global Blur Sigma (1 Slot)
layout(location = 341) uniform float uGlobalBlurSigma;

// 2. Touch Glow Strengths (8 Slots)
layout(location = 342) uniform float uTouchGlowStrengths[MAX_TOUCHES]; // Ends 349

// 3. Shape Glow Data Array
// Größe: 16 Shapes * 4 vec4s = 64 Locations
// Start: 350. Ende: 350 + 64 = 414.
layout(location = 350) uniform vec4 uShapeGlowData[MAX_SHAPES * 4];

// --- Projection & Environment (Nach hinten geschoben) ---
// Startet ab 414

layout(location = 414) uniform vec2 uBgScale;
layout(location = 416) uniform vec2 uNormalParams; // +2 Gap (wie vorher)
layout(location = 418) uniform vec4 uChildProjection;
layout(location = 422) uniform vec2 uChildSize;

uniform sampler2D uBackgroundTexture;
uniform sampler2D uBackgroundChildTexture;

layout(location = 0) out vec4 fragColor;


// Unpack optical properties for readability
float uRefractiveIndex     = uOpticalProps.x;
float uChromaticAberration = uOpticalProps.y;
float uThickness           = uOpticalProps.z;
float uBlend               = uOpticalProps.w;

// Unpack lighting
float uLightIntensity      = uLightConfig.y;
float uAmbientStrength     = uLightConfig.z;
float uSaturation          = uLightConfig.w;
float uLightness           = uColorAdjust.x;
float uNumShapes           = uColorAdjust.y; 

// Unpack Geometry
float rimWidthPx           = uRimParams.x;
float rimSharpness         = uRimParams.y;
float uNormalPlateauWidth  = uNormalParams.x;
float uNormalSoftness      = uNormalParams.y;

#include "shared.glsl"
#include "lg_union_sdf.glsl"

#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

/// Calculates the 2D gradient of the distance field using screen-space derivatives.
vec2 _computeSdfGradient(float dist) {
    return vec2(dFdx(dist), dFdy(dist));
}

/// Calculates a pseudo-3D surface normal based on the distance field.
vec3 _computeSurfaceNormal(float dist, vec2 grad, float thickness, float plateauWidth, float softness) {
    float fullRange = thickness + plateauWidth;
    float t = max(fullRange + dist, 0.0) / max(fullRange, 1e-6);
    float nCos = pow(t, softness);
    float nSin = sqrt(max(0.0, 1.0 - nCos * nCos));
    return normalize(vec3(grad * nCos, nSin));
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

void main() {
    // Unpack Uniforms
    float uRefractiveIndex = uOpticalProps.x;
    float uChromaticAberration = uOpticalProps.y;
    float uThickness = uOpticalProps.z;
    
    float uLightIntensity = uLightConfig.y;
    float uAmbientStrength = uLightConfig.z;
    float uSaturation = uLightConfig.w;
    float uLightness = uColorAdjust.x;
    
    float rimWidthPx = uRimParams.x;
    float rimSharpness = uRimParams.y;
    float uNormalPlateauWidth = uNormalParams.x;
    float uNormalSoftness = uNormalParams.y; // <--- Das nutzen wir unten für die Scale-Rampe

    // Coordinate System Setup
    vec2 pScreen = FlutterFragCoord().xy;
    vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
    vec2 screenUV = pScreen * invSize;

    vec2 invChildSize = vec2(1.0) / max(uChildSize, vec2(1.0));
    vec2 childUV = pScreen * invChildSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    screenUV.y = 1.0 - screenUV.y;
    childUV.y = 1.0 - childUV.y;
    #endif

    vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
    vec2 p = transformedCoord.xy;

    // SDF Calculation
    int idx;
    float sdUnion = sceneSDF_withIndex_fast(p, idx);

    float foregroundAlpha = smoothstep(
        0.0,
        float(AGSL_AA_WIDTH_PX),
        clamp(-sdUnion, 0.0, float(AGSL_AA_WIDTH_PX))
    );

    // Early Exit: Background Only
    if (foregroundAlpha < 0.01) {
        fragColor = _sampleTexture(uBackgroundTexture, screenUV);
        return;
    }

    // --- DYNAMIC BACKGROUND SCALING (Controlled by NormalSoftness) ---
    vec2 targetScale = max(uBgScale, vec2(1e-4));

    // HIER DIE ÄNDERUNG:
    // Wir nutzen uNormalSoftness als Breite für den Übergang.
    // Wir klemmen es auf min 1.0, um Division durch Null im smoothstep zu verhindern.
    // Das bedeutet: Der Scale blendet genau in dem Bereich ein, in dem auch die Kante "weich" wird.
    float scaleRampWidth = max(uNormalSoftness, 1.0); 
    
    // smoothstep berechnet den Faktor 0.0 (Rand) bis 1.0 (Innen) über die Distanz der Softness
    float scaleWeight = smoothstep(0.0, scaleRampWidth, -sdUnion);
    
    // Interpolation: 
    // Am Rand (scaleWeight=0) -> vec2(1.0) (Kein Zoom, pixelgenaues Matching)
    // Innen (scaleWeight=1)   -> targetScale (Dein Zoom)
    vec2 dynamicS = mix(vec2(1.0), targetScale, scaleWeight);
    // ---------------------------------------------------------------

    float cx = uShapeData[idx * 7 + 1];
    float cy = uShapeData[idx * 7 + 2];

    vec2 centerScreenPx = _projectSdfToScreen(vec2(cx, cy));
    vec2 centerUV = centerScreenPx * invSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    centerUV.y = 1.0 - centerUV.y;
    #endif

    // Anwenden des dynamischen Scales
    vec2 scaledUV = centerUV + (screenUV - centerUV) / dynamicS;
    
    vec2 childUVRaw = uChildProjection.xy + childUV;

    // Normal Calculation
    vec2 gradient = _computeSdfGradient(sdUnion);
    vec3 normal = _computeSurfaceNormal(sdUnion, gradient, uThickness, uNormalPlateauWidth, uNormalSoftness);

    // Render Final Composite
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