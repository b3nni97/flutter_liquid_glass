#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uOffset; 
uniform vec2 uSize;      
uniform vec3 uKeyColor;   
uniform vec4 uLayerColor; 
uniform float uMode; // 0.0 = Colorize, 1.0 = Cutout

uniform sampler2D uImage; 

out vec4 fragColor;

void main() {
    vec2 globalPos = FlutterFragCoord().xy;
    vec2 localPos = globalPos - uOffset;
    vec2 uv = localPos / uSize;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec4 c = texture(uImage, uv);
    if (c.a < 0.01) {
        fragColor = vec4(0.0);
        return;
    }

    // Keying Logik (aus Shared.glsl übernommen für maximale Präzision)
    vec3 rawRgb = c.rgb / max(c.a, 0.0001); 
    vec3 diffVec = abs(rawRgb - uKeyColor);
    float diff = max(diffVec.r, max(diffVec.g, diffVec.b));
    float isIcon = 1.0 - smoothstep(0.01, 0.04, diff);

    if (uMode < 0.5) {
        // --- COLORIZE MODUS ---
        // Wir behalten nur das Icon und färben es ein.
        float finalAlpha = c.a * uLayerColor.a * isIcon;
        fragColor = vec4(uLayerColor.rgb * finalAlpha, finalAlpha);
    } else {
        // --- CUTOUT MODUS ---
        // Wir behalten das Originalbild, löschen aber das Icon (1.0 - isIcon).
        float mask = 1.0 - isIcon;
        float finalAlpha = c.a * mask;
        fragColor = vec4(c.rgb * mask, finalAlpha);
    }
}