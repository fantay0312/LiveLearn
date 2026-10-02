/// The Metal shading language source of the particle pipelines.
///
/// It is compiled at launch with `MTLDevice.makeLibrary(source:options:)` rather than by SwiftPM:
/// Xcode 26 ships the shader compiler as a separately downloaded "Metal Toolchain", and a
/// machine without it cannot build a `.metal` file, while the runtime compiler is always part of
/// the OS. The source is small and compiles in well under a second, once per process.
///
/// Every sprite is a point primitive whose fragment computes the *area coverage* of its pixel:
/// - a box is the exact overlap of the pixel square with the rectangle, which is what the
///   canvases' antialiaser produces for the rects they draw for grains narrower than 1.3 pt
///   (a sub-pixel grain thereby lands as a 1 px point whose alpha is its area, `d²`);
/// - a disc uses the lens between the grain disc and a disc of unit area standing in for the
///   pixel, a smooth approximation of the polygon coverage the canvases rasterise;
/// - a halo fades linearly from the tint to clear over its radius (`ParticleSprites.halo`);
/// - a glow is an ellipse with the three-stop profile of `ControlBreathingLight`'s gradient
///   (α, 0.68 α at 0.4, clear at 1), evaluated at pixel centres like a shading, and clipped to
///   the frame's capsule (`PointUniforms.clip`) with a one-pixel antialiased edge, as
///   `.clipShape(Capsule())` clips the canvas.
/// Colour is straight sRGB, blended source-over in gamma space like `GraphicsContext.fill` into a
/// transparent layer; the drawable holds premultiplied colour for the compositor.
enum ParticleMetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct PointVertex { float x, y, hw, hh, alpha; ushort kind, color; };
    // `clip`: centre (xy) and half extents (zw) of the capsule glows are clipped to; zw = 0 for none.
    struct PointUniforms { float2 viewport; float4 palette[8]; float4 clip; };

    struct PointVarying {
        float4 position [[position]];
        float size [[point_size]];
        float2 center [[flat]];
        float2 extent [[flat]];
        float4 color [[flat]];
        float4 clip [[flat]];
        uint kind [[flat]];
    };

    vertex PointVarying particle_vertex(const device PointVertex *points [[buffer(0)]],
                                        constant PointUniforms &u [[buffer(1)]],
                                        uint vid [[vertex_id]]) {
        PointVertex p = points[vid];
        PointVarying out;
        float2 c = float2(p.x, p.y);
        out.position = float4(c.x / u.viewport.x * 2.0 - 1.0, 1.0 - c.y / u.viewport.y * 2.0, 0.0, 1.0);
        // Wide enough that every pixel the sprite touches, even partially, gets a fragment. Apple
        // GPUs cap a point at 511 px: a glow's ellipse (≈ 427 px for the 184 pt capsule at 2×) fits;
        // on a denser display its outermost, near-transparent skirt would be cut.
        out.size = ceil(2.0 * max(p.hw, p.hh)) + 2.0;
        out.center = c;
        out.extent = float2(p.hw, p.hh);
        out.color = float4(u.palette[p.color].rgb, p.alpha);
        out.clip = u.clip;
        out.kind = p.kind;
        return out;
    }

    static float box_coverage(float2 pixel, float2 c, float2 h) {
        float2 lo = max(pixel, c - h);
        float2 hi = min(pixel + 1.0, c + h);
        float2 d = max(hi - lo, 0.0);
        return d.x * d.y;
    }

    static float disc_coverage(float2 p, float2 c, float r) {
        const float rp = 0.5641896f;   // radius of the unit-area disc that stands in for the pixel
        float d = distance(p, c);
        if (d >= r + rp) { return 0.0; }
        if (d <= fabs(r - rp)) { float m = min(r, rp); return min(1.0, M_PI_F * m * m); }
        float r2 = r * r, p2 = rp * rp, d2 = d * d;
        float a1 = acos(clamp((d2 + r2 - p2) / (2.0 * d * r), -1.0, 1.0));
        float a2 = acos(clamp((d2 + p2 - r2) / (2.0 * d * rp), -1.0, 1.0));
        float k = 0.5 * sqrt(max(0.0, (-d + r + rp) * (d + r - rp) * (d - r + rp) * (d + r + rp)));
        return clamp(r2 * a1 + p2 * a2 - k, 0.0, 1.0);
    }

    // Antialiased inside-ness of a capsule (a rounded rectangle whose radius is its smaller half
    // extent): the signed distance to its edge, ramped over one pixel. No capsule: fully inside.
    static float capsule_coverage(float2 p, float4 clip) {
        if (clip.z <= 0.0 || clip.w <= 0.0) { return 1.0; }
        float2 h = clip.zw;
        float r = min(h.x, h.y);
        float2 q = fabs(p - clip.xy) - (h - r);
        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        return clamp(0.5 - sd, 0.0, 1.0);
    }

    // `ControlBreathingLight`'s gradient along the normalised elliptical radius t: α at the
    // centre, 0.68 α at t = 0.4, clear at t = 1, linear between the stops.
    static float glow_profile(float t) {
        if (t < 0.4) { return 1.0 - 0.8 * t; }
        if (t < 1.0) { return (1.0 - t) * (0.68 / 0.6); }
        return 0.0;
    }

    static float coverage(PointVarying in) {
        float2 pixel = floor(in.position.xy);
        switch (in.kind) {
        case 0: return box_coverage(pixel, in.center, in.extent);
        case 1: return disc_coverage(pixel + 0.5, in.center, in.extent.x);
        case 3: {
            float2 p = pixel + 0.5;
            return glow_profile(length((p - in.center) / in.extent)) * capsule_coverage(p, in.clip);
        }
        default: return max(0.0, 1.0 - distance(pixel + 0.5, in.center) / in.extent.x);
        }
    }

    fragment float4 particle_fragment(PointVarying in [[stage_in]]) {
        return float4(in.color.rgb, in.color.a * coverage(in));
    }

    // Coverage alone, accumulated additively into the glow mask and clamped by the target.
    // This is a sum, not the nonzero-winding union Canvas gets from filling the same boxes as
    // one path: boxes that merely abut sum to the union's coverage, boxes that overlap sum
    // above it (overshoot). The mask is blurred afterwards, which absorbs the difference for
    // the core's glow layer; it is not a substitute for a union fill (see the wordmark@1x
    // parity note in doc/项目实现文档.md §5.11).
    fragment float4 mask_fragment(PointVarying in [[stage_in]]) {
        return float4(coverage(in), 0.0, 0.0, 0.0);
    }

    struct ScreenVarying { float4 position [[position]]; };

    vertex ScreenVarying screen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
        ScreenVarying out;
        out.position = float4(p, 0.0, 1.0);
        return out;
    }

    fragment float4 blur_fragment(ScreenVarying in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  constant float2 &step [[buffer(0)]],
                                  constant int &radius [[buffer(1)]],
                                  constant float *weights [[buffer(2)]]) {
        constexpr sampler s(coord::pixel, address::clamp_to_zero, filter::nearest);
        float2 p = in.position.xy;
        float acc = source.sample(s, p).r * weights[0];
        for (int i = 1; i <= radius; ++i) {
            float2 o = step * float(i);
            acc += (source.sample(s, p + o).r + source.sample(s, p - o).r) * weights[i];
        }
        return float4(acc, 0.0, 0.0, 0.0);
    }

    fragment float4 glow_fragment(ScreenVarying in [[stage_in]],
                                  texture2d<float> mask [[texture(0)]],
                                  constant float4 &tint [[buffer(0)]]) {
        float m = mask.read(uint2(in.position.xy)).r;
        return float4(tint.rgb, tint.a * m);
    }
    """
}
