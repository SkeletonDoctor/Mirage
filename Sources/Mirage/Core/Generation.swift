import Foundation
import AppKit

/// Everything the user chose for one generation.
struct GenerationParams: Codable, Equatable {
    var repo: String = ""
    var modelTitle: String = ""
    var kind: MediaKind = .image
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var frames: Int = 97
    var fps: Int = 24
    /// nil means "use the model's own default".
    var steps: Int? = nil
    var guidance: Double? = nil
    var seed: Int = 0
    var randomSeed = true
    var inputImage: String? = nil
    var imageStrength: Double = 0.5
    var endImage: String? = nil
    var inputAudio: String? = nil
    var withAudio = true
    var lowMemory = false
    var cacheLimitGB: Double? = nil
    var vaeTiling = false
    var temporalTiles = 1
    /// Set for an upscale job: the image to enlarge and by how much. Optional so older gallery files still load.
    var upscaleSource: String? = nil
    var upscaleFactor: Double? = nil
    var upscaleSoftness: Double? = nil
    var upscaleQuant: Int? = nil
    var upscaleTile: Int? = nil

    var seconds: Double { Double(frames) / Double(max(fps, 1)) }
}

struct BuiltCommand {
    let executable: URL
    let arguments: [String]
    let output: URL
}

enum CommandBuilder {
    enum BuildError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Turns the parameters into the exact command line for the model's engine.
    @MainActor
    static func build(_ p: GenerationParams, model: InstalledModel, output: URL) throws -> BuiltCommand {
        let profile = model.profile
        guard let engine = profile.engine else { throw BuildError.message("No installed engine can run \(model.repo).") }
        let bin = EngineManager.shared.bin(engine)
        if profile.imageInput == .required && p.inputImage == nil && p.upscaleSource == nil {
            throw BuildError.message("\(model.title) needs an input image.")
        }

        if let source = p.upscaleSource {
            let command = "mflux-upscale-seedvr2"
            var args = ["--model", model.repo == Upscaler.repo ? (profile.baseModel ?? "seedvr2-3b") : model.repo]
            if model.repo != Upscaler.repo, let base = profile.baseModel { args += ["--base-model", base] }
            let factor = p.upscaleFactor ?? 2
            args += ["--image-path", source, "--resolution", factor == factor.rounded() ? "\(Int(factor))x" : String(format: "%.1fx", factor)]
            args += ["--seed", "\(p.seed)", "--low-ram"]      // low-ram frees the model before the memory-heavy decode
            if let q = p.upscaleQuant, q == 4 || q == 8 { args += ["--quantize", "\(q)"] }
            if let tile = p.upscaleTile, tile > 0 { args += ["--vae-tile-size", "\(tile)"] }
            if let softness = p.upscaleSoftness, softness > 0.001 { args += ["--softness", String(format: "%.2f", softness)] }
            args += ["--output", output.path]
            return BuiltCommand(executable: bin.appendingPathComponent(command), arguments: args, output: output)
        }

        switch profile.family {
        case .mflux:
            let editing = p.inputImage != nil && profile.editCommand != nil
            let command = editing ? profile.editCommand! : profile.command
            let allowed = EngineManager.shared.mfluxOptions[command]
            var args: [String] = []
            func add(_ flag: String, _ values: String...) {
                if let allowed, !allowed.contains(flag) { return }
                args.append(flag); args.append(contentsOf: values)
            }
            add("--model", model.repo)
            if let base = profile.baseModel { add("--base-model", base) }
            add("--prompt", p.prompt)
            if profile.supportsNegative, !p.negativePrompt.isEmpty { add("--negative-prompt", p.negativePrompt) }
            add("--width", "\(p.width)")
            add("--height", "\(p.height)")
            if let steps = p.steps { add("--steps", "\(steps)") }
            if profile.supportsGuidance, let g = p.guidance { add("--guidance", String(format: "%.2f", g)) }
            add("--seed", "\(p.seed)")
            if let image = p.inputImage {
                if editing { add("--image-paths", image) }
                else { add("--image-path", image); add("--image-strength", String(format: "%.2f", p.imageStrength)) }
            }
            if p.lowMemory { add("--low-ram") }
            else if let cache = p.cacheLimitGB { add("--mlx-cache-limit-gb", String(format: "%.0f", cache)) }
            if p.vaeTiling && !p.lowMemory { add("--vae-tiling") }
            add("--output", output.path)
            return BuiltCommand(executable: bin.appendingPathComponent(command), arguments: args, output: output)

        case .ltx:
            let audioDriven = p.inputAudio != nil
            var args: [String] = [audioDriven ? "a2v" : "generate"]
            args += ["--prompt", p.prompt, "--output", output.path, "--model", model.snapshot.path]
            args += ["--seed", "\(p.seed)", "--height", "\(p.height)", "--width", "\(p.width)"]
            args += ["--frames", "\(p.frames)", "--frame-rate", "\(p.fps)", "--distilled"]
            if p.lowMemory { args.append("--low-ram") }
            if let audio = p.inputAudio { args += ["--audio", audio] }
            if let image = p.inputImage { args += ["--image", image] }
            if !audioDriven {
                if p.temporalTiles > 1 { args += ["--tile-frames", "\(p.temporalTiles)"] }
                if !p.withAudio { args.append("--no-audio") }
            }
            return BuiltCommand(executable: bin.appendingPathComponent("ltx-2-mlx"), arguments: args, output: output)

        case .ltxMlxVideo:
            var args = ["--prompt", p.prompt, "--model-repo", model.repo, "--pipeline", "distilled",
                        "--width", "\(p.width)", "--height", "\(p.height)", "--num-frames", "\(p.frames)",
                        "--seed", "\(p.seed)", "--fps", "\(p.fps)", "--output-path", output.path,
                        "--tiling", p.lowMemory ? "aggressive" : "auto"]
            if let image = p.inputImage { args += ["--image", image] }
            if let audio = p.inputAudio { args += ["--audio-file", audio] } else if p.withAudio { args.append("--audio") }
            return BuiltCommand(executable: bin.appendingPathComponent("mlx_video.ltx_2.generate"), arguments: args, output: output)

        case .wan:
            var args = ["--model-dir", model.snapshot.path, "--prompt", p.prompt,
                        "--width", "\(p.width)", "--height", "\(p.height)", "--num-frames", "\(p.frames)",
                        "--seed", "\(p.seed)", "--output-path", output.path,
                        "--tiling", p.lowMemory ? "aggressive" : "auto"]
            if let steps = p.steps { args += ["--steps", "\(steps)"] }
            if let g = p.guidance { args += ["--guide-scale", String(format: "%.1f", g)] }
            if !p.negativePrompt.isEmpty { args += ["--negative-prompt", p.negativePrompt] }
            if let image = p.inputImage { args += ["--image", image] }
            return BuiltCommand(executable: bin.appendingPathComponent("mlx_video.wan_2.generate"), arguments: args, output: output)

        case .chat:
            throw BuildError.message("\(model.title) is a chat model. Use it from the Chat tab.")

        case .unsupported:
            throw BuildError.message("No installed engine can run \(model.repo).")
        }
    }
}

/// Pulls progress out of the engines' terminal output (tqdm bars and "step x/y" lines).
struct ProgressParser {
    struct Update {
        var fraction: Double?
        var status: String?
        var eta: String?
        var lines: [String] = []
    }

    private var buffer = ""
    private static let bar = try! NSRegularExpression(pattern: #"^(.*?)(\d{1,3})%\|.*?\|\s*(\d+)/(\d+)\s*\[([^<\]]*)<([^,\]]*)"#)
    private static let step = try! NSRegularExpression(pattern: #"(?i)\bstep\s+(\d+)\s*(?:/|of)\s*(\d+)"#)

    mutating func feed(_ chunk: String) -> Update {
        buffer += chunk
        var update = Update()
        var parts = buffer.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }.map(String.init)
        buffer = parts.popLast() ?? ""
        for raw in parts {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let m = Self.bar.firstMatch(in: line, range: range) {
                func group(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
                let current = Double(group(3)) ?? 0, total = Double(group(4)) ?? 0
                if total > 0 { update.fraction = min(1, current / total) }
                let label = group(1).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
                update.status = label.isEmpty ? "Step \(Int(current)) of \(Int(total))" : "\(label) · \(Int(current))/\(Int(total))"
                let eta = group(6).trimmingCharacters(in: .whitespaces)
                if !eta.isEmpty && eta != "?" { update.eta = eta }
                continue    // progress bars are not kept in the log
            }
            if let m = Self.step.firstMatch(in: line, range: range),
               let a = Range(m.range(at: 1), in: line), let b = Range(m.range(at: 2), in: line),
               let current = Double(line[a]), let total = Double(line[b]), total > 0 {
                update.fraction = min(1, current / total)
                update.status = "Step \(Int(current)) of \(Int(total))"
            }
            update.lines.append(line)
        }
        return update
    }
}

enum JobState: Equatable {
    case queued, running, finished, cancelled
    case failed(String)
    var isActive: Bool { self == .queued || self == .running }
}

@Observable @MainActor
final class GenerationJob: Identifiable {
    let id = UUID()
    let params: GenerationParams
    let model: InstalledModel
    var state: JobState = .queued
    var fraction: Double?
    var status = "Waiting"
    var eta: String?
    var log = ""
    var startedAt: Date?
    var finishedAt: Date?
    var peakMemoryGB: Double = 0
    var output: URL?
    var commandLine = ""
    fileprivate var runner: ProcessRunner?

    init(params: GenerationParams, model: InstalledModel) {
        self.params = params; self.model = model
    }

    var elapsed: Double { (finishedAt ?? Date()).timeIntervalSince(startedAt ?? Date()) }

    func appendLog(_ text: String) {
        log += text
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
    }
}

/// Runs generations one at a time. Two models in memory at once would defeat the memory planning.
@Observable @MainActor
final class JobQueue {
    static let shared = JobQueue()
    private(set) var jobs: [GenerationJob] = []
    private(set) var current: GenerationJob?
    private var pump: Task<Void, Never>?

    var pending: [GenerationJob] { jobs.filter { $0.state == .queued } }

    init() {
        MemoryMonitor.shared.onCritical = { [weak self] in
            guard AppSettings.shared.stopOnCritical, let job = self?.current, job.state == .running else { return }
            job.appendLog("\nStopped: macOS reported critical memory pressure.\n")
            self?.stop(job, reason: "Stopped to protect your Mac: memory ran out. Try a smaller size, fewer frames or a smaller model variant.")
        }
    }

    @discardableResult
    func enqueue(_ params: GenerationParams, model: InstalledModel) -> GenerationJob {
        var p = params
        if p.randomSeed { p.seed = Int.random(in: 1..<2_147_483_647) }
        let job = GenerationJob(params: p, model: model)
        jobs.insert(job, at: 0)
        if jobs.count > 60 { jobs.removeLast(jobs.count - 60) }
        startPump()
        return job
    }

    func cancel(_ job: GenerationJob) {
        if job.state == .queued { job.state = .cancelled; return }
        guard job.state == .running else { return }
        job.state = .cancelled
        job.status = "Cancelled"
        job.runner?.terminate()
    }

    /// Stops everything; called when the app quits so no engine process is left running.
    func cancelAll() {
        for job in jobs where job.state.isActive { cancel(job) }
    }

    private func stop(_ job: GenerationJob, reason: String) {
        guard job.state == .running else { return }
        job.state = .failed(reason)
        job.status = "Stopped"
        job.runner?.terminate()
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, let next = self.jobs.last(where: { $0.state == .queued }) {
                await self.run(next)
            }
            self?.pump = nil
        }
    }

    private func run(_ job: GenerationJob) async {
        current = job
        // A loaded chat model would compete for the same memory, so it steps aside first.
        ChatEngine.shared.unload(reason: "Unloaded to make room for a generation.")
        // Hand back the app's own image caches before a model needs the memory.
        ThumbnailCache.shared.purge()
        ImageLoader.shared.purge()
        // Keep the Mac from idle-sleeping in the middle of a long generation.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Generating with Mirage")
        defer {
            current = nil
            MemoryMonitor.shared.watchedPID = nil
            ProcessInfo.processInfo.endActivity(activity)
            // Bounce the Dock icon if the user has switched to another app.
            if !job.state.isActive, job.state != .cancelled, NSApp?.isActive == false {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        job.state = .running
        job.startedAt = Date()
        job.status = "Preparing"

        guard let engine = job.model.profile.engine else {
            job.state = .failed("No engine can run this model."); return
        }
        if !EngineManager.shared.state(engine).isInstalled {
            job.status = "Installing the \(EngineSpec.spec(engine).title) engine"
            guard await EngineManager.shared.ensureInstalled(engine) else {
                job.state = .failed("The \(EngineSpec.spec(engine).title) engine could not be installed. Open Engines to see why.")
                return
            }
        }
        if job.state != .running { return }

        let ext = job.params.kind == .image ? "png" : "mp4"
        let stamp = Self.stampFormatter.string(from: Date())
        let slug = job.params.prompt.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { if !($1 == "-" && $0.hasSuffix("-")) { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let prefix = job.params.upscaleSource != nil ? "upscaled-" : ""
        let output = AppSettings.shared.outputDir(for: job.params.kind).appendingPathComponent("\(stamp)-\(prefix)\(slug.isEmpty ? "untitled" : String(slug)).\(ext)")

        let command: BuiltCommand
        do { command = try CommandBuilder.build(job.params, model: job.model, output: output) }
        catch { job.state = .failed(error.localizedDescription); return }

        job.commandLine = ([command.executable.lastPathComponent] + command.arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        job.appendLog("$ \(job.commandLine)\n\n")
        job.status = "Loading model"

        let runner = ProcessRunner()
        job.runner = runner
        let env = ProcessRunner.baseEnvironment(extraPath: [EngineManager.shared.bin(engine).path])
        let parser = ParserBox()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if runner.isRunning {
                    if MemoryMonitor.shared.watchedPID != runner.pid { MemoryMonitor.shared.watchedPID = runner.pid }
                    let gb = Double(MemoryProbe.footprint(pid: runner.pid)) / 1_073_741_824
                    if gb > job.peakMemoryGB + 0.05 { job.peakMemoryGB = gb }
                }
            }
        }
        let status = await runner.run(command.executable, command.arguments, environment: env, cwd: Paths.workDir) { text in
            let update = parser.feed(text)
            Task { @MainActor in
                // The engines report many times a second; only touch the interface when a value really changed.
                if let f = update.fraction, job.fraction.map({ abs($0 - f) >= 0.005 }) ?? true { job.fraction = f }
                if let s = update.status, s != job.status { job.status = s }
                if let e = update.eta, e != job.eta { job.eta = e }
                if !update.lines.isEmpty { job.appendLog(update.lines.joined(separator: "\n") + "\n") }
                // mflux reports its own peak at the end; trust it when it is higher than what was sampled.
                for line in update.lines where line.contains("Peak MLX memory") {
                    let digits = line.split(separator: ":").last?.split(separator: " ").first.flatMap { Double($0) }
                    if let digits { job.peakMemoryGB = max(job.peakMemoryGB, digits) }
                }
            }
        }
        watcher.cancel()
        // Let the last output callbacks land before reading the log.
        try? await Task.sleep(nanoseconds: 150_000_000)
        job.finishedAt = Date()
        job.runner = nil
        job.eta = nil

        if job.state != .running { return }      // cancelled or stopped for memory
        if status == 0, FileManager.default.fileExists(atPath: output.path) {
            job.output = output
            job.fraction = 1
            job.status = "Done in \(Format.duration(job.elapsed))"
            job.state = .finished
            var finalParams = job.params
            if finalParams.upscaleSource != nil,
               let source = CGImageSourceCreateWithURL(output as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                finalParams.width = w; finalParams.height = h       // record what the upscaler actually produced
            }
            Gallery.shared.add(GalleryItem(file: output.path, kind: job.params.kind, params: finalParams,
                                           date: Date(), seconds: job.elapsed, peakMemoryGB: job.peakMemoryGB))
        } else {
            job.state = .failed(Self.explain(log: job.log, status: status))
            job.status = "Failed"
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()

    /// Turns the tail of an engine log into a sentence a person can act on.
    static func explain(log: String, status: Int32) -> String {
        let lower = log.lowercased()
        if status == 9 || status == 137 || lower.contains("out of memory") || lower.contains("insufficient memory")
            || lower.contains("failed to allocate") || lower.contains("metal::malloc") {
            return "Ran out of memory. Try a smaller size, fewer frames, or a smaller variant of the model."
        }
        if lower.contains("401") && lower.contains("huggingface") || lower.contains("gatedrepoerror") || lower.contains("gated repo") {
            return "This model is gated. Accept its terms on Hugging Face and add your token in Settings."
        }
        if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("no such file")) {
            return "ffmpeg is missing. Reinstall the engine from the Engines page."
        }
        let lines = log.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let error = lines.last(where: { $0.contains("Error") || $0.contains("error:") || $0.contains("Exception") }) {
            return String(error.trimmingCharacters(in: .whitespaces).prefix(300))
        }
        return "The engine stopped with code \(status). Open the log for details."
    }
}

private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = ProgressParser()
    func feed(_ text: String) -> ProgressParser.Update { lock.lock(); defer { lock.unlock() }; return parser.feed(text) }
}

// MARK: - Gallery

struct GalleryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var kind: MediaKind
    var params: GenerationParams
    var date: Date
    var seconds: Double
    var peakMemoryGB: Double
    /// Optional so gallery files written by earlier versions still load.
    var favorite: Bool?

    var isFavorite: Bool { favorite ?? false }
    var url: URL { URL(fileURLWithPath: file) }
    var exists: Bool { FileManager.default.fileExists(atPath: file) }
}

@Observable @MainActor
final class Gallery {
    static let shared = Gallery()
    private(set) var items: [GalleryItem] = []
    private let storeURL = Paths.appSupport.appendingPathComponent("gallery.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: storeURL), let decoded = try? decoder.decode([GalleryItem].self, from: data) {
            items = decoded.filter(\.exists)
        }
    }

    func add(_ item: GalleryItem) {
        items.insert(item, at: 0)
        save()
    }

    func toggleFavorite(_ item: GalleryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].favorite = !items[i].isFavorite
        save()
    }

    /// Rough time for a new generation, scaled from the most similar past run of the same model.
    /// Returns nil until that model has been used at least once.
    func estimateSeconds(for p: GenerationParams) -> Double? {
        func work(_ q: GenerationParams) -> Double {
            Double(q.width * q.height) / 1_000_000 * Double(q.kind == .video ? max(q.frames, 1) : 1)
        }
        let target = work(p)
        let past = items.filter { $0.params.repo == p.repo && $0.kind == p.kind && $0.seconds > 0 }
        guard target > 0, let ref = past.min(by: { abs(log(work($0.params) / target)) < abs(log(work($1.params) / target)) }) else { return nil }
        let fixed = min(6.0, ref.seconds * 0.5)          // model loading, roughly constant
        var scale = target / max(work(ref.params), 0.0001)
        if let a = p.steps, let b = ref.params.steps, b > 0 { scale *= Double(a) / Double(b) }
        if p.lowMemory && !ref.params.lowMemory { scale *= 1.6 }
        return fixed + (ref.seconds - fixed) * scale
    }

    /// The most recent deletion, so it can be undone.
    private(set) var lastDeleted: (item: GalleryItem, trashed: URL?)?

    /// Moves the file to the Trash and forgets it. `undoDelete()` brings it back.
    func delete(_ item: GalleryItem) {
        var trashed: NSURL?
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
        items.removeAll { $0.id == item.id }
        lastDeleted = (item, trashed as URL?)
        save()
    }

    func undoDelete() {
        guard let last = lastDeleted else { return }
        lastDeleted = nil
        if let trashed = last.trashed { try? FileManager.default.moveItem(at: trashed, to: last.item.url) }
        guard last.item.exists else { return }
        items.append(last.item)
        items.sort { $0.date > $1.date }
        save()
    }

    func forgetLastDeleted() { lastDeleted = nil }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) { try? data.write(to: storeURL, options: .atomic) }
    }
}
