// Gaussian 1D Backdrop-Blur (Impeller)
// Pass-Richtung und Kernel kommen aus Uniforms.

#include <flutter/runtime_effect.glsl>
precision mediump float;
precision mediump int;

// 1) Wird von der Engine gesetzt (Pflicht bei ImageFilter.shader).
uniform vec2 u_size;

// 2) Richtung: (1,0) = horizontal, (0,1) = vertikal
uniform vec2 u_dir;

// 3) Anzahl zusammengefasster Samples (nach Lerp-Hack, Host-normalisiert)
uniform float u_sample_count;

// 4) Tile-Mode: 0=clamp, 1=repeat, 2=mirror, 3=decal (transparent außerhalb)
uniform float u_tile_mode;

// 5) Komprimierte Samples: x = Offset in "Pixeln" entlang u_dir, z = Gewicht
uniform vec4 u_samples[50];

// 6) Wird von der Engine mit dem Filter-Input befüllt (erster sampler2D).
uniform sampler2D u_texture_input;

vec2 tile_uv(vec2 uv) {
  if (u_tile_mode < 0.5) {
    // clamp-to-edge (kleines Epsilon zur Vermeidung von Out-Of-Range)
    vec2 eps = 0.5 / u_size;
    return clamp(uv, eps, 1.0 - eps);
  } else if (u_tile_mode < 1.5) {
    return fract(uv);
  } else if (u_tile_mode < 2.5) {
    // mirror repeat
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    // decal: uv bleibt unverändert, OutOfBounds wird später zu 0
    return uv;
  }
}

vec4 sample_uv(vec2 uv) {
  if (u_tile_mode >= 2.5) {
    // decal -> außerhalb [0,1] transparent
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
      return vec4(0.0);
    }
  }
  return texture(u_texture_input, tile_uv(uv));
}

out vec4 frag_color;

void main() {
  vec2 inv_size = 1.0 / u_size;
  vec2 uv = FlutterFragCoord().xy * inv_size;

  // GLES hat invertierte Y-Achse – korrigieren.
  #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
  #endif

  // Early-out: kein Blur-Kernel aktiv
  if (u_sample_count < 0.5) {
    frag_color = sample_uv(uv);
    return;
  }

  vec2 step_vec = vec2(u_dir.x * inv_size.x, u_dir.y * inv_size.y);

  vec4 sum = vec4(0.0);
  // Schleife bis 50, aber früh abbrechen anhand u_sample_count.
  for (int i = 0; i < 50; i++) {
    if (float(i) >= u_sample_count) break;
    float t = u_samples[i].x;     // Offset entlang der Achse (in Pixeln)
    float w = u_samples[i].z;     // Gewicht (Host schon normalisiert)
    sum += w * sample_uv(uv + step_vec * t);
  }

  // Gewichte sind Host-seitig normiert -> keine Division nötig
  frag_color = sum;
}
