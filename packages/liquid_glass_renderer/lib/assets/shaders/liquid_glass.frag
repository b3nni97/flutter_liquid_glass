#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ─────────────────────────────────────────────────────────────────────────────
// Uniform Layouts
// ─────────────────────────────────────────────────────────────────────────────

// Global Configuration
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uGlassColor;
layout(location = 2) uniform vec4 uOpticalProps;  // x:refract, y:chroma, z:thick, w:blend
layout(location = 3) uniform vec4 uLightConfig;   // x:angle, y:intense, z:ambient, w:sat
layout(location = 4) uniform vec2 uColorAdjust;   // x:lightness, y:numShapes
layout(location = 5) uniform vec2 uLightDirection;
layout(location = 6) uniform mat4 uTransform;
layout(location = 10) uniform vec2 uRimParams;

// Shape Data
// 16 Shapes * 7 Floats per shape = 112 floats
// Base index: 36 (matches Dart _uShapeData)
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 7];

// Blur Configuration
// Base index: 148 (matches Dart _uBlurHeader)
layout(location = 123) uniform vec4 uBlurHeader; // x:dirX, y:dirY, z:count, w:unused
layout(location = 124) uniform vec4 u_samples[50];

// Touch & Glow
// Base index: 352 (matches Dart _uTouchCount)
#define MAX_TOUCHES 8
layout(location = 324) uniform float uTouchCount_f;
layout(location = 325) uniform vec4 uTouches[MAX_TOUCHES];
layout(location = 333) uniform float uTouchOwners[MAX_TOUCHES];

layout(location = 341) uniform vec4 uGlowParams;
layout(location = 342) uniform vec4 uGlowColor;
layout(location = 343) uniform vec4 uGlowOverrides;
layout(location = 344) uniform vec4 uGlowFlags;
layout(location = 345) uniform vec4 uGlowGlass;
layout(location = 346) uniform float uGlobalBlurSigma;
layout(location = 347) uniform float uTouchGlowStrengths[MAX_TOUCHES];

// Projection & Environment
// Base index: 422
layout(location = 355) uniform vec2 uBgScale;
layout(location = 357) uniform vec2 uNormalParams;
layout(location = 425) uniform vec4 uChildProjection; // x:offX, y:offY, z:scaleX, w:scaleY
layout(location = 429) uniform vec2 uChildSize;

// ─────────────────────────────────────────────────────────────────────────────
// Textures
// ─────────────────────────────────────────────────────────────────────────────

uniform sampler2D uBackgroundTexture;
uniform sampler2D uBackgroundChildTexture;

layout(location = 0) out vec4 fragColor;

// ─────────────────────────────────────────────────────────────────────────────
// Utilities & Includes
// ─────────────────────────────────────────────────────────────────────────────

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

// Include your custom SDF libraries
#include "shared.glsl"
#include "lg_union_sdf.glsl"

#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

/// Calculates the 2D gradient of the distance field using screen-space derivatives.
/// This tells us in which direction the distance increases most (the "slope").
vec2 calculateSDFGradient(float dist) {
    return vec2(dFdx(dist), dFdy(dist));
}

/// Calculates a pseudo-3D surface normal based on the distance field.
/// It creates a rounded profile ("plateau") for the glass surface.
///
/// @param dist   The signed distance to the shape edge.
/// @param grad   The 2D gradient of the distance field.
vec3 calculateSurfaceNormal(float dist, vec2 grad) {
    float fullRange = uThickness + uNormalPlateauWidth;
    // Normalize distance: 0.0 = deep inside, 1.0 = at the edge/plateau start
    float t = max(fullRange + dist, 0.0) / max(fullRange, 1e-6);
    
    // Shape the curve
    float n_cos = pow(t, uNormalSoftness);
    float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
    
    return normalize(vec3(grad * n_cos, n_sin));
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Shader
// ─────────────────────────────────────────────────────────────────────────────

void main() {
    // 1. Coordinate Setup
    vec2 pScreen = FlutterFragCoord().xy;
    vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
    vec2 screenUV = pScreen * invSize;

    // Child projection coordinates
    vec2 invChildSize = vec2(1.0) / max(uChildSize, vec2(1.0));
    vec2 childUV = pScreen * invChildSize;

    // Flip Y for OpenGLES backends (Android compatibility)
    #ifdef IMPELLER_TARGET_OPENGLES
    screenUV.y = 1.0 - screenUV.y;
    childUV.y = 1.0 - childUV.y;
    #endif

    // Transform screen coordinates to local layer space
    vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
    vec2 p = transformedCoord.xy;

    // 2. SDF Calculation
    int idx;
    float sdUnion = sceneSDF_withIndex_fast(p, idx);

    // Compute alpha mask based on distance
    float foregroundAlpha = smoothstep(
        0.0,
        AGSL_AA_WIDTH_PX,
        clamp(-sdUnion, 0.0, AGSL_AA_WIDTH_PX)
    );

    // 3. Early Exit (Background Pass)
    if (foregroundAlpha < 0.01) {
        fragColor = texScreen(uBackgroundTexture, screenUV);
        return;
    }

    // 4. Background Scaling Logic
    // Compute the center of the active shape to zoom the background relative to it
    vec2 s = max(uBgScale, vec2(1e-4));
    // Index stride is 7 (matches Dart uShapeData packing)
    float cx = uShapeData[idx * 7 + 1]; // Center X
    float cy = uShapeData[idx * 7 + 2]; // Center Y
    
    vec2 centerScreenPx = sdfToScreenPx(vec2(cx, cy));
    vec2 centerUV = centerScreenPx * invSize;
    
    #ifdef IMPELLER_TARGET_OPENGLES
    centerUV.y = 1.0 - centerUV.y;
    #endif

    vec2 scaledUV = centerUV + (screenUV - centerUV) / s;

    // 5. Reflection/Refraction Setup
    vec2 childUVRaw = uChildProjection.xy + childUV;
    
    // Calculate Normal Map
    vec2 gradient = calculateSDFGradient(sdUnion);
    vec3 normal = calculateSurfaceNormal(sdUnion, gradient);

    // 6. Final Composition
    // Delegates to the lighting model defined in shared.glsl
    fragColor = renderLiquidGlass(
        scaledUV,                // Background UV (scaled)
        childUVRaw,              // Reflection/Refraction UV
        p,                       // Local coordinates
        uSize,                   // Viewport size
        sdUnion,                 // Signed Distance
        uThickness,              // Glass Thickness
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