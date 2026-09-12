import MetalKit
import NimbusKit

/// Drives the ring shader.
///
/// The shader is compiled from source at launch rather than from a prebuilt
/// `.metallib`. Metal's compiler lives in the OS, not in Xcode, so this removes
/// the build-time dependency on the Xcode Metal toolchain entirely. It costs a
/// few milliseconds once, at startup.
final class RingRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private var uniforms = Uniforms()

    /// Accumulated phases. See `Uniforms.flowPhase`.
    private var flowPhase: Double = 0
    private var warpPhase: Double = 0
    private var lastFrameAt: CFTimeInterval?

    /// The tracked window's rect in the view's own point coordinates.
    var windowRect: CGRect = .zero
    var bandInnerPoints: CGFloat = 6
    var bandOuterPoints: CGFloat = 18
    var cornerRadiusPoints: CGFloat = 11
    var debugMode: Int = 0

    /// Baselines, before the flare's transient multipliers are applied.
    var flowSpeed: Float = 0.45
    var noiseScale: Float = 4.0

    /// Rate while a flare is running, and the settled rate it drops back to.
    var peakFrameRate: Int = 30
    var restingFrameRate: Int { max(10, peakFrameRate / 2) }

    /// Evaluated every frame. Brightness, band width and speed all come off the
    /// same decay curve so the ring relaxes as one thing.
    var animator = Animator()
    var paletteController = PaletteController()

    /// Four quads, two triangles each.
    private static let vertexCount = 24

    /// Throttled diagnostics: one line a second is enough to see whether the
    /// draw loop is running and what geometry it thinks it has.
    private var lastDiagnosticAt: CFTimeInterval = 0

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.write("no Metal device")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            Log.write("could not create a command queue")
            return nil
        }

        // A silent mismatch here renders garbage with no error from either
        // compiler, so fail loudly instead.
        guard MemoryLayout<Uniforms>.stride == Uniforms.expectedStride else {
            Log.write("Uniforms stride is \(MemoryLayout<Uniforms>.stride), "
                  + "expected \(Uniforms.expectedStride) — Swift and Metal layouts disagree")
            return nil
        }

        guard let library = RingRenderer.makeLibrary(device: device) else { return nil }
        guard let vertexFunction = library.makeFunction(name: "ring_vertex"),
              let fragmentFunction = library.makeFunction(name: "ring_fragment") else {
            Log.write("shader functions not found in library")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.pixelFormat = view.colorPixelFormat
        // Premultiplied alpha, matching the shader's output (§8.3).
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.write("pipeline creation failed: \(error)")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        super.init()
    }

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            Log.write("Shaders.metal missing from the bundle")
            return nil
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            Log.write("shader compilation failed: \(error)")
            return nil
        }
    }

    var metalDevice: MTLDevice { device }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing cached against size; the uniforms are rebuilt every frame.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let drawableSize = view.drawableSize

        uniforms.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        uniforms.windowRect = SIMD4(Float(windowRect.origin.x) * scale,
                                    Float(windowRect.origin.y) * scale,
                                    Float(windowRect.width) * scale,
                                    Float(windowRect.height) * scale)
        // One clock for everything, monotonic so it survives wall-clock changes.
        let now = CACurrentMediaTime()
        let colors = paletteController.colors(at: now)
        uniforms.colorA = SIMD4(colors.a, 0)
        uniforms.colorB = SIMD4(colors.b, 0)
        uniforms.colorGlow = SIMD4(colors.glow, 0)

        let bandScale = animator.bandScale(at: now)

        uniforms.cornerRadius = Float(cornerRadiusPoints) * scale
        // Feather both edges by at least 1.5px or the ring aliases badly (§8.3).
        uniforms.bandInner = max(Float(bandInnerPoints) * scale, 1.5)
        // The band visibly swells at the peak of a flare and relaxes back.
        uniforms.bandOuter = max(Float(bandOuterPoints) * scale * bandScale, 1.5)
        // 0.6 keeps the bloom essentially spent by the time it reaches the
        // overlay's edge. Any higher and the glow gets clipped into a visible
        // rectangle where the overlay window ends.
        uniforms.glowFalloff = max(Float(bandOuterPoints) * scale * 0.6, 1.0)

        uniforms.debugMode = Float(debugMode)
        // Integrate. dt is clamped because the view is paused while the ring is
        // hidden, idle or the displays are asleep; without the clamp the first
        // frame back would advance the pattern by however long that lasted and
        // the ring would visibly jump.
        let dt = min(now - (lastFrameAt ?? now), 0.1)
        lastFrameAt = now
        let speed = Double(flowSpeed * animator.speedScale(at: now))
        flowPhase += dt * speed
        warpPhase += dt * speed * 0.4

        uniforms.flowPhase = Float(flowPhase)
        uniforms.warpPhase = Float(warpPhase)
        uniforms.intensity = animator.intensity(at: now)

        // Frames are the whole cost: measured at roughly 0.1% of a core per
        // frame-per-second on this hardware, essentially independent of what the
        // shader does. So run at the full rate only while a flare is actually
        // moving quickly, and halve it once the ring settles into its slow
        // drift, where the difference is not visible.
        // Assigning this reconfigures the view's display link, so only touch it
        // on an actual transition. Writing it every frame costs more than the
        // frames it saves.
        let wanted = animator.isFlaring(at: now) ? peakFrameRate : restingFrameRate
        if view.preferredFramesPerSecond != wanted {
            view.preferredFramesPerSecond = wanted
            Log.write("frame rate -> \(wanted)")
        }
        // Slow enough that the movement reads as drifting rather than
        // flickering — §8.3's photosensitivity constraint. The structure comes
        // from the turbulence, not from speed.
        // Features per turn around the ring. At 2.5 there were only two or
        // three, which read as a single bright dot orbiting the window.
        uniforms.noiseScale = noiseScale

        // Surface anything the GPU rejects. A pixel-format or blend mismatch
        // shows up here and nowhere else — the frame simply never appears.
        buffer.addCompletedHandler { completed in
            if let error = completed.error {
                Log.write("command buffer error: \(error)")
            }
        }

        if debugMode > 0, now - lastDiagnosticAt > 1.0 {
            if let layer = view.layer as? CAMetalLayer {
                Log.write("  layer bounds=\(layer.bounds) scale=\(layer.contentsScale) "
                          + "opaque=\(layer.isOpaque) drawableSize=\(layer.drawableSize) "
                          + "pixelFormat=\(layer.pixelFormat.rawValue) "
                          + "framebufferOnly=\(layer.framebufferOnly) "
                          + "device=\(layer.device?.name ?? "nil") "
                          + "maxDrawables=\(layer.maximumDrawableCount) "
                          + "displaySync=\(layer.displaySyncEnabled)")
                Log.write("  layer superlayer=\(layer.superlayer.map { String(describing: type(of: $0)) } ?? "NONE") "
                          + "hidden=\(layer.isHidden) opacity=\(layer.opacity) "
                          + "position=\(layer.position) frame=\(layer.frame)")
            }
            Log.write("  view hidden=\(view.isHidden) alpha=\(view.alphaValue) "
                      + "inWindow=\(view.window != nil) "
                      + "superview=\(view.superview.map { String(describing: type(of: $0)) } ?? "NONE") "
                      + "wantsLayer=\(view.wantsLayer) "
                      + "drawableTex=\(drawable.texture.width)x\(drawable.texture.height) "
                      + "attachmentTex=\(descriptor.colorAttachments[0].texture.map { "\($0.width)x\($0.height)" } ?? "nil") "
                      + "loadAction=\(descriptor.colorAttachments[0].loadAction.rawValue)")
            lastDiagnosticAt = now
            Log.write("draw res=\(Int(uniforms.resolution.x))x\(Int(uniforms.resolution.y)) "
                  + "windowRect=\(Int(uniforms.windowRect.x)),\(Int(uniforms.windowRect.y)) "
                  + "\(Int(uniforms.windowRect.z))x\(Int(uniforms.windowRect.w)) "
                  + "scale=\(scale) band=\(uniforms.bandInner)/\(uniforms.bandOuter) "
                  + "intensity=\(uniforms.intensity) fps=\(view.preferredFramesPerSecond) "
                  + "occluded=\(!(view.window?.occlusionState.contains(.visible) ?? false)) "
                  + "debugMode=\(debugMode) pad0.x=\(uniforms.pad0.x)")
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle,
                               vertexStart: 0,
                               vertexCount: RingRenderer.vertexCount)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }
}
