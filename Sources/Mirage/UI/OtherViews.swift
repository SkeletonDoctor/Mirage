import SwiftUI

// MARK: - Gallery

struct GalleryView: View {
    @Environment(AppState.self) private var app
    @State private var gallery = Gallery.shared
    @State private var settings = AppSettings.shared
    @State private var kind: MediaKind?
    @State private var opened: GalleryItem?
    @State private var search = ""
    @State private var favoritesOnly = false

    private var filtered: [GalleryItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return gallery.items.filter { item in
            (kind == nil || item.kind == kind)
                && (!favoritesOnly || item.isFavorite)
                && (needle.isEmpty || item.params.prompt.lowercased().contains(needle) || item.params.modelTitle.lowercased().contains(needle))
        }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindFilter(kind: $kind)
                Button(favoritesOnly ? "Showing Favourites" : "Favourites", systemImage: favoritesOnly ? "star.fill" : "star") {
                    withAnimation(.snappy) { favoritesOnly.toggle() }
                }
                .buttonStyle(ChipButtonStyle(selected: favoritesOnly)).help("Show only favourites")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search prompts", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { search = "" }
                            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: 260)
                .glassEffect(.regular, in: Capsule())
                Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button("Images Folder", systemImage: "photo.on.rectangle") { NSWorkspace.shared.open(settings.outputDir(for: .image)) }
                    .buttonStyle(.soft).help("Open the folder images are saved to")
                Button("Videos Folder", systemImage: "film.stack") { NSWorkspace.shared.open(settings.outputDir(for: .video)) }
                    .buttonStyle(.soft).help("Open the folder videos are saved to")
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)

            if items.isEmpty && !gallery.items.isEmpty {
                ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass",
                                       description: Text("Try a different search or filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("Everything you generate is saved and shown here. You can change the folders under This Mac.")
                } actions: {
                    Button("Create Something") { app.section = .create }.buttonStyle(.miragePrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 14)], spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { opened = item } label: {
                                Thumbnail(url: item.url, side: 280)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        HStack(spacing: 4) {
                                            Image(systemName: item.kind == .video ? "play.fill" : "photo")
                                            Text(verbatim: item.kind == .video ? String(format: "%.1fs", item.params.seconds) : "\(item.params.width)×\(item.params.height)")
                                        }
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .glassEffect(.regular, in: Capsule()).padding(8)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if item.isFavorite {
                                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                                .padding(6).background(.black.opacity(0.45), in: Circle()).padding(8)
                                                .transition(.scale.combined(with: .opacity))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .hoverLift(1.035)
                            .appearStagger(index)
                            .help(item.params.prompt)
                            .contextMenu {
                                Button(item.isFavorite ? "Remove Favourite" : "Favourite") { withAnimation(.snappy) { gallery.toggleFavorite(item) } }
                                if item.kind == .image {
                                    Button("Upscale…") { app.upscaleHubItem = item; app.showUpscaleHub = true }
                                }
                                Button("Make Another") { app.makeAnother(of: item) }
                                Button("Reuse Settings") { app.composer.reuse(item.params); app.section = .create }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { withAnimation { gallery.delete(item) } }
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(18)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: items.map(\.id))
                }
            }
        }
        .navigationTitle("Mirage")
        .onChange(of: gallery.items.map(\.id)) { _, ids in
            if let current = opened, !ids.contains(current.id) { opened = nil }
        }
        .sheet(item: $opened) { item in
            VStack(spacing: 0) {
                ResultView(item: gallery.items.first { $0.id == item.id } ?? item)
                    .padding(14)
                HStack { Spacer(); Button("Done") { opened = nil }.buttonStyle(.soft).keyboardShortcut(.defaultAction) }.padding(12)
            }
            .frame(minWidth: 760, minHeight: 600)
        }
    }
}

/// All / Image / Video filter.
struct KindFilter: View {
    @Binding var kind: MediaKind?
    var body: some View {
        SlidingSegments(items: [.init(value: MediaKind?.none, title: "All"),
                                .init(value: MediaKind?.some(.image), title: "Images", symbol: "photo"),
                                .init(value: MediaKind?.some(.video), title: "Videos", symbol: "film")],
                        selection: $kind)
    }
}

// MARK: - This Mac (hardware, settings, engines)

struct EnginesView: View {
    @State private var engines = EngineManager.shared
    @State private var settings = AppSettings.shared
    @State private var monitor = MemoryMonitor.shared

    var body: some View {
        let sys = SystemInfo.current
        let limits = MemoryPlanner.limits(unlocked: settings.unlockLimits)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "cpu").font(.system(size: 30)).mirageGradient()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sys.chip).font(.title3.weight(.semibold))
                                Text("\(Format.gb(sys.totalGB)) unified memory · \(sys.performanceCores) performance + \(sys.efficiencyCores) efficiency cores · macOS \(sys.osVersion)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            row("Usable by a model", "\(Format.gb(MemoryPlanner.budgetGB(override: settings.memoryLimitGB))) of \(Format.gb(sys.totalGB))",
                                settings.memoryLimitGB == 0 ? "Recommended. Change it under Memory below." : "Your own limit. Recommended is \(Format.gb(MemoryPlanner.recommendedBudgetGB())).")
                            row("Free right now", Format.gb(monitor.availableGB),
                                monitor.swapGB > 0.5 ? "Swap in use: \(Format.gb(monitor.swapGB)). Closing apps will speed up generation." : "Memory pressure: \(monitor.pressure.label.lowercased()).")
                            row("Largest image", "\(limits.maxImageSide(multiple: 16)) px on the long side", "About \(String(format: "%.1f", Double(limits.maxImagePixels) / 1_000_000)) megapixels.")
                            row("Longest video", "\(limits.maxFrames) frames", "Up to \(String(format: "%.0f", Double(limits.maxVideoPixels) / 1000))k pixels per frame.")
                        }
                    }
                }
                .appearStagger(0)

                section("Storage", index: 1) { StorageCard() }
                section("Memory", index: 2) { MemoryCard() }
                section("Chat", index: 3) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SwitchRow(title: "Allow models to run their own code",
                                      subtitle: "Some chat models ship a program that runs on your Mac when the model loads. Off, Mirage refuses them.",
                                      isOn: $settings.allowCustomCode)
                            if settings.allowCustomCode {
                                Label("That code runs with your account's full access to your files, and nobody at Mirage or Hugging Face has reviewed it. Only load such models from authors you trust. They are marked “Runs its own code” in the list.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: settings.allowCustomCode)
                    }
                }
                section("Hugging Face", index: 3) { AccountCard() }

                section("Acceleration", index: 4) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            accelerator("GPU and its neural accelerators", sys.gpuName, used: true,
                                        "All model math runs here through MLX and Metal. This is the fastest path for image and video models.")
                            accelerator("CPU", "\(sys.performanceCores + sys.efficiencyCores) cores with Accelerate", used: true,
                                        "Handles loading, tokenising and encoding the finished file.")
                            accelerator("Neural Engine", "Core ML only", used: false,
                                        "Apple exposes it only to Core ML models. MLX models cannot use it, and models this large do not fit its limits.")
                            if !engines.mlxVersion.isEmpty {
                                Text("MLX \(engines.mlxVersion)").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Engines")
                    Text("Each engine lives in its own private Python environment inside Mirage's folder. They are installed automatically when a model needs them.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(EngineSpec.all.enumerated()), id: \.element.id) { index, spec in
                        EngineCard(spec: spec).appearStagger(index + 5)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Mirage")
        .task { await engines.refresh() }
    }

    private func section<Content: View>(_ title: String, index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
        .appearStagger(index)
    }

    private func row(_ title: String, _ value: String, _ note: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func accelerator(_ name: String, _ detail: String, used: Bool, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: used ? "bolt.circle.fill" : "minus.circle")
                .foregroundStyle(used ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary)).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium)
                    Text(detail).foregroundStyle(.secondary)
                    Tag(text: used ? "In use" : "Not used")
                }
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where models, images and videos are kept.
struct StorageCard: View {
    @State private var settings = AppSettings.shared
    @State private var store = ModelStore.shared
    @State private var downloads = DownloadManager.shared
    @State private var queue = JobQueue.shared
    @State private var pendingModelsFolder: URL?
    @State private var problem: String?

    private var modelsBusy: Bool { store.relocating || downloads.activeCount > 0 || queue.current != nil }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                FolderRow(title: "Models", symbol: "shippingbox", path: Paths.hfHub.path,
                          note: modelsNote, busy: store.relocating) {
                    guard let url = pickFolder(startingAt: Paths.hfHub) else { return }
                    if store.models.isEmpty { move(to: url, moveExisting: false) } else { pendingModelsFolder = url }
                }
                .disabled(modelsBusy && !store.relocating)
                if !settings.modelsPath.isEmpty && !modelsBusy {
                    Button("Use the standard Hugging Face folder again") {
                        if store.models.isEmpty { move(to: Paths.defaultHFHub, moveExisting: false) } else { pendingModelsFolder = Paths.defaultHFHub }
                    }
                    .buttonStyle(.softSmall).padding(.leading, 46)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                FolderRow(title: "Images", symbol: "photo.on.rectangle", path: settings.imagePath) {
                    if let url = pickFolder(startingAt: URL(fileURLWithPath: settings.imagePath)) { settings.imagePath = url.path }
                }
                Divider()
                FolderRow(title: "Videos", symbol: "film.stack", path: settings.videoPath) {
                    if let url = pickFolder(startingAt: URL(fileURLWithPath: settings.videoPath)) { settings.videoPath = url.path }
                }
                Text("New generations go to these folders. Files you already made stay where they are and still appear in the Gallery.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy(duration: 0.3), value: store.relocating)
        .animation(.snappy(duration: 0.3), value: settings.modelsPath)
        .confirmationDialog("Move your models to the new folder?",
                            isPresented: Binding(get: { pendingModelsFolder != nil }, set: { if !$0 { pendingModelsFolder = nil } })) {
            Button("Move \(store.models.count) Model\(store.models.count == 1 ? "" : "s")") {
                if let url = pendingModelsFolder { move(to: url, moveExisting: true) }
            }
            Button("Switch Without Moving") {
                if let url = pendingModelsFolder { move(to: url, moveExisting: false) }
            }
            Button("Cancel", role: .cancel) { pendingModelsFolder = nil }
        } message: {
            Text("Moving keeps your \(Format.bytes(store.totalBytes)) of models usable from \((pendingModelsFolder?.path ?? "") as NSString).abbreviatingWithTildeInPath. Switching without moving leaves them in the old folder, and they will need downloading again here.")
        }
    }

    private var modelsNote: String {
        if store.relocating { return "Moving models…" }
        if downloads.activeCount > 0 { return "Finish or pause downloads before changing this folder." }
        if queue.current != nil { return "Wait for the current generation before changing this folder." }
        let kind = settings.modelsPath.isEmpty ? "Standard Hugging Face cache, shared with other tools" : "Custom folder, Hugging Face cache layout"
        return "\(store.models.count) model\(store.models.count == 1 ? "" : "s") · \(Format.bytes(store.totalBytes)) · \(kind)"
    }

    private func move(to url: URL, moveExisting: Bool) {
        pendingModelsFolder = nil
        problem = nil
        Task { problem = await store.relocate(to: url, moveExisting: moveExisting) }
    }

    private func pickFolder(startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct MemoryCard: View {
    @State private var settings = AppSettings.shared
    var body: some View {
        @Bindable var settings = settings
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SwitchRow(title: "Adjust settings to fit this Mac's memory",
                          subtitle: "Picks low-memory modes, tiled decoding and cache limits for each generation, and caps size and length.",
                          isOn: $settings.autoMemory)
                Divider()
                MemoryLimitControls()
                Divider()
                SwitchRow(title: "Stop a generation when memory becomes critical",
                          subtitle: "Protects the rest of your Mac if a model outgrows its memory.", isOn: $settings.stopOnCritical)
                Divider()
                SwitchRow(title: "Moving backdrop",
                          subtitle: "Pauses on its own while a model is working or the window is in the background. Turn it off to use the least possible power.",
                          isOn: $settings.animatedBackdrop)
            }
        }
    }
}

/// The memory limit slider and the size-limit switch. Used on This Mac and from the memory card on Create.
struct MemoryLimitControls: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings
        let total = SystemInfo.current.totalGB
        let recommended = MemoryPlanner.recommendedBudgetGB()
        let current = MemoryPlanner.budgetGB(override: settings.memoryLimitGB)
        let raised = current > recommended + 0.25
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory a model may use")
                Spacer()
                Text(settings.memoryLimitGB == 0 ? "Recommended · \(Format.gb(recommended))" : "\(Format.gb(current)) of \(Format.gb(total))")
                    .foregroundStyle(raised ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).monospacedDigit().contentTransition(.numericText())
            }
            MirageSlider(value: Binding(get: { current }, set: { settings.memoryLimitGB = ($0 * 2).rounded() / 2 }),
                         range: min(4, total / 2)...total, step: 0.5, marker: recommended,
                         tint: raised ? AnyShapeStyle(LinearGradient(colors: [Brand.violet, .orange], startPoint: .leading, endPoint: .trailing))
                                      : AnyShapeStyle(Brand.gradient))
            HStack(alignment: .top) {
                Group {
                    if raised {
                        Label("Above the recommended \(Format.gb(recommended)) (the mark on the track). Bigger models and sizes are allowed, but macOS may swap to disk and slow down, and other apps may be pushed out of memory.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if current < recommended - 0.25 {
                        Text("Below the recommended \(Format.gb(recommended)): leaves more room for your other apps.").foregroundStyle(.secondary)
                    } else {
                        Text("The rest of the \(Format.gb(total)) is kept for macOS and your other apps. Drag right to allow more.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if settings.memoryLimitGB != 0 {
                    Button("Reset") { withAnimation { settings.memoryLimitGB = 0 } }.buttonStyle(.softSmall)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            SwitchRow(title: "Allow sizes and lengths beyond the recommended caps", isOn: $settings.unlockLimits)
        }
        .animation(.snappy(duration: 0.25), value: settings.memoryLimitGB)
    }
}

struct AccountCard: View {
    @State private var token = ""
    @State private var status: String?
    @State private var ok = false
    @State private var busy = false
    @State private var hasToken = TokenStore.load() != nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SecureField("Access token", text: $token, prompt: Text(hasToken ? "A token is saved" : "hf_…"))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.primary.opacity(0.07), in: Capsule())
                        .onSubmit { Task { await save() } }
                    Button("Save and Verify") { Task { await save() } }
                        .buttonStyle(.miragePrimary).disabled(token.isEmpty || busy)
                    if hasToken {
                        Button("Remove", role: .destructive) {
                            TokenStore.delete(); hasToken = false; status = "Token removed."; ok = false
                        }
                        .buttonStyle(.soft)
                    }
                }
                if let status {
                    Label(status, systemImage: ok ? "checkmark.circle.fill" : "info.circle").font(.caption)
                        .foregroundStyle(ok ? .green : .secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HStack {
                    Text("Only needed for gated models such as LTX-2.5. A read-only token is enough. It is kept in a file only your Mac account can read and is sent only to huggingface.co.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Link("Create a token", destination: URL(string: "https://huggingface.co/settings/tokens")!).font(.caption)
                }
            }
            .animation(.snappy(duration: 0.25), value: status)
        }
        .task { if hasToken { await verify() } }
    }

    private func save() async {
        guard !token.isEmpty else { return }
        TokenStore.save(token)
        token = ""
        hasToken = TokenStore.load() != nil
        await verify()
    }

    private func verify() async {
        busy = true
        defer { busy = false }
        do {
            let name = try await HFClient.whoami()
            status = "Signed in as \(name)."; ok = true
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; ok = false
        }
    }
}

struct EngineCard: View {
    let spec: EngineSpec
    @State private var engines = EngineManager.shared
    @State private var showLog = false
    @State private var confirmRemove = false

    var body: some View {
        let state = engines.state(spec.id)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(spec.title).font(.headline)
                            statusTag(state)
                        }
                        Text(spec.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch state {
                    case .notInstalled, .failed:
                        Button("Install") { Task { await engines.ensureInstalled(spec.id) } }.buttonStyle(.miragePrimary)
                    case .installing:
                        ProgressView().controlSize(.small)
                    case .installed:
                        Button("Update") { Task { await engines.update(spec.id) } }.buttonStyle(.softSmall)
                            .help("Check for a newer version of this engine")
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = true }
                            .buttonStyle(IconButtonStyle(size: 26)).help("Remove this engine")
                    }
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let log = engines.logs[spec.id], !log.isEmpty {
                    Button(showLog ? "Hide install log" : "Show install log") { withAnimation(.snappy) { showLog.toggle() } }
                        .buttonStyle(.softSmall)
                    if showLog || state.isBusy { LogView(text: String(log.suffix(4000))).frame(height: 130).transition(.opacity) }
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: state)
        .confirmationDialog("Remove the \(spec.title) engine?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { engines.uninstall(spec.id) }
        } message: { Text("Your models stay on disk. The engine is reinstalled the next time it is needed.") }
    }

    @ViewBuilder
    private func statusTag(_ state: EngineState) -> some View {
        switch state {
        case .installed(let v): Tag(text: "v\(v)", symbol: "checkmark.circle.fill")
        case .installing(let step): Tag(text: step)
        case .notInstalled: Tag(text: "Not installed")
        case .failed: Tag(text: "Failed", symbol: "exclamationmark.triangle.fill")
        }
    }
}
