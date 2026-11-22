import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case create, chat, gallery, models, engines
    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: return "Create"
        case .chat: return "Chat"
        case .gallery: return "Gallery"
        case .models: return "Models"
        case .engines: return "This Mac"
        }
    }
    var symbol: String {
        switch self {
        case .create: return "sparkles"
        case .chat: return "bubble.left.and.bubble.right"
        case .gallery: return "square.grid.2x2"
        case .models: return "shippingbox"
        case .engines: return "cpu"
        }
    }
}

enum Aspect: String, CaseIterable, Identifiable {
    case square = "1:1", landscape = "4:3", photo = "3:2", wide = "16:9", portrait = "3:4", tall = "9:16"
    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .square: return 1
        case .landscape: return 4.0 / 3
        case .photo: return 3.0 / 2
        case .wide: return 16.0 / 9
        case .portrait: return 3.0 / 4
        case .tall: return 9.0 / 16
        }
    }
    static func closest(width: Int, height: Int) -> Aspect {
        let r = Double(width) / Double(max(height, 1))
        return allCases.min { abs($0.ratio - r) < abs($1.ratio - r) } ?? .square
    }
}

/// A look appended to the prompt.
enum StylePreset: String, CaseIterable, Identifiable {
    case none = "None", photo = "Photo", cinematic = "Cinematic", illustration = "Illustration", anime = "Anime"
    case render = "3D Render", watercolor = "Watercolour", noir = "Noir", pixel = "Pixel Art"
    var id: String { rawValue }
    var suffix: String {
        switch self {
        case .none: return ""
        case .photo: return "professional photograph, natural light, sharp focus, high detail"
        case .cinematic: return "cinematic still, anamorphic lens, dramatic lighting, film grain, shallow depth of field"
        case .illustration: return "detailed digital illustration, clean linework, rich colour palette"
        case .anime: return "anime style, cel shading, vibrant colours, expressive lighting"
        case .render: return "3D render, soft global illumination, physically based materials, octane style"
        case .watercolor: return "watercolour painting, soft washes, visible paper texture"
        case .noir: return "black and white film noir, hard shadows, high contrast"
        case .pixel: return "pixel art, 16-bit, limited palette, crisp pixels"
        }
    }
}

/// The state of the Create screen: chosen model, prompt and settings, plus the memory plan they imply.
@Observable @MainActor
final class Composer {
    var model: InstalledModel?
    var prompt = ""
    var negativePrompt = ""
    var aspect: Aspect = .square
    var longSide: Double = 1024
    var seconds: Double = 4
    var autoSteps = true
    var steps: Double = 20
    var autoGuidance = true
    var guidance: Double = 3.5
    var randomSeed = true
    var seedText = ""
    var inputImage: String?
    var imageStrength: Double = 0.5
    var inputAudio: String?
    var withAudio = true
    /// How many to make in one go, each with its own seed.
    var count = 1
    var style: StylePreset = .none

    private let settings = AppSettings.shared

    var profile: ModelProfile { model?.profile ?? .unsupported }
    var limits: GenerationLimits { MemoryPlanner.limits(unlocked: settings.unlockLimits || !settings.autoMemory) }

    func select(_ model: InstalledModel) {
        self.model = model
        let p = model.profile
        aspect = Aspect.closest(width: p.defaultWidth, height: p.defaultHeight)
        longSide = min(Double(max(p.defaultWidth, p.defaultHeight)), maxLongSide)
        seconds = min(Double(p.defaultFrames) / Double(p.fps), maxSeconds)
        autoSteps = true
        steps = Double(p.defaultSteps ?? 20)
        autoGuidance = true
        guidance = p.defaultGuidance ?? 3.5
        if p.imageInput == .none { inputImage = nil }
        if !p.audioInput { inputAudio = nil }
        settings.lastModelRepo = model.repo
    }

    var maxLongSide: Double {
        let pixels = Double(profile.kind == .image ? limits.maxImagePixels : limits.maxVideoPixels)
        let r = max(aspect.ratio, 1 / aspect.ratio)
        let m = Double(profile.sizeMultiple)
        return max(m * 4, ((pixels * r).squareRoot() / m).rounded(.down) * m)
    }
    var minLongSide: Double { Double(profile.sizeMultiple) * (profile.kind == .image ? 8 : 4) }
    var maxSeconds: Double { Double(limits.maxFrames) / Double(max(profile.fps, 1)) }

    var size: (width: Int, height: Int) {
        let long = min(max(longSide, minLongSide), maxLongSide)
        let w = aspect.ratio >= 1 ? long : long * aspect.ratio
        let h = aspect.ratio >= 1 ? long / aspect.ratio : long
        let (cw, ch) = MemoryPlanner.clampSize(width: Int(w), height: Int(h), kind: profile.kind,
                                               multiple: profile.sizeMultiple, limits: limits)
        return (cw, ch)
    }

    var frames: Int {
        guard profile.kind == .video else { return 1 }
        return MemoryPlanner.clampFrames(Int((seconds * Double(profile.fps)).rounded()), step: profile.frameStep, limits: limits)
    }

    var plan: MemoryPlan? {
        guard let model else { return nil }
        let s = size
        return MemoryPlanner.plan(footprint: model.footprint, profile: profile, width: s.width, height: s.height,
                                  frames: frames, auto: settings.autoMemory, memoryLimitGB: settings.memoryLimitGB)
    }

    var blockReason: String? {
        guard model != nil else { return "Choose a model first." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe what you want to see." }
        if profile.imageInput == .required && inputImage == nil { return "This model needs an input image." }
        if let plan, plan.fit == .tooLarge, settings.autoMemory, !settings.unlockLimits {
            return "Too large for this Mac's memory. Lower the size or length, or pick a smaller variant."
        }
        return nil
    }

    func buildParams() -> GenerationParams? {
        guard let model, blockReason == nil else { return nil }
        let s = size
        var p = GenerationParams()
        p.repo = model.repo
        p.modelTitle = model.title
        p.kind = profile.kind
        p.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if style != .none { p.prompt += ", " + style.suffix }
        p.negativePrompt = profile.supportsNegative ? negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        p.width = s.width; p.height = s.height
        p.frames = frames; p.fps = profile.fps
        p.steps = autoSteps ? profile.defaultSteps : Int(steps)
        p.guidance = profile.supportsGuidance ? (autoGuidance ? profile.defaultGuidance : guidance) : nil
        p.randomSeed = randomSeed || Int(seedText) == nil
        p.seed = Int(seedText) ?? 0
        p.inputImage = profile.imageInput == .none ? nil : inputImage
        p.imageStrength = imageStrength
        p.inputAudio = profile.audioInput ? inputAudio : nil
        p.withAudio = profile.generatesAudio && withAudio
        if let plan {
            p.lowMemory = plan.lowMemory
            p.cacheLimitGB = plan.cacheLimitGB
            p.vaeTiling = plan.vaeTiling
            p.temporalTiles = plan.temporalTiles
        }
        return p
    }

    /// Loads a past generation's settings back into the composer.
    static let imageIdeas = [
        "A weathered lighthouse at dawn, mist rolling over the rocks, soft pastel sky, 35mm photograph",
        "A tiny robot watering a bonsai on a sunlit windowsill, shallow depth of field, warm tones",
        "An isometric cutaway of a cosy bookshop on a rainy night, glowing lamps, detailed illustration",
        "Portrait of an old fisherman with a silver beard, dramatic side light, weathered skin, sharp focus",
        "A glass greenhouse in a snowy forest at blue hour, golden light spilling out, cinematic wide shot",
        "A bowl of ramen seen from above, steam rising, chopsticks resting on the rim, food photography",
    ]
    static let videoIdeas = [
        "A slow dolly shot through a neon-lit market in the rain, reflections on wet pavement, ambient chatter",
        "Waves rolling onto a black sand beach at sunset, drone shot pulling back, sound of surf",
        "A campfire crackling under a starry sky, sparks drifting upward, gentle handheld camera",
        "A paper boat drifting down a rain-filled gutter, close tracking shot, soft patter of rain",
        "Time-lapse of clouds racing over a mountain ridge, light sweeping across the valley",
    ]
    private var ideaIndex = Int.random(in: 0..<100)

    /// Fills the prompt with the next sample idea for the current kind of model.
    func suggestIdea() {
        let ideas = profile.kind == .video ? Self.videoIdeas : Self.imageIdeas
        ideaIndex += 1
        prompt = ideas[ideaIndex % ideas.count]
    }

    func reuse(_ p: GenerationParams) {
        if let m = ModelStore.shared.model(p.repo) { select(m) }
        style = .none            // the saved prompt already contains its style text
        prompt = p.prompt
        negativePrompt = p.negativePrompt
        aspect = Aspect.closest(width: p.width, height: p.height)
        longSide = Double(max(p.width, p.height))
        seconds = p.seconds
        if let s = p.steps, s != profile.defaultSteps { autoSteps = false; steps = Double(s) }
        randomSeed = false
        seedText = "\(p.seed)"
        inputImage = p.inputImage.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        inputAudio = p.inputAudio.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        withAudio = p.withAudio
    }
}

@Observable @MainActor
final class AppState {
    var section: AppSection = .create
    var composer = Composer()
    /// The gallery item shown on the Create canvas.
    var shownItemID: UUID?
    var kindFilter: MediaKind?
    var showDownloads = false
    /// Which part of the Models screen is showing.
    var modelsTab: ModelsTab = .recommended
    /// Image shown in the full-window viewer.
    var lightbox: GalleryItem?
    /// The toolbar's Upscale panel, and the image it should open with (nil lets the user pick one).
    var showUpscaleHub = false
    var upscaleHubItem: GalleryItem?

    /// Wraps any image file on disk so it can be upscaled like a generated result.
    static func importedItem(path: String) -> GalleryItem? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        var p = GenerationParams()
        p.kind = .image
        p.prompt = url.deletingPathExtension().lastPathComponent
        p.modelTitle = "Imported image"
        p.width = w; p.height = h
        return GalleryItem(file: path, kind: .image, params: p, date: Date(), seconds: 0, peakMemoryGB: 0)
    }

    /// True when the previous launch died within seconds of starting. The app then opens without
    /// putting the newest result on screen, so one unshowable file can never lock you out.
    private(set) var safeLaunch = false

    func bootstrap() async {
        let defaults = UserDefaults.standard
        safeLaunch = defaults.bool(forKey: "launchInProgress")
        defaults.set(true, forKey: "launchInProgress")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            defaults.set(false, forKey: "launchInProgress")
        }
        MemoryMonitor.shared.start()
        ChatEngine.stopStrays()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                JobQueue.shared.cancelAll()
                ChatEngine.shared.unload(reason: nil)        // do not leave a model server running
                ChatStore.shared.saveNow()
            }
        }
        async let engines: Void = EngineManager.shared.refresh()
        async let models: Void = ModelStore.shared.refresh()
        _ = await (engines, models)
        pickDefaultModel()
    }

    func pickDefaultModel() {
        let models = ModelStore.shared.generators
        if let current = composer.model, let fresh = models.first(where: { $0.repo == current.repo }) {
            composer.model = fresh
            return
        }
        let last = AppSettings.shared.lastModelRepo
        if let m = models.first(where: { $0.repo == last }) ?? models.first { composer.select(m) }
        else { composer.model = nil }
    }

    func use(_ model: InstalledModel) {
        if model.profile.isChat {
            if AppSettings.shared.lastChatRepo != model.repo {
                AppSettings.shared.lastChatRepo = model.repo
                ChatEngine.shared.unload(reason: nil)
            }
            section = .chat
            return
        }
        composer.select(model)
        section = .create
    }

    func generate() {
        guard let model = composer.model, let params = composer.buildParams() else { return }
        shownItemID = nil
        AppSettings.shared.remember(prompt: composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        for index in 0..<max(1, composer.count) {
            var p = params
            if !p.randomSeed { p.seed += index }
            JobQueue.shared.enqueue(p, model: model)
        }
    }

    /// Size and memory plan for enlarging an image by `factor`, using the saved upscaler settings.
    func upscalePlan(for item: GalleryItem, factor: Double) -> (width: Int, height: Int, upscale: MemoryPlanner.UpscalePlan) {
        let w = Int(Double(item.params.width) * factor) / 2 * 2, h = Int(Double(item.params.height) * factor) / 2 * 2
        let settings = AppSettings.shared
        let plan = MemoryPlanner.upscale(width: w, height: h, quant: settings.upscaleQuant, tile: settings.upscaleTile,
                                         memoryLimitGB: settings.memoryLimitGB)
        return (w, h, plan)
    }

    /// Queues an upscale of a finished image.
    func upscale(_ item: GalleryItem, factor: Double) {
        guard let model = ModelStore.shared.upscaler else { return }
        let planned = upscalePlan(for: item, factor: factor)
        var p = GenerationParams()
        p.repo = model.repo
        p.modelTitle = Upscaler.title
        p.kind = .image
        p.prompt = item.params.prompt
        p.width = planned.width; p.height = planned.height
        p.randomSeed = true
        p.upscaleSource = item.file
        p.upscaleFactor = factor
        p.upscaleSoftness = AppSettings.shared.upscaleSoftness
        p.upscaleQuant = planned.upscale.quant
        p.upscaleTile = planned.upscale.tile
        p.lowMemory = true
        p.vaeTiling = true
        shownItemID = nil
        section = .create
        JobQueue.shared.enqueue(p, model: model)
    }

    /// Runs a past generation again with a fresh seed.
    func makeAnother(of item: GalleryItem) {
        guard let model = ModelStore.shared.model(item.params.repo), item.params.upscaleSource == nil else { return }
        var p = item.params
        p.randomSeed = true
        shownItemID = nil
        section = .create
        JobQueue.shared.enqueue(p, model: model)
    }
}

struct MirageApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Mirage") {
            RootView()
                .environment(app)
                .frame(minWidth: 1020, minHeight: 660)
                .task { await app.bootstrap() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.section = .engines }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Generate") {
                Button("Generate") { app.generate() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(app.composer.blockReason != nil)
                Button("Stop") { if let job = JobQueue.shared.current { JobQueue.shared.cancel(job) } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(JobQueue.shared.current == nil)
                Divider()
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { app.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}
