/// Metal shaders, compiled at launch from source so the project needs no .metal
/// build step. Struct layouts must match `CanvasUniforms` (CanvasRenderer.swift)
/// and `CapsuleTessellator` (CharacterCore).
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 worldToClip;
        float3x3 pixelToWorld;
        float worldPerPixel;
        float gridSpacing;
        float2 padding;
        float4 background;
        float4 gridColor;
    };

    // 12 floats per vertex, see CapsuleTessellator.
    struct StrokeVertex {
        packed_float2 a;
        packed_float2 b;
        packed_float2 corner;
        float radius;
        float padding;
        packed_float4 color;
    };

    struct StrokeOut {
        float4 position [[position]];
        float2 world;
        float2 a [[flat]];
        float2 b [[flat]];
        float radius [[flat]];
        float4 color [[flat]];
    };

    vertex StrokeOut stroke_vertex(uint vid [[vertex_id]],
                                   const device StrokeVertex *vertices [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
        StrokeVertex v = vertices[vid];
        float2 a = float2(v.a);
        float2 b = float2(v.b);
        float2 corner = float2(v.corner);
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-6 ? d / len : float2(1.0, 0.0);
        float2 normal = float2(-dir.y, dir.x);
        // Grow the quad past the capsule by a pixel and a half for anti-aliasing.
        float extent = v.radius + u.worldPerPixel * 1.5;
        float2 end = corner.x < 0.0 ? a - dir * extent : b + dir * extent;
        float2 world = end + normal * (corner.y * extent);

        StrokeOut out;
        out.position = u.worldToClip * float4(world, 0.0, 1.0);
        out.world = world;
        out.a = a;
        out.b = b;
        out.radius = v.radius;
        out.color = float4(v.color);
        return out;
    }

    fragment float4 stroke_fragment(StrokeOut in [[stage_in]]) {
        float2 pa = in.world - in.a;
        float2 ba = in.b - in.a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12), 0.0, 1.0);
        float dist = length(pa - ba * h);
        float aa = max(fwidth(dist), 1e-6);
        float coverage = saturate((in.radius - dist) / aa + 0.5);
        if (coverage <= 0.0) {
            discard_fragment();
        }
        return in.color * coverage; // premultiplied
    }

    struct GridOut {
        float4 position [[position]];
    };

    // One triangle that covers the whole screen.
    vertex GridOut grid_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        GridOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Dot grid over the infinite canvas, so pan, zoom and rotation are visible.
    fragment float4 grid_fragment(GridOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 world = (u.pixelToWorld * float3(in.position.xy, 1.0)).xy;
        float2 cell = world / u.gridSpacing;
        float2 offset = (cell - round(cell)) * u.gridSpacing;
        float distPx = length(offset) / u.worldPerPixel;
        float dotRadiusPx = 1.5;
        // The world origin gets a larger dot.
        if (all(round(cell) == float2(0.0))) {
            dotRadiusPx = 4.0;
        }
        float alpha = saturate(dotRadiusPx + 0.5 - distPx) * u.gridColor.a;
        return float4(mix(u.background.rgb, u.gridColor.rgb, alpha), 1.0);
    }
    """
}
