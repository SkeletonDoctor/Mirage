import Foundation

let ltxDefaultTextEncoder = "mlx-community/gemma-3-12b-it-4bit"

/// One repo to fetch, with the files to leave out.
struct DownloadPart {
    let repo: String
    /// nil means "skip only what the engine never loads".
    var excluded: Set<String>? = nil
}

enum DownloadState: Equatable {
    case queued, preparing, downloading, paused, completed
    case failed(String)

    var isActive: Bool { self == .queued || self == .preparing || self == .downloading }
}

@Observable @MainActor
final class DownloadTask: Identifiable {
    let id = UUID()
    let repo: String
    let title: String
    let parts: [DownloadPart]
    let tags: [String]
    let library: String?

    var state: DownloadState = .queued
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var speed: Double = 0
    var currentFile = ""

    fileprivate var worker: Task<Void, Never>?
    fileprivate var activeDownloader: FileDownloader?

    init(repo: String, title: String, parts: [DownloadPart], tags: [String], library: String?) {
        self.repo = repo; self.title = title; self.parts = parts; self.tags = tags; self.library = library
    }

    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    var etaSeconds: Double? { speed > 1000 && totalBytes > receivedBytes ? Double(totalBytes - receivedBytes) / speed : nil }
}

/// Downloads model repos straight into the standard Hugging Face cache layout
/// (`blobs/`, `snapshots/<commit>/`, `refs/main`), so every engine finds them without copying.
@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()
    private(set) var tasks: [DownloadTask] = []
    /// The download that most recently finished, for the "ready" notice.
    var justFinished: DownloadTask?

    var activeCount: Int { tasks.filter { $0.state.isActive }.count }

    func task(for repo: String) -> DownloadTask? { tasks.last { $0.repo == repo } }

    @discardableResult
    func start(repo: String, title: String, excluded: Set<String>? = nil, companions: [String] = [],
               tags: [String] = [], library: String? = nil) -> DownloadTask {
        if let existing = task(for: repo), existing.state.isActive { return existing }
        tasks.removeAll { $0.repo == repo }
        let parts = [DownloadPart(repo: repo, excluded: excluded)] + companions.map { DownloadPart(repo: $0) }
        let task = DownloadTask(repo: repo, title: title, parts: parts, tags: tags, library: library)
        tasks.append(task)
        run(task)
        return task
    }

    func pause(_ task: DownloadTask) {
        guard task.state.isActive else { return }
        task.worker?.cancel()
        task.activeDownloader?.cancel()
        task.state = .paused
        task.speed = 0
    }

    func resume(_ task: DownloadTask) {
        guard !task.state.isActive, task.state != .completed else { return }
        run(task)
    }

    /// Cancels a download and deletes what it had fetched so far.
    func remove(_ task: DownloadTask) {
        let finished = task.state == .completed
        pause(task)
        tasks.removeAll { $0.id == task.id }
        guard !finished else { return }
        ModelStore.shared.discardIncomplete(repo: task.repo)
        // Companion repos may be shared with other models: only clear their half-written files.
        for part in task.parts.dropFirst() {
            let blobs = Paths.repoDir(part.repo).appendingPathComponent("blobs")
            for file in (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "incomplete" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func clearFinished() { tasks.removeAll { $0.state == .completed } }

    private func run(_ task: DownloadTask) {
        task.state = .preparing
        ModelStore.shared.markStarted(repo: task.repo, title: task.title, companions: task.parts.dropFirst().map(\.repo),
                                      tags: task.tags, library: task.library)
        task.worker = Task { [weak self] in
            // Models need their engine; install it alongside the download.
            let profile = ModelProfile.resolve(repo: task.repo, tags: task.tags, library: task.library)
            if let engine = profile.engine { Task { await EngineManager.shared.ensureInstalled(engine) } }
            do {
                try await self?.perform(task)
                if Task.isCancelled { return }
                task.state = .completed
                task.speed = 0
                self?.justFinished = task
                await ModelStore.shared.markComplete(repo: task.repo, title: task.title, companions: task.parts.dropFirst().map(\.repo),
                                                     tags: task.tags, library: task.library)
            } catch is CancellationError {
                if task.state != .paused { task.state = .paused }
            } catch {
                if task.state == .paused { return }
                task.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                task.speed = 0
            }
        }
    }

    private struct PlannedFile {
        let repo: String
        let revision: String
        let file: HFFile
    }

    private func perform(_ task: DownloadTask) async throws {
        // 1. Work out the full file list and total size.
        try FileManager.default.createDirectory(at: Paths.hfHub, withIntermediateDirectories: true)
        var planned: [PlannedFile] = []
        var parts = task.parts
        var index = 0
        while index < parts.count {
            let part = parts[index]
            index += 1
            let detail = try await HFClient.detail(part.repo)
            guard let revision = detail.sha, let files = detail.siblings else { throw HFError.notFound }
            let names = files.map(\.rfilename)
            let family = ModelProfile.resolve(repo: part.repo, tags: detail.tags, library: detail.libraryName, files: names).family
            let skip = part.excluded ?? defaultExcludedFiles(repo: part.repo, family: family, files: names)
            // LTX packs without their own text encoder rely on Gemma 3; fetch it now rather than at first run.
            if family == .ltx, !names.contains("text_encoder.safetensors"),
               !parts.contains(where: { $0.repo == ltxDefaultTextEncoder }) {
                parts.append(DownloadPart(repo: ltxDefaultTextEncoder))
            }
            for f in files where !skip.contains(f.rfilename) && f.blobName != nil {
                planned.append(PlannedFile(repo: part.repo, revision: revision, file: f))
            }
            let dir = Paths.repoDir(part.repo)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("blobs"), withIntermediateDirectories: true)
            try revision.write(to: dir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        }
        try Task.checkCancellation()

        let fm = FileManager.default
        func existingSize(_ url: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        task.totalBytes = planned.reduce(0) { $0 + $1.file.bytes }
        var done: Int64 = 0
        for p in planned {
            let blobs = Paths.repoDir(p.repo).appendingPathComponent("blobs")
            let blob = blobs.appendingPathComponent(p.file.blobName!)
            if fm.fileExists(atPath: blob.path) { done += p.file.bytes }
            else { done += min(existingSize(blob.appendingPathExtension("incomplete")), p.file.bytes) }
        }
        task.receivedBytes = done
        // Refuse early if the disk cannot hold what is left, rather than failing hours in.
        let needed = task.totalBytes - done
        if let free = try? Paths.hfHub.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed + 1_000_000_000 {
            throw HFError.other("Not enough disk space: this needs \(Format.bytes(needed)) but only \(Format.bytes(free)) is free where models are kept. Free some space or choose another models folder in Settings.")
        }
        task.state = .downloading

        // 2. Fetch what is missing, smallest files first so configs land early.
        let counter = ByteCounter()
        let ticker = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let n = counter.take()
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                task.receivedBytes += n
                if dt > 0 { task.speed = task.speed * 0.6 + (Double(n) / dt) * 0.4 }
            }
        }
        defer { ticker.cancel() }

        for p in planned.sorted(by: { $0.file.bytes < $1.file.bytes }) {
            try Task.checkCancellation()
            let repoDir = Paths.repoDir(p.repo)
            let blob = repoDir.appendingPathComponent("blobs").appendingPathComponent(p.file.blobName!)
            if !fm.fileExists(atPath: blob.path) {
                task.currentFile = p.file.rfilename
                let partial = blob.appendingPathExtension("incomplete")
                let offset = existingSize(partial)
                if p.file.bytes > 0 && offset >= p.file.bytes {
                    try? fm.removeItem(at: blob)
                    try fm.moveItem(at: partial, to: blob)
                } else {
                    var request = HFClient.request(HFClient.fileURL(repo: p.repo, revision: p.revision, path: p.file.rfilename))
                    if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                    let downloader = FileDownloader(request: request, destination: partial, resumeOffset: offset, repo: p.repo) { n in
                        counter.add(n)
                    }
                    task.activeDownloader = downloader
                    let restarted = try await downloader.start()
                    task.activeDownloader = nil
                    if restarted { task.receivedBytes -= offset }   // server ignored the range; counted bytes were discarded
                    let size = existingSize(partial)
                    if p.file.bytes > 0 && size != p.file.bytes {
                        throw HFError.other("\(p.file.rfilename) arrived incomplete (\(size) of \(p.file.bytes) bytes). Resume to continue.")
                    }
                    try? fm.removeItem(at: blob)
                    try fm.moveItem(at: partial, to: blob)
                }
            }
            // Link the file into the snapshot folder under its real name.
            let link = repoDir.appendingPathComponent("snapshots/\(p.revision)/\(p.file.rfilename)")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = p.file.rfilename.split(separator: "/").count - 1
            let target = String(repeating: "../", count: depth + 2) + "blobs/" + p.file.blobName!
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        }
        task.receivedBytes += counter.take()
        task.receivedBytes = task.totalBytes
        task.currentFile = ""
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int64 = 0
    func add(_ v: Int64) { lock.lock(); n += v; lock.unlock() }
    func take() -> Int64 { lock.lock(); defer { n = 0; lock.unlock() }; return n }
}

/// Streams one HTTP response to a file, appending when the server honours a Range request.
final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destination: URL
    private let resumeOffset: Int64
    private let repo: String
    private let onBytes: @Sendable (Int64) -> Void

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Bool, Error>?
    private var failure: Error?
    private var restarted = false
    private var cancelled = false
    private let lock = NSLock()

    init(request: URLRequest, destination: URL, resumeOffset: Int64, repo: String, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.request = request; self.destination = destination; self.resumeOffset = resumeOffset
        self.repo = repo; self.onBytes = onBytes
    }

    /// Returns true when the server sent the whole file again instead of resuming.
    func start() async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); cont.resume(throwing: CancellationError()); return }
                continuation = cont
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 90
                config.timeoutIntervalForResource = 60 * 60 * 24
                config.waitsForConnectivity = true
                let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                session = s
                let t = s.dataTask(with: request)
                dataTask = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let t = dataTask; lock.unlock()
        t?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        switch code {
        case 200, 206:
            if code == 200 && resumeOffset > 0 {
                restarted = true
                try? fm.removeItem(at: destination)
            }
            if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
            do {
                let h = try FileHandle(forWritingTo: destination)
                try h.seekToEnd()
                handle = h
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        case 416:
            completionHandler(.cancel)          // nothing left to fetch; the caller checks the size
            failure = nil
            restarted = false
            finishedEarly = true
        case 401, 403:
            failure = HFError.gated(repo)
            completionHandler(.cancel)
        case 404:
            failure = HFError.notFound
            completionHandler(.cancel)
        default:
            failure = HFError.http(code)
            completionHandler(.cancel)
        }
    }
    private var finishedEarly = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            onBytes(Int64(data.count))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        lock.lock()
        let cont = continuation
        continuation = nil
        let wasCancelled = cancelled
        lock.unlock()
        if let failure { cont?.resume(throwing: failure) }
        else if finishedEarly { cont?.resume(returning: false) }
        else if wasCancelled { cont?.resume(throwing: CancellationError()) }
        else if let error { cont?.resume(throwing: HFError.offline(error.localizedDescription)) }
        else { cont?.resume(returning: restarted) }
    }
}
