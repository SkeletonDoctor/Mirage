import Foundation

/// Headless checks, run as `Mirage --selftest <command> …`. Used to verify the core without the window.
enum SelfTest {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)      // show progress as it happens, even when output is redirected
        let args = Array(CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst())
        Task { @MainActor in
            let code = await dispatch(args)
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    private static func dispatch(_ args: [String]) async -> Int32 {
        switch args.first {
        case "system": return system()
        case "search": return await search(args.dropFirst().joined(separator: " "))
        case "download": return await download(args.count > 1 ? args[1] : "")
        case "generate": return await generate(Array(args.dropFirst()))
        case "engines": return await engines(Array(args.dropFirst()))
        case "chat":
            guard args.count > 2 else { print("chat <repo> <message>"); return 2 }
            await EngineManager.shared.refresh()
            await ModelStore.shared.refresh()
            guard let model = ModelStore.shared.model(args[1]) else { print("chat model not installed: \(args[1])"); return 1 }
            print("model: \(model.title) · chat \(model.profile.isChat) · needs \(Format.gb(model.footprint.residentGB))")
            let started = Date()
            guard await ChatEngine.shared.load(model) else { print("load failed: \(ChatEngine.shared.state)\n\(ChatEngine.shared.log.suffix(1500))"); return 1 }
            print("loaded in \(Format.duration(Date().timeIntervalSince(started)))")
            var reply = "", thinking = ""
            let t0 = Date()
            do {
                for try await piece in ChatEngine.shared.reply(to: [ChatMessage(role: "user", text: args[2])], system: "",
                                                                 temperature: 0.7, maxTokens: 200) {
                    reply += piece.text; thinking += piece.thinking
                }
            } catch { print("stream error: \(error.localizedDescription)") }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            print("reply (\(Format.duration(Date().timeIntervalSince(t0)))): \(reply.prefix(600))")
            if !thinking.isEmpty { print("thinking field: \(thinking.prefix(200))") }
            print("memory while loaded: \(Format.gb(ChatEngine.shared.memoryGB))")
            ChatEngine.shared.unload(reason: nil)
            return reply.isEmpty ? 1 : 0
        case "relocate":
            await ModelStore.shared.refresh()
            let target = args.count > 1 && args[1] != "default" ? URL(fileURLWithPath: args[1], isDirectory: true) : Paths.defaultHFHub
            let problem = await ModelStore.shared.relocate(to: target, moveExisting: true)
            print("models folder: \(Paths.hfHub.path) · problem: \(problem ?? "none")")
            for m in ModelStore.shared.models { print("installed: \(m.repo) at \(m.snapshot.path)") }
            return problem == nil ? 0 : 1
        default:
            print("usage: --selftest system | search <text> | download <repo> | engines [install <id>] | generate <repo> <prompt> [width height [frames]]")
            return 2
        }
    }

    @MainActor
    private static func system() -> Int32 {
        let s = SystemInfo.current
        print("\(s.chip) · \(Format.gb(s.totalGB)) · \(s.performanceCores)P+\(s.efficiencyCores)E · GPU \(s.gpuName) (working set \(Format.gb(s.gpuWorkingSetGB))) · macOS \(s.osVersion)")
        print("Budget \(Format.gb(MemoryPlanner.budgetGB())) · available now \(Format.gb(Double(MemoryProbe.availableBytes()) / 1_073_741_824))")
        let l = MemoryPlanner.limits()
        print("Limits: image \(l.maxImagePixels) px, video \(l.maxVideoPixels) px, \(l.maxFrames) frames")
        for gb in [8.0, 16, 24, 36, 64, 128] {
            let fake = SystemInfo(chip: "Test", totalMemory: UInt64(gb * 1_073_741_824), performanceCores: 8, efficiencyCores: 4,
                                  gpuName: "Test", gpuWorkingSet: UInt64(gb * 0.75 * 1_073_741_824), osVersion: "27", isAppleSilicon: true)
            let picks = Catalog.models.map { m -> String in
                let v = MemoryPlanner.bestVariant(for: m, system: fake)
                return "\(m.id)=\(v.quant)/\(MemoryPlanner.fit(variant: v, profile: m.profile, system: fake).label)"
            }
            print("\(Int(gb)) GB → " + picks.joined(separator: ", "))
        }
        return 0
    }

    private static func search(_ query: String) async -> Int32 {
        do {
            let results = try await HFClient.searchMLX(query: query, sort: .downloads)
            for m in results.prefix(25) {
                let p = m.profile
                print("\(m.id) | \(p.isRunnable ? "\(p.label) via \(p.engine!.rawValue)" : "unsupported") | dl \(m.downloads ?? 0) | gated \(m.gated)")
            }
            print("\(results.count) results, \(results.filter { $0.profile.isRunnable }.count) runnable")
            return 0
        } catch {
            print("search failed: \(error.localizedDescription)"); return 1
        }
    }

    @MainActor
    private static func download(_ repo: String) async -> Int32 {
        let entry = Catalog.entry(forRepo: repo)
        let task = DownloadManager.shared.start(repo: repo, title: entry?.model.name ?? repo, companions: entry?.model.companions ?? [])
        var last = Date.distantPast
        while task.state.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Date().timeIntervalSince(last) > 5 {
                last = Date()
                print(String(format: "%@ %.1f%% of %@ at %@/s  %@", "\(task.state)", task.fraction * 100,
                             Format.bytes(task.totalBytes), Format.bytes(Int64(task.speed)), task.currentFile))
            }
        }
        print("final: \(task.state)")
        await ModelStore.shared.refresh()
        for m in ModelStore.shared.models {
            print("installed: \(m.repo) | \(m.profile.label) | \(Format.bytes(m.sizeBytes)) | resident \(Format.gb(m.footprint.residentGB)) low \(Format.gb(m.footprint.lowMemoryGB))")
        }
        return task.state == .completed ? 0 : 1
    }

    @MainActor
    private static func engines(_ args: [String]) async -> Int32 {
        await EngineManager.shared.refresh()
        if args.first == "install", args.count > 1, let id = EngineID(rawValue: args[1]) {
            let ok = await EngineManager.shared.ensureInstalled(id)
            print(EngineManager.shared.logs[id] ?? "")
            print("install \(id.rawValue): \(ok)")
        }
        for spec in EngineSpec.all { print("\(spec.id.rawValue): \(EngineManager.shared.state(spec.id))") }
        print("mlx \(EngineManager.shared.mlxVersion) · mflux commands known: \(EngineManager.shared.mfluxOptions.count)")
        return 0
    }

    @MainActor
    private static func generate(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else { print("generate <repo> <prompt> [width height [frames]]"); return 2 }
        await EngineManager.shared.refresh()
        await ModelStore.shared.refresh()
        MemoryMonitor.shared.start()
        guard let model = ModelStore.shared.model(args[0]) else { print("model not installed: \(args[0])"); return 1 }
        let profile = model.profile
        var p = GenerationParams()
        p.repo = model.repo; p.modelTitle = model.title; p.kind = profile.kind; p.prompt = args[1]
        p.width = args.count > 3 ? Int(args[2]) ?? profile.defaultWidth : profile.defaultWidth
        p.height = args.count > 3 ? Int(args[3]) ?? profile.defaultHeight : profile.defaultHeight
        p.frames = args.count > 4 ? Int(args[4]) ?? profile.defaultFrames : profile.defaultFrames
        p.fps = profile.fps
        p.steps = profile.defaultSteps
        p.guidance = profile.defaultGuidance
        if let i = args.firstIndex(of: "--image"), i + 1 < args.count { p.inputImage = args[i + 1] }
        if let i = args.firstIndex(of: "--upscale"), i + 2 < args.count {
            p.upscaleSource = args[i + 1]
            p.upscaleFactor = Double(args[i + 2]) ?? 2
        }
        let plan = MemoryPlanner.plan(footprint: model.footprint, profile: profile, width: p.width, height: p.height,
                                      frames: p.kind == .video ? p.frames : 1, auto: true)
        p.lowMemory = plan.lowMemory; p.cacheLimitGB = plan.cacheLimitGB; p.vaeTiling = plan.vaeTiling; p.temporalTiles = plan.temporalTiles
        print("plan: \(plan.fit.label) · peak \(Format.gb(plan.peakGB)) of \(Format.gb(plan.budgetGB)) · lowMemory \(plan.lowMemory) · \(plan.notes)")
        let job = JobQueue.shared.enqueue(p, model: model)
        var lastStatus = ""
        while job.state.isActive {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if job.status != lastStatus {
                lastStatus = job.status
                print(String(format: "[%@] %@ %@ mem %.1f GB", Format.duration(job.elapsed), job.status,
                             job.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "", job.peakMemoryGB))
            }
        }
        print("---- log ----\n\(job.log.suffix(3000))")
        print("state: \(job.state) · output: \(job.output?.path ?? "none") · peak \(Format.gb(job.peakMemoryGB)) · \(Format.duration(job.elapsed))")
        return job.state == .finished ? 0 : 1
    }
}
