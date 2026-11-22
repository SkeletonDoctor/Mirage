import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var downloads = DownloadManager.shared
    @State private var queue = JobQueue.shared
    @State private var store = ModelStore.shared
    @State private var gallery = Gallery.shared

    var body: some View {
        @Bindable var app = app
        ZStack {
            AmbientBackground(active: queue.current != nil)
            Group {
                switch app.section {
                case .create: CreateView()
                case .chat: ChatView()
                case .gallery: GalleryView()
                case .models: ModelsView()
                case .engines: EnginesView()
                }
            }
            .id(app.section)
            .transition(.blurReplace.combined(with: .opacity))
        }
        .animation(.smooth(duration: 0.38), value: app.section)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").mirageGradient()
                    Text("Mirage").font(.headline)
                }
                .padding(.horizontal, 6)
            }
            ToolbarItem(placement: .principal) { SectionTabs() }
            ToolbarItemGroup(placement: .primaryAction) {
                if let job = queue.current, app.section != .create {
                    JobChip(job: job)
                }
                Button { app.upscaleHubItem = nil; app.showUpscaleHub.toggle() } label: {
                    Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.titleAndIcon)
                }
                .help("Enlarge an image up to 4×")
                .popover(isPresented: $app.showUpscaleHub, arrowEdge: .bottom) { UpscaleHub() }
                MemoryPill()
                Button { app.showDownloads.toggle() } label: {
                    Label("Downloads", systemImage: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .symbolEffect(.pulse, isActive: downloads.activeCount > 0)
                }
                .help("Downloads")
                .popover(isPresented: $app.showDownloads, arrowEdge: .bottom) { DownloadsPopover() }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) {
            if let finished = downloads.justFinished {
                ToastView(symbol: "checkmark.circle.fill", title: "\(finished.title) is ready",
                          actionTitle: store.model(finished.repo) != nil ? "Use" : nil) {
                    if let model = store.model(finished.repo) { app.use(model) }
                    downloads.justFinished = nil
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: finished.id) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    if downloads.justFinished?.id == finished.id { downloads.justFinished = nil }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: downloads.justFinished?.id)
        .overlay(alignment: .bottom) {
            if let deleted = gallery.lastDeleted {
                ToastView(symbol: "trash", tint: .secondary, title: "Moved to Trash", actionTitle: "Undo") {
                    withAnimation(.snappy) { gallery.undoDelete() }
                }
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: deleted.item.id) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    if gallery.lastDeleted?.item.id == deleted.item.id { gallery.forgetLastDeleted() }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: gallery.lastDeleted?.item.id)
        .overlay {
            if let item = app.lightbox {
                Lightbox(item: item).transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: app.lightbox?.id)
        .onExitCommand { app.lightbox = nil }
        .onChange(of: store.models) { app.pickDefaultModel() }
    }
}

/// Full-window image viewer. Click the backdrop or press Esc to close; double-click to switch between fit and full size.
struct Lightbox: View {
    @Environment(AppState.self) private var app
    let item: GalleryItem
    @State private var actualSize = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.82)).ignoresSafeArea()
                .onTapGesture { app.lightbox = nil }
            if let image {
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable()
                            .frame(width: CGFloat(item.params.width) / 2, height: CGFloat(item.params.height) / 2)
                            .onTapGesture(count: 2) { withAnimation(.snappy) { actualSize = false } }
                    }
                    .defaultScrollAnchor(.center)
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 40)
                        .padding(28)
                        .onTapGesture(count: 2) { withAnimation(.snappy) { actualSize = true } }
                }
            }
            VStack {
                HStack {
                    Text(actualSize ? "Full size · double-click to fit" : "Double-click for full size")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Button("Close", systemImage: "xmark") { app.lightbox = nil }
                        .buttonStyle(IconButtonStyle(size: 34)).keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
            .padding(16)
        }
        .environment(\.colorScheme, .dark)
        .task(id: actualSize) {
            image = await ImageLoader.shared.image(for: item.url, maxPixel: actualSize ? 0 : 3200)
        }
    }
}

/// Section switcher in the toolbar. The highlight slides between tabs.
struct SectionTabs: View {
    @Environment(AppState.self) private var app
    @State private var queue = JobQueue.shared
    @State private var downloads = DownloadManager.shared
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { section in
                let selected = app.section == section
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { app.section = section }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                            .symbolEffect(.bounce, value: selected)
                        Text(section.title)
                        if badge(section) > 0 {
                            Text("\(badge(section))").font(.caption2.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tint, in: Capsule()).foregroundStyle(.white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule().fill(.primary.opacity(0.12))
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(section.title)
            }
        }
        .padding(.horizontal, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: queue.pending.count + downloads.activeCount)
    }

    private func badge(_ section: AppSection) -> Int {
        switch section {
        case .create: return queue.pending.count
        case .models: return downloads.activeCount
        default: return 0
        }
    }
}

/// Compact memory readout for the toolbar; click for detail.
struct MemoryPill: View {
    @State private var monitor = MemoryMonitor.shared
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle().trim(from: 0, to: monitor.usedFraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: monitor.usedFraction)
                }
                .frame(width: 15, height: 15)
                Text(String(format: "%.1f GB free", monitor.availableGB))
                    .font(.callout).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: monitor.availableGB)
            }
            .padding(.horizontal, 4)
        }
        .help("Memory")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                MemoryGauge()
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("Usable by a model").foregroundStyle(.secondary); Text(Format.gb(MemoryPlanner.budgetGB(override: AppSettings.shared.memoryLimitGB))) }
                    GridRow { Text("Pressure").foregroundStyle(.secondary); Text(monitor.pressure.label).foregroundStyle(color) }
                    GridRow { Text("Swap in use").foregroundStyle(.secondary); Text(Format.gb(monitor.swapGB)) }
                }
                .font(.callout).monospacedDigit()
                if monitor.swapGB > 2 {
                    Text("Your Mac is already swapping. Closing other apps will make generation faster.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 290)
        }
    }

    private var color: Color {
        switch monitor.pressure {
        case .normal: return monitor.usedFraction > 0.9 ? .orange : .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Shows the running generation in the toolbar while you are on another screen.
struct JobChip: View {
    @Environment(AppState.self) private var app
    let job: GenerationJob
    var body: some View {
        Button { app.section = .create } label: {
            HStack(spacing: 7) {
                ProgressView(value: job.fraction ?? 0).progressViewStyle(.circular).controlSize(.small)
                Text(job.fraction.map { "\(Int($0 * 100))%" } ?? "Working")
                    .font(.callout).monospacedDigit().contentTransition(.numericText())
            }
            .padding(.horizontal, 4)
        }
        .help(job.status)
        .transition(.scale.combined(with: .opacity))
    }
}

struct DownloadsPopover: View {
    @State private var downloads = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if downloads.tasks.contains(where: { $0.state == .completed }) {
                    Button("Clear finished") { withAnimation { downloads.clearFinished() } }.buttonStyle(.link)
                }
            }
            .padding(14)
            Divider()
            if downloads.tasks.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Models you download appear here."))
                    .frame(height: 170)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.tasks.reversed()) { task in
                            DownloadRow(task: task)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 400)
    }
}

struct DownloadRow: View {
    let task: DownloadTask
    @State private var downloads = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).fontWeight(.medium).lineLimit(1)
                    Text(task.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                switch task.state {
                case .queued, .preparing, .downloading:
                    Button { downloads.pause(task) } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause")
                case .paused, .failed:
                    Button { downloads.resume(task) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Resume")
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .symbolEffect(.bounce, value: task.state == .completed)
                }
                if task.state != .completed {
                    Button { withAnimation { downloads.remove(task) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Cancel and delete what was downloaded")
                }
            }
            if task.state != .completed {
                ProgressView(value: task.fraction).animation(.easeOut(duration: 0.4), value: task.fraction)
            }
            Text(detail).font(.caption).foregroundStyle(isFailed ? .red : .secondary).monospacedDigit()
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var isFailed: Bool { if case .failed = task.state { return true }; return false }

    private var detail: String {
        switch task.state {
        case .queued: return "Waiting"
        case .preparing: return "Reading file list…"
        case .downloading:
            var s = "\(Format.bytes(task.receivedBytes)) of \(Format.bytes(task.totalBytes))"
            if task.speed > 1000 { s += " · \(Format.bytes(Int64(task.speed)))/s" }
            if let eta = task.etaSeconds { s += " · \(Format.duration(eta)) left" }
            return s
        case .paused: return "Paused at \(Format.bytes(task.receivedBytes)) of \(Format.bytes(task.totalBytes))"
        case .completed: return "\(Format.bytes(task.totalBytes)) · ready to use"
        case .failed(let message): return message
        }
    }
}
