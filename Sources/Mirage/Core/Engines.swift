import Foundation

struct EngineSpec {
    let id: EngineID
    let title: String
    let summary: String
    /// Arguments handed to `uv pip install`.
    let packages: [String]
    /// The distribution whose version is shown in the UI.
    let versionPackage: String
    /// A file in the environment's bin folder that proves the install worked.
    let probeBinary: String

    static let all: [EngineSpec] = [
        EngineSpec(id: .mflux, title: "mflux", summary: "Image models: FLUX, Z-Image, Qwen Image, Krea and more.",
                   packages: ["mflux"], versionPackage: "mflux", probeBinary: "mflux-generate"),
        EngineSpec(id: .ltx, title: "ltx-2-mlx", summary: "LTX-2.3 and LTX-2.5 video with sound, with block streaming for small Macs.",
                   packages: [
                    "ltx-core-mlx @ git+https://github.com/dgrauet/ltx-2-mlx.git#subdirectory=packages/ltx-core-mlx",
                    "ltx-pipelines-mlx @ git+https://github.com/dgrauet/ltx-2-mlx.git#subdirectory=packages/ltx-pipelines-mlx",
                    "imageio-ffmpeg",
                   ], versionPackage: "ltx-pipelines-mlx", probeBinary: "ltx-2-mlx"),
        EngineSpec(id: .mlxVideo, title: "mlx-video", summary: "Wan 2.1 / 2.2 video, and LTX in mlx-video format.",
                   packages: ["git+https://github.com/Blaizzy/mlx-video.git", "imageio-ffmpeg"],
                   versionPackage: "mlx-video", probeBinary: "mlx_video.wan_2.generate"),
    ]

    static func spec(_ id: EngineID) -> EngineSpec { all.first { $0.id == id }! }
}

enum EngineState: Equatable {
    case notInstalled
    case installing(String)        // current step
    case installed(version: String)
    case failed(String)

    var isInstalled: Bool { if case .installed = self { return true }; return false }
    var isBusy: Bool { if case .installing = self { return true }; return false }
}

/// Installs and tracks the Python engines. Each engine gets its own private environment
/// under Application Support, so nothing touches the system Python.
@Observable @MainActor
final class EngineManager {
    static let shared = EngineManager()

    private(set) var states: [EngineID: EngineState] = [:]
    private(set) var logs: [EngineID: String] = [:]
    /// mflux reports which options each of its commands honours; used to build valid command lines.
    private(set) var mfluxOptions: [String: Set<String>] = [:]
    private(set) var mlxVersion: String = ""

    private var installTasks: [EngineID: Task<Bool, Never>] = [:]

    func venv(_ id: EngineID) -> URL { Paths.enginesDir.appendingPathComponent(id.rawValue).appendingPathComponent("venv") }
    func bin(_ id: EngineID) -> URL { venv(id).appendingPathComponent("bin") }
    func python(_ id: EngineID) -> URL { bin(id).appendingPathComponent("python") }
    func state(_ id: EngineID) -> EngineState { states[id] ?? .notInstalled }

    func refresh() async {
        for spec in EngineSpec.all {
            if state(spec.id).isBusy { continue }
            let probe = bin(spec.id).appendingPathComponent(spec.probeBinary)
            if FileManager.default.isExecutableFile(atPath: probe.path) {
                let v = await version(of: spec.versionPackage, engine: spec.id)
                states[spec.id] = .installed(version: v ?? "installed")
            } else {
                states[spec.id] = .notInstalled
            }
        }
        if state(.mflux).isInstalled { await loadMfluxOptions() }
        if mlxVersion.isEmpty, let any = EngineID.allCases.first(where: { state($0).isInstalled }) {
            mlxVersion = await version(of: "mlx", engine: any) ?? ""
        }
    }

    private func version(of package: String, engine: EngineID) async -> String? {
        let code = "import importlib.metadata as m; print(m.version('\(package)'))"
        let r = await runCapture(python(engine), ["-c", code])
        guard r.status == 0 else { return nil }
        return r.output.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    /// Installs an engine if needed. Safe to call repeatedly; concurrent callers share one install.
    @discardableResult
    func ensureInstalled(_ id: EngineID) async -> Bool {
        if state(id).isInstalled { return true }
        if let running = installTasks[id] { return await running.value }
        let task = Task { await self.install(id, upgrade: false) }
        installTasks[id] = task
        let ok = await task.value
        installTasks[id] = nil
        return ok
    }

    func update(_ id: EngineID) async {
        guard !state(id).isBusy else { return }
        _ = await install(id, upgrade: true)
    }

    func uninstall(_ id: EngineID) {
        guard !state(id).isBusy else { return }
        try? FileManager.default.removeItem(at: Paths.enginesDir.appendingPathComponent(id.rawValue))
        states[id] = .notInstalled
        logs[id] = nil
    }

    private func appendLog(_ id: EngineID, _ text: String) {
        var log = (logs[id] ?? "") + text
        if log.count > 40_000 { log = String(log.suffix(30_000)) }
        logs[id] = log
    }

    private func install(_ id: EngineID, upgrade: Bool) async -> Bool {
        let spec = EngineSpec.spec(id)
        logs[id] = ""
        states[id] = .installing("Preparing")
        do {
            let uv = try await locateUV(log: { [weak self] s in self?.appendLog(id, s) })
            let dir = Paths.enginesDir.appendingPathComponent(id.rawValue)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let env = ProcessRunner.baseEnvironment()

            if !FileManager.default.fileExists(atPath: python(id).path) {
                states[id] = .installing("Setting up Python 3.12")
                let status = await ProcessRunner().run(uv, ["venv", "--python", "3.12", venv(id).path], environment: env) { text in
                    Task { @MainActor in self.appendLog(id, text) }
                }
                guard status == 0 else { throw EngineError.message("Could not create the Python environment.") }
            }

            states[id] = .installing(upgrade ? "Updating packages" : "Downloading packages")
            var args = ["pip", "install", "--python", python(id).path]
            if upgrade { args.append("--upgrade") }
            args += spec.packages
            let status = await ProcessRunner().run(uv, args, environment: env) { text in
                Task { @MainActor in self.appendLog(id, text) }
            }
            guard status == 0 else { throw EngineError.message("Package install failed. See the log for details.") }

            linkFFmpegIfNeeded(id)
            let v = await version(of: spec.versionPackage, engine: id)
            states[id] = .installed(version: v ?? "installed")
            if id == .mflux { await loadMfluxOptions(force: true) }
            if mlxVersion.isEmpty { mlxVersion = await version(of: "mlx", engine: id) ?? "" }
            return true
        } catch {
            let message = (error as? EngineError)?.text ?? error.localizedDescription
            appendLog(id, "\n\(message)\n")
            states[id] = .failed(message)
            return false
        }
    }

    /// Video engines shell out to ffmpeg. If the Mac has none, expose the copy bundled with imageio-ffmpeg.
    private func linkFFmpegIfNeeded(_ id: EngineID) {
        let fm = FileManager.default
        let system = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", Paths.binDir.appendingPathComponent("ffmpeg").path]
        if system.contains(where: { fm.isExecutableFile(atPath: $0) }) { return }
        let link = bin(id).appendingPathComponent("ffmpeg")
        if fm.fileExists(atPath: link.path) { return }
        let lib = venv(id).appendingPathComponent("lib")
        guard let e = fm.enumerator(at: lib, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.lastPathComponent.hasPrefix("ffmpeg-") && url.path.contains("imageio_ffmpeg/binaries") {
            try? fm.createSymbolicLink(at: link, withDestinationURL: url)
            return
        }
    }

    private func loadMfluxOptions(force: Bool = false) async {
        let cache = Paths.enginesDir.appendingPathComponent("mflux/capabilities.json")
        if force || !FileManager.default.fileExists(atPath: cache.path) {
            let tool = bin(.mflux).appendingPathComponent("mflux-capabilities")
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { return }
            let r = await runCapture(tool, ["--format", "json"])
            if r.status == 0, let start = r.output.firstIndex(of: "{") {
                try? String(r.output[start...]).write(to: cache, atomically: true, encoding: .utf8)
            }
        }
        guard let data = try? Data(contentsOf: cache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = root["commands"] as? [[String: Any]] else { return }
        var map: [String: Set<String>] = [:]
        for c in commands {
            guard let name = c["command"] as? String, let options = c["options"] as? [[String: Any]] else { continue }
            var usable = Set<String>()
            for o in options {
                guard let flag = o["flag"] as? String else { continue }
                let status = (o["status"] as? String) ?? "honored"
                if status == "honored" || status == "conditional" { usable.insert(flag) }
            }
            map[name] = usable
        }
        mfluxOptions = map
    }

    /// Finds `uv`, or downloads Astral's standalone build into the app's own folder.
    private func locateUV(log: @escaping @MainActor (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [Paths.binDir.appendingPathComponent("uv").path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: found) }

        log("Downloading the uv package manager…\n")
        let arch = SystemInfo.current.isAppleSilicon ? "aarch64" : "x86_64"
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-\(arch)-apple-darwin.tar.gz")!
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EngineError.message("Could not download uv.") }
        try fm.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
        let r = await runCapture(URL(fileURLWithPath: "/usr/bin/tar"),
                                 ["-xzf", tmp.path, "-C", Paths.binDir.path, "--strip-components", "1"])
        try? fm.removeItem(at: tmp)
        let uv = Paths.binDir.appendingPathComponent("uv")
        guard r.status == 0, fm.isExecutableFile(atPath: uv.path) else { throw EngineError.message("Could not unpack uv.") }
        return uv
    }
}

enum EngineError: Error {
    case message(String)
    var text: String { if case .message(let m) = self { return m }; return "" }
}
