import Foundation
import Darwin

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String              // "user" or "assistant"
    var text: String
    /// Reasoning the model produced before its answer, when it separates the two.
    var thinking: String?
    var date = Date()
    /// Tokens per second for an assistant reply, once it has finished.
    var speed: Double?
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New chat"
    var messages: [ChatMessage] = []
    var modelRepo = ""
    var updated = Date()
}

/// Saved conversations.
@Observable @MainActor
final class ChatStore {
    static let shared = ChatStore()
    private(set) var conversations: [Conversation] = []
    var currentID: UUID?
    private let url = Paths.appSupport.appendingPathComponent("chats.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Conversation].self, from: data) {
            conversations = saved
        }
        currentID = conversations.first?.id
    }

    var current: Conversation? { conversations.first { $0.id == currentID } }

    @discardableResult
    func newConversation() -> Conversation {
        // Reuse an untouched empty chat rather than piling them up.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) { currentID = empty.id; return empty }
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
        scheduleSave()
        return c
    }

    func update(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
        scheduleSave()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        scheduleSave()
    }

    /// Saves shortly after the last change, so a streaming reply does not rewrite the file per word.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            self.saveNow()
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(conversations) { try? data.write(to: url, options: .atomic) }
    }
}

enum ChatEngineState: Equatable {
    case idle
    case loading(String)
    case ready
    case failed(String)
}

/// Keeps one language model loaded in a local mlx-lm server and streams replies from it.
/// The model stays in memory between messages, so it is unloaded when idle, when a generation
/// starts, and when the app quits.
@Observable @MainActor
final class ChatEngine {
    static let shared = ChatEngine()

    private(set) var state: ChatEngineState = .idle
    private(set) var loadedRepo: String?
    private(set) var memoryGB: Double = 0
    private(set) var notice: String?
    private(set) var isReplying = false
    private(set) var log = ""

    private var runner: ProcessRunner?
    private var port = 0
    private var lastUsed = Date()
    private var housekeeping: Timer?
    private let idleLimit: TimeInterval = 10 * 60

    private init() {}

    var isReady: Bool { state == .ready }

    /// Stops any chat server left over from an earlier run of the app.
    static func stopStrays() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "Mirage/engines/mlx-lm/venv/bin/mlx_lm.server"]
        try? pkill.run()
    }

    /// Starts the server for `model` (installing the engine first if needed) and waits until it answers.
    func load(_ model: InstalledModel) async -> Bool {
        if loadedRepo == model.repo, state == .ready { return true }
        unload(reason: nil)
        notice = nil
        log = ""
        state = .loading("Preparing")

        // Some repos ship their own Python model code. mlx-lm refuses to run it unless told to trust it,
        // and Mirage never does: it would mean running an unreviewed program from the internet.
        if model.files.contains("model.py") {
            state = .failed(ChatEngine.customCodeMessage)
            return false
        }
        if JobQueue.shared.current != nil {
            state = .failed("A generation is running. Chat can load once it finishes.")
            return false
        }
        if !EngineManager.shared.state(.mlxLM).isInstalled {
            state = .loading("Installing the chat engine")
            guard await EngineManager.shared.ensureInstalled(.mlxLM) else {
                state = .failed("The chat engine could not be installed. See This Mac for details.")
                return false
            }
        }
        let budget = MemoryPlanner.budgetGB(override: AppSettings.shared.memoryLimitGB)
        if AppSettings.shared.autoMemory && !AppSettings.shared.unlockLimits && model.footprint.residentGB > budget * 1.1 {
            state = .failed("\(model.title) needs about \(Format.gb(model.footprint.residentGB)) but only \(Format.gb(budget)) may be used. Pick a smaller model, or raise the memory limit under This Mac.")
            return false
        }

        guard let free = Self.freePort() else { state = .failed("Could not find a free local port."); return false }
        port = free
        state = .loading("Loading \(model.title)")
        let bin = EngineManager.shared.bin(.mlxLM)
        let runner = ProcessRunner()
        self.runner = runner
        let env = ProcessRunner.baseEnvironment(extraPath: [bin.path])
        // The server runs under a tiny launcher that stops it if Mirage disappears for any reason
        // (quit, crash or force-quit), so a multi-gigabyte model is never left behind in memory.
        let launcher = """
        "$0" "$@" &
        child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT
        while kill -0 $child 2>/dev/null; do
          kill -0 $PPID 2>/dev/null || { kill $child 2>/dev/null; exit 0; }
          sleep 2 &
          wait $!
        done
        wait $child
        """
        let args = ["-c", launcher, bin.appendingPathComponent("mlx_lm.server").path,
                    "--model", model.snapshot.path, "--host", "127.0.0.1", "--port", "\(port)", "--log-level", "WARNING"]
        let repo = model.repo
        Task { [weak self] in
            let status = await runner.run(URL(fileURLWithPath: "/bin/sh"), args, environment: env, cwd: Paths.workDir) { text in
                Task { @MainActor in
                    guard let self else { return }
                    self.log += text
                    if self.log.count > 20_000 { self.log = String(self.log.suffix(12_000)) }
                }
            }
            await MainActor.run {
                guard let self, self.runner === runner else { return }
                // The server stopped on its own.
                self.runner = nil
                self.loadedRepo = nil
                self.memoryGB = 0
                if case .loading = self.state {
                    self.state = .failed(JobQueue.explain(log: self.log, status: status))
                } else if self.state == .ready {
                    self.state = .failed("The model stopped unexpectedly. " + JobQueue.explain(log: self.log, status: status))
                }
            }
        }

        // Wait for the server to answer; loading a large model can take a while.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.runner === runner else { return false }       // failed or was unloaded meanwhile
            let health = await ping()
            // The server answers 503 once its model thread has died; stop at once instead of waiting it out.
            if health == 503 || log.contains("generation thread died") {
                let reason = log.contains("custom modu") ? ChatEngine.customCodeMessage : JobQueue.explain(log: log, status: 1)
                unload(reason: nil)
                state = .failed(reason)
                return false
            }
            if health == 200 {
                loadedRepo = repo
                state = .ready
                lastUsed = Date()
                AppSettings.shared.lastChatRepo = repo
                startHousekeeping()
                return true
            }
        }
        unload(reason: nil)
        state = .failed("The model took too long to load.")
        return false
    }

    func unload(reason: String?) {
        guard runner != nil || loadedRepo != nil else { return }
        let r = runner
        runner = nil
        r?.terminate()
        loadedRepo = nil
        memoryGB = 0
        isReplying = false
        housekeeping?.invalidate(); housekeeping = nil
        state = .idle
        notice = reason
    }

    static let customCodeMessage = "This model only runs with its own custom program code, which Mirage will not execute for safety. Pick a model without that requirement."

    /// The server's health status code, or 0 while it is not answering yet.
    private func ping() async -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func startHousekeeping() {
        housekeeping?.invalidate()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let runner = self.runner, runner.isRunning else { return }
                let gb = (Double(MemoryProbe.footprintWithChildren(pid: runner.pid)) / 1_073_741_824 * 10).rounded() / 10
                if gb != self.memoryGB { self.memoryGB = gb }
                if !self.isReplying, Date().timeIntervalSince(self.lastUsed) > self.idleLimit {
                    self.unload(reason: "Unloaded after ten minutes idle to free memory. It reloads when you send a message.")
                }
            }
        }
    }

    struct Piece { var text = ""; var thinking = "" }

    /// Streams a reply. Each element is the new text since the previous one.
    func reply(to messages: [ChatMessage], system: String, temperature: Double, maxTokens: Int) -> AsyncThrowingStream<Piece, Error> {
        let port = self.port
        isReplying = true
        lastUsed = Date()
        var payload: [[String: String]] = []
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty { payload.append(["role": "system", "content": trimmedSystem]) }
        for m in messages where !m.text.isEmpty { payload.append(["role": m.role, "content": m.text]) }
        let body: [String: Any] = ["model": "default_model", "messages": payload, "stream": true,
                                   "temperature": temperature, "max_tokens": maxTokens]

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { Task { @MainActor in self.isReplying = false; self.lastUsed = Date() } }
                do {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw HFError.other("The model returned an error (\(code)).") }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if json == "[DONE]" { break }
                        guard let data = json.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (object["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }
                        var piece = Piece()
                        if let content = delta["content"] as? String { piece.text = content }
                        if let reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String) { piece.thinking = reasoning }
                        if !piece.text.isEmpty || !piece.thinking.isEmpty { continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the system for an unused local port.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
