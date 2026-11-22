import SwiftUI

enum ModelsTab: String, CaseIterable, Identifiable {
    case recommended = "Recommended", huggingFace = "Hugging Face", chat = "Chat", installed = "Installed"
    var id: String { rawValue }
}

struct ModelsView: View {
    @Environment(AppState.self) private var app
    @State private var kind: MediaKind?

    var body: some View {
        @Bindable var app = app
        let tab = app.modelsTab
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SlidingSegments(items: [.init(value: ModelsTab.recommended, title: "Recommended", symbol: "star"),
                                        .init(value: ModelsTab.huggingFace, title: "Hugging Face", symbol: "globe"),
                                        .init(value: ModelsTab.chat, title: "Chat", symbol: "bubble.left.and.bubble.right"),
                                        .init(value: ModelsTab.installed, title: "Installed", symbol: "internaldrive")],
                                selection: $app.modelsTab)
                Spacer()
                // The image and video filter does not apply to chat models.
                if tab != .chat {
                    KindFilter(kind: $kind).transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)
            Group {
                switch tab {
                case .recommended: RecommendedView(kind: kind)
                case .huggingFace: HuggingFaceView(kind: kind)
                case .chat: ChatModelsView()
                case .installed: InstalledView(kind: kind)
                }
            }
            .id(tab)
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.32), value: tab)
        .navigationTitle("Mirage")
    }
}

// MARK: - Recommended

struct RecommendedView: View {
    let kind: MediaKind?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 480), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(Array(Catalog.models.filter { kind == nil || $0.kind == kind }.enumerated()), id: \.element.id) { index, model in
                    CatalogCard(model: model)
                        .hoverLift(1.015)
                        .appearStagger(index)
                }
            }
            .padding(18)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: kind)
        }
    }
}

struct CatalogCard: View {
    @Environment(AppState.self) private var app
    let model: CatalogModel
    @State private var variant: ModelVariant
    @State private var store = ModelStore.shared
    @State private var settings = AppSettings.shared
    private let best: ModelVariant

    init(model: CatalogModel) {
        self.model = model
        let pick = MemoryPlanner.bestVariant(for: model, memoryLimitGB: AppSettings.shared.memoryLimitGB)
        best = pick
        // Show the variant that is already on disk, if there is one.
        let installed = model.variants.first { ModelStore.shared.isInstalled($0.repo) }
        _variant = State(initialValue: installed ?? pick)
    }

    var body: some View {
        let fit = MemoryPlanner.fit(variant: variant, profile: model.profile, memoryLimitGB: settings.memoryLimitGB)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.kind.symbol)
                        .font(.title2).frame(width: 38, height: 38).mirageGradient()
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(model.maker).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(model.blurb).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowTags(tags: model.abilities)

                HStack(spacing: 8) {
                    FitBadge(fit: fit, compact: true)
                    Text(Format.gb(variant.downloadGB + model.companionGB) + " download")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                .animation(.snappy(duration: 0.25), value: variant)
                if model.variants.count > 1 {
                    Picker("Variant", selection: $variant) {
                        ForEach(model.variants) { v in
                            Text(v.repo == best.repo ? "\(v.quant) · best for this Mac" : v.quant).tag(v)
                        }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Tag(text: variant.quant)
                }
                if let note = model.note {
                    Label(note, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DownloadControl(repo: variant.repo, title: model.name, companions: model.companions,
                                tags: ["mlx"], library: nil, blocked: fit == .tooLarge && !settings.unlockLimits)
            }
        }
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { ForEach(tags, id: \.self) { Tag(text: $0) } }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) { ForEach(tags.prefix(2), id: \.self) { Tag(text: $0) } }
                HStack(spacing: 5) { ForEach(tags.dropFirst(2), id: \.self) { Tag(text: $0) } }
            }
        }
    }
}

/// Download / progress / Use button for one repo.
struct DownloadControl: View {
    @Environment(AppState.self) private var app
    let repo: String
    let title: String
    var companions: [String] = []
    var excluded: Set<String>? = nil
    var tags: [String] = []
    var library: String? = nil
    var blocked = false
    @State private var store = ModelStore.shared
    @State private var downloads = DownloadManager.shared

    var body: some View {
        if let installed = store.model(repo) {
            HStack {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Spacer()
                if installed.profile.isTool {
                    Text("Use it from a result's Upscale button").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(installed.profile.isChat ? "Chat" : "Use") { app.use(installed) }.buttonStyle(.miragePrimary)
                }
            }
        } else if let task = downloads.task(for: repo), task.state != .completed {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView(value: task.fraction).animation(.easeOut(duration: 0.4), value: task.fraction)
                    if task.state.isActive {
                        Button { downloads.pause(task) } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause")
                    } else {
                        Button { downloads.resume(task) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Resume")
                    }
                    Button { downloads.remove(task) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Cancel")
                }
                Text(status(task)).font(.caption).monospacedDigit()
                    .foregroundStyle(isFailed(task) ? .red : .secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack {
                if blocked {
                    Text("Too large for this Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download", systemImage: "arrow.down.circle") {
                    downloads.start(repo: repo, title: title, excluded: excluded, companions: companions, tags: tags, library: library)
                }
                .buttonStyle(.soft)
                .disabled(blocked)
            }
        }
    }

    private func isFailed(_ t: DownloadTask) -> Bool { if case .failed = t.state { return true }; return false }
    private func status(_ t: DownloadTask) -> String {
        switch t.state {
        case .failed(let m): return m
        case .paused: return "Paused · \(Format.bytes(t.receivedBytes)) of \(Format.bytes(t.totalBytes))"
        case .preparing, .queued: return "Preparing…"
        default:
            var s = "\(Format.bytes(t.receivedBytes)) of \(Format.bytes(t.totalBytes))"
            if t.speed > 1000 { s += " · \(Format.bytes(Int64(t.speed)))/s" }
            if let eta = t.etaSeconds { s += " · \(Format.duration(eta)) left" }
            return s
        }
    }
}

// MARK: - Hugging Face browser

@Observable @MainActor
final class HFBrowser {
    var query = ""
    var sort: HFSort = .trending
    var runnableOnly = true
    var results: [HFModel] = []
    var loading = false
    var error: String?
    private var loadedKey = ""

    func load(force: Bool = false) async {
        let key = "\(query)|\(sort.rawValue)"
        if !force && key == loadedKey && !results.isEmpty { return }
        loading = true
        error = nil
        do {
            let found = try await HFClient.searchMLX(query: query, sort: sort)
            if Task.isCancelled { return }
            results = found
            loadedKey = key
        } catch {
            if Task.isCancelled { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

struct HuggingFaceView: View {
    let kind: MediaKind?
    @State private var browser = HFBrowser()
    @State private var selected: HFModel?

    private var visible: [HFModel] {
        browser.results.filter { m in
            let p = m.profile
            if browser.runnableOnly && !p.isRunnable { return false }
            if let kind {
                if p.isRunnable { return p.kind == kind }
                let pipe = m.pipelineTag ?? ""
                return kind == .video ? pipe.contains("video") : pipe.contains("image") && !pipe.contains("video")
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search MLX image and video models", text: $browser.query)
                        .textFieldStyle(.plain)
                    if browser.loading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                Picker("Sort", selection: $browser.sort) {
                    ForEach(HFSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Toggle("Runnable here", isOn: $browser.runnableOnly)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Only show models one of Mirage's engines can run")
                Button { Task { await browser.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Refresh from Hugging Face")
            }
            .padding(.horizontal, 18).padding(.vertical, 8)

            if let error = browser.error, browser.results.isEmpty {
                ContentUnavailableView {
                    Label("Could not load models", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await browser.load(force: true) } }
                }
            } else if visible.isEmpty && !browser.loading {
                ContentUnavailableView("No matching MLX models", systemImage: "magnifyingglass",
                                       description: Text("Try a different search, or turn off “Runnable here”."))
            } else {
                List(visible) { model in
                    HFRow(model: model)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = model }
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .animation(.smooth(duration: 0.3), value: visible.map(\.id))
                .glassPanel(cornerRadius: 22)
                .padding(.horizontal, 18).padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .task(id: "\(browser.query)|\(browser.sort.rawValue)") {
            try? await Task.sleep(nanoseconds: browser.query.isEmpty ? 0 : 400_000_000)
            if Task.isCancelled { return }
            await browser.load()
        }
        .sheet(item: $selected) { HFDetailSheet(summary: $0) }
    }
}

struct HFRow: View {
    let model: HFModel
    @State private var store = ModelStore.shared

    var body: some View {
        let profile = model.profile
        HStack(spacing: 12) {
            Image(systemName: profile.isRunnable ? profile.kind.symbol : "questionmark.square.dashed")
                .font(.title3).frame(width: 30).foregroundStyle(profile.isRunnable ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.id.split(separator: "/").last.map(String.init) ?? model.id).fontWeight(.medium).lineLimit(1)
                    if model.gated { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary).help("Gated: needs a Hugging Face login") }
                    if store.isInstalled(model.id) { Image(systemName: "checkmark.circle.fill").imageScale(.small).foregroundStyle(.green) }
                }
                HStack(spacing: 5) {
                    Text(model.id.split(separator: "/").first.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary)
                    Tag(text: profile.isRunnable ? profile.label : "Not supported yet")
                    if let q = model.quantLabel { Tag(text: q) }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Label(Format.count(model.downloads ?? 0), systemImage: "arrow.down.to.line").frame(width: 66, alignment: .leading)
                Label(Format.count(model.likes ?? 0), systemImage: "heart").frame(width: 52, alignment: .leading)
                Text(model.updated.map(relativeDate) ?? "").frame(width: 62, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct HFDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let summary: HFModel
    @State private var detail: HFModel?
    @State private var error: String?
    @State private var excluded: Set<String> = []
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.id).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        let p = (detail ?? summary).profile
                        Tag(text: p.isRunnable ? "\(p.label) · \(p.engine?.rawValue ?? "")" : "Not supported yet")
                        if let q = summary.quantLabel { Tag(text: q) }
                        if summary.gated { Tag(text: "Gated", symbol: "lock.fill") }
                    }
                }
                Spacer()
                Button("Open on Hugging Face", systemImage: "safari") { openURL(HFClient.pageURL(summary.id)) }.buttonStyle(.soft)
            }
            .padding(18)
            Divider()

            if let detail, let files = detail.siblings {
                let profile = detail.profile
                let chosen = files.filter { !excluded.contains($0.rfilename) }
                let total = chosen.reduce(Int64(0)) { $0 + $1.bytes }
                let footprint = ModelFootprint.estimate(family: profile.family, files: chosen.map { ($0.rfilename, $0.bytes) })
                let plan = MemoryPlanner.plan(footprint: footprint, profile: profile, width: profile.defaultWidth,
                                              height: profile.defaultHeight, frames: profile.kind == .video ? 49 : 1,
                                              auto: true, memoryLimitGB: settings.memoryLimitGB)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(chosen.count) of \(files.count) files · \(Format.bytes(total))").font(.callout.weight(.medium))
                        Spacer()
                        if profile.isRunnable { FitBadge(fit: plan.fit) }
                    }
                    if profile.isRunnable {
                        Text("Estimated memory while running: about \(Format.gb(plan.peakGB)) of \(Format.gb(plan.budgetGB)) usable.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("None of Mirage's engines recognise this model's layout, so it cannot be run here yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if summary.gated {
                        Label("Gated model: accept its terms on Hugging Face and add your token in Settings before downloading.",
                              systemImage: "lock").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                List(files.sorted { $0.bytes > $1.bytes }, id: \.rfilename) { file in
                    Toggle(isOn: Binding(get: { !excluded.contains(file.rfilename) },
                                         set: { if $0 { excluded.remove(file.rfilename) } else { excluded.insert(file.rfilename) } })) {
                        HStack {
                            Text(file.rfilename).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(file.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Button("Close") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                    Spacer()
                    DownloadControl(repo: detail.id, title: detail.id.split(separator: "/").last.map(String.init) ?? detail.id,
                                    excluded: excluded, tags: detail.tags, library: detail.libraryName,
                                    blocked: !profile.isRunnable)
                        .frame(maxWidth: 360)
                }
                .padding(14)
            } else if let error {
                ContentUnavailableView("Could not load this model", systemImage: "exclamationmark.triangle", description: Text(error))
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(14)
            } else {
                ProgressView("Reading file list…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 560)
        .task {
            do {
                let d = try await HFClient.detail(summary.id)
                excluded = defaultExcludedFiles(repo: d.id, family: d.profile.family, files: d.siblings?.map(\.rfilename) ?? [])
                detail = d
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Installed

struct InstalledView: View {
    @Environment(AppState.self) private var app
    let kind: MediaKind?
    @State private var store = ModelStore.shared

    var body: some View {
        // Image and video models (and the upscaler) follow the kind filter; chat models have their own group.
        let media = store.models.filter { !$0.profile.isChat && (kind == nil || $0.kind == kind) }
        let chat = kind == nil ? store.chatModels : []
        Group {
            if media.isEmpty && chat.isEmpty {
                ContentUnavailableView("Nothing installed", systemImage: "shippingbox",
                                       description: Text("Models you download appear here. Compatible models already in your Hugging Face cache are picked up too."))
            } else {
                List {
                    if !media.isEmpty {
                        Section("Images and video") {
                            ForEach(media) { InstalledRow(model: $0).listRowBackground(Color.clear) }
                        }
                    }
                    if !chat.isEmpty {
                        Section("Chat") {
                            ForEach(chat) { InstalledRow(model: $0).listRowBackground(Color.clear) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .glassPanel(cornerRadius: 22)
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .task { await store.refresh() }
    }
}

/// One installed model: what it is, whether it fits, and the actions on it.
struct InstalledRow: View {
    @Environment(AppState.self) private var app
    let model: InstalledModel
    @State private var store = ModelStore.shared
    @State private var settings = AppSettings.shared
    @State private var confirmDelete = false

    var body: some View {
        let fit: FitLevel = model.profile.isChat
            ? MemoryPlanner.chatFit(residentGB: model.footprint.residentGB, memoryLimitGB: settings.memoryLimitGB)
            : MemoryPlanner.plan(footprint: model.footprint, profile: model.profile, width: model.profile.defaultWidth,
                                 height: model.profile.defaultHeight, frames: model.kind == .video ? 49 : 1,
                                 auto: true, memoryLimitGB: settings.memoryLimitGB).fit
        HStack(spacing: 12) {
            Image(systemName: model.profile.isChat ? "bubble.left.and.bubble.right" : model.profile.isTool ? "arrow.up.left.and.arrow.down.right" : model.kind.symbol)
                .font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(model.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Tag(text: model.profile.label)
                    if let q = model.quantLabel { Tag(text: q) }
                }
            }
            Spacer()
            FitBadge(fit: fit, compact: true)
            Text(Format.bytes(model.sizeBytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if !model.profile.isTool {
                Button(model.profile.isChat ? "Chat" : "Use") { app.use(model) }.buttonStyle(.miragePrimary)
            }
            Menu {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.snapshot]) }
                Button("Open on Hugging Face", systemImage: "safari") { NSWorkspace.shared.open(HFClient.pageURL(model.repo)) }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(model.title)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                if model.repo == ChatEngine.shared.loadedRepo { ChatEngine.shared.unload(reason: nil) }
                Task { await store.delete(model) }
            }
        } message: {
            Text("Its \(Format.bytes(model.sizeBytes)) of files move to the Trash. You can download it again later.")
        }
    }
}

// MARK: - Chat models

/// The Chat section of Models: installed chat models first, then unlocked ones to download.
struct ChatModelsView: View {
    @State private var search = ChatModelSearch()
    @State private var store = ModelStore.shared

    var body: some View {
        let installed = store.chatModels
        let installedIDs = Set(installed.map(\.repo))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search unlocked chat models, for example qwen or gemma", text: $search.query).textFieldStyle(.plain)
                    if search.loading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                Picker("Sort", selection: $search.sort) {
                    ForEach(HFSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button { Task { await search.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 28)).help("Refresh from Hugging Face")
            }
            .padding(.horizontal, 18).padding(.vertical, 8)

            if let error = search.error, search.results.isEmpty, installed.isEmpty {
                ContentUnavailableView {
                    Label("Could not load models", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await search.load() } }.buttonStyle(.soft)
                }
            } else {
                List {
                    if !installed.isEmpty {
                        Section("Installed") {
                            ForEach(installed) { InstalledRow(model: $0).listRowBackground(Color.clear) }
                        }
                    }
                    Section {
                        ForEach(search.results.filter { !installedIDs.contains($0.id) }) { model in
                            ChatModelRow(model: model, search: search).listRowBackground(Color.clear)
                        }
                        if search.results.isEmpty && !search.loading {
                            Text("No matching models. Try a different search.").foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Unlocked models on Hugging Face")
                    } footer: {
                        Text("Only MLX language models labelled abliterated, uncensored or similar are listed. Sizes and fit are for this \(SystemInfo.current.chip) with \(Format.gb(SystemInfo.current.totalGB)).")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .glassPanel(cornerRadius: 22)
                .padding(.horizontal, 18).padding(.bottom, 16)
            }
        }
        .task(id: "\(search.query)|\(search.sort.rawValue)") {
            try? await Task.sleep(nanoseconds: search.query.isEmpty ? 0 : 400_000_000)
            if Task.isCancelled { return }
            await search.load()
        }
        .task { await store.refresh() }
    }
}
