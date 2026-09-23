//
//  InvisibleInk.metal
//  Command
//
//  Animated "invisible ink" veil for hidden captures — a SwiftUI colorEffect shader that
//  replicates iOS iMessage's invisible ink: a dense, CHURNING cloud of fine soft-round
//  white particles that drift, flow and twinkle over a silvery base. The signature is
//  motion — the grains flow and swirl (not a blinking lattice). colorEffect runs per-pixel
//  on the GPU; see WWDC24 "Create custom visual effects with SwiftUI" (session 10151).
//

#include <metal_stdlib>
using namespace metal;

static inline float ink_hash1(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
static inline float2 ink_hash2(float2 p) {
    float2 q = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
}

// One layer of soft, drifting, twinkling particles — one particle per grid cell, sampled
// over the 3×3 neighbourhood so a grain that drifts across a cell edge still renders whole.
// Returns accumulated brightness.
static inline float ink_layer(float2 uv, float time, float cell, float radius, float speed) {
    float2 gv = uv / cell;
    float2 id = floor(gv);
    float2 f  = fract(gv);
    float acc = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 o   = float2(x, y);
            float2 cid = id + o;
            float2 r   = ink_hash2(cid);
            // Each grain drifts on its own slow loop, plus a random static offset.
            float ang  = 6.2831853 * r.x + time * speed * mix(0.6, 1.4, r.y);
            float2 pp  = o + 0.5 + (r - 0.5) * 0.5 + 0.3 * float2(cos(ang), sin(ang));
            float d    = length(f - pp);
            float dot  = smoothstep(radius, 0.0, d);   // soft round particle
            float tw   = 0.5 + 0.5 * sin(time * mix(2.5, 6.0, ink_hash1(cid + 3.7)) + r.x * 6.2831853);
            acc += dot * (0.28 + 0.72 * tw * tw);      // dim base + bright twinkle peaks (sparkle)
        }
    }
    return acc;
}

// position : pixel coordinate in the view's user space (points)
// color    : the overlay layer's own pixel (ignored — we synthesize the veil)
// time     : elapsed seconds (continuous, from TimelineView)
// tint     : base veil colour (the "bubble"), premultiplied
// density  : grain in points (smaller = finer glitter)
[[ stitchable ]]
half4 invisibleInk(float2 position, half4 color, float time, half4 tint, float density) {
    float g = max(density, 1.0);

    // Global churn: warp the sampling coordinates with two octaves of evolving low-frequency
    // flow so the whole particle field swirls and streams over time.
    float2 p = position;
    p += float2(sin(position.y * 0.045 + time * 0.55), cos(position.x * 0.045 - time * 0.50)) * (g * 2.2);
    p += float2(sin(position.y * 0.110 - time * 0.90), cos(position.x * 0.100 + time * 0.80)) * (g * 1.0);

    // Two parallax layers of soft particles at different scales + drift speeds → depth + churn.
    float a = ink_layer(p,               time, g * 2.1, 0.26, 0.9);
    float b = ink_layer(p * 1.7 + 41.0,  time, g * 1.5, 0.24, 1.3);
    float spark = clamp(a * 0.7 + b * 0.6, 0.0, 1.0);

    half3 base = tint.rgb;                              // silvery base shows in the gaps
    half3 rgb  = mix(base, half3(1.0), half(spark));   // white grains painted over it
    half al    = half(clamp(0.85 + 0.15 * spark, 0.0, 1.0));
    return half4(rgb * al, al);                         // premultiplied
}
