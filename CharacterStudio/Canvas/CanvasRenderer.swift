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

/// Draws the canvas: dot grid, reference images, the art, the live stroke, then the
/// editing overlay.
///
/// Rendering is 4x multisampled into memoryless targets and resolved into the
/// drawable. Shapes are filled with stencil-then-cover (any freehand outline fills
/// correctly, and multisampling anti-aliases the edge) and outlined with capsules.
/// Each shape's triangles are cached and rebuilt only when that shape changes, so a
/// drag re-tessellates just the shapes it moves. Vertices are in world space and the
/// camera is applied in the vertex shader, so navigation never re-tessellates, except
/// for a refinement pass when zoom crosses a power of two.
@MainActor
final class CanvasRenderer {
    private static let sampleCount = 4

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let strokePipeline: any MTLRenderPipelineState
    private let fillStencilPipeline: any MTLRenderPipelineState
    private let fillCoverPipeline: any MTLRenderPipelineState
    private let imagePipeline: any MTLRenderPipelineState
    private let gridPipeline: any MTLRenderPipelineState
    private let plainState: any MTLDepthStencilState
    private let stencilWriteState: any MTLDepthStencilState
    private let coverState: any MTLDepthStencilState
    private let sampler: any MTLSamplerState
    private let pixelFormat = MTLPixelFormat.bgra8Unorm
    private let stencilFormat = MTLPixelFormat.stencil8
    private weak var layer: CAMetalLayer?

    private var msaaTexture: (any MTLTexture)?
    private var stencilTexture: (any MTLTexture)?

    // Art cache.
    private struct ShapeGeometry {
        var shape: VectorShape
        var tolerance: Double
        var fan: [Float]
        var cover: [Float]
        var outline: [Float]
    }

    private enum ArtOp {
        case fill(fanStart: Int, fanCount: Int, coverStart: Int, color: SIMD4<Float>)
        case outline(start: Int, count: Int)
    }

    private var shapeCache: [Int: ShapeGeometry] = [:]
    private var artRevision = -1
    private var artTolerance = 0.0
    private var artOps: [ArtOp] = []
    private var fillBuffer: (any MTLBuffer)?
    private var capsuleBuffer: (any MTLBuffer)?

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

            let stencil = descriptor("Fill stencil", vertex: "fill_vertex", fragment: "fill_fragment")
            stencil.colorAttachments[0].writeMask = []
            fillStencilPipeline = try device.makeRenderPipelineState(descriptor: stencil)

            let cover = descriptor("Fill cover", vertex: "fill_vertex", fragment: "fill_fragment")
            premultipliedBlending(cover)
            fillCoverPipeline = try device.makeRenderPipelineState(descriptor: cover)

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

        let write = MTLDepthStencilDescriptor()
        write.label = "Stencil winding"
        let front = MTLStencilDescriptor()
        front.stencilCompareFunction = .always
        front.depthStencilPassOperation = .incrementWrap
        let back = MTLStencilDescriptor()
        back.stencilCompareFunction = .always
        back.depthStencilPassOperation = .decrementWrap
        write.frontFaceStencil = front
        write.backFaceStencil = back

        let cover = MTLDepthStencilDescriptor()
        cover.label = "Stencil cover"
        let coverFace = MTLStencilDescriptor()
        coverFace.stencilCompareFunction = .notEqual
        coverFace.stencilFailureOperation = .keep
        coverFace.depthStencilPassOperation = .zero
        cover.frontFaceStencil = coverFace
        cover.backFaceStencil = coverFace

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let plainState = device.makeDepthStencilState(descriptor: plain),
              let stencilWriteState = device.makeDepthStencilState(descriptor: write),
              let coverState = device.makeDepthStencilState(descriptor: cover),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }
        self.plainState = plainState
        self.stencilWriteState = stencilWriteState
        self.coverState = coverState
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

    func render(session: CanvasSession, viewSize: CGSize, scale: CGFloat, darkMode: Bool) {
        guard let layer, viewSize.width > 0, viewSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        ensureTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let msaaTexture, let stencilTexture else { return }

        let editor = session.editor
        updateArt(editor: editor, zoom: session.camera.zoom)
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

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setDepthStencilState(plainState)

        encoder.setRenderPipelineState(gridPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        drawReferences(editor.drawing.references, encoder: encoder, uniforms: &uniforms)
        drawArt(encoder: encoder, uniforms: &uniforms)

        // The live stroke and the overlay change every frame, so they are built fresh.
        encoder.setDepthStencilState(plainState)
        encoder.setRenderPipelineState(strokePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        if let live = session.liveStroke {
            drawCapsules(CapsuleTessellator.vertices(for: live), encoder: encoder)
        }
        drawCapsules(EditorOverlay.vertices(for: editor, zoom: session.camera.zoom), encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

    private func updateArt(editor: DrawingEditor, zoom: Double) {
        // Flatten finely enough for the current zoom, in power-of-two steps.
        let bucket = pow(2, ceil(log2(max(zoom, 1.0 / 64))))
        let tolerance = 0.2 / bucket
        guard editor.revision != artRevision || tolerance != artTolerance else { return }
        artRevision = editor.revision
        artTolerance = tolerance

        var fills: [Float] = []
        var capsules: [Float] = []
        var ops: [ArtOp] = []
        var live: Set<Int> = []

        for part in editor.drawing.parts {
            for shape in part.shapes {
                live.insert(shape.id)
                let geometry: ShapeGeometry
                if let cached = shapeCache[shape.id], cached.shape == shape, cached.tolerance == tolerance {
                    geometry = cached
                } else {
                    geometry = tessellate(shape, tolerance: tolerance)
                    shapeCache[shape.id] = geometry
                }

                if let color = shape.visibleFill, !geometry.fan.isEmpty {
                    let fanStart = fills.count / FillTessellator.floatsPerVertex
                    fills += geometry.fan
                    let coverStart = fills.count / FillTessellator.floatsPerVertex
                    fills += geometry.cover
                    let a = Float(color.a)
                    ops.append(.fill(
                        fanStart: fanStart,
                        fanCount: geometry.fan.count / FillTessellator.floatsPerVertex,
                        coverStart: coverStart,
                        color: SIMD4(Float(color.r) * a, Float(color.g) * a, Float(color.b) * a, a)
                    ))
                }
                if !geometry.outline.isEmpty {
                    let start = capsules.count / CapsuleTessellator.floatsPerVertex
                    capsules += geometry.outline
                    ops.append(.outline(start: start, count: geometry.outline.count / CapsuleTessellator.floatsPerVertex))
                }
            }
        }
        shapeCache = shapeCache.filter { live.contains($0.key) }
        artOps = ops
        fillBuffer = makeBuffer(fills)
        capsuleBuffer = makeBuffer(capsules)
    }

    private func tessellate(_ shape: VectorShape, tolerance: Double) -> ShapeGeometry {
        let poly = shape.path.flattened(tolerance: tolerance)
        var fan: [Float] = []
        var cover: [Float] = []
        if shape.visibleFill != nil, poly.count >= 3 {
            FillTessellator.appendFan(polygon: poly, to: &fan)
            FillTessellator.appendCover(Rect(points: poly), to: &cover)
        }
        var outline: [Float] = []
        if let stroke = shape.stroke {
            let points = shape.path.closed && poly.count > 2 ? poly + [poly[0]] : poly
            CapsuleTessellator.append(points: points, width: stroke.width, color: stroke.color, to: &outline)
        }
        return ShapeGeometry(shape: shape, tolerance: tolerance, fan: fan, cover: cover, outline: outline)
    }

    private func drawArt(encoder: any MTLRenderCommandEncoder, uniforms: inout CanvasUniforms) {
        var strokeStateSet = false
        for op in artOps {
            switch op {
            case .fill(let fanStart, let fanCount, let coverStart, var color):
                guard let fillBuffer else { continue }
                strokeStateSet = false
                encoder.setRenderPipelineState(fillStencilPipeline)
                encoder.setDepthStencilState(stencilWriteState)
                encoder.setVertexBuffer(fillBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: fanStart, vertexCount: fanCount)

                encoder.setRenderPipelineState(fillCoverPipeline)
                encoder.setDepthStencilState(coverState)
                encoder.setStencilReferenceValue(0)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: coverStart, vertexCount: 6)

            case .outline(let start, let count):
                guard let capsuleBuffer else { continue }
                if !strokeStateSet {
                    encoder.setRenderPipelineState(strokePipeline)
                    encoder.setDepthStencilState(plainState)
                    encoder.setVertexBuffer(capsuleBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                    strokeStateSet = true
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: start, vertexCount: count)
            }
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
