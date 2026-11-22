import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image, video
    var id: String { rawValue }
    var title: String { self == .image ? "Image" : "Video" }
    var symbol: String { self == .image ? "photo" : "film" }
}

enum EngineID: String, Codable, CaseIterable, Identifiable {
    case mflux = "mflux"
    case ltx = "ltx-2-mlx"
    case mlxVideo = "mlx-video"
    var id: String { rawValue }
}

/// Which engine family a model repo belongs to.
enum ModelFamily: String, Codable {
    case mflux          // image models in mflux format
    case ltx            // LTX-2.x packs for ltx-2-mlx
    case ltxMlxVideo    // LTX-2.x in mlx-video layout
    case wan            // Wan 2.x converted for mlx-video
    case unsupported

    var engine: EngineID? {
        switch self {
        case .mflux: return .mflux
        case .ltx: return .ltx
        case .ltxMlxVideo, .wan: return .mlxVideo
        case .unsupported: return nil
        }
    }
}

enum InputSupport { case none, optional, required }

/// Everything the app needs to know to drive one model: which command runs it and what it accepts.
struct ModelProfile {
    var family: ModelFamily
    var kind: MediaKind
    var label: String
    var command: String
    /// Command used instead when the user supplies reference images (instruction-style editing).
    var editCommand: String? = nil
    var baseModel: String? = nil
    var defaultSteps: Int? = nil
    var defaultGuidance: Double? = nil
    var supportsNegative = false
    var supportsGuidance = false
    var imageInput: InputSupport = .optional
    var audioInput = false
    var generatesAudio = false
    var defaultWidth = 1024
    var defaultHeight = 1024
    var sizeMultiple = 16
    /// Frame counts must be `frameStep * n + 1`.
    var frameStep = 8
    var defaultFrames = 97
    var fps = 24
    /// A helper that works on existing results (the upscaler) rather than generating from a prompt.
    var isTool = false

    var engine: EngineID? { family.engine }
    var isRunnable: Bool { family != .unsupported }

    static let unsupported = ModelProfile(family: .unsupported, kind: .image, label: "Unsupported", command: "")

    /// Works out the profile from a repo's name, tags and (when known) file list.
    static func resolve(repo: String, tags: [String] = [], library: String? = nil,
                        pipeline: String? = nil, files: [String]? = nil) -> ModelProfile {
        let name = repo.lowercased().replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        let short = name.split(separator: "/").last.map(String.init) ?? name
        let lowerTags = Set(tags.map { $0.lowercased() })
        let isMLX = lowerTags.contains("mlx") || lowerTags.contains("mflux") || lowerTags.contains("mlx-video")
            || library == "mlx" || library == "mflux" || library == "mlx-video" || short.contains("mlx") || short.contains("mflux")
        func has(_ s: String) -> Bool { short.contains(s) }
        func hasFile(_ f: String) -> Bool { files?.contains(where: { $0 == f || $0.hasPrefix(f) }) ?? false }

        // The SeedVR2 upscaler: either the original weights mflux converts on load, or an mflux-format copy.
        if has("seedvr2") {
            let original = repo == Upscaler.repo
            let mfluxFormat = library == "mflux" || lowerTags.contains("mflux") || has("mflux")
            guard original || mfluxFormat else { return .unsupported }
            if original, let files, !files.contains(Upscaler.transformerFile) { return .unsupported }
            var p = ModelProfile(family: .mflux, kind: .image, label: "Upscaler", command: "mflux-upscale-seedvr2")
            p.baseModel = has("7b") ? "seedvr2-7b" : "seedvr2-3b"
            p.imageInput = .required
            p.isTool = true
            return p
        }

        // Helper pieces that are not generators on their own.
        if has("lora") || has("controlnet") || has("-vae") || has("gemma") || has("text-encoder") || has("upscal") {
            return .unsupported
        }

        // ---- Video: LTX ----
        if has("ltx") {
            guard isMLX || files != nil else { return .unsupported }
            if let files {
                let isPack = files.contains("connector.safetensors") && files.contains(where: { $0.hasPrefix("transformer") && $0.hasSuffix(".safetensors") })
                let isMlxVideoLayout = hasFile("transformer/") && (hasFile("text_projections/") || hasFile("vae/"))
                if isPack { return ltxProfile(short) }
                if isMlxVideoLayout { return ltxMlxVideoProfile() }
                return .unsupported
            }
            return ltxProfile(short)
        }

        // ---- Video: Wan ----
        if has("wan2") || has("wan-2") {
            guard isMLX else { return .unsupported }
            if let files {
                let ok = files.contains("model.safetensors") || files.contains("high_noise_model.safetensors")
                    || files.contains(where: { $0.hasSuffix("noise_model.safetensors") })
                guard ok && files.contains("config.json") else { return .unsupported }
            }
            var p = ModelProfile(family: .wan, kind: .video, label: "Wan 2.x", command: "mlx_video.wan_2.generate")
            p.supportsNegative = true
            p.supportsGuidance = true
            p.imageInput = has("i2v") ? .required : (has("ti2v") ? .optional : .none)
            p.defaultWidth = 832; p.defaultHeight = 480; p.sizeMultiple = 32
            p.frameStep = 4; p.defaultFrames = 49
            p.fps = has("5b") ? 24 : 16
            return p
        }

        // ---- Images: mflux ----
        let looksMflux = library == "mflux" || lowerTags.contains("mflux") || has("mflux")
        guard looksMflux else { return .unsupported }
        for row in mfluxTable where row.match.contains(where: { has($0) }) {
            var p = ModelProfile(family: .mflux, kind: .image, label: row.label, command: row.command)
            p.editCommand = row.edit
            p.baseModel = row.base?(short)
            p.defaultSteps = row.steps
            p.defaultGuidance = row.guidance
            p.supportsGuidance = row.guidance != nil
            p.supportsNegative = row.negative
            p.imageInput = row.image
            return p
        }
        return ModelProfile(family: .mflux, kind: .image, label: "mflux model", command: "mflux-generate")
    }

    private static func ltxProfile(_ short: String) -> ModelProfile {
        var p = ModelProfile(family: .ltx, kind: .video, label: short.contains("2-5") ? "LTX-2.5" : "LTX-2", command: "ltx-2-mlx")
        p.audioInput = true
        p.generatesAudio = true
        p.defaultWidth = 704; p.defaultHeight = 480; p.sizeMultiple = 64
        p.frameStep = 8; p.defaultFrames = 97; p.fps = 24
        return p
    }

    private static func ltxMlxVideoProfile() -> ModelProfile {
        var p = ModelProfile(family: .ltxMlxVideo, kind: .video, label: "LTX-2 (mlx-video)", command: "mlx_video.ltx_2.generate")
        p.audioInput = true
        p.generatesAudio = true
        p.defaultWidth = 768; p.defaultHeight = 512; p.sizeMultiple = 64
        return p
    }

    private struct MfluxRow {
        let match: [String]
        let label: String
        let command: String
        var edit: String? = nil
        var base: ((String) -> String?)? = nil
        var steps: Int? = nil
        var guidance: Double? = nil
        var negative = false
        var image: InputSupport = .optional
    }

    // Order matters: more specific names first.
    private static let mfluxTable: [MfluxRow] = [
        MfluxRow(match: ["z-image-turbo"], label: "Z-Image Turbo", command: "mflux-generate-z-image-turbo", steps: 9),
        MfluxRow(match: ["z-image"], label: "Z-Image", command: "mflux-generate-z-image", guidance: 4.0, negative: true),
        MfluxRow(match: ["flux2-klein", "flux-2-klein"], label: "FLUX.2 klein", command: "mflux-generate-flux2",
                 edit: "mflux-generate-flux2-edit", steps: 4),
        MfluxRow(match: ["flux-3-image-klein", "flux3-image-klein", "flux-3-klein"], label: "FLUX 3 Klein",
                 command: "mflux-generate-flux3", edit: "mflux-generate-flux3-edit"),
        MfluxRow(match: ["qwen-image-edit"], label: "Qwen Image Edit", command: "mflux-generate-qwen-edit",
                 edit: "mflux-generate-qwen-edit", guidance: 4.0, negative: true, image: .required),
        MfluxRow(match: ["qwen-image-2-1"], label: "Qwen Image 2.1", command: "mflux-generate-qwen-2.1", negative: true),
        MfluxRow(match: ["qwen-image"], label: "Qwen Image", command: "mflux-generate-qwen", guidance: 4.0, negative: true),
        MfluxRow(match: ["krea-2"], label: "Krea 2", command: "mflux-generate-krea2"),
        MfluxRow(match: ["kontext"], label: "FLUX Kontext", command: "mflux-generate-kontext",
                 base: { _ in "dev-kontext" }, steps: 25, guidance: 2.5, image: .required),
        MfluxRow(match: ["schnell"], label: "FLUX.1 schnell", command: "mflux-generate", base: { _ in "schnell" }, steps: 4),
        MfluxRow(match: ["krea-dev"], label: "FLUX.1 Krea", command: "mflux-generate", base: { _ in "krea-dev" }, steps: 25, guidance: 4.5),
        MfluxRow(match: ["flux-1-dev", "flux1-dev", "flux-dev"], label: "FLUX.1 dev", command: "mflux-generate",
                 base: { _ in "dev" }, steps: 25, guidance: 3.5),
        MfluxRow(match: ["fibo2"], label: "FIBO 2", command: "mflux-generate-fibo2"),
        MfluxRow(match: ["fibo"], label: "FIBO", command: "mflux-generate-fibo"),
        MfluxRow(match: ["ernie-image-turbo"], label: "ERNIE Image Turbo", command: "mflux-generate-ernie-image-turbo"),
        MfluxRow(match: ["ernie-image"], label: "ERNIE Image", command: "mflux-generate-ernie-image"),
        MfluxRow(match: ["ideogram"], label: "Ideogram 4", command: "mflux-generate-ideogram4"),
        MfluxRow(match: ["anima"], label: "Anima", command: "mflux-generate-anima"),
        MfluxRow(match: ["boogu"], label: "Boogu", command: "mflux-generate-boogu"),
        MfluxRow(match: ["moss-image"], label: "MOSS Image", command: "mflux-generate-moss-image"),
        MfluxRow(match: ["ming-image", "ming"], label: "Ming Image", command: "mflux-generate-ming"),
        MfluxRow(match: ["lens"], label: "Lens", command: "mflux-generate-lens"),
        MfluxRow(match: ["iris"], label: "Iris", command: "mflux-generate-iris"),
    ]
}

/// Rough memory needs of a model, in GB of weights held in memory at the busiest moment.
struct ModelFootprint: Codable, Equatable {
    /// Peak with everything loaded the normal way.
    var residentGB: Double
    /// Peak when the engine's low-memory mode is on (components loaded one at a time or streamed).
    var lowMemoryGB: Double

    /// Estimates a footprint from a list of files and sizes.
    static func estimate(family: ModelFamily, files: [(path: String, size: Int64)]) -> ModelFootprint {
        let weights = files.filter { $0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".npz") || $0.path.hasSuffix(".gguf") }
        func gb(_ n: Int64) -> Double { Double(n) / 1_073_741_824 }
        var groups: [String: Int64] = [:]
        for f in weights {
            let key = f.path.contains("/") ? String(f.path.split(separator: "/")[0]) : f.path
            groups[key, default: 0] += f.size
        }
        let total = weights.reduce(Int64(0)) { $0 + $1.size }
        let largest = groups.values.max() ?? 0
        switch family {
        case .mflux:
            return ModelFootprint(residentGB: gb(total), lowMemoryGB: gb(largest))
        case .ltx:
            let transformer = weights.filter { $0.path.hasPrefix("transformer-distilled") }.map(\.size).max()
                ?? weights.filter { $0.path.hasPrefix("transformer") }.map(\.size).max() ?? largest
            // The text encoder is loaded alone before the transformer; packs without one use Gemma 3 12B 4-bit (~8 GB).
            let encoder = weights.first(where: { $0.path == "text_encoder.safetensors" })?.size ?? Int64(8.1 * 1_073_741_824)
            let streamed = Int64(Double(transformer) * 0.28)
            return ModelFootprint(residentGB: gb(max(transformer, encoder)), lowMemoryGB: gb(max(streamed, encoder)))
        case .wan, .ltxMlxVideo:
            return ModelFootprint(residentGB: gb(largest), lowMemoryGB: gb(largest))
        case .unsupported:
            return ModelFootprint(residentGB: gb(largest), lowMemoryGB: gb(largest))
        }
    }
}

/// The image upscaler. mflux reads SeedVR2's original weights and converts them to MLX as it loads them.
enum Upscaler {
    static let repo = "numz/SeedVR2_comfyUI"
    static let transformerFile = "seedvr2_ema_3b_fp16.safetensors"
    /// The only files the 3B upscaler loads; the repo also holds 40 GB of other variants.
    static let neededFiles: Set<String> = [transformerFile, "ema_vae_fp16.safetensors", "config.json"]
    static let title = "SeedVR2 Upscaler"
}

/// Files a pack ships that fast generation never loads. Skipping them saves tens of GB.
func defaultExcludedFiles(repo: String = "", family: ModelFamily, files: [String]) -> Set<String> {
    var skip = Set<String>()
    if repo == Upscaler.repo { return Set(files).subtracting(Upscaler.neededFiles) }
    for f in files where f.hasPrefix(".git") { skip.insert(f) }
    guard family == .ltx else { return skip }
    for f in files {
        let lower = f.lowercased()
        if lower.contains("lora") || lower == "transformer-dev.safetensors" || lower.contains("upscaler_x1_5") {
            skip.insert(f)
        }
    }
    // When a versioned fast transformer exists the engine prefers it, so the unversioned one is dead weight.
    let versioned = files.filter { $0.hasPrefix("transformer-distilled-") && $0.hasSuffix(".safetensors") }
    if !versioned.isEmpty { skip.insert("transformer-distilled.safetensors") }
    return skip
}

// MARK: - Curated catalog

struct ModelVariant: Identifiable, Hashable {
    let quant: String          // "4-bit", "8-bit", "Full"
    let repo: String
    let downloadGB: Double
    let footprint: ModelFootprint
    var id: String { repo }

    static func == (a: ModelVariant, b: ModelVariant) -> Bool { a.repo == b.repo }
    func hash(into h: inout Hasher) { h.combine(repo) }
}

struct CatalogModel: Identifiable {
    let id: String
    let name: String
    let maker: String
    let kind: MediaKind
    let blurb: String
    let abilities: [String]
    let variants: [ModelVariant]      // smallest first
    /// Extra repos the engine needs alongside the model (for example a text encoder).
    var companions: [String] = []
    var companionGB: Double = 0
    var needsLogin = false
    var note: String? = nil

    var profile: ModelProfile { ModelProfile.resolve(repo: variants[0].repo, tags: ["mlx", "mflux"]) }
}

private func fp(_ resident: Double, _ low: Double) -> ModelFootprint { ModelFootprint(residentGB: resident, lowMemoryGB: low) }

enum Catalog {
    static let models: [CatalogModel] = [
        CatalogModel(
            id: "z-image-turbo", name: "Z-Image Turbo", maker: "Alibaba Tongyi", kind: .image,
            blurb: "Fast, sharp photorealistic images in about nine steps. The best all-rounder on small Macs.",
            abilities: ["Text to image", "Image to image"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/z-image-turbo-mflux-q4", downloadGB: 5.9, footprint: fp(5.5, 3.3)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/z-image-turbo-mflux-q8", downloadGB: 11.0, footprint: fp(10.3, 6.1)),
            ]),
        CatalogModel(
            id: "flux2-klein-4b", name: "FLUX.2 klein 4B", maker: "Black Forest Labs", kind: .image,
            blurb: "Small and very quick four-step model that also edits images from a text instruction.",
            abilities: ["Text to image", "Image editing"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/flux2-klein-4b-mflux-q4", downloadGB: 4.6, footprint: fp(4.3, 2.1)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/flux2-klein-4b-mflux-q8", downloadGB: 8.6, footprint: fp(8.0, 4.0)),
            ]),
        CatalogModel(
            id: "flux3-klein", name: "FLUX 3 Image Klein", maker: "Black Forest Labs", kind: .image,
            blurb: "The newest small FLUX generation, in a size that fits most Macs.",
            abilities: ["Text to image", "Image editing"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/flux-3-image-klein-mflux-q4", downloadGB: 5.3, footprint: fp(4.9, 2.9)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/flux-3-image-klein-mflux-q8", downloadGB: 9.9, footprint: fp(9.2, 5.5)),
            ]),
        CatalogModel(
            id: "flux2-klein-9b", name: "FLUX.2 klein 9B", maker: "Black Forest Labs", kind: .image,
            blurb: "The larger klein: more detail and better prompt following, for Macs with more memory.",
            abilities: ["Text to image", "Image editing"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/flux2-klein-9b-mflux-q4", downloadGB: 9.5, footprint: fp(8.8, 4.7)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/flux2-klein-9b-mflux-q8", downloadGB: 17.9, footprint: fp(16.7, 8.9)),
            ]),
        CatalogModel(
            id: "qwen-image-21-turbo", name: "Qwen Image 2.1 Turbo", maker: "Alibaba Qwen", kind: .image,
            blurb: "Strong at layouts, posters and readable text inside images.",
            abilities: ["Text to image", "Image to image"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/qwen-image-2-1-turbo-mflux-q4", downloadGB: 10.0, footprint: fp(9.3, 4.8)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/qwen-image-2-1-turbo-mflux-q8", downloadGB: 17.8, footprint: fp(16.6, 8.8)),
            ]),
        CatalogModel(
            id: "krea-2-turbo", name: "Krea 2 Turbo", maker: "Krea", kind: .image,
            blurb: "Aesthetic, natural-looking images with less of the usual AI gloss.",
            abilities: ["Text to image"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/krea-2-turbo-mflux-q4", downloadGB: 15.8, footprint: fp(14.7, 7.5)),
                ModelVariant(quant: "8-bit", repo: "mflux-community/krea-2-turbo-mflux-q8", downloadGB: 22.2, footprint: fp(20.7, 13.0)),
            ]),
        CatalogModel(
            id: "qwen-image-edit", name: "Qwen Image Edit 2511", maker: "Alibaba Qwen", kind: .image,
            blurb: "Edits a photo from a written instruction while keeping the subject consistent. A large model.",
            abilities: ["Image editing"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "mflux-community/qwen-image-edit-2511-mflux-q4", downloadGB: 29.0, footprint: fp(27.0, 14.4)),
            ]),
        CatalogModel(
            id: "seedvr2-upscaler", name: Upscaler.title, maker: "ByteDance Seed", kind: .image,
            blurb: "Enlarges any image two to four times and restores real detail. Use it from the Upscale button under a result.",
            abilities: ["Upscaling"],
            variants: [
                ModelVariant(quant: "Full", repo: Upscaler.repo, downloadGB: 7.3, footprint: fp(6.8, 6.3)),
            ],
            note: "Runs on MLX; the original weights are converted as they load."),
        CatalogModel(
            id: "ltx-2.3", name: "LTX-2.3", maker: "Lightricks", kind: .video,
            blurb: "Video with synchronised sound in one pass, from text, an image or an audio track.",
            abilities: ["Text to video", "Image to video", "Audio to video", "Sound"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "dgrauet/ltx-2.3-mlx-q4", downloadGB: 21.8, footprint: fp(10.6, 7.6)),
                ModelVariant(quant: "8-bit", repo: "dgrauet/ltx-2.3-mlx-q8", downloadGB: 31.0, footprint: fp(19.2, 7.6)),
                ModelVariant(quant: "Full", repo: "dgrauet/ltx-2.3-mlx", downloadGB: 48.5, footprint: fp(35.4, 10.0)),
            ],
            companions: ["mlx-community/gemma-3-12b-it-4bit"], companionGB: 8.1),
        CatalogModel(
            id: "ltx-2.5", name: "LTX-2.5", maker: "Lightricks", kind: .video,
            blurb: "The newest LTX: multi-shot video with sound and an automatically chosen clip length.",
            abilities: ["Text to video", "Image to video", "Audio to video", "Sound"],
            variants: [
                ModelVariant(quant: "4-bit", repo: "dgrauet/ltx-2.5-mlx-q4", downloadGB: 29.8, footprint: fp(10.6, 9.9)),
                ModelVariant(quant: "8-bit", repo: "dgrauet/ltx-2.5-mlx-q8", downloadGB: 44.6, footprint: fp(19.2, 14.9)),
                ModelVariant(quant: "Full", repo: "dgrauet/ltx-2.5-mlx", downloadGB: 72.2, footprint: fp(35.4, 24.4)),
            ],
            needsLogin: true,
            note: "Needs a free Hugging Face account: accept the model terms on its page, then add your token in Settings."),
        CatalogModel(
            id: "wan-2.2-ti2v-5b", name: "Wan 2.2 TI2V-5B", maker: "Alibaba Wan", kind: .video,
            blurb: "Compact Wan model for text or image to video at 24 fps. No sound.",
            abilities: ["Text to video", "Image to video"],
            variants: [
                ModelVariant(quant: "8-bit", repo: "Anes1032/Wan2.2-TI2V-5B-mlx-q8", downloadGB: 19.6, footprint: fp(10.6, 10.6)),
            ]),
    ]

    static func entry(forRepo repo: String) -> (model: CatalogModel, variant: ModelVariant)? {
        for m in models {
            if let v = m.variants.first(where: { $0.repo == repo }) { return (m, v) }
        }
        return nil
    }
}
