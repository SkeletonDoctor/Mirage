import Foundation
import AppKit
import CryptoKit

struct AvailableUpdate: Equatable {
    let version: String
    let notes: String
    let downloadURL: URL
    let size: Int64
    /// SHA-256 the release notes state for the download, when they give one.
    let sha256: String?
    let pageURL: URL
}

enum UpdateState: Equatable {
    case idle, checking, upToDate
    case available(AvailableUpdate)
    case downloading(Double)
    case installing
    case failed(String)
}

/// Checks the project's GitHub releases for a newer version and can install it in place.
@Observable @MainActor
final class Updater {
    static let shared = Updater()
    nonisolated static let repo = "SkeletonDoctor/Mirage"

    private(set) var state: UpdateState = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var available: AvailableUpdate? { if case .available(let u) = state { return u }; return nil }

    /// Numeric comparison of dotted versions: 1.10 is newer than 1.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Looks up the latest release. Does nothing while a download or install is under way.
    func check(quietly: Bool = false) async {
        switch state { case .downloading, .installing, .checking: return; default: break }
        if !quietly { state = .checking }
        do {
            let latest = try await Self.fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "lastUpdateCheck")
            if Self.isNewer(latest.version, than: currentVersion) { state = .available(latest) }
            else if !quietly || state == .checking { state = .upToDate }
        } catch {
            if !quietly { state = .failed("Could not check for updates: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
        }
    }

    /// At launch: check at most once every twelve hours, without showing anything unless there is news.
    func checkAtLaunchIfDue() async {
        guard AppSettings.shared.autoCheckUpdates, Bundle.main.bundleIdentifier != nil else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 12 * 3600 { return }
        await check(quietly: true)
    }

    nonisolated static func fetchLatest() async throws -> AvailableUpdate {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mirage-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { throw HFError.other("GitHub did not return a release.") }
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let link = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw HFError.other("The latest release has no installer attached.")
        }
        let notes = (object["body"] as? String) ?? ""
        var sha: String?
        if let range = notes.range(of: #"[0-9a-fA-F]{64}"#, options: .regularExpression) { sha = String(notes[range]).lowercased() }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/releases")!
        return AvailableUpdate(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: notes, downloadURL: link,
                               size: (dmg["size"] as? NSNumber)?.int64Value ?? 0, sha256: sha, pageURL: page)
    }

    /// Downloads the update, checks it, swaps it in for the running copy and relaunches.
    func install(_ update: AvailableUpdate) async {
        if JobQueue.shared.current != nil {
            state = .failed("A generation is running. Update once it has finished.")
            return
        }
        state = .downloading(0)
        do {
            let staged = try await Self.downloadAndStage(update) { fraction in
                Task { @MainActor in if case .downloading = self.state { self.state = .downloading(fraction) } }
            }
            state = .installing
            ChatEngine.shared.unload(reason: nil)
            try Self.swapAndRelaunch(staged: staged, target: Bundle.main.bundleURL)
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Fetches the disk image, verifies its checksum, and copies the app out of it into a staging folder.
    nonisolated static func downloadAndStage(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MirageUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Mirage.dmg")

        let (bytes, response) = try await URLSession.shared.bytes(from: update.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HFError.other("The update could not be downloaded.") }
        fm.createFile(atPath: dmg.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dmg)
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var hasher = SHA256()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer); hasher.update(data: buffer)
                received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if update.size > 0 { progress(min(1, Double(received) / Double(update.size))) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); hasher.update(data: buffer) }
        try handle.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = update.sha256, expected != digest {
            try? fm.removeItem(at: work)
            throw HFError.other("The downloaded update did not match the checksum in its release notes, so it was not installed.")
        }

        // Mount the image out of sight, copy the app out, unmount.
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = await runCapture(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                      ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw HFError.other("The update's disk image could not be opened.") }
        let staged = work.appendingPathComponent("Mirage.app", isDirectory: true)
        let source = mount.appendingPathComponent("Mirage.app")
        let copy = await runCapture(URL(fileURLWithPath: "/usr/bin/ditto"), [source.path, staged.path])
        _ = await runCapture(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-quiet"])
        guard copy.status == 0, fm.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Mirage").path) else {
            throw HFError.other("The update did not contain the app.")
        }
        // The copy must be intact and still be Mirage before it replaces anything.
        let verify = await runCapture(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", staged.path])
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard verify.status == 0, info?["CFBundleIdentifier"] as? String == "app.mirage.local" else {
            throw HFError.other("The update failed its integrity check and was not installed.")
        }
        return staged
    }

    /// Starts a small script that waits for this app to quit, swaps the new copy in, and opens it.
    nonisolated static func swapAndRelaunch(staged: URL, target: URL, relaunch: Bool = true, waitForPID: Int32? = ProcessInfo.processInfo.processIdentifier) throws {
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw HFError.other("Mirage cannot replace itself in \(target.deletingLastPathComponent().path). Move it to Applications, or download the update from GitHub.")
        }
        let script = """
        pid="$1"; staged="$2"; target="$3"; relaunch="$4"
        if [ -n "$pid" ]; then while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done; fi
        old="$target.old-$$"
        if [ -e "$target" ]; then mv "$target" "$old" || exit 1; fi
        if mv "$staged" "$target"; then rm -rf "$old"; else [ -e "$old" ] && mv "$old" "$target"; exit 1; fi
        rm -rf "$(dirname "$staged")"
        [ "$relaunch" = "1" ] && open "$target"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "mirage-update", waitForPID.map(String.init) ?? "", staged.path, target.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if waitForPID == nil { process.waitUntilExit() }
    }
}
