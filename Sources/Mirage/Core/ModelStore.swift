import Foundation

/// A model that is on disk and ready to run.
struct InstalledModel: Identifiable, Hashable {
    let repo: String
    var title: String
    var sizeBytes: Int64
    var footprint: ModelFootprint
    var companions: [String]
    var profile: ModelProfile
    var snapshot: URL
    var files: Set<String>

    var id: String { repo }
    var kind: MediaKind { profile.kind }
    var quantLabel: String? {
        if let entry = Catalog.entry(forRepo: repo) { return entry.variant.quant }
        let n = repo.lowercased()
        if n.contains("q4") || n.contains("4bit") { return "4-bit" }
        if n.contains("q6") { return "6-bit" }
        if n.contains("q8") || n.contains("8bit") { return "8-bit" }
        return nil
    }

    static func == (a: InstalledModel, b: InstalledModel) -> Bool { a.repo == b.repo && a.sizeBytes == b.sizeBytes }
    func hash(into h: inout Hasher) { h.combine(repo) }
}

private struct RegistryEntry: Codable {
    var title: String
    var companions: [String]
    var tags: [String]
    var library: String?
    var complete: Bool
}

/// Tracks installed models: those downloaded here plus any compatible repo already in the Hugging Face cache.
@Observable @MainActor
final class ModelStore {
    static let shared = ModelStore()
    private(set) var models: [InstalledModel] = []
    /// False until the first scan finishes, so the UI does not flash its empty state at launch.
    private(set) var loaded = false
    /// True while models are being moved to a new folder.
    private(set) var relocating = false
    private var registry: [String: RegistryEntry] = [:]
    private let registryURL = Paths.appSupport.appendingPathComponent("models.json")

    private init() {
        if let data = try? Data(contentsOf: registryURL),
           let decoded = try? JSONDecoder().decode([String: RegistryEntry].self, from: data) {
            registry = decoded
        }
    }

    private func saveRegistry() {
        if let data = try? JSONEncoder().encode(registry) { try? data.write(to: registryURL, options: .atomic) }
    }

    /// Models you generate with, as opposed to helpers such as the upscaler.
    var generators: [InstalledModel] { models.filter { !$0.profile.isTool && !$0.profile.isChat } }
    var chatModels: [InstalledModel] { models.filter { $0.profile.isChat } }
    var upscaler: InstalledModel? { models.first { $0.profile.isTool } }

    func isInstalled(_ repo: String) -> Bool { models.contains { $0.repo == repo } }
    func model(_ repo: String) -> InstalledModel? { models.first { $0.repo == repo } }

    /// Records a download in progress so a half-fetched repo is never listed as ready.
    func markStarted(repo: String, title: String, companions: [String], tags: [String], library: String?) {
        if registry[repo]?.complete == true, isInstalled(repo) { return }
        registry[repo] = RegistryEntry(title: title, companions: companions, tags: tags, library: library, complete: false)
        saveRegistry()
    }

    /// Deletes a partly downloaded repo. Does nothing for a model that finished downloading.
    func discardIncomplete(repo: String) {
        guard let entry = registry[repo], !entry.complete else { return }
        try? FileManager.default.removeItem(at: Paths.repoDir(repo))
        registry[repo] = nil
        saveRegistry()
    }

    func markComplete(repo: String, title: String, companions: [String], tags: [String], library: String?) async {
        registry[repo] = RegistryEntry(title: title, companions: companions, tags: tags, library: library, complete: true)
        saveRegistry()
        await refresh()
    }

    func refresh() async {
        let registry = self.registry
        let inProgress = Set(DownloadManager.shared.tasks.filter { $0.state != .completed }.map(\.repo))
        let found = await Task.detached(priority: .utility) { Self.scan(registry: registry, skipping: inProgress) }.value
        models = found.sorted { ($0.kind.rawValue, $0.title.lowercased()) < ($1.kind.rawValue, $1.title.lowercased()) }
        loaded = true
    }

    /// Total size on disk of the models Mirage manages.
    var totalBytes: Int64 { models.reduce(0) { $0 + $1.sizeBytes } }

    /// Switches the models folder. With `moveExisting`, the models Mirage knows about (and the helper
    /// repos they need) are moved across; anything else in the old folder is left alone.
    /// Returns a message if something could not be moved.
    func relocate(to newFolder: URL, moveExisting: Bool) async -> String? {
        guard !relocating else { return "A move is already in progress." }
        let old = Paths.hfHub
        guard old.standardizedFileURL != newFolder.standardizedFileURL else { return nil }
        relocating = true
        defer { relocating = false }
        var problem: String?
        if moveExisting {
            var repos = Set(models.map(\.repo)).union(registry.keys)
            for m in models { repos.formUnion(m.companions) }
            for entry in registry.values { repos.formUnion(entry.companions) }
            repos.insert(ltxDefaultTextEncoder)
            let names = repos.map { "models--" + $0.replacingOccurrences(of: "/", with: "--") }
            problem = await Task.detached(priority: .userInitiated) { () -> String? in
                let fm = FileManager.default
                do { try fm.createDirectory(at: newFolder, withIntermediateDirectories: true) }
                catch { return "Could not create that folder: \(error.localizedDescription)" }
                var failed: [String] = []
                for name in names {
                    let src = old.appendingPathComponent(name), dst = newFolder.appendingPathComponent(name)
                    guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                    do { try fm.moveItem(at: src, to: dst) } catch { failed.append(name) }
                }
                return failed.isEmpty ? nil : "Some models could not be moved and stayed in the old folder: \(failed.joined(separator: ", "))"
            }.value
        } else {
            try? FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        }
        AppSettings.shared.modelsPath = newFolder.standardizedFileURL == Paths.defaultHFHub.standardizedFileURL ? "" : newFolder.path
        await refresh()
        return problem
    }

    /// Moves the model's cache folder to the Trash.
    func delete(_ model: InstalledModel) async {
        let dir = Paths.repoDir(model.repo)
        do { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        catch { try? FileManager.default.removeItem(at: dir) }
        registry[model.repo] = nil
        saveRegistry()
        await refresh()
    }

    nonisolated private static func scan(registry: [String: RegistryEntry], skipping: Set<String>) -> [InstalledModel] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.hfHub, includingPropertiesForKeys: nil) else { return [] }
        var out: [InstalledModel] = []
        for dir in dirs {
            let name = dir.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            let rest = String(name.dropFirst("models--".count))
            guard let sep = rest.range(of: "--") else { continue }
            let repo = rest[..<sep.lowerBound] + "/" + rest[sep.upperBound...]
            let repoID = String(repo)
            if skipping.contains(repoID) { continue }
            let entry = registry[repoID]
            if let entry, !entry.complete { continue }
            guard let snapshot = Paths.snapshotDir(repoID) else { continue }

            var files: [(path: String, size: Int64)] = []
            if let e = fm.enumerator(at: snapshot, includingPropertiesForKeys: [.isDirectoryKey]) {
                let base = snapshot.path.hasSuffix("/") ? snapshot.path : snapshot.path + "/"
                for case let url as URL in e {
                    let resolved = url.resolvingSymlinksInPath()
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                    let size = ((try? fm.attributesOfItem(atPath: resolved.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    let rel = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
                    files.append((rel, size))
                }
            }
            guard !files.isEmpty else { continue }
            let profile = ModelProfile.resolve(repo: repoID, tags: entry?.tags ?? [], library: entry?.library, files: files.map(\.path))
            guard profile.isRunnable else { continue }
            let catalog = Catalog.entry(forRepo: repoID)
            let title = entry?.title ?? catalog?.model.name ?? String(repoID.split(separator: "/").last ?? Substring(repoID))
            out.append(InstalledModel(
                repo: repoID, title: title,
                sizeBytes: files.reduce(0) { $0 + $1.size },
                footprint: catalog?.variant.footprint ?? ModelFootprint.estimate(family: profile.family, files: files),
                companions: entry?.companions ?? catalog?.model.companions ?? [],
                profile: profile, snapshot: snapshot, files: Set(files.map(\.path))))
        }
        return out
    }
}
