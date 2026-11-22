import Foundation

struct HFFile: Decodable, Hashable {
    struct LFS: Decodable, Hashable { let sha256: String?; let size: Int64? }
    let rfilename: String
    let size: Int64?
    let blobId: String?
    let lfs: LFS?

    var bytes: Int64 { lfs?.size ?? size ?? 0 }
    /// File name inside the cache's `blobs` folder: the SHA-256 for large files, the git blob id otherwise.
    var blobName: String? { lfs?.sha256 ?? blobId }
}

struct HFModel: Decodable, Identifiable, Hashable {
    let id: String
    let author: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]
    let gated: Bool
    let trendingScore: Double?
    let sha: String?
    let siblings: [HFFile]?

    enum CodingKeys: String, CodingKey {
        case id, author, downloads, likes, lastModified, tags, gated, trendingScore, sha, siblings
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        author = try? c.decode(String.self, forKey: .author)
        downloads = try? c.decode(Int.self, forKey: .downloads)
        likes = try? c.decode(Int.self, forKey: .likes)
        lastModified = try? c.decode(String.self, forKey: .lastModified)
        pipelineTag = try? c.decode(String.self, forKey: .pipelineTag)
        libraryName = try? c.decode(String.self, forKey: .libraryName)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        trendingScore = try? c.decode(Double.self, forKey: .trendingScore)
        sha = try? c.decode(String.self, forKey: .sha)
        siblings = try? c.decode([HFFile].self, forKey: .siblings)
        // `gated` is false, or a string such as "auto" / "manual".
        if let b = try? c.decode(Bool.self, forKey: .gated) { gated = b }
        else if let s = try? c.decode(String.self, forKey: .gated) { gated = s != "false" }
        else { gated = false }
    }

    var profile: ModelProfile {
        ModelProfile.resolve(repo: id, tags: tags, library: libraryName, pipeline: pipelineTag, files: siblings?.map(\.rfilename))
    }

    var updated: Date? {
        guard let lastModified else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: lastModified) ?? ISO8601DateFormatter().date(from: lastModified)
    }

    var quantLabel: String? {
        let n = id.lowercased()
        for (needle, label) in [("q4", "4-bit"), ("4bit", "4-bit"), ("int4", "4-bit"), ("q5", "5-bit"), ("q6", "6-bit"),
                                ("q8", "8-bit"), ("8bit", "8-bit"), ("int8", "8-bit"), ("bf16", "Full"), ("fp16", "Full")] {
            if n.contains(needle) { return label }
        }
        return nil
    }

    static func == (a: HFModel, b: HFModel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum HFSort: String, CaseIterable, Identifiable {
    case trending = "trendingScore", downloads = "downloads", updated = "lastModified", likes = "likes"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trending: return "Trending"
        case .downloads: return "Most downloaded"
        case .updated: return "Recently updated"
        case .likes: return "Most liked"
        }
    }
}

enum HFError: LocalizedError {
    case unauthorized, gated(String), notFound, http(Int), offline(String), other(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Hugging Face rejected the access token. Check it in Settings."
        case .gated(let repo): return "\(repo) is gated. Accept its terms on huggingface.co, then add your access token in Settings."
        case .notFound: return "That model was not found on Hugging Face."
        case .http(let code): return "Hugging Face returned an error (\(code))."
        case .offline(let why): return "Could not reach Hugging Face: \(why)"
        case .other(let message): return message
        }
    }
}

enum HFClient {
    static let host = "https://huggingface.co"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, authorized: Bool = true) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Mirage-macOS", forHTTPHeaderField: "User-Agent")
        if authorized, let token = TokenStore.load() { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func get(_ url: URL, repo: String? = nil) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request(url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return data
            case 401: throw repo != nil && TokenStore.load() == nil ? HFError.gated(repo!) : HFError.unauthorized
            case 403: throw HFError.gated(repo ?? "This model")
            case 404: throw HFError.notFound
            default: throw HFError.http(code)
            }
        } catch let e as HFError {
            throw e
        } catch {
            throw HFError.offline(error.localizedDescription)
        }
    }

    private static func list(_ items: [URLQueryItem]) async throws -> [HFModel] {
        var comps = URLComponents(string: "\(host)/api/models")!
        comps.queryItems = items + [URLQueryItem(name: "full", value: "true")]
        let data = try await get(comps.url!)
        return try JSONDecoder().decode([HFModel].self, from: data)
    }

    /// Searches MLX-format image and video models only. Several narrow queries run in parallel
    /// because the hub's "mlx" tag is dominated by language models.
    static func searchMLX(query: String, sort: HFSort, limit: Int = 40) async throws -> [HFModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func items(_ extra: [URLQueryItem]) -> [URLQueryItem] {
            var base = [URLQueryItem(name: "sort", value: sort.rawValue), URLQueryItem(name: "direction", value: "-1"),
                        URLQueryItem(name: "limit", value: "\(limit)")]
            if !q.isEmpty { base.append(URLQueryItem(name: "search", value: q)) }
            return base + extra
        }
        var queries: [[URLQueryItem]] = [
            items([URLQueryItem(name: "filter", value: "mflux")]),
            items([URLQueryItem(name: "filter", value: "mlx-video")]),
        ]
        for pipeline in ["text-to-image", "image-to-image", "text-to-video", "image-to-video", "image-text-to-video"] {
            queries.append(items([URLQueryItem(name: "filter", value: "mlx"), URLQueryItem(name: "pipeline_tag", value: pipeline)]))
        }
        if q.isEmpty {
            // Many video packs carry no pipeline tag, so look for the main families by name too.
            for name in ["ltx", "wan2"] {
                queries.append([URLQueryItem(name: "sort", value: sort.rawValue), URLQueryItem(name: "direction", value: "-1"),
                                URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "search", value: name),
                                URLQueryItem(name: "filter", value: "mlx")])
            }
        } else {
            queries.append(items([URLQueryItem(name: "filter", value: "mlx")]))
        }

        var merged: [String: HFModel] = [:]
        var firstError: Error?
        await withTaskGroup(of: Result<[HFModel], Error>.self) { group in
            for query in queries {
                group.addTask {
                    do { return .success(try await list(query)) } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let models): for m in models { merged[m.id] = m }
                case .failure(let e): if firstError == nil { firstError = e }
                }
            }
        }
        if merged.isEmpty, let firstError { throw firstError }
        let all = Array(merged.values)
        switch sort {
        case .trending: return all.sorted { ($0.trendingScore ?? 0, $0.downloads ?? 0) > ($1.trendingScore ?? 0, $1.downloads ?? 0) }
        case .downloads: return all.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
        case .likes: return all.sorted { ($0.likes ?? 0) > ($1.likes ?? 0) }
        case .updated: return all.sorted { ($0.lastModified ?? "") > ($1.lastModified ?? "") }
        }
    }

    /// Searches MLX language models whose names mark them as unlocked (abliterated, uncensored and so on).
    static func searchUnlockedChat(query: String, sort: HFSort, limit: Int = 30) async throws -> [HFModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let markers = ["abliterated", "uncensored", "heretic", "dolphin", "josiefied", "unlocked"]
        let queries: [[URLQueryItem]] = markers.map { marker in
            [URLQueryItem(name: "search", value: q.isEmpty ? marker : "\(q) \(marker)"),
             URLQueryItem(name: "filter", value: "mlx"),
             URLQueryItem(name: "pipeline_tag", value: "text-generation"),
             URLQueryItem(name: "sort", value: sort.rawValue), URLQueryItem(name: "direction", value: "-1"),
             URLQueryItem(name: "limit", value: "\(limit)")]
        }
        var merged: [String: HFModel] = [:]
        var firstError: Error?
        await withTaskGroup(of: Result<[HFModel], Error>.self) { group in
            for query in queries {
                group.addTask { do { return .success(try await list(query)) } catch { return .failure(error) } }
            }
            for await result in group {
                switch result {
                case .success(let models): for m in models where m.profile.isChat { merged[m.id] = m }
                case .failure(let e): if firstError == nil { firstError = e }
                }
            }
        }
        if merged.isEmpty, let firstError { throw firstError }
        let all = Array(merged.values)
        switch sort {
        case .trending: return all.sorted { ($0.trendingScore ?? 0, $0.downloads ?? 0) > ($1.trendingScore ?? 0, $1.downloads ?? 0) }
        case .downloads: return all.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
        case .likes: return all.sorted { ($0.likes ?? 0) > ($1.likes ?? 0) }
        case .updated: return all.sorted { ($0.lastModified ?? "") > ($1.lastModified ?? "") }
        }
    }

    /// Full repo details including every file's size and content hash.
    static func detail(_ repo: String) async throws -> HFModel {
        let escaped = repo.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let url = URL(string: "\(host)/api/models/\(escaped)?blobs=true")!
        let data = try await get(url, repo: repo)
        return try JSONDecoder().decode(HFModel.self, from: data)
    }

    /// The text of a repo's model card, or nil if it has none.
    static func readme(_ repo: String) async -> String? {
        guard let url = URL(string: "\(host)/\(repo)/raw/main/README.md"),
              let (data, response) = try? await session.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data.prefix(200_000), as: UTF8.self)
    }

    /// The refusal rate stated on a model's card, falling back to the card of the model it was converted from.
    static func refusalReport(repo: String, tags: [String]) async -> RefusalReport? {
        if let card = await readme(repo), let report = RefusalParser.parse(card) { return report }
        for base in RefusalParser.baseModels(tags: tags).prefix(2) {
            if let card = await readme(base), var report = RefusalParser.parse(card) {
                report.fromBase = true
                return report
            }
        }
        return nil
    }

    /// Returns the account name for the saved token.
    static func whoami() async throws -> String {
        let data = try await get(URL(string: "\(host)/api/whoami-v2")!)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["name"] as? String) ?? "signed in"
    }

    static func fileURL(repo: String, revision: String, path: String) -> URL {
        let escaped = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(host)/\(repo)/resolve/\(revision)/\(escaped)")!
    }

    static func pageURL(_ repo: String) -> URL { URL(string: "\(host)/\(repo)")! }
}
