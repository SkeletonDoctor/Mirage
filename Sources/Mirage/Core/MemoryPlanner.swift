import Foundation

enum FitLevel: Int, Comparable {
    case comfortable, lowMemoryMode, tight, tooLarge
    static func < (a: FitLevel, b: FitLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .comfortable: return "Fits"
        case .lowMemoryMode: return "Fits in low-memory mode"
        case .tight: return "Tight"
        case .tooLarge: return "Too large"
        }
    }
    var symbol: String {
        switch self {
        case .comfortable: return "checkmark.circle.fill"
        case .lowMemoryMode: return "checkmark.circle"
        case .tight: return "exclamationmark.triangle.fill"
        case .tooLarge: return "xmark.octagon.fill"
        }
    }
}

/// Upper bounds on what this Mac should be asked to generate.
struct GenerationLimits {
    var maxImagePixels: Int
    var maxVideoPixels: Int
    var maxFrames: Int

    func maxImageSide(multiple: Int) -> Int {
        max(512, Int(Double(maxImagePixels).squareRoot()) / multiple * multiple)
    }
}

/// The decisions the app makes for one generation so it stays inside this Mac's memory.
struct MemoryPlan {
    var fit: FitLevel
    var peakGB: Double
    var budgetGB: Double
    var lowMemory: Bool
    /// Cap for MLX's buffer cache, where the engine supports one.
    var cacheLimitGB: Double?
    var vaeTiling: Bool
    var temporalTiles: Int
    var notes: [String]
}

enum MemoryPlanner {
    /// What the app allows by default: the smaller of what Metal recommends for the GPU
    /// and total memory minus what is kept back for macOS and other apps.
    static func recommendedBudgetGB(system: SystemInfo = .current) -> Double {
        let total = system.totalGB
        let reserve: Double = total <= 16 ? 3.5 : total <= 36 ? 5 : 8
        return max(2, min(system.gpuWorkingSetGB, total - reserve))
    }

    /// Memory the generation process may use. `override` is the user's own limit in GB (0 = recommended);
    /// it may go above the recommendation, up to all of the Mac's memory.
    static func budgetGB(override: Double = 0, system: SystemInfo = .current) -> Double {
        override > 0 ? min(override, system.totalGB) : recommendedBudgetGB(system: system)
    }

    static func limits(system: SystemInfo = .current, unlocked: Bool = false) -> GenerationLimits {
        if unlocked {
            return GenerationLimits(maxImagePixels: 4096 * 4096, maxVideoPixels: 3840 * 2176, maxFrames: 481)
        }
        switch system.totalGB {
        case ..<12:
            return GenerationLimits(maxImagePixels: 1280 * 1280, maxVideoPixels: 512 * 320, maxFrames: 49)
        case ..<20:
            return GenerationLimits(maxImagePixels: 2560 * 2560, maxVideoPixels: 704 * 480, maxFrames: 97)
        case ..<28:
            return GenerationLimits(maxImagePixels: 3072 * 3072, maxVideoPixels: 960 * 544, maxFrames: 121)
        case ..<40:
            return GenerationLimits(maxImagePixels: 3584 * 3584, maxVideoPixels: 1280 * 704, maxFrames: 145)
        case ..<72:
            return GenerationLimits(maxImagePixels: 4096 * 4096, maxVideoPixels: 1280 * 704, maxFrames: 241)
        case ..<140:
            return GenerationLimits(maxImagePixels: 4096 * 4096, maxVideoPixels: 1920 * 1088, maxFrames: 241)
        default:
            return GenerationLimits(maxImagePixels: 4096 * 4096, maxVideoPixels: 1920 * 1088, maxFrames: 481)
        }
    }

    /// Working memory on top of the weights: latents, attention and the decoder.
    static func activationGB(kind: MediaKind, width: Int, height: Int, frames: Int) -> Double {
        let megapixels = Double(width * height) / 1_000_000
        switch kind {
        case .image: return 1.2 + megapixels * 0.95      // measured: 6.6 GB total at 4.2 MP in low-memory mode
        case .video: return 1.0 + megapixels * Double(max(frames, 1)) * 0.055
        }
    }

    static func plan(footprint: ModelFootprint, profile: ModelProfile, width: Int, height: Int, frames: Int,
                     auto: Bool, memoryLimitGB: Double = 0, system: SystemInfo = .current) -> MemoryPlan {
        let budget = budgetGB(override: memoryLimitGB, system: system)
        let raised = budget > recommendedBudgetGB(system: system) + 0.25
        let activation = activationGB(kind: profile.kind, width: width, height: height, frames: frames)
        let normalPeak = footprint.residentGB + activation
        let lowPeak = footprint.lowMemoryGB + activation
        var notes: [String] = []

        var lowMemory = false
        var fit: FitLevel
        var peak = normalPeak
        if normalPeak <= budget * 0.92 {
            fit = .comfortable
        } else if lowPeak <= budget * 0.95 {
            fit = .lowMemoryMode; lowMemory = true; peak = lowPeak
        } else if lowPeak <= budget * 1.25 {
            fit = .tight; lowMemory = true; peak = lowPeak
        } else {
            fit = .tooLarge; lowMemory = true; peak = lowPeak
        }
        if !auto {
            // Manual mode: report honestly but leave the engine's defaults alone.
            return MemoryPlan(fit: normalPeak <= budget ? .comfortable : (normalPeak <= budget * 1.25 ? .tight : .tooLarge),
                              peakGB: normalPeak, budgetGB: budget, lowMemory: false, cacheLimitGB: nil,
                              vaeTiling: false, temporalTiles: 1,
                              notes: ["Automatic memory management is off."])
        }

        if lowMemory {
            switch profile.family {
            case .ltx: notes.append("Streaming the model from disk block by block to stay within memory.")
            case .mflux: notes.append("Loading one component at a time and releasing each after use.")
            default: notes.append("Using the engine's memory-saving decode.")
            }
        }
        let megapixels = Double(width * height) / 1_000_000
        let vaeTiling = profile.kind == .image ? (megapixels > 1.2 || lowMemory && megapixels > 0.8) : lowMemory
        if vaeTiling && profile.kind == .image { notes.append("Decoding the image in tiles.") }

        var temporalTiles = 1
        if profile.family == .ltx {
            let load = megapixels * Double(frames)
            let comfortable = budget * 3.0          // megapixel-frames one pass can hold
            if load > comfortable {
                temporalTiles = min(4, Int((load / comfortable).rounded(.up)))
                notes.append("Splitting the clip into \(temporalTiles) time tiles.")
            }
        }
        // Leave room for activations; the cache cap stops MLX hoarding freed buffers.
        let cache: Double? = lowMemory || budget < 16 ? max(1, (budget - peak) * 0.5).rounded() : nil

        if raised && peak > recommendedBudgetGB(system: system) {
            notes.append("Using your raised memory limit. macOS may swap, which slows everything down.")
        }
        switch fit {
        case .tight: notes.append("Expect some swapping. Close other apps before you start.")
        case .tooLarge: notes.append("Needs about \(Format.gb(peak)) but only \(Format.gb(budget)) is safely usable. Try a smaller variant or size.")
        default: break
        }
        return MemoryPlan(fit: fit, peakGB: peak, budgetGB: budget, lowMemory: lowMemory, cacheLimitGB: cache,
                          vaeTiling: vaeTiling, temporalTiles: temporalTiles, notes: notes)
    }

    /// What an upscale needs and the settings chosen for it.
    struct UpscalePlan {
        var plan: MemoryPlan
        /// Bits per weight: 16 (full), 8 or 4.
        var quant: Int
        /// Decode tile size in pixels.
        var tile: Int
    }

    /// Memory plan for the SeedVR2 upscaler. `quant` and `tile` of 0 let the app choose.
    /// Figures come from measurements on an M5: about 1.2 GB per output megapixel while enlarging,
    /// and an 11.3 GB decode peak with 512 px tiles against well under that with 256 px tiles.
    static func upscale(width: Int, height: Int, quant: Int = 0, tile: Int = 0,
                        memoryLimitGB: Double = 0, system: SystemInfo = .current) -> UpscalePlan {
        let budget = budgetGB(override: memoryLimitGB, system: system)
        let megapixels = Double(width * height) / 1_000_000
        func weights(_ q: Int) -> Double { q == 4 ? 1.7 : q == 8 ? 3.2 : 6.3 }
        func decodePeak(_ t: Int) -> Double { t >= 512 ? 11.3 : t >= 256 ? 4.5 : 2.5 }
        func peak(_ q: Int, _ t: Int) -> Double { max(weights(q) + megapixels * 1.2 + 0.5, decodePeak(t)) }

        let chosenTile = tile > 0 ? tile : (decodePeak(512) <= budget * 0.92 ? 512 : 256)
        var chosenQuant = quant
        if chosenQuant == 0 {
            chosenQuant = [16, 8, 4].first { peak($0, chosenTile) <= budget * 0.92 } ?? 4
        }
        let need = peak(chosenQuant, chosenTile)
        let fit: FitLevel = need <= budget * 0.92 ? (chosenQuant == 16 && chosenTile >= 512 ? .comfortable : .lowMemoryMode)
            : need <= budget * 1.25 ? .tight : .tooLarge
        var notes: [String] = []
        if quant == 0 && chosenQuant != 16 { notes.append("Using \(chosenQuant)-bit weights to save memory.") }
        if tile == 0 && chosenTile < 512 { notes.append("Decoding in \(chosenTile) px tiles to save memory.") }
        if fit == .tight { notes.append("Expect some swapping. Close other apps before you start.") }
        if fit == .tooLarge { notes.append("Needs about \(Format.gb(need)) but only \(Format.gb(budget)) may be used. Lower the scale, or raise the memory limit under This Mac.") }
        let plan = MemoryPlan(fit: fit, peakGB: need, budgetGB: budget, lowMemory: true, cacheLimitGB: nil,
                              vaeTiling: true, temporalTiles: 1, notes: notes)
        return UpscalePlan(plan: plan, quant: chosenQuant, tile: chosenTile)
    }

    /// Whether a chat model of this size fits: all its weights stay loaded, plus room for the conversation.
    static func chatFit(weightBytes: Int64, memoryLimitGB: Double = 0, system: SystemInfo = .current) -> FitLevel {
        chatFit(residentGB: Double(weightBytes) / 1_073_741_824 + 1.2, memoryLimitGB: memoryLimitGB, system: system)
    }

    static func chatFit(residentGB: Double, memoryLimitGB: Double = 0, system: SystemInfo = .current) -> FitLevel {
        let budget = budgetGB(override: memoryLimitGB, system: system)
        if residentGB <= budget * 0.85 { return .comfortable }
        if residentGB <= budget * 1.1 { return .tight }
        return .tooLarge
    }

    /// Fit of a catalog variant at its default size, for the model cards.
    static func fit(variant: ModelVariant, profile: ModelProfile, system: SystemInfo = .current, memoryLimitGB: Double = 0) -> FitLevel {
        plan(footprint: variant.footprint, profile: profile, width: profile.defaultWidth, height: profile.defaultHeight,
             frames: profile.kind == .video ? min(profile.defaultFrames, 49) : 1, auto: true, memoryLimitGB: memoryLimitGB, system: system).fit
    }

    /// The highest-quality variant that fits comfortably; otherwise the best that fits at all; otherwise the smallest.
    static func bestVariant(for model: CatalogModel, system: SystemInfo = .current, memoryLimitGB: Double = 0) -> ModelVariant {
        let profile = model.profile
        let scored = model.variants.map { ($0, fit(variant: $0, profile: profile, system: system, memoryLimitGB: memoryLimitGB)) }
        if let v = scored.last(where: { $0.1 == .comfortable }) { return v.0 }
        if let v = scored.first(where: { $0.1 == .lowMemoryMode }) { return v.0 }
        return model.variants[0]
    }

    /// Clamps a requested size to the limits and to the model's size multiple, keeping the aspect ratio.
    static func clampSize(width: Int, height: Int, kind: MediaKind, multiple: Int, limits: GenerationLimits) -> (Int, Int) {
        let maxPixels = kind == .image ? limits.maxImagePixels : limits.maxVideoPixels
        var w = Double(width), h = Double(height)
        let pixels = w * h
        if pixels > Double(maxPixels) {
            let scale = (Double(maxPixels) / pixels).squareRoot()
            w *= scale; h *= scale
        }
        func snap(_ v: Double) -> Int { max(multiple * 4, Int(v) / multiple * multiple) }
        return (snap(w), snap(h))
    }

    static func clampFrames(_ frames: Int, step: Int, limits: GenerationLimits) -> Int {
        let capped = min(max(frames, step + 1), limits.maxFrames)
        return (capped - 1) / step * step + 1
    }
}
