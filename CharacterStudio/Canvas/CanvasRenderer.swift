import CharacterCore
import CoreGraphics
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

/// A solid color or gradient for the cover shader. Layout must match `Paint` in
/// ShaderSource: three float4s, then eight stop colors and eight stop offsets.
private struct PaintUniforms {
    var color: SIMD4<Float>
    var points: SIMD4<Float> = .zero
    var info: SIMD4<Float>
    var stopColors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var stopOffsets: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)

    init(_ paint: ArtPaint) {
        color = Self.vector(paint.color)
        info = SIMD4(0, 0, Float(min(max(paint.opacity, 0), 1)), 0)
        guard let gradient = paint.gradient, !gradient.stops.isEmpty else { return }
        points = SIMD4(Float(gradient.start.x), Float(gradient.start.y), Float(gradient.end.x), Float(gradient.end.y))
        let stops = Array(gradient.stops.prefix(ShapeGradient.maxStops))
        info.x = gradient.kind == .linear ? 1 : 2
        info.y = Float(stops.count)
        var colors = [SIMD4<Float>](repeating: .zero, count: 8)
        var offsets = [Float](repeating: 1, count: 8)
        for (i, stop) in stops.enumerated() {
            colors[i] = Self.vector(stop.color)
            offsets[i] = Float(stop.offset)
        }
        stopColors = (colors[0], colors[1], colors[2], colors[3], colors[4], colors[5], colors[6], colors[7])
        stopOffsets = (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]),
                       SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]))
    }

    /// A solid color, given in straight alpha.
    init(solid: SIMD4<Float>) {
        color = solid
        info = SIMD4(0, 0, 1, 0)
    }

    private static func vector(_ c: RGBAColor) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

/// Draws the canvas: dot grid, reference images, the art, the live stroke, then the
/// editing overlay. Hidden shapes are skipped. In isolation the other parts are drawn
/// first under a veil of the background color, then the isolated part on top.
///
/// Rendering is 4x multisampled into memoryless targets and resolved into the
/// drawable. The art is built by CharacterCore's `ArtBuilder` as stencil-then-cover
/// steps: fills, outlines (from the stroker, with caps, joins, dashes and varying
/// width), gradients and clipping all mark the stencil and then paint a rectangle
/// where the test passes, and multisampling anti-aliases the edges. Each shape's
/// triangles are cached and rebuilt only when that shape changes, so a drag
/// re-tessellates just the shapes it moves. Vertices are in world space and the
/// camera is applied in the vertex shader, so navigation never re-tessellates, except
/// for a refinement pass when zoom crosses a power of two.
@MainActor
final class CanvasRenderer {
    private static let sampleCount = 4

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let strokePipeline: any MTLRenderPipelineState
    private let stencilPipeline: any MTLRenderPipelineState
    private let coverPipeline: any MTLRenderPipelineState
    private let imagePipeline: any MTLRenderPipelineState
    private let gridPipeline: any MTLRenderPipelineState
    private let plainState: any MTLDepthStencilState
    /// Depth-stencil states for the art's steps, made on first use.
    private var stencilStates: [StencilState: any MTLDepthStencilState] = [:]
    private let sampler: any MTLSamplerState
    private let pixelFormat = MTLPixelFormat.bgra8Unorm
    private let stencilFormat = MTLPixelFormat.stencil8
    private weak var layer: CAMetalLayer?

    private var msaaTexture: (any MTLTexture)?
    private var stencilTexture: (any MTLTexture)?

    // Art cache.
    private var artBuilder = ArtBuilder()
    private var artRevision = -1
    private var artTolerance = 0.0
    private var artIsolation: Int?
    /// True when the cached art was built from the wiggle preview's moving picture.
    private var artWiggled = false
    private var artSteps: [ArtStep] = []
    private var artBuffer: (any MTLBuffer)?

    private var textures: [Int: any MTLTexture] = [:]

    /// Supplies the pixels for a reference image id.
    var referenceImage: (@MainActor (Int) -> CGImage?)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

            func descriptor(_ label: String, vertex: String, fragment: String?) -> MTLRenderPipelineDescriptor {
                let d = MTLRenderPipelineDescriptor()
                d.label = label
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                d.rasterSampleCount = Self.sampleCount
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.stencilAttachmentPixelFormat = .stencil8
                return d
            }
            func premultipliedBlending(_ d: MTLRenderPipelineDescriptor) {
                let attachment = d.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }

            let stroke = descriptor("Stroke", vertex: "stroke_vertex", fragment: "stroke_fragment")
            premultipliedBlending(stroke)
            strokePipeline = try device.makeRenderPipelineState(descriptor: stroke)

            let stencil = descriptor("Art stencil", vertex: "fill_vertex", fragment: "stencil_fragment")
            stencil.colorAttachments[0].writeMask = []
            stencilPipeline = try device.makeRenderPipelineState(descriptor: stencil)

            let cover = descriptor("Art cover", vertex: "fill_vertex", fragment: "fill_fragment")
            premultipliedBlending(cover)
            coverPipeline = try device.makeRenderPipelineState(descriptor: cover)

            let image = descriptor("Reference image", vertex: "image_vertex", fragment: "image_fragment")
            premultipliedBlending(image)
            imagePipeline = try device.makeRenderPipelineState(descriptor: image)

            let grid = descriptor("Grid", vertex: "grid_vertex", fragment: "grid_fragment")
            gridPipeline = try device.makeRenderPipelineState(descriptor: grid)
        } catch {
            assertionFailure("Canvas shaders failed to build: \(error)")
            return nil
        }

        let plain = MTLDepthStencilDescriptor()
        plain.label = "No stencil"

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let plainState = device.makeDepthStencilState(descriptor: plain),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }
        self.plainState = plainState
        self.sampler = sampler
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

    /// Draws one frame. Returns false when the system had no drawable to give (it
    /// does that under load), so the caller draws again instead of leaving the last
    /// edit, such as a released anchor drag, undrawn until the next touch.
    @discardableResult
    func render(session: CanvasSession, viewSize: CGSize, scale: CGFloat, darkMode: Bool) -> Bool {
        guard let layer, viewSize.width > 0, viewSize.height > 0 else { return true }
        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return false }

        ensureTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let msaaTexture, let stencilTexture else { return true }

        let editor = session.editor
        updateArt(editor: editor, zoom: session.camera.zoom, time: CACurrentMediaTime())
        loadMissingTextures(for: editor.drawing.references, commandBuffer: commandBuffer)

        var uniforms = makeUniforms(camera: session.camera, viewSize: viewSize, scale: scale, darkMode: darkMode)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTexture
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare // the grid covers every pixel
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.stencilAttachment.texture = stencilTexture
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setDepthStencilState(plainState)

        encoder.setRenderPipelineState(gridPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        drawReferences(editor.drawing.references, encoder: encoder, uniforms: &uniforms)
        let w = Double(viewSize.width), h = Double(viewSize.height)
        let screen = [Vec2(0, 0), Vec2(w, 0), Vec2(w, h), Vec2(0, h)].map { session.camera.toWorld($0) }
        drawArt(encoder: encoder, uniforms: &uniforms, viewRect: Rect(points: screen))

        // The live stroke and the overlay change every frame, so they are built fresh.
        encoder.setDepthStencilState(plainState)
        encoder.setRenderPipelineState(strokePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        if let live = session.liveStroke {
            drawCapsules(CapsuleTessellator.vertices(for: live), encoder: encoder)
        }
        if let mirrored = session.mirroredLiveStroke {
            drawCapsules(CapsuleTessellator.vertices(for: mirrored), encoder: encoder)
        }
        drawCapsules(EditorOverlay.vertices(for: editor, zoom: session.camera.zoom, viewRect: Rect(points: screen)),
                     encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    // MARK: Targets

    private func ensureTargets(width: Int, height: Int) {
        if let msaaTexture, msaaTexture.width == width, msaaTexture.height == height { return }
        #if targetEnvironment(simulator)
        let storage = MTLStorageMode.private
        #else
        let storage = MTLStorageMode.memoryless
        #endif

        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        color.textureType = .type2DMultisample
        color.sampleCount = Self.sampleCount
        color.usage = .renderTarget
        color.storageMode = storage
        msaaTexture = device.makeTexture(descriptor: color)

        let stencil = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: stencilFormat, width: width, height: height, mipmapped: false)
        stencil.textureType = .type2DMultisample
        stencil.sampleCount = Self.sampleCount
        stencil.usage = .renderTarget
        stencil.storageMode = storage
        stencilTexture = device.makeTexture(descriptor: stencil)
    }

    // MARK: Art

    /// Rebuilds the art when the drawing, zoom bucket or isolation changed, and on every
    /// frame of the wiggle preview (only the wiggling shapes re-tessellate).
    private func updateArt(editor: DrawingEditor, zoom: Double, time: Double) {
        // Flatten finely enough for the current zoom, in power-of-two steps.
        let bucket = pow(2, ceil(log2(max(zoom, 1.0 / 64))))
        let tolerance = 0.2 / bucket
        let wiggling = editor.wigglePart != nil
        guard wiggling || artWiggled || editor.revision != artRevision || tolerance != artTolerance ||
            editor.isolatedPart != artIsolation else { return }
        artRevision = editor.revision
        artTolerance = tolerance
        artIsolation = editor.isolatedPart
        artWiggled = wiggling
        let drawing = wiggling ? editor.displayDrawing(at: time) : editor.drawing
        let batch = artBuilder.build(drawing, isolatedPart: editor.isolatedPart, tolerance: tolerance)
        artSteps = batch.steps
        artBuffer = makeBuffer(batch.vertices)
    }

    private func drawArt(encoder: any MTLRenderCommandEncoder, uniforms: inout CanvasUniforms, viewRect: Rect) {
        guard !artSteps.isEmpty else { return }
        var view: [Float] = []
        let corners = viewRect.corners
        for i in [0, 1, 2, 0, 2, 3] {
            view.append(Float(corners[i].x))
            view.append(Float(corners[i].y))
        }
        enum Bound { case none, stencil, cover }
        var bound = Bound.none
        func bind(_ pipeline: any MTLRenderPipelineState, as kind: Bound) {
            guard bound != kind else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
            if let artBuffer { encoder.setVertexBuffer(artBuffer, offset: 0, index: 0) }
            bound = kind
        }

        for step in artSteps {
            switch step {
            case .stencil(let range, let state, let reference):
                bind(stencilPipeline, as: .stencil)
                encoder.setDepthStencilState(depthStencilState(state))
                encoder.setStencilReferenceValue(UInt32(reference))
                encoder.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)

            case .cover(let range, let paint, let state, let reference):
                bind(coverPipeline, as: .cover)
                var paintUniforms = PaintUniforms(paint)
                encoder.setDepthStencilState(depthStencilState(state))
                encoder.setStencilReferenceValue(UInt32(reference))
                encoder.setFragmentBytes(&paintUniforms, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)

            case .stencilView(let state, let reference):
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                encoder.setDepthStencilState(depthStencilState(state))
                encoder.setStencilReferenceValue(UInt32(reference))
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                bound = .none

            case .veil:
                let bg = uniforms.background
                var paint = PaintUniforms(solid: SIMD4(bg.x, bg.y, bg.z, 0.7))
                encoder.setRenderPipelineState(coverPipeline)
                encoder.setDepthStencilState(plainState)
                encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&paint, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                bound = .none
            }
        }
    }

    /// The Metal state for a stencil configuration from the art pass.
    private func depthStencilState(_ state: StencilState) -> any MTLDepthStencilState {
        if let cached = stencilStates[state] { return cached }
        func face(_ pass: StencilOperation) -> MTLStencilDescriptor {
            let d = MTLStencilDescriptor()
            d.stencilCompareFunction = switch state.compare {
            case .always: .always
            case .equal: .equal
            case .notEqual: .notEqual
            case .less: .less
            }
            d.stencilFailureOperation = CanvasRenderer.operation(state.fail)
            d.depthFailureOperation = .keep
            d.depthStencilPassOperation = CanvasRenderer.operation(pass)
            d.readMask = UInt32(state.readMask)
            d.writeMask = UInt32(state.writeMask)
            return d
        }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.frontFaceStencil = face(state.pass)
        descriptor.backFaceStencil = face(state.backPass)
        let made = device.makeDepthStencilState(descriptor: descriptor) ?? plainState
        stencilStates[state] = made
        return made
    }

    private static func operation(_ op: StencilOperation) -> MTLStencilOperation {
        switch op {
        case .keep: .keep
        case .zero: .zero
        case .replace: .replace
        case .incrementWrap: .incrementWrap
        case .decrementWrap: .decrementWrap
        }
    }

    private func drawCapsules(_ floats: [Float], encoder: any MTLRenderCommandEncoder) {
        guard !floats.isEmpty, let buffer = makeBuffer(floats) else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: floats.count / CapsuleTessellator.floatsPerVertex)
    }

    private func makeBuffer(_ floats: [Float]) -> (any MTLBuffer)? {
        guard !floats.isEmpty else { return nil }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    // MARK: Reference images

    private func drawReferences(_ references: [ReferenceImage], encoder: any MTLRenderCommandEncoder,
                                uniforms: inout CanvasUniforms) {
        let visible = references.filter { !$0.isHidden && $0.opacity > 0 && textures[$0.id] != nil }
        guard !visible.isEmpty else { return }
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for ref in visible {
            guard let texture = textures[ref.id] else { continue }
            let c = ref.corners
            let uv = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
            var floats: [Float] = []
            for i in [0, 1, 2, 0, 2, 3] {
                floats += [Float(c[i].x), Float(c[i].y), Float(uv[i].x), Float(uv[i].y)]
            }
            var opacity = Float(ref.opacity)
            encoder.setVertexBytes(floats, length: floats.count * MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func loadMissingTextures(for references: [ReferenceImage], commandBuffer: any MTLCommandBuffer) {
        for ref in references where textures[ref.id] == nil {
            guard let image = referenceImage?(ref.id), let texture = makeTexture(image, commandBuffer: commandBuffer) else { continue }
            textures[ref.id] = texture
        }
    }

    /// Uploads a CGImage as premultiplied RGBA with mipmaps, so it stays smooth when zoomed out.
    private func makeTexture(_ image: CGImage, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        if texture.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        return texture
    }

    // MARK: Uniforms

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
