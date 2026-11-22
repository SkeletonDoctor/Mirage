import Foundation
import Security

enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var enginesDir: URL { appSupport.appendingPathComponent("engines", isDirectory: true) }
    static var binDir: URL { appSupport.appendingPathComponent("bin", isDirectory: true) }
    static var workDir: URL {
        let dir = appSupport.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The standard Hugging Face cache, shared with every other HF tool on this Mac.
    static var defaultHFHub: URL {
        let env = ProcessInfo.processInfo.environment
        if let cache = env["HF_HUB_CACHE"], !cache.isEmpty { return URL(fileURLWithPath: cache) }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("hub")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Where models are kept: the folder the user chose, or the standard Hugging Face cache.
    /// Read straight from defaults so background work can use it too.
    static var hfHub: URL {
        if let custom = UserDefaults.standard.string(forKey: "modelsPath"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultHFHub
    }

    static func repoDir(_ repo: String) -> URL {
        hfHub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// The snapshot folder the cache's `refs/main` points to, if this repo has been downloaded.
    static func snapshotDir(_ repo: String) -> URL? {
        let dir = repoDir(repo)
        let ref = dir.appendingPathComponent("refs/main")
        if let sha = try? String(contentsOf: ref, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
            let snap = dir.appendingPathComponent("snapshots/\(sha)", isDirectory: true)
            if FileManager.default.fileExists(atPath: snap.path) { return snap }
        }
        let snaps = dir.appendingPathComponent("snapshots")
        if let first = try? FileManager.default.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil).first {
            return first
        }
        return nil
    }

    static var defaultImageDir: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Mirage", isDirectory: true)
    }
    static var defaultVideoDir: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Mirage", isDirectory: true)
    }
}

@Observable @MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var autoMemory: Bool { didSet { d.set(autoMemory, forKey: "autoMemory") } }
    /// The most memory a model may use, in GB. 0 means "use the recommended amount".
    var memoryLimitGB: Double { didSet { d.set(memoryLimitGB, forKey: "memoryLimitGB") } }
    var stopOnCritical: Bool { didSet { d.set(stopOnCritical, forKey: "stopOnCritical") } }
    var unlockLimits: Bool { didSet { d.set(unlockLimits, forKey: "unlockLimits") } }
    var animatedBackdrop: Bool { didSet { d.set(animatedBackdrop, forKey: "animatedBackdrop") } }
    /// Folder for generated images, and a separate one for videos.
    var imagePath: String { didSet { d.set(imagePath, forKey: "imagePath") } }
    var videoPath: String { didSet { d.set(videoPath, forKey: "videoPath") } }
    /// Folder for downloaded models. Empty means the standard Hugging Face cache.
    var modelsPath: String { didSet { d.set(modelsPath, forKey: "modelsPath") } }
    var lastModelRepo: String { didSet { d.set(lastModelRepo, forKey: "lastModelRepo") } }
    var lastChatRepo: String { didSet { d.set(lastChatRepo, forKey: "lastChatRepo") } }
    var chatTemperature: Double { didSet { d.set(chatTemperature, forKey: "chatTemperature") } }
    var chatMaxTokens: Double { didSet { d.set(chatMaxTokens, forKey: "chatMaxTokens") } }
    var chatSystemPrompt: String { didSet { d.set(chatSystemPrompt, forKey: "chatSystemPrompt") } }
    // Upscaler choices. 0 means "choose for me" for precision and tile size.
    var upscaleScale: Double { didSet { d.set(upscaleScale, forKey: "upscaleScale") } }
    var upscaleSoftness: Double { didSet { d.set(upscaleSoftness, forKey: "upscaleSoftness") } }
    var upscaleQuant: Int { didSet { d.set(upscaleQuant, forKey: "upscaleQuant") } }
    var upscaleTile: Int { didSet { d.set(upscaleTile, forKey: "upscaleTile") } }
    /// Prompts used recently, newest first.
    var recentPrompts: [String] { didSet { d.set(recentPrompts, forKey: "recentPrompts") } }

    func remember(prompt: String) {
        var list = recentPrompts.filter { $0 != prompt }
        list.insert(prompt, at: 0)
        recentPrompts = Array(list.prefix(25))
    }

    private init() {
        d.register(defaults: ["autoMemory": true, "stopOnCritical": true, "animatedBackdrop": true, "memoryLimitGB": 0.0])
        autoMemory = d.bool(forKey: "autoMemory")
        memoryLimitGB = d.double(forKey: "memoryLimitGB")
        stopOnCritical = d.bool(forKey: "stopOnCritical")
        unlockLimits = d.bool(forKey: "unlockLimits")
        animatedBackdrop = d.bool(forKey: "animatedBackdrop")
        let legacy = d.string(forKey: "outputPath")
        imagePath = d.string(forKey: "imagePath") ?? legacy ?? Paths.defaultImageDir.path
        videoPath = d.string(forKey: "videoPath") ?? legacy ?? Paths.defaultVideoDir.path
        modelsPath = d.string(forKey: "modelsPath") ?? ""
        lastModelRepo = d.string(forKey: "lastModelRepo") ?? ""
        lastChatRepo = d.string(forKey: "lastChatRepo") ?? ""
        chatTemperature = d.object(forKey: "chatTemperature") as? Double ?? 0.7
        chatMaxTokens = d.object(forKey: "chatMaxTokens") as? Double ?? 1024
        chatSystemPrompt = d.string(forKey: "chatSystemPrompt") ?? ""
        recentPrompts = d.stringArray(forKey: "recentPrompts") ?? []
        upscaleScale = d.object(forKey: "upscaleScale") as? Double ?? 2
        upscaleSoftness = d.double(forKey: "upscaleSoftness")
        upscaleQuant = d.integer(forKey: "upscaleQuant")
        upscaleTile = d.integer(forKey: "upscaleTile")
    }

    func outputDir(for kind: MediaKind) -> URL {
        let url = URL(fileURLWithPath: kind == .image ? imagePath : videoPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The Hugging Face access token is kept in a file only this user account can read, the same way
/// Hugging Face's own tools store it.
///
/// It used to live in the login keychain. macOS ties keychain access to an app's exact signature, and
/// without an Apple Developer ID every build of Mirage has a new one, so the keychain asked for
/// permission again on every launch after an update.
enum TokenStore {
    private static let service = "Mirage.HuggingFaceToken"
    private static let account = "default"
    private static var cached: String??
    private static var fileURL: URL { Paths.appSupport.appendingPathComponent("hf-token") }

    static func load() -> String? {
        if let cached { return cached }
        var token = readFile(fileURL)
        if token == nil { token = migrateFromKeychain() }
        if token == nil {
            // Fall back to a token saved by the `hf` command-line tool, if the user already logged in there.
            token = readFile(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/token"))
        }
        cached = .some(token)
        return token
    }

    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(); return }
        write(trimmed)
        cached = .some(trimmed)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        deleteKeychainItem()
        cached = nil
    }

    private static func readFile(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func write(_ token: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        // Created already restricted to the owner, so the token is never readable by others even briefly.
        fm.createFile(atPath: fileURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Moves a token saved by an earlier version out of the keychain. Tried once only: macOS may ask
    /// permission this one last time, and after that the keychain is never touched at launch again.
    private static func migrateFromKeychain() -> String? {
        // Only the installed app migrates; the headless test binary must never raise a keychain prompt.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "tokenMigratedFromKeychain") else { return nil }
        defaults.set(true, forKey: "tokenMigratedFromKeychain")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        write(token)
        deleteKeychainItem()
        return token
    }

    private static func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Runs a child process and streams its combined output.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var started = false

    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    static func baseEnvironment(extraPath: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = extraPath + [Paths.binDir.path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = path.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_CACHE"] = Paths.hfHub.path          // engines look for models where the app keeps them
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["COLUMNS"] = "100"
        if let token = TokenStore.load() { env["HF_TOKEN"] = token }
        return env
    }

    @discardableResult
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
             cwd: URL? = nil, onOutput: @escaping @Sendable (String) -> Void) async -> Int32 {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? Self.baseEnvironment()
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { onOutput(String(decoding: rest, as: UTF8.self)) }
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
                lock.lock(); started = true; lock.unlock()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                onOutput("Could not start \(executable.lastPathComponent): \(error.localizedDescription)\n")
                process.terminationHandler = nil
                cont.resume(returning: -1)
            }
        }
    }

    func terminate() {
        lock.lock(); let didStart = started; lock.unlock()
        guard didStart, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Runs a short command and returns its output.
func runCapture(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async -> (status: Int32, output: String) {
    let box = OutputBox()
    let status = await ProcessRunner().run(executable, arguments, environment: environment) { box.append($0) }
    return (status, box.value)
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        let gb = Double(n) / 1_000_000_000
        if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
        let mb = Double(n) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(n) / 1000)
    }
    static func gb(_ v: Double) -> String { String(format: v >= 10 ? "%.0f GB" : "%.1f GB", v) }
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
