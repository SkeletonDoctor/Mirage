import SwiftUI
import AVKit

struct CreateView: View {
    @Environment(AppState.self) private var app

    @State private var store = ModelStore.shared

    var body: some View {
        ZStack {
            if !store.loaded {
                ProgressView().controlSize(.large)
            } else if store.generators.isEmpty {
                QuickStartView().transition(.blurReplace)
            } else {
                HStack(spacing: 14) {
                    ComposerPanel()
                        .frame(width: 364)
                        .glassPanel()
                    CanvasView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(14)
                .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.5), value: store.generators.isEmpty)
        .animation(.smooth(duration: 0.3), value: store.loaded)
        .navigationTitle("Mirage")
    }
}

/// First-run screen: three picks that suit this Mac, one click each.
struct QuickStartView: View {
    @Environment(AppState.self) private var app
    @State private var float = false

    private var picks: [CatalogModel] {
        let wanted = ["z-image-turbo", "flux2-klein-4b", "ltx-2.3"]
        return wanted.compactMap { id in Catalog.models.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 54, weight: .light)).mirageGradient()
                        .scaleEffect(float ? 1 : 0.7).opacity(float ? 1 : 0)
                        .shadow(color: Brand.violet.opacity(0.6), radius: 18)
                        .animation(.spring(response: 0.6, dampingFraction: 0.6), value: float)
                    Text("Welcome to Mirage").font(.largeTitle.weight(.semibold))
                    Text("Pick a model to start. It downloads once, then everything runs on this \(SystemInfo.current.chip) — nothing is sent anywhere.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
                }
                .padding(.top, 26)
                .appearStagger(0)

                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, model in
                        CatalogCard(model: model).hoverLift(1.015).appearStagger(index + 1)
                    }
                }
                .frame(maxWidth: 1080)

                Button("See All Models", systemImage: "shippingbox") { app.section = .models }
                    .buttonStyle(.soft).appearStagger(5)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .onAppear { float = true }
    }
}

// MARK: - Composer

struct ComposerPanel: View {
    @Environment(AppState.self) private var app
    @State private var store = ModelStore.shared
    @State private var queue = JobQueue.shared
    @State private var settings = AppSettings.shared
    @State private var generateTaps = 0
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var c = app.composer
        let profile = c.profile
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelPicker

                    if c.model != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                SectionLabel("Prompt")
                                Spacer()
                                if !c.prompt.isEmpty {
                                    Button("Clear", systemImage: "xmark") { withAnimation(.snappy(duration: 0.2)) { c.prompt = "" } }
                                        .buttonStyle(IconButtonStyle(size: 22)).help("Clear the prompt")
                                        .transition(.scale.combined(with: .opacity))
                                }
                                if !settings.recentPrompts.isEmpty {
                                    Menu {
                                        ForEach(settings.recentPrompts, id: \.self) { past in
                                            Button(past.count > 70 ? String(past.prefix(70)) + "…" : past) { c.prompt = past }
                                        }
                                        Divider()
                                        Button("Clear History") { settings.recentPrompts = [] }
                                    } label: {
                                        Image(systemName: "clock.arrow.circlepath")
                                    }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .help("Recent prompts")
                                }
                                Button { withAnimation(.snappy(duration: 0.25)) { c.suggestIdea() } } label: {
                                    Label("Idea", systemImage: "dice")
                                }
                                .buttonStyle(.softSmall).help("Fill in a sample prompt")
                            }
                            .animation(.snappy(duration: 0.2), value: c.prompt.isEmpty)
                            TextEditor(text: $c.prompt)
                                .font(.body)
                                .focused($promptFocused)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 96, maxHeight: 180)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Brand.gradient, lineWidth: promptFocused ? 1.5 : 0)
                                    .animation(.easeOut(duration: 0.2), value: promptFocused))
                                .overlay(alignment: .topLeading) {
                                    if c.prompt.isEmpty {
                                        Text(profile.kind == .video ? "A slow dolly shot through a neon-lit market in the rain…"
                                             : "A weathered lighthouse at dawn, mist rolling over the rocks…")
                                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                }
                            if profile.supportsNegative {
                                TextField("Things to avoid (optional)", text: $c.negativePrompt, axis: .vertical)
                                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                            }
                            HStack(spacing: 8) {
                                Text("Style").font(.caption).foregroundStyle(.secondary).fixedSize()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(StylePreset.allCases) { style in
                                            Button(style.rawValue) { c.style = style }
                                                .buttonStyle(ChipButtonStyle(selected: c.style == style))
                                                .help(style == .none ? "Use the prompt exactly as written" : "Adds: \(style.suffix)")
                                        }
                                    }
                                    .padding(.vertical, 2).padding(.trailing, 14)
                                }
                                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                            }
                        }

                        if profile.imageInput != .none || profile.audioInput {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel("Inputs")
                                if profile.imageInput != .none {
                                    FileWell(title: imageWellTitle(profile), symbol: "photo.badge.plus",
                                             allowed: FileKinds.images, path: $c.inputImage)
                                    if c.inputImage != nil && profile.family == .mflux && profile.editCommand == nil {
                                        LabeledSlider(title: "Change", value: $c.imageStrength, range: 0.1...0.95, step: 0.05,
                                                      display: "\(Int(c.imageStrength * 100))%")
                                            .help("How far the result may move away from the input image.")
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                if profile.audioInput {
                                    FileWell(title: "Audio to drive the video", symbol: "waveform.badge.plus",
                                             allowed: FileKinds.audio, path: $c.inputAudio, showsPreview: false)
                                }
                            }
                            .animation(.snappy(duration: 0.28), value: c.inputImage)
                        }

                        shapeSection(profile: profile)
                        qualitySection(profile: profile)
                        if let plan = c.plan { MemoryPlanCard(plan: plan) }
                    }
                }
                .padding(18)
                .animation(.snappy(duration: 0.3), value: c.model?.repo)
            }
            .scrollIndicators(.never)
            generateBar
        }
    }

    private func imageWellTitle(_ p: ModelProfile) -> String {
        if p.kind == .video { return "First frame (image to video)" }
        if p.editCommand != nil || p.imageInput == .required { return "Image to edit" }
        return "Starting image"
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Model")
            if store.generators.isEmpty {
                Card(inset: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No models installed yet", systemImage: "shippingbox").font(.headline)
                        Text("Pick one that fits this Mac. Mirage sets up the engine it needs on its own.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Browse Models") { app.section = .models }
                            .buttonStyle(.miragePrimary)
                    }
                }
            } else {
                Menu {
                    ForEach(MediaKind.allCases) { kind in
                        let group = store.generators.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section(kind.title) {
                                ForEach(group) { m in
                                    Button { app.composer.select(m) } label: {
                                        Label("\(m.title)\(m.quantLabel.map { " · \($0)" } ?? "")", systemImage: kind.symbol)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Get More Models…") { app.section = .models }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: app.composer.profile.kind.symbol)
                            .font(.title3).frame(width: 30, height: 30).mirageGradient()
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.composer.model?.title ?? "Choose a model").fontWeight(.medium).lineLimit(1)
                            if let m = app.composer.model {
                                Text([m.profile.label, m.quantLabel, Format.bytes(m.sizeBytes)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary).imageScale(.small)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func shapeSection(profile: ModelProfile) -> some View {
        @Bindable var c = app.composer
        let size = c.size
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(profile.kind == .video ? "Frame" : "Size")
                Spacer()
                Text(verbatim: profile.kind == .image
                     ? String(format: "%d × %d · %.1f MP", size.width, size.height, Double(size.width * size.height) / 1_000_000)
                     : "\(size.width) × \(size.height)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: size.width * 10_000 + size.height)
            }
            AspectPicker(selection: $c.aspect)
            if c.maxLongSide > c.minLongSide {
                MirageSlider(value: $c.longSide, range: c.minLongSide...c.maxLongSide, step: Double(profile.sizeMultiple))
            }
            if profile.kind == .image {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sizePresets(c), id: \.self) { side in
                            Button(String(side)) {
                                withAnimation(.snappy(duration: 0.25)) { c.longSide = Double(side) }
                            }
                            .buttonStyle(ChipButtonStyle(selected: Int(c.longSide) == side))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if profile.kind == .video {
                LabeledSlider(title: "Length", value: $c.seconds, range: 1...max(1.5, c.maxSeconds), step: 0.5,
                              display: String(format: "%.1f s · %d frames", Double(c.frames) / Double(profile.fps), c.frames))
                if profile.generatesAudio && c.inputAudio == nil {
                    SwitchRow(title: "Generate sound", isOn: $c.withAudio).font(.callout)
                }
            }
            HStack {
                Text(profile.kind == .video ? "How many clips" : "How many images").font(.callout)
                Spacer()
                CountStepper(value: $c.count, range: 1...(profile.kind == .video ? 4 : 8))
            }
            .help("Each one gets its own seed and they run one after another.")
            if settings.autoMemory && !settings.unlockLimits {
                Text(profile.kind == .video
                     ? "Capped for \(Format.gb(SystemInfo.current.totalGB)) of memory: up to \(c.limits.maxFrames) frames."
                     : "Up to \(Int(c.maxLongSide)) px on this Mac. Large sizes switch to low-memory mode and take longer.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Long-side shortcuts that are valid for the current model and limits.
    private func sizePresets(_ c: Composer) -> [Int] {
        [1024, 1536, 2048, 2560, 3072, 4096].filter { Double($0) <= c.maxLongSide && Double($0) >= c.minLongSide }
    }

    @ViewBuilder
    private func qualitySection(profile: ModelProfile) -> some View {
        @Bindable var c = app.composer
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if profile.family == .mflux || profile.family == .wan {
                    SwitchRow(title: "Automatic steps", isOn: $c.autoSteps).font(.callout)
                    if !c.autoSteps {
                        LabeledSlider(title: "Steps", value: $c.steps, range: 1...60, step: 1, display: "\(Int(c.steps))")
                    }
                }
                if profile.supportsGuidance {
                    SwitchRow(title: "Automatic guidance", isOn: $c.autoGuidance).font(.callout)
                    if !c.autoGuidance {
                        LabeledSlider(title: "Guidance", value: $c.guidance, range: 1...10, step: 0.5,
                                      display: String(format: "%.1f", c.guidance))
                    }
                }
                SwitchRow(title: "Random seed", isOn: $c.randomSeed).font(.callout)
                if !c.randomSeed {
                    TextField("Seed", text: $c.seedText).textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 8)
            .animation(.snappy(duration: 0.25), value: [c.autoSteps, c.autoGuidance, c.randomSeed])
        } label: {
            SectionLabel("Advanced")
        }
    }

    private var generateBar: some View {
        let c = app.composer
        let reason = c.blockReason
        let estimate = reason == nil ? c.buildParams().flatMap { Gallery.shared.estimateSeconds(for: $0) } : nil
        return VStack(alignment: .leading, spacing: 8) {
            if let estimate {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(c.count > 1 ? "About \(Format.duration(estimate)) each, \(Format.duration(estimate * Double(c.count))) in all"
                                     : "About \(Format.duration(estimate))")
                        .contentTransition(.numericText())
                    Spacer()
                    Text("⌘↩").foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .padding(.horizontal, 6)
                .animation(.snappy(duration: 0.25), value: Int(estimate))
            }
            if let reason, c.model != nil, !c.prompt.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 8) {
                Button {
                    generateTaps += 1
                    app.generate()
                } label: {
                    Label(generateTitle(c), systemImage: "sparkles")
                        .symbolEffect(.bounce, value: generateTaps)
                        .contentTransition(.interpolate)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.miragePrimaryLarge)
                .disabled(reason != nil)
                .help("Generate (⌘↩)")
                if let job = queue.current {
                    Button { queue.cancel(job) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(IconButtonStyle(size: 40)).help("Stop (⌘.)")
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(14)
        .animation(.snappy(duration: 0.28), value: queue.current?.id)
        .animation(.snappy(duration: 0.28), value: reason)
    }
}

extension ComposerPanel {
    func generateTitle(_ c: Composer) -> String {
        let noun = c.profile.kind == .video ? "Clips" : "Images"
        if JobQueue.shared.current != nil { return c.count > 1 ? "Queue \(c.count) \(noun)" : "Add to Queue" }
        return c.count > 1 ? "Generate \(c.count) \(noun)" : "Generate"
    }
}

/// Aspect-ratio chooser: each option shows its shape, and the highlight slides between them.
struct AspectPicker: View {
    @Binding var selection: Aspect
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Aspect.allCases) { aspect in
                let selected = aspect == selection
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = aspect }
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary), lineWidth: 1.5)
                            .frame(width: aspect.ratio >= 1 ? 16 : 16 * aspect.ratio, height: aspect.ratio >= 1 ? 16 / aspect.ratio : 16)
                            .frame(width: 18, height: 17)
                        Text(aspect.rawValue).font(.caption2.weight(selected ? .semibold : .regular)).monospacedDigit()
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient)
                                .shadow(color: Brand.violet.opacity(0.45), radius: 7, y: 2)
                                .matchedGeometryEffect(id: "aspect", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(aspect.rawValue)
            }
        }
        .padding(3)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
            }
            .font(.callout)
            MirageSlider(value: $value, range: range, step: step)
        }
    }
}

struct MemoryPlanCard: View {
    let plan: MemoryPlan
    @State private var adjusting = false

    var body: some View {
        Card(padding: 12, inset: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Memory", systemImage: "memorychip").font(.subheadline.weight(.semibold))
                    Spacer()
                    FitBadge(fit: plan.fit, compact: true)
                        .contentTransition(.interpolate)
                    Button { adjusting.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("Change the memory limit")
                        .popover(isPresented: $adjusting, arrowEdge: .trailing) {
                            MemoryLimitControls().padding(18).frame(width: 380)
                        }
                }
                GeometryReader { geo in
                    let fraction = min(1, plan.peakGB / max(plan.budgetGB, 0.1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(plan.fit.color.gradient).frame(width: max(6, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                Text("About \(Format.gb(plan.peakGB)) of the \(Format.gb(plan.budgetGB)) a model may use.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                ForEach(plan.notes, id: \.self) { note in
                    Label(note, systemImage: "wand.and.sparkles")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: plan.peakGB)
            .animation(.snappy(duration: 0.3), value: plan.notes)
        }
    }
}

// MARK: - Canvas

struct CanvasView: View {
    @Environment(AppState.self) private var app
    @State private var queue = JobQueue.shared
    @State private var gallery = Gallery.shared
    @State private var dropTargeted = false

    private var shownItem: GalleryItem? {
        if let id = app.shownItemID, let item = gallery.items.first(where: { $0.id == id }) { return item }
        return nil
    }
    /// The most recent job that ended badly and has not been replaced by a newer result.
    private var failedJob: GenerationJob? {
        guard let latest = queue.jobs.first(where: { !$0.state.isActive }) else { return nil }
        if case .failed = latest.state { return latest }
        return nil
    }
    private var showingJob: Bool { queue.current != nil && app.shownItemID == nil }
    private var visibleItem: GalleryItem? {
        showingJob ? nil : (shownItem ?? (failedJob == nil ? gallery.items.first : nil))
    }
    /// Identity of what the stage shows, so changes cross-fade.
    private var stageKey: String {
        if showingJob { return "job" }
        if let item = visibleItem { return item.id.uuidString }
        return failedJob != nil ? "failed" : "empty"
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if showingJob, let job = queue.current {
                    JobProgressView(job: job).transition(.blurReplace)
                } else if let item = visibleItem {
                    ResultView(item: item).id(item.id).transition(.blurReplace)
                } else if let job = failedJob {
                    FailedView(job: job).transition(.blurReplace)
                } else {
                    EmptyCanvas().transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.45), value: stageKey)

            if !gallery.items.isEmpty {
                filmstrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: gallery.items.isEmpty)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Brand.gradient, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Brand.violet.opacity(0.18)))
                    .overlay(Label("Drop to use as the input image", systemImage: "photo.badge.plus").font(.title3.weight(.medium)))
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard app.composer.profile.imageInput != .none,
                  let url = urls.first(where: { FileKinds.images.contains($0.pathExtension.lowercased()) }) else { return false }
            withAnimation(.snappy) { app.composer.inputImage = url.path }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted && app.composer.profile.imageInput != .none }
        }
        .onChange(of: gallery.items.first?.id) { _, new in
            // Show a fresh result as soon as it lands.
            if let new, queue.current == nil { app.shownItemID = new }
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let job = queue.current {
                    Button { app.shownItemID = nil } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.08))
                            ProgressView(value: job.fraction ?? 0).progressViewStyle(.circular).controlSize(.small)
                        }
                        .frame(width: 58, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Brand.gradient, lineWidth: showingJob ? 2 : 0))
                    }
                    .buttonStyle(.plain).help("Current generation")
                    .transition(.scale.combined(with: .opacity))
                }
                ForEach(queue.pending.reversed()) { job in
                    PendingTile(job: job)
                        .transition(.scale.combined(with: .opacity))
                }
                ForEach(gallery.items.prefix(30)) { item in
                    let selected = visibleItem?.id == item.id
                    Button { app.shownItemID = item.id } label: {
                        Thumbnail(url: item.url, side: 58)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if item.kind == .video {
                                    Image(systemName: "play.fill").font(.system(size: 8)).padding(3)
                                        .background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white).padding(3)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2))
                            .scaleEffect(selected ? 1.0 : 0.92)
                            .opacity(selected ? 1 : 0.8)
                    }
                    .buttonStyle(.plain)
                    .hoverLift(1.08)
                    .help(item.params.prompt)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: gallery.items.map(\.id))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: queue.pending.map(\.id))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: stageKey)
        }
        .frame(height: 74)
        .glassPanel(cornerRadius: 22)
    }
}

/// A queued generation in the filmstrip; hover to cancel it.
struct PendingTile: View {
    let job: GenerationJob
    @State private var hovering = false
    var body: some View {
        Button { JobQueue.shared.cancel(job) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Image(systemName: hovering ? "xmark" : "hourglass")
                    .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Waiting: \(job.params.prompt). Click to remove it from the queue.")
    }
}

struct EmptyCanvas: View {
    @State private var store = ModelStore.shared
    @State private var float = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 60, weight: .light)).mirageGradient()
                .scaleEffect(float ? 1 : 0.7).opacity(float ? 1 : 0)
                .shadow(color: Brand.violet.opacity(0.6), radius: 20)
                .animation(.spring(response: 0.6, dampingFraction: 0.6), value: float)
            Text("Images and video, made on this Mac").font(.title2.weight(.semibold))
            Text(store.models.isEmpty
                 ? "Download a model to begin. Everything runs locally on the GPU with MLX — nothing is sent anywhere."
                 : "Write a prompt on the left and press ⌘↩. Everything runs locally on the GPU with MLX.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Text("\(SystemInfo.current.chip) · \(Format.gb(SystemInfo.current.totalGB)) memory")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(44)
        .glassPanel(cornerRadius: 34)
        .onAppear { float = true }
    }
}

struct JobProgressView: View {
    let job: GenerationJob
    @State private var monitor = MemoryMonitor.shared
    @State private var showLog = false
    @State private var spin = false
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 9)
                if let f = job.fraction {
                    Circle().trim(from: 0, to: max(0.015, f))
                        .stroke(AngularGradient(colors: [Brand.violet, Brand.coral, Brand.violet], center: .center),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: f)
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    if let f = job.fraction {
                        Text("\(Int(f * 100))%").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(value: f))
                            .animation(.snappy(duration: 0.35), value: f)
                    } else {
                        // Model loading: the system spinner is drawn by the window server, not by app code.
                        ProgressView().controlSize(.large)
                    }
                }
            }
            .frame(width: 160, height: 160)
            .shadow(color: Brand.violet.opacity(0.4), radius: 22)

            VStack(spacing: 4) {
                Text(job.status).font(.headline).lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.25), value: job.status)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(detailLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("“\(job.params.prompt)”").font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 440)

            HStack(spacing: 10) {
                Button("Stop", systemImage: "stop.fill") { JobQueue.shared.cancel(job) }.buttonStyle(.soft)
                Button(showLog ? "Hide Log" : "Show Log", systemImage: "text.alignleft") {
                    withAnimation(.snappy(duration: 0.3)) { showLog.toggle() }
                }
                .buttonStyle(.soft)
            }
            if showLog {
                LogView(text: job.log).frame(maxWidth: 620, maxHeight: 200)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(36)
        .glassPanel(cornerRadius: 34)
        .onAppear { spin = true; breathe = true }
    }

    private var detailLine: String {
        var parts = ["\(Format.duration(job.elapsed)) elapsed"]
        if let eta = job.eta { parts.append("\(eta) left") }
        if monitor.jobGB > 0.1 { parts.append("\(Format.gb(monitor.jobGB)) in use") }
        if job.params.lowMemory { parts.append("low-memory mode") }
        return parts.joined(separator: " · ")
    }
}

struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("end")
            }
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct FailedView: View {
    let job: GenerationJob
    @State private var showLog = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                .symbolEffect(.bounce, value: job.id)
            Text("That generation did not finish").font(.title3.weight(.semibold))
            if case .failed(let message) = job.state {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    .textSelection(.enabled)
            }
            Button(showLog ? "Hide Log" : "Show Log", systemImage: "text.alignleft") {
                withAnimation(.snappy(duration: 0.3)) { showLog.toggle() }
            }
            .buttonStyle(.soft)
            if showLog { LogView(text: job.log).frame(maxWidth: 640, maxHeight: 260).transition(.opacity) }
        }
        .padding(36)
        .glassPanel(cornerRadius: 34)
    }
}

struct ResultView: View {
    @Environment(AppState.self) private var app
    let item: GalleryItem
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 12) {
            MediaView(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(arrived ? 1 : 0.94)
                .opacity(arrived ? 1 : 0)
                .onTapGesture { if item.kind == .image { app.lightbox = item } }
                .help(item.kind == .image ? "Click to view larger" : "")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.params.prompt).lineLimit(1).truncationMode(.tail)
                    Text(metaLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 12)
                ItemActions(item: item)
            }
            .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 9)
            .glassPanel(cornerRadius: 22)
        }
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { arrived = true } }
    }

    private var metaLine: String {
        var parts = [item.params.modelTitle, "\(item.params.width)×\(item.params.height)"]
        if item.kind == .video { parts.append(String(format: "%.1f s", item.params.seconds)) }
        parts.append("seed \(item.params.seed)")
        parts.append("took \(Format.duration(item.seconds))")
        if item.peakMemoryGB > 0.1 { parts.append("peak \(Format.gb(item.peakMemoryGB))") }
        return parts.joined(separator: " · ")
    }
}

struct ItemActions: View {
    @Environment(AppState.self) private var app
    let item: GalleryItem
    @State private var showInfo = false
    @State private var showUpscale = false

    var body: some View {
        HStack(spacing: 7) {
            if item.kind == .image {
                Button { showUpscale.toggle() } label: {
                    Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.miragePrimary)
                .help("Enlarge this image up to 4×")
                .popover(isPresented: $showUpscale, arrowEdge: .top) {
                    UpscalePanel(item: item) { showUpscale = false }
                }
            }
            if ModelStore.shared.model(item.params.repo) != nil, item.params.upscaleSource == nil {
                Button("Make Another", systemImage: "dice") { app.makeAnother(of: item) }
                    .buttonStyle(.icon)
                    .help("Run this again with a new seed")
            }
            Group {
                Button(item.isFavorite ? "Remove Favourite" : "Favourite", systemImage: item.isFavorite ? "star.fill" : "star") {
                    withAnimation(.snappy) { Gallery.shared.toggleFavorite(item) }
                }
                .help(item.isFavorite ? "Remove from favourites" : "Add to favourites")
                Button("Info", systemImage: "info.circle") { showInfo.toggle() }
                    .help("Show every setting used")
                    .popover(isPresented: $showInfo, arrowEdge: .top) { ItemInfo(item: item) }
                Button("Reuse Settings", systemImage: "arrow.uturn.backward") {
                    app.composer.reuse(item.params)
                    app.section = .create
                }
                .help("Load this prompt, seed and size back into the composer")
                if item.kind == .image, app.composer.profile.imageInput != .none {
                    Button("Use as Input", systemImage: "photo.badge.arrow.down") {
                        withAnimation(.snappy) { app.composer.inputImage = item.file }
                        app.section = .create
                    }
                    .help("Use this image as the input for the selected model")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                .help("Show in Finder")
                ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if app.shownItemID == item.id { app.shownItemID = nil }
                    withAnimation(.snappy) { Gallery.shared.delete(item) }
                }
                .help("Move to Trash (you can undo)")
            }
            .buttonStyle(.icon)
        }
        .labelStyle(.iconOnly)
    }
}

/// The toolbar's Upscale panel: pick any image (a result or a file from disk), then set how to enlarge it.
struct UpscaleHub: View {
    @Environment(AppState.self) private var app
    @State private var gallery = Gallery.shared
    @State private var picked: GalleryItem?
    @State private var path: String?
    @State private var problem: String?

    private var onScreen: GalleryItem? {
        let shown = app.shownItemID.flatMap { id in gallery.items.first { $0.id == id } } ?? gallery.items.first
        return shown?.kind == .image ? shown : gallery.items.first { $0.kind == .image }
    }

    var body: some View {
        Group {
            if let picked {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Thumbnail(url: picked.url, side: 44).frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(picked.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Change") { withAnimation(.snappy) { self.picked = nil; path = nil } }.buttonStyle(.softSmall)
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    UpscalePanel(item: picked) { app.showUpscaleHub = false }
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").mirageGradient()
                        Text("Upscale an image").font(.headline)
                    }
                    Text("Enlarge any picture up to 4× with restored detail. Pick one of your results or any image file.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let current = onScreen {
                        Button { withAnimation(.snappy) { picked = current } } label: {
                            HStack(spacing: 10) {
                                Thumbnail(url: current.url, side: 44).frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Use your latest image").fontWeight(.medium)
                                    Text(verbatim: "\(current.params.width) × \(current.params.height)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverLift(1.02)
                    }
                    FileWell(title: "Any image file", symbol: "photo.badge.plus", allowed: FileKinds.images, path: $path)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                }
                .padding(16)
                .frame(width: 380)
                .transition(.opacity)
            }
        }
        .onAppear { picked = app.upscaleHubItem }
        .onChange(of: path) { _, new in
            guard let new else { return }
            if let item = AppState.importedItem(path: new) { withAnimation(.snappy) { picked = item; problem = nil } }
            else { problem = "That file could not be read as an image."; path = nil }
        }
    }
}

/// Upscale settings for one image; offers the upscaler download if it is not installed yet.
struct UpscalePanel: View {
    @Environment(AppState.self) private var app
    let item: GalleryItem
    let close: () -> Void
    @State private var store = ModelStore.shared
    @State private var settings = AppSettings.shared
    @State private var gallery = Gallery.shared
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").mirageGradient()
                Text("Upscale").font(.headline)
                Spacer()
                Text(verbatim: "\(item.params.width) × \(item.params.height) now").font(.caption).foregroundStyle(.secondary)
            }
            if store.upscaler == nil {
                Text("Upscaling uses the SeedVR2 model, which enlarges an image and restores real detail. It is an optional one-time 7.3 GB download.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DownloadControl(repo: Upscaler.repo, title: Upscaler.title, tags: ["mlx"], library: nil)
            } else {
                let planned = app.upscalePlan(for: item, factor: settings.upscaleScale)
                let blocked = planned.upscale.plan.fit == .tooLarge && settings.autoMemory && !settings.unlockLimits

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scale")
                        Spacer()
                        Text(verbatim: String(format: "%g×  ·  %d × %d  ·  %.1f MP", settings.upscaleScale, planned.width, planned.height,
                                              Double(planned.width * planned.height) / 1_000_000))
                            .foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
                    }
                    .font(.callout)
                    MirageSlider(value: $settings.upscaleScale, range: 1.5...4, step: 0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Softness")
                        Spacer()
                        Text(settings.upscaleSoftness < 0.01 ? "Off" : "\(Int(settings.upscaleSoftness * 100))%")
                            .foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
                    }
                    .font(.callout)
                    MirageSlider(value: $settings.upscaleSoftness, range: 0...1, step: 0.05)
                    Text("Smooths the source first. Raise it for noisy or over-sharpened images; leave it off for clean ones.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Weight precision").font(.callout)
                            SlidingSegments(items: [.init(value: 0, title: "Auto"), .init(value: 16, title: "Full"),
                                                    .init(value: 8, title: "8-bit"), .init(value: 4, title: "4-bit")],
                                            selection: $settings.upscaleQuant, glass: false)
                            Text("Lower precision uses less memory with a small loss of fine detail.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Decode tile size").font(.callout)
                            SlidingSegments(items: [.init(value: 0, title: "Auto"), .init(value: 512, title: "512"),
                                                    .init(value: 256, title: "256"), .init(value: 128, title: "128")],
                                            selection: $settings.upscaleTile, glass: false)
                            Text("Smaller tiles need much less memory and take slightly longer.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }

                Card(padding: 10, inset: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Memory", systemImage: "memorychip").font(.caption.weight(.semibold))
                            Spacer()
                            FitBadge(fit: planned.upscale.plan.fit, compact: true)
                        }
                        Text("About \(Format.gb(planned.upscale.plan.peakGB)) of \(Format.gb(planned.upscale.plan.budgetGB)) · \(planned.upscale.quant == 16 ? "full" : "\(planned.upscale.quant)-bit") weights · \(planned.upscale.tile) px tiles\(estimateText(planned))")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(planned.upscale.plan.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(planned.upscale.plan.fit >= .tight ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Button("Reset") {
                        withAnimation(.snappy) {
                            settings.upscaleScale = 2; settings.upscaleSoftness = 0; settings.upscaleQuant = 0; settings.upscaleTile = 0
                        }
                    }
                    .buttonStyle(.softSmall)
                    Spacer()
                    Button {
                        app.upscale(item, factor: settings.upscaleScale)
                        close()
                    } label: {
                        Label(String(format: "Upscale %g×", settings.upscaleScale), systemImage: "sparkles")
                    }
                    .buttonStyle(.miragePrimary)
                    .disabled(blocked)
                }
                Text("Saved as a new image; the original is kept.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .animation(.snappy(duration: 0.25), value: settings.upscaleScale)
        .animation(.snappy(duration: 0.25), value: settings.upscaleQuant)
        .animation(.snappy(duration: 0.25), value: settings.upscaleTile)
    }

    private func estimateText(_ planned: (width: Int, height: Int, upscale: MemoryPlanner.UpscalePlan)) -> String {
        var p = GenerationParams()
        p.repo = Upscaler.repo; p.kind = .image; p.width = planned.width; p.height = planned.height
        p.lowMemory = true
        guard let seconds = gallery.estimateSeconds(for: p) else { return "" }
        return " · about \(Format.duration(seconds))"
    }
}

/// Every setting behind one result, with the prompt ready to copy.
struct ItemInfo: View {
    let item: GalleryItem
    @State private var copied = false

    var body: some View {
        let p = item.params
        VStack(alignment: .leading, spacing: 12) {
            Text(p.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("Model", p.modelTitle)
                if let factor = p.upscaleFactor { row("Upscaled", String(format: "%g× from %d × %d", factor, Int(Double(p.width) / factor), Int(Double(p.height) / factor))) }
                row("Size", p.kind == .video ? "\(p.width) × \(p.height) · \(p.frames) frames at \(p.fps) fps" : "\(p.width) × \(p.height)")
                row("Seed", String(p.seed))
                if let steps = p.steps { row("Steps", String(steps)) }
                if let g = p.guidance { row("Guidance", String(format: "%.1f", g)) }
                if !p.negativePrompt.isEmpty { row("Avoid", p.negativePrompt) }
                if let image = p.inputImage { row("Input image", URL(fileURLWithPath: image).lastPathComponent) }
                row("Took", Format.duration(item.seconds))
                if item.peakMemoryGB > 0.1 { row("Peak memory", Format.gb(item.peakMemoryGB) + (p.lowMemory ? " · low-memory mode" : "")) }
                row("Made", item.date.formatted(date: .abbreviated, time: .shortened))
                row("File", item.url.lastPathComponent)
            }
            .font(.callout)
            HStack {
                Button(copied ? "Copied" : "Copy Prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.prompt, forType: .string)
                    withAnimation(.snappy) { copied = true }
                }
                .buttonStyle(.soft)
                Button("Copy Seed", systemImage: "number") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(p.seed), forType: .string)
                }
                .buttonStyle(.soft)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled).lineLimit(2)
        }
    }
}

struct MediaView: View {
    let item: GalleryItem
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if item.kind == .video {
                LoopingVideo(url: item.url).id(item.id)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
                    .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                    .transition(.opacity)
            } else if missing {
                ContentUnavailableView("File is missing", systemImage: "questionmark.folder",
                                       description: Text(item.url.lastPathComponent))
            } else {
                Color.clear
            }
        }
        // Decoded once, off the main thread, at screen size rather than full size.
        .task(id: item.id) {
            guard item.kind == .image else { return }
            let loaded = await ImageLoader.shared.image(for: item.url, maxPixel: 2200)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            missing = loaded == nil
        }
    }
}

struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @Environment(\.controlActiveState) private var controlState

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(contentMode: .fit)
            .onAppear {
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: item)
                player = queue
                queue.play()
            }
            .onDisappear { player?.pause(); player = nil; looper = nil }
            .onChange(of: controlState) { _, state in
                if state == .inactive { player?.pause() } else { player?.play() }
            }
    }
}
