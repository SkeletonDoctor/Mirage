import Foundation
import CryptoKit

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
        ModelStore.shared.markPaused(repo: task.repo, true)
    }

    func resume(_ task: DownloadTask) {
        guard !task.state.isActive, task.state != .completed else { return }
        ModelStore.shared.markPaused(repo: task.repo, false)
        run(task)
    }

    /// Picks up downloads that were cut short when the app last closed: those that were running carry on
    /// by themselves, and those the user had paused come back paused.
    func restoreInterrupted() {
        for item in ModelStore.shared.interruptedDownloads() where task(for: item.repo) == nil {
            if item.paused {
                let parts = [DownloadPart(repo: item.repo)] + item.companions.map { DownloadPart(repo: $0) }
                let task = DownloadTask(repo: item.repo, title: item.title, parts: parts, tags: item.tags, library: item.library)
                task.state = .paused
                tasks.append(task)
            } else {
                start(repo: item.repo, title: item.title, companions: item.companions, tags: item.tags, library: item.library)
            }
        }
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
            where file.pathExtension == "incomplete" || file.lastPathComponent.hasSuffix(".incomplete.map") {
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
            else { done += SegmentedDownload.bytesOnDisk(partial: blob.appendingPathExtension("incomplete"), size: p.file.bytes) }
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
            // Large files arrive as whole 8 MB parts, so bytes land in bursts. Averaging over the last
            // ten seconds gives a steady speed and a believable time remaining on slow connections.
            let started = Date()
            var window: [(time: Date, bytes: Int64)] = []
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let n = counter.take()
                let now = Date()
                task.receivedBytes += n
                window.append((now, n))
                window.removeAll { now.timeIntervalSince($0.time) > 10 }
                let span = min(10, max(1, now.timeIntervalSince(started)))
                task.speed = Double(window.reduce(Int64(0)) { $0 + $1.bytes }) / span
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
                var fetchedInParts = false
                if p.file.bytes >= SegmentedDownload.minimumSize {
                    // Big file: fetch many parts at once over separate connections.
                    let already = SegmentedDownload.bytesOnDisk(partial: partial, size: p.file.bytes)
                    let segmented = SegmentedDownload(resolve: HFClient.request(HFClient.fileURL(repo: p.repo, revision: p.revision, path: p.file.rfilename)),
                                                      partial: partial, size: p.file.bytes, sha256: p.file.lfs?.sha256, repo: p.repo,
                                                      onBytes: { counter.add($0) },
                                                      onVerifying: { Task { @MainActor in task.currentFile = "Checking \(p.file.rfilename)" } })
                    do {
                        try await segmented.run()
                        try? fm.removeItem(at: blob)
                        try fm.moveItem(at: partial, to: blob)
                        fetchedInParts = true
                    } catch SegmentedDownload.Failure.rangesUnsupported {
                        // The server would not serve parts; start this file again the simple way.
                        SegmentedDownload.discard(partial: partial)
                        task.receivedBytes -= already
                    }
                }
                let offset = fetchedInParts ? 0 : existingSize(partial)
                if fetchedInParts {
                    // already moved into place
                } else if p.file.bytes > 0 && offset >= p.file.bytes {
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


/// Downloads one large file as many parts at once, each over its own connection, writing every part
/// straight to its place in the file. A small map beside the file records the finished parts, so a
/// paused or interrupted download carries on where it stopped.
struct SegmentedDownload: Sendable {
    enum Failure: Error { case rangesUnsupported }

    static let minimumSize: Int64 = 64 * 1024 * 1024
    static let partSize: Int64 = 8 * 1024 * 1024
    static let connections = 8

    let resolve: URLRequest
    let partial: URL
    let size: Int64
    let sha256: String?
    let repo: String
    let onBytes: @Sendable (Int64) -> Void
    let onVerifying: @Sendable () -> Void

    struct MapSnapshot: Codable, Sendable {
        var partSize: Int64
        var size: Int64
        var done: [Int]
    }
    private typealias Map = MapSnapshot

    private static func mapURL(_ partial: URL) -> URL { partial.appendingPathExtension("map") }

    private static func loadMap(_ partial: URL, size: Int64) -> Map? {
        guard let data = try? Data(contentsOf: mapURL(partial)), let map = try? JSONDecoder().decode(Map.self, from: data),
              map.size == size, map.partSize > 0 else { return nil }
        return map
    }

    private static func partLength(_ index: Int, partSize: Int64, size: Int64) -> Int64 {
        min(partSize, size - Int64(index) * partSize)
    }

    /// Bytes of this file already downloaded, whether it was fetched in parts or front to back.
    static func bytesOnDisk(partial: URL, size: Int64) -> Int64 {
        if let map = loadMap(partial, size: size) {
            return map.done.reduce(0) { $0 + partLength($1, partSize: map.partSize, size: size) }
        }
        let existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return min(existing, size)
    }

    static func discard(partial: URL) {
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: mapURL(partial))
    }

    func run() async throws {
        let fm = FileManager.default
        // Pick up an earlier attempt: a part map, or a file that was being written front to back.
        var map = Self.loadMap(partial, size: size) ?? {
            let existing = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let whole = existing < size ? Int(existing / Self.partSize) : 0
            return Map(partSize: Self.partSize, size: size, done: Array(0..<whole))
        }()
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let sizing = try FileHandle(forWritingTo: partial)
        try sizing.truncate(atOffset: UInt64(size))        // sparse: takes no space until parts arrive
        try sizing.close()

        let count = Int((size + map.partSize - 1) / map.partSize)
        let finished = Set(map.done)
        let pending = (0..<count).filter { !finished.contains($0) }
        let state = PartState(pending: pending, map: map, mapURL: Self.mapURL(partial))
        let source = SourceURL(resolve: resolve, repo: repo)
        let partSize = map.partSize
        map.done = []                                       // the actor owns the list from here

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(Self.connections, pending.count) {
                    group.addTask {
                        // One session per worker, so each gets its own connection instead of sharing one.
                        let config = URLSessionConfiguration.ephemeral
                        config.timeoutIntervalForRequest = 60
                        config.waitsForConnectivity = true
                        config.urlCache = nil
                        let session = URLSession(configuration: config)
                        defer { session.invalidateAndCancel() }
                        let handle = try FileHandle(forWritingTo: partial)
                        defer { try? handle.close() }

                        while let index = await state.next() {
                            try Task.checkCancellation()
                            let start = Int64(index) * partSize
                            let length = Self.partLength(index, partSize: partSize, size: size)
                            let data = try await Self.fetch(session: session, source: source, start: start, length: length)
                            try handle.seek(toOffset: UInt64(start))
                            try handle.write(contentsOf: data)
                            await state.finish(index)
                            onBytes(length)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        // Parts were written out of order, so confirm the whole file against Hugging Face's checksum.
        if let sha256 {
            onVerifying()
            let url = partial
            let actual = try await Task.detached(priority: .userInitiated) { try Self.hash(of: url) }.value
            if actual != sha256.lowercased() {
                Self.discard(partial: partial)
                throw HFError.other("The downloaded file did not match its checksum and was discarded. Start the download again.")
            }
        }
        try? fm.removeItem(at: Self.mapURL(partial))
    }

    /// Fetches one part, retrying brief network failures and refreshing the download link if it expires.
    private static func fetch(session: URLSession, source: SourceURL, start: Int64, length: Int64) async throws -> Data {
        var lastError: Error = HFError.offline("no response")
        for attempt in 0..<5 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: try await source.url(refresh: false))
                request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 206, Int64(data.count) == length { return data }
                if code == 200 { throw Failure.rangesUnsupported }
                if code == 401 || code == 403 || code == 410 {
                    _ = try await source.url(refresh: true)         // signed link expired
                    lastError = HFError.http(code)
                    continue
                }
                lastError = code == 206 ? HFError.offline("a part arrived short") : HFError.http(code)
            } catch let failure as Failure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HFError {
                throw error
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = HFError.offline(error.localizedDescription)
            }
            try await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    private static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Hands out the parts still to fetch and records the finished ones on disk.
private actor PartState {
    private var pending: [Int]
    private var done: [Int]
    private let partSize: Int64
    private let size: Int64
    private let mapURL: URL
    private var sinceSave = 0

    init(pending: [Int], map: SegmentedDownload.MapSnapshot, mapURL: URL) {
        self.pending = pending.reversed()
        self.done = map.done
        self.partSize = map.partSize
        self.size = map.size
        self.mapURL = mapURL
    }

    func next() -> Int? { pending.popLast() }

    func finish(_ index: Int) {
        done.append(index)
        sinceSave += 1
        if sinceSave >= 4 || pending.isEmpty { save() }
    }

    private func save() {
        sinceSave = 0
        let body = "{\"partSize\":\(partSize),\"size\":\(size),\"done\":[\(done.map(String.init).joined(separator: ","))]}"
        try? Data(body.utf8).write(to: mapURL, options: .atomic)
    }
}

/// The signed delivery-network address behind a Hugging Face file link. Resolved once and shared by
/// all parts, so only one request per file counts against Hugging Face's request limits.
private actor SourceURL {
    private let resolve: URLRequest
    private let repo: String
    private var cached: URL?
    private var inFlight: Task<URL, Error>?

    init(resolve: URLRequest, repo: String) { self.resolve = resolve; self.repo = repo }

    func url(refresh: Bool) async throws -> URL {
        if refresh { cached = nil }
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        let request = resolve
        let repo = repo
        let task = Task { () throws -> URL in
            var probe = request
            probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, response) = try await URLSession.shared.data(for: probe)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200: throw SegmentedDownload.Failure.rangesUnsupported
            case 206: break
            case 401, 403: throw HFError.gated(repo)
            case 404: throw HFError.notFound
            default: throw HFError.http(http?.statusCode ?? 0)
            }
            return http?.url ?? request.url!
        }
        inFlight = task
        defer { inFlight = nil }
        let url = try await task.value
        cached = url
        return url
    }
}
