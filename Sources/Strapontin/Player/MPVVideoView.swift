import AppKit
import Cmpv
import OpenGL.GL3
import QuartzCore

/// Couche OpenGL dans laquelle mpv dessine (API de rendu de libmpv), à la résolution Retina native.
final class MPVLayer: CAOpenGLLayer {
    weak var player: MPVPlayer?
    private let pixelFormat: CGLPixelFormatObj?
    private var cglContext: CGLContextObj?

    override init() {
        pixelFormat = Self.choosePixelFormat()
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        pixelFormat = (layer as? MPVLayer)?.pixelFormat.map { CGLRetainPixelFormat($0) }
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let cglContext { CGLReleaseContext(cglContext) }
        if let pixelFormat { CGLReleasePixelFormat(pixelFormat) }
    }

    private static func choosePixelFormat() -> CGLPixelFormatObj? {
        func choose(_ attrs: [CGLPixelFormatAttribute]) -> CGLPixelFormatObj? {
            var pix: CGLPixelFormatObj?
            var n: GLint = 0
            CGLChoosePixelFormat(attrs + [CGLPixelFormatAttribute(rawValue: 0)], &pix, &n)
            return pix
        }
        let base: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
        ]
        // 16 bits flottant par canal (moins de banding), sinon 8 bits classique
        let deep = base + [kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 64), kCGLPFAColorFloat]
        return choose(deep) ?? choose(base)
    }

    /// Crée tout de suite le contexte GL et le contexte de rendu mpv. CAOpenGLLayer ne demande son contexte
    /// qu'au premier affichage, après le `loadfile` : mpv ne trouvait alors pas de contexte de rendu,
    /// abandonnait la piste vidéo (« No render context set ») et ne jouait que le son, d'où l'écran noir.
    func prepare() {
        guard cglContext == nil, let pixelFormat else { return }
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let ctx else { return }
        var one: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &one)
        cglContext = ctx
        CGLSetCurrentContext(ctx)
        createRenderContext()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pixelFormat { return CGLRetainPixelFormat(pixelFormat) }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        prepare()
        if let cglContext { return CGLRetainContext(cglContext) }
        return super.copyCGLContext(forPixelFormat: pf)
    }

    private func createRenderContext() {
        guard let player, player.renderContext == nil else { return }
        let getProc: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name else { return nil }
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
            guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }
        var glInit = mpv_opengl_init_params(get_proc_address: getProc, get_proc_address_ctx: nil)
        let api = strdup("opengl")
        defer { free(api) }
        var ctx: OpaquePointer?
        withUnsafeMutablePointer(to: &glInit) { glPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPtr)),
                mpv_render_param(),
            ]
            mpv_render_context_create(&ctx, player.handle, &params)
        }
        player.renderContext = ctx
        mpv_render_context_set_update_callback(ctx, { raw in
            guard let raw else { return }
            let layer = Unmanaged<MPVLayer>.fromOpaque(raw).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        guard let rc = player?.renderContext else { glFlush(); return }
        _ = mpv_render_context_update(rc)
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var vp: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &vp)
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(vp[2]), h: Int32(vp[3]), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &target) { tp in
            withUnsafeMutablePointer(to: &flip) { fp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(tp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(rc, &params)
            }
        }
        glFlush()
    }

    /// À appeler avant de détruire mpv, contexte GL courant.
    func teardown() {
        guard let player, let rc = player.renderContext else { return }
        if let cglContext { CGLSetCurrentContext(cglContext) }
        mpv_render_context_set_update_callback(rc, nil, nil)
        mpv_render_context_free(rc)
        player.renderContext = nil
    }
}

final class MPVVideoView: NSView {
    let videoLayer = MPVLayer()

    init(player: MPVPlayer) {
        super.init(frame: .zero)
        videoLayer.player = player
        videoLayer.prepare()
        layer = videoLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // pixels réels de l'écran : sans ça la vidéo serait rendue en basse définition puis agrandie
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
