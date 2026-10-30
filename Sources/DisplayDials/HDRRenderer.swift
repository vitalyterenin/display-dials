import AppKit
@preconcurrency import Metal
import QuartzCore

enum HDRError: Error { case noDevice, noQueue, noDrawable, noBuffer, noEncoder, failed }

/// Uniform float surfaces; no screen capture, gamma tables, presets or hardware writes.
@MainActor
final class HDRRenderer {
    private final class PassiveWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private struct Surface {
        let window: NSWindow
        let layer: CAMetalLayer
    }
    private let queue: MTLCommandQueue
    private let device: MTLDevice
    private var trigger: Surface?
    private var overlay: Surface?
    private var inFlight = false
    private var lastSubmission: Double = 0
    private var lastFactor: Double = -1
    private(set) var failed = false
    private(set) var ready = false
    private(set) var presentedFrames = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw HDRError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw HDRError.noQueue }
        self.device = device; self.queue = queue
    }

    private func surface(frame: NSRect, scale: CGFloat, multiply: Bool) -> Surface {
        let window = PassiveWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = multiply ? "Display Dials · Boost" : "Display Dials · HDR probe"
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + (multiply ? 0 : 1))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // Do not expose an uninitialized float surface.
        window.alphaValue = 0
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, frame.width * scale), height: max(1, frame.height * scale))
        layer.allowsNextDrawableTimeout = true
        if multiply {
            // macOS compositor behavior is experimental; this is not a public
            // whole-desktop brightness API. Keep bounded trials and manual validation.
            layer.compositingFilter = "multiply"
        }
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.orderFrontRegardless()
        return Surface(window: window, layer: layer)
    }

    func begin(on screen: NSScreen, comparison: Bool = false, triggerOnly: Bool = false) throws {
        // A one-point HDR highlight requests headroom; the desktop remains at gain 1
        // until macOS reports actual available headroom. It is not an upscaling gain.
        trigger = surface(frame: NSRect(x: screen.frame.minX + 2, y: screen.frame.maxY - 2, width: 1, height: 1),
                          scale: screen.backingScaleFactor, multiply: false)
        let area = comparison ? NSRect(x: screen.frame.midX, y: screen.frame.minY,
                                       width: screen.frame.width / 2, height: screen.frame.height) : screen.frame
        if !triggerOnly { overlay = surface(frame: area, scale: screen.backingScaleFactor, multiply: true) }
        try render(factor: 1, now: ProcessInfo.processInfo.systemUptime, force: true)
    }

    func render(factor: Double, now: Double, force: Bool = false) throws {
        guard factor.isFinite, factor >= 1, factor <= 1.25, !failed else { throw HDRError.failed }
        if inFlight {
            if now - lastSubmission > 1 { failed = true; throw HDRError.failed }
            return
        }
        guard force || factor != lastFactor || now - lastSubmission >= 0.18 else { return }
        guard let trigger else { throw HDRError.failed }
        guard let command = queue.makeCommandBuffer() else { throw HDRError.noBuffer }
        var surfaces: [(Surface, Double)] = [(trigger, 1.25)]
        if let overlay { surfaces.append((overlay, factor)) }
        for (surface, value) in surfaces {
            guard let drawable = surface.layer.nextDrawable() else { throw HDRError.noDrawable }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(value, value, value, 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw HDRError.noEncoder }
            encoder.endEncoding()
            command.present(drawable)
        }
        inFlight = true; lastSubmission = now; lastFactor = factor
        command.addCompletedHandler { [weak self] buffer in
            let ok = buffer.status == .completed
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                guard ok else { self.failed = true; return }
                self.presentedFrames += 1
                if !self.ready {
                    self.ready = true
                    self.trigger?.window.alphaValue = 1
                    self.overlay?.window.alphaValue = 1
                }
            }
        }
        command.commit()
    }

    func stop() {
        trigger?.window.orderOut(nil); overlay?.window.orderOut(nil)
        trigger?.window.close(); overlay?.window.close()
        trigger = nil; overlay = nil; ready = false
    }

    /// Exercises the float render path offscreen. This cannot prove desktop compositing
    /// behavior or physical luminance; those require a live, bounded trial.
    static func offscreenCheck() throws -> [String: Any] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw HDRError.noDevice }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw HDRError.noBuffer }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1.1, 1.1, 1.1, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw HDRError.noEncoder }
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw HDRError.failed }
        var pixels = [UInt16](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0) }
        let red = Double(Float16(bitPattern: pixels[0]))
        guard abs(red - 1.1) < 0.002 else { throw HDRError.failed }
        return ["device": device.name, "floatRenderPassed": true, "pixelValue": red, "displayChanged": false]
    }
}
