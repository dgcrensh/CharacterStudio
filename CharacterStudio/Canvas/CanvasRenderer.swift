import CharacterCore
import Metal
import QuartzCore
import simd

/// Uniforms shared by every shader. Layout must match `Uniforms` in ShaderSource.
private struct CanvasUniforms {
    var worldToClip: simd_float4x4
    var pixelToWorld: simd_float3x3
    var worldPerPixel: Float
    var gridSpacing: Float
    var padding: SIMD2<Float> = .zero
    var background: SIMD4<Float>
    var gridColor: SIMD4<Float>
}

/// Draws the canvas: dot grid, finished strokes, then the live stroke.
///
/// Finished strokes are tessellated once into a cached vertex buffer that is rebuilt
/// only when `CanvasSession.strokesRevision` changes; the live stroke is
/// re-tessellated each frame. Vertices are in world space and the camera is applied
/// in the vertex shader, so panning and zooming never re-tessellate.
@MainActor
final class CanvasRenderer {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let strokePipeline: any MTLRenderPipelineState
    private let gridPipeline: any MTLRenderPipelineState
    private let pixelFormat = MTLPixelFormat.bgra8Unorm
    private weak var layer: CAMetalLayer?

    private var committedBuffer: (any MTLBuffer)?
    private var committedVertexCount = 0
    private var committedRevision = -1

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

            let stroke = MTLRenderPipelineDescriptor()
            stroke.label = "Stroke"
            stroke.vertexFunction = library.makeFunction(name: "stroke_vertex")
            stroke.fragmentFunction = library.makeFunction(name: "stroke_fragment")
            let attachment = stroke.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            strokePipeline = try device.makeRenderPipelineState(descriptor: stroke)

            let grid = MTLRenderPipelineDescriptor()
            grid.label = "Grid"
            grid.vertexFunction = library.makeFunction(name: "grid_vertex")
            grid.fragmentFunction = library.makeFunction(name: "grid_fragment")
            grid.colorAttachments[0].pixelFormat = pixelFormat
            gridPipeline = try device.makeRenderPipelineState(descriptor: grid)
        } catch {
            assertionFailure("Canvas shaders failed to build: \(error)")
            return nil
        }
    }

    func attach(to layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.framebufferOnly = true
        // Two drawables instead of three trims a frame of latency; the scene is light.
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        self.layer = layer
    }

    func render(session: CanvasSession, viewSize: CGSize, scale: CGFloat, darkMode: Bool) {
        guard let layer, viewSize.width > 0, viewSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        updateCommittedBuffer(for: session)

        var uniforms = makeUniforms(camera: session.camera, viewSize: viewSize, scale: scale, darkMode: darkMode)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare // the grid covers every pixel
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(gridPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(strokePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        if let committedBuffer, committedVertexCount > 0 {
            encoder.setVertexBuffer(committedBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committedVertexCount)
        }
        if let live = session.liveStroke {
            let floats = CapsuleTessellator.vertices(for: live)
            if !floats.isEmpty,
               let buffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: floats.count / CapsuleTessellator.floatsPerVertex)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateCommittedBuffer(for session: CanvasSession) {
        guard session.strokesRevision != committedRevision else { return }
        committedRevision = session.strokesRevision
        var floats: [Float] = []
        for stroke in session.strokes {
            CapsuleTessellator.append(points: stroke.points, width: stroke.width, color: stroke.color, to: &floats)
        }
        committedVertexCount = floats.count / CapsuleTessellator.floatsPerVertex
        committedBuffer = floats.isEmpty
            ? nil
            : device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func makeUniforms(camera: CanvasCamera, viewSize: CGSize, scale: CGFloat, darkMode: Bool) -> CanvasUniforms {
        let w = Double(viewSize.width), h = Double(viewSize.height), s = Double(scale)

        // Screen points to clip space: x right, y up, both -1...1.
        let screenToClip = Affine2D(a: 2 / w, b: 0, c: 0, d: -2 / h, tx: -1, ty: 1)
        let worldToClip = screenToClip * camera.worldToScreen
        let pixelToWorld = camera.screenToWorld * Affine2D.scale(1 / s)

        // Pick a power-of-two grid spacing that keeps dots 24-48 points apart on screen.
        var spacing = 32.0
        let zoom = camera.zoom
        while spacing * zoom < 24 { spacing *= 2 }
        while spacing * zoom >= 48 { spacing /= 2 }

        let background: SIMD4<Float> = darkMode ? [0.11, 0.11, 0.12, 1] : [0.98, 0.98, 0.97, 1]
        let gridColor: SIMD4<Float> = darkMode ? [0.35, 0.35, 0.38, 1] : [0.78, 0.78, 0.80, 1]

        return CanvasUniforms(
            worldToClip: worldToClip.matrix4x4,
            pixelToWorld: pixelToWorld.matrix3x3,
            worldPerPixel: Float(1 / (zoom * s)),
            gridSpacing: Float(spacing),
            background: background,
            gridColor: gridColor
        )
    }
}

private extension Affine2D {
    var matrix4x4: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(a), Float(b), 0, 0),
            SIMD4<Float>(Float(c), Float(d), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(tx), Float(ty), 0, 1)
        ))
    }

    var matrix3x3: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(a), Float(b), 0),
            SIMD3<Float>(Float(c), Float(d), 0),
            SIMD3<Float>(Float(tx), Float(ty), 1)
        ))
    }
}
