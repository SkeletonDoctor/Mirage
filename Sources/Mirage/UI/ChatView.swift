import SwiftUI

/// Drives one conversation: sending, streaming the reply into the store, stopping.
@Observable @MainActor
final class ChatController {
    static let shared = ChatController()
    var draft = ""
    private(set) var streamingID: UUID?         // the assistant message being written
    private(set) var problem: String?
    private var task: Task<Void, Never>?

    var isBusy: Bool { task != nil }

    func selectedModel() -> InstalledModel? {
        let models = ModelStore.shared.chatModels
        return models.first { $0.repo == AppSettings.shared.lastChatRepo } ?? models.first
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, task == nil, let model = selectedModel() else { return }
        draft = ""
        problem = nil
        let store = ChatStore.shared
        let conversation = store.current ?? store.newConversation()
        let id = conversation.id
        store.update(id) { c in
            c.messages.append(ChatMessage(role: "user", text: text))
            if c.title == "New chat" { c.title = String(text.prefix(48)) }
            c.modelRepo = model.repo
            c.updated = Date()
        }
        respond(in: id, model: model)
    }

    /// Drops the last reply and asks again.
    func regenerate() {
        guard task == nil, let c = ChatStore.shared.current, let model = selectedModel(), c.messages.last?.role == "assistant" else { return }
        ChatStore.shared.update(c.id) { $0.messages.removeLast() }
        respond(in: c.id, model: model)
    }

    func stop() {
        task?.cancel()
    }

    /// Asks the model to carry on after a reply that ran into the length limit.
    func continueReply() {
        guard task == nil else { return }
        draft = "Continue exactly where you stopped."
        send()
    }

    private func respond(in id: UUID, model: InstalledModel) {
        let store = ChatStore.shared
        let settings = AppSettings.shared
        task = Task { @MainActor in
            defer { task = nil; streamingID = nil }
            guard await ChatEngine.shared.load(model) else {
                if case .failed(let message) = ChatEngine.shared.state { problem = message }
                return
            }
            guard let history = store.conversations.first(where: { $0.id == id })?.messages else { return }
            let reply = ChatMessage(role: "assistant", text: "")
            store.update(id) { $0.messages.append(reply) }
            streamingID = reply.id

            var text = "", thinking = "", pieces = 0
            var finish: String?
            var promptTokens: Int?, replyTokens: Int?
            let options = ChatOptions.current
            let fitted = ChatContext.fit(history, system: settings.chatSystemPrompt, options: options)
            var lastFlush = Date.distantPast
            let started = Date()
            @MainActor func flush(final: Bool) {
                store.update(id) { c in
                    guard let i = c.messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    c.messages[i].text = text
                    c.messages[i].thinking = thinking.isEmpty ? nil : thinking
                    if final {
                        c.messages[i].hitLimit = finish == "length" ? true : nil
                        c.messages[i].contextTokens = promptTokens
                        c.messages[i].droppedMessages = fitted.dropped > 0 ? fitted.dropped : nil
                        let elapsed = Date().timeIntervalSince(started)
                        c.messages[i].speed = elapsed > 0.5 ? Double(replyTokens ?? pieces) / elapsed : nil
                        c.updated = Date()
                    }
                }
            }
            do {
                let stream = ChatEngine.shared.reply(to: fitted.kept, system: settings.chatSystemPrompt, options: options)
                for try await piece in stream {
                    if Task.isCancelled { break }
                    text += piece.text
                    thinking += piece.thinking
                    if let f = piece.finish { finish = f }
                    if let p = piece.promptTokens { promptTokens = p }
                    if let r = piece.replyTokens { replyTokens = r }
                    if !piece.text.isEmpty || !piece.thinking.isEmpty { pieces += 1 }
                    // Redraw about twelve times a second at most, however fast the words arrive.
                    if Date().timeIntervalSince(lastFlush) > 0.08 { flush(final: false); lastFlush = Date() }
                }
            } catch {
                if !Task.isCancelled { problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
            flush(final: true)
            if text.isEmpty && thinking.isEmpty {
                store.update(id) { c in c.messages.removeAll { $0.id == reply.id } }
            }
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var store = ChatStore.shared
    @State private var engine = ChatEngine.shared
    @State private var models = ModelStore.shared
    @State private var controller = ChatController.shared
    @State private var settings = AppSettings.shared
    @FocusState private var inputFocused: Bool

    /// Chat models are managed under Models › Chat.
    private func openChatModels() {
        app.modelsTab = .chat
        app.section = .models
    }

    var body: some View {
        HStack(spacing: 14) {
            ChatSidebar(openModels: openChatModels)
                .frame(width: 284)
                .glassPanel()
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .navigationTitle("Mirage")
        .onAppear { inputFocused = true }
    }

    @ViewBuilder
    private var conversation: some View {
        if models.chatModels.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 50, weight: .light)).mirageGradient()
                Text("Chat with an unlocked model").font(.title2.weight(.semibold))
                Text("This tab lists only language models whose makers removed the built-in refusals (often labelled abliterated or uncensored). They run entirely on this Mac; nothing you type leaves it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                Button("Get a Chat Model", systemImage: "arrow.down.circle") { openChatModels() }
                    .buttonStyle(.miragePrimaryLarge)
            }
            .padding(40)
            .glassPanel(cornerRadius: 34)
        } else {
            VStack(spacing: 12) {
                MessageList(conversation: store.current, streamingID: controller.streamingID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = controller.problem ?? engine.notice {
                    Label(notice, systemImage: controller.problem != nil ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(controller.problem != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .transition(.opacity)
                }
                inputBar
            }
            .animation(.snappy(duration: 0.25), value: controller.problem)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { controller.send() }
                .padding(.vertical, 6)
            if controller.isBusy {
                Button("Stop", systemImage: "stop.fill") { controller.stop() }
                    .buttonStyle(IconButtonStyle(size: 34)).help("Stop the reply")
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Send", systemImage: "arrow.up") { controller.send() }
                    .buttonStyle(IconButtonStyle(size: 34, tinted: true))
                    .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (Return). Option-Return adds a line.")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .glassPanel(cornerRadius: 24)
        .animation(.snappy(duration: 0.2), value: controller.isBusy)
    }
}

// MARK: - Sidebar

struct ChatSidebar: View {
    let openModels: () -> Void
    @State private var store = ChatStore.shared
    @State private var engine = ChatEngine.shared
    @State private var models = ModelStore.shared
    @State private var controller = ChatController.shared
    @State private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var showSampling = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { _ = store.newConversation() }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.miragePrimary)
            .padding(14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.conversations) { c in
                        ConversationRow(conversation: c, selected: c.id == store.currentID)
                    }
                }
                .padding(.horizontal, 8)
                .animation(.snappy(duration: 0.25), value: store.conversations.map(\.id))
            }
            .scrollIndicators(.never)

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                modelSection
                DisclosureGroup(isExpanded: $showSettings) {
                    ViewThatFits(in: .vertical) {
                        settingsControls
                        ScrollView { settingsControls.padding(.trailing, 4) }.scrollIndicators(.automatic)
                    }
                    .frame(maxHeight: 330)
                } label: {
                    SectionLabel("Settings")
                }
            }
            .padding(14)
        }
    }

    /// Every adjustable chat setting. Scrolls when the sidebar is too short to show it all.
    private var settingsControls: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 10) {
                        LabeledSlider(title: "Creativity", value: $settings.chatTemperature, range: 0...1.5, step: 0.05,
                                      display: String(format: "%.2f", settings.chatTemperature))
                        LabeledSlider(title: "Longest reply", value: $settings.chatMaxTokens, range: 256...16384, step: 256,
                                      display: "\(Int(settings.chatMaxTokens)) tokens")
                            .help("The most the model may write in one reply, including its reasoning.")
                        LabeledSlider(title: "Context length", value: $settings.chatContext, range: 2048...131072, step: 2048,
                                      display: "\(Int(settings.chatContext)) tokens")
                            .help("How much of the conversation the model is given. Older messages beyond this are left out. Larger values use more memory and slow each reply.")
                        SwitchRow(title: "Let the model reason first", isOn: $settings.chatThinking).font(.callout)
                            .help("Only affects models that can think before answering. Off gives faster, shorter replies.")
                        DisclosureGroup(isExpanded: $showSampling) {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledSlider(title: "Top-p", value: $settings.chatTopP, range: 0.05...1, step: 0.05,
                                              display: settings.chatTopP >= 0.999 ? "Off" : String(format: "%.2f", settings.chatTopP))
                                    .help("Limits word choice to the most likely options that together reach this probability.")
                                LabeledSlider(title: "Top-k", value: $settings.chatTopK, range: 0...200, step: 5,
                                              display: settings.chatTopK < 1 ? "Off" : "\(Int(settings.chatTopK))")
                                    .help("Limits word choice to this many most likely options.")
                                LabeledSlider(title: "Repetition penalty", value: $settings.chatRepetition, range: 1...1.5, step: 0.05,
                                              display: settings.chatRepetition <= 1.001 ? "Off" : String(format: "%.2f", settings.chatRepetition))
                                    .help("Discourages the model from repeating itself.")
                                HStack {
                                    Text("Seed").font(.callout)
                                    TextField("Random", text: $settings.chatSeed).textFieldStyle(.roundedBorder).frame(width: 110)
                                    Spacer()
                                    Button("Reset All") { withAnimation(.snappy) { settings.resetChatDefaults() } }.buttonStyle(.softSmall)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Sampling").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Instructions for every chat").font(.callout)
                        TextEditor(text: $settings.chatSystemPrompt)
                            .font(.callout).scrollContentBackground(.hidden).padding(6)
                            .frame(height: 70)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.top, 8)
    }

    @ViewBuilder
    private var modelSection: some View {
        let chatModels = models.chatModels
        let selected = controller.selectedModel()
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Model")
            if chatModels.isEmpty {
                Text("No chat model installed.").font(.callout).foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(chatModels) { m in
                        Button("\(m.title) · \(Format.bytes(m.sizeBytes))") {
                            if settings.lastChatRepo != m.repo {
                                settings.lastChatRepo = m.repo
                                engine.unload(reason: nil)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain").mirageGradient()
                        Text(selected?.title ?? "Choose").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.secondary)
                    }
                    .padding(9).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                HStack(spacing: 6) {
                    statusDot
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.numericText())
                    Spacer()
                    switch engine.state {
                    case .ready:
                        Button("Unload") { engine.unload(reason: nil) }.buttonStyle(.softSmall)
                            .help("Free the model's memory. It reloads when you send a message.")
                    case .loading:
                        ProgressView().controlSize(.small)
                    default:
                        if let selected {
                            Button("Load") { Task { _ = await engine.load(selected) } }.buttonStyle(.softSmall)
                        }
                    }
                }
                .animation(.snappy(duration: 0.2), value: engine.state)
            }
            Button("Manage Chat Models", systemImage: "shippingbox") { openModels() }
                .buttonStyle(.softSmall).help("Download or remove chat models under Models › Chat")
        }
    }

    private var statusDot: some View {
        let color: Color = {
            switch engine.state {
            case .ready: return .green
            case .loading: return .orange
            case .failed: return .red
            case .idle: return .secondary
            }
        }()
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Not loaded"
        case .loading(let step): return step
        case .ready: return engine.memoryGB > 0.1 ? "Loaded · \(Format.gb(engine.memoryGB)) in use" : "Loaded"
        case .failed(let message): return message
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button { ChatStore.shared.currentID = conversation.id } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                    Text(relativeDate(conversation.updated)).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        withAnimation(.snappy(duration: 0.25)) { ChatStore.shared.delete(conversation.id) }
                    }
                    .buttonStyle(IconButtonStyle(size: 22)).help("Delete this chat")
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(selected ? 0.12 : hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Messages

struct MessageList: View {
    let conversation: Conversation?
    let streamingID: UUID?

    var body: some View {
        if let conversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message, streaming: message.id == streamingID,
                                       isLast: message.id == conversation.messages.last?.id)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 8)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .onChange(of: conversation.messages.last?.text.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: conversation.messages.count) { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: conversation.id) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40, weight: .light)).mirageGradient()
                Text("Start a conversation").font(.title3.weight(.semibold))
                Text("The model loads the first time you send a message and stays ready until it has been idle for ten minutes.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool
    let isLast: Bool
    @State private var hovering = false
    @State private var copied = false
    @State private var showThinking = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Brand.gradient.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let thinking = message.thinking, !thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(thinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    } label: {
                        Label(streaming && message.text.isEmpty ? "Thinking…" : "Reasoning", systemImage: "brain")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                } else if !streaming, message.hitLimit == true {
                    Text("The model used the whole reply length on its reasoning and never got to an answer.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if streaming {
                    ProgressView().controlSize(.small)
                }
                if !streaming, message.hitLimit == true {
                    HStack(spacing: 8) {
                        Label("Stopped at the reply length limit (\(Int(AppSettings.shared.chatMaxTokens)) tokens).", systemImage: "scissors")
                            .font(.caption).foregroundStyle(.orange)
                        if isLast {
                            Button("Continue") { ChatController.shared.continueReply() }.buttonStyle(.softSmall)
                        }
                        Text("Raise “Longest reply” under Settings to allow more.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    if !streaming {
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            copied = true
                        }
                        .buttonStyle(IconButtonStyle(size: 22)).help("Copy the reply")
                        if isLast {
                            Button("Try Again", systemImage: "arrow.clockwise") { ChatController.shared.regenerate() }
                                .buttonStyle(IconButtonStyle(size: 22)).help("Replace this reply with a new one")
                        }
                        if let speed = message.speed {
                            Text(String(format: "%.0f tokens/s", speed)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        if let used = message.contextTokens {
                            Text("context \(used) of \(Int(AppSettings.shared.chatContext))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                .help("Tokens of conversation the model was given for this reply.")
                        }
                        if let dropped = message.droppedMessages {
                            Text("\(dropped) older message\(dropped == 1 ? "" : "s") left out").font(.caption2).foregroundStyle(.orange)
                                .help("The conversation is longer than the context length, so the oldest messages were not sent. Raise Context length under Settings to include more.")
                        }
                    }
                }
                .opacity(hovering || isLast ? 1 : 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Renders a reply: inline Markdown for prose, monospaced boxes for fenced code.
struct MarkdownText: View {
    let text: String

    private struct Block: Identifiable { let id: Int; let code: Bool; let body: String }

    private var blocks: [Block] {
        var out: [Block] = []
        for (i, part) in text.components(separatedBy: "```").enumerated() {
            let isCode = i % 2 == 1
            var body = part
            if isCode, let newline = body.firstIndex(of: "\n") {
                // Drop the language tag on the fence line.
                let tag = body[..<newline]
                if !tag.contains(" ") { body = String(body[body.index(after: newline)...]) }
            }
            body = body.trimmingCharacters(in: .newlines)
            if !body.isEmpty { out.append(Block(id: i, code: isCode, body: body)) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                if block.code {
                    Text(block.body)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text((try? AttributedString(markdown: block.body,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.body))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Model browser

enum ChatModelSort: String, CaseIterable, Identifiable {
    case lowestRefusals = "Lowest refusal rate", downloads = "Most downloaded", trending = "Trending", updated = "Recently updated"
    var id: String { rawValue }
    var apiSort: HFSort {
        switch self {
        case .lowestRefusals, .downloads: return .downloads
        case .trending: return .trending
        case .updated: return .updated
        }
    }
}

/// How low a model's stated refusal rate must be to be listed.
enum RefusalLimit: String, CaseIterable, Identifiable {
    case any = "Any refusal rate", stated = "Stated rates only", ten = "10% or less", five = "5% or less", zero = "0% only"
    var id: String { rawValue }
    /// nil means no figure is required.
    var ceiling: Double? {
        switch self {
        case .any: return nil
        case .stated: return 1
        case .ten: return 0.10
        case .five: return 0.05
        case .zero: return 0
        }
    }
}

@Observable @MainActor
final class ChatModelSearch {
    var query = ""
    var sort: ChatModelSort = .lowestRefusals
    var limit: RefusalLimit = .any
    /// Hide models too large for this Mac's memory.
    var fitsOnly = false
    private(set) var results: [HFModel] = []
    private(set) var sizes: [String: Int64] = [:]
    /// Repos that ship their own model code, which Mirage will not run.
    private(set) var customCode: Set<String> = []
    /// Refusal figures read from model cards; a repo is in `checked` once its card has been read.
    private(set) var refusals: [String: RefusalReport] = [:]
    private(set) var checked: Set<String> = []
    private(set) var loading = false
    private(set) var readingCards = false
    private(set) var error: String?
    private var cardTask: Task<Void, Never>?

    /// Results after the refusal filter, in the chosen order.
    var visible: [HFModel] {
        var list = results
        if !AppSettings.shared.allowCustomCode { list = list.filter { !customCode.contains($0.id) } }   // cannot run unless allowed
        if fitsOnly {
            let limitGB = AppSettings.shared.memoryLimitGB
            list = list.filter { m in sizes[m.id].map { MemoryPlanner.chatFit(weightBytes: $0, memoryLimitGB: limitGB) != .tooLarge } ?? false }
        }
        if let ceiling = limit.ceiling {
            list = list.filter { m in refusals[m.id].map { $0.rate <= ceiling + 0.0001 } ?? false }
        }
        guard sort == .lowestRefusals else { return list }
        return list.sorted { a, b in
            switch (refusals[a.id], refusals[b.id]) {
            case let (x?, y?): return x.rate != y.rate ? x.rate < y.rate : (a.downloads ?? 0) > (b.downloads ?? 0)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.downloads ?? 0) > (b.downloads ?? 0)
            }
        }
    }

    func load() async {
        loading = true
        error = nil
        do {
            let found = try await HFClient.searchUnlockedChat(query: query, sort: sort.apiSort)
            if Task.isCancelled { return }
            results = found
            readCards()
        } catch {
            if Task.isCancelled { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    /// Reads each listed model's card for a stated refusal rate, a few at a time.
    private func readCards() {
        cardTask?.cancel()
        let pending = results.filter { !checked.contains($0.id) }
        guard !pending.isEmpty else { readingCards = false; return }
        readingCards = true
        cardTask = Task { @MainActor in
            await withTaskGroup(of: (String, RefusalReport?).self) { group in
                var iterator = pending.makeIterator()
                func addNext() {
                    guard let m = iterator.next() else { return }
                    group.addTask {
                        await self.size(for: m.id)          // sizes are needed to filter by fit
                        return (m.id, await HFClient.refusalReport(repo: m.id, tags: m.tags))
                    }
                }
                for _ in 0..<6 { addNext() }
                for await (id, report) in group {
                    if Task.isCancelled { break }
                    checked.insert(id)
                    if let report { refusals[id] = report }
                    addNext()
                }
            }
            if !Task.isCancelled { readingCards = false }
        }
    }

    /// Looks up a repo's weight size the first time its row appears.
    func size(for repo: String) async {
        guard sizes[repo] == nil, let detail = try? await HFClient.detail(repo) else { return }
        if (detail.siblings ?? []).contains(where: { $0.rfilename == "model.py" }) { customCode.insert(repo) }
        sizes[repo] = (detail.siblings ?? []).filter { $0.rfilename.hasSuffix(".safetensors") }.reduce(0) { $0 + $1.bytes }
    }
}

/// The refusal rate a model's author states on its card.
struct RefusalBadge: View {
    let report: RefusalReport?
    let checked: Bool

    var body: some View {
        if let report {
            let color: Color = report.rate <= 0.05 ? .green : report.rate <= 0.15 ? .orange : .red
            Label("Refuses \(report.percentText)", systemImage: report.rate <= 0.0001 ? "checkmark.seal.fill" : "hand.raised")
                .font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
                .help("Stated by the model's author\(report.fromBase ? " on the card of the model this was converted from" : "") (\(report.figure)), not verified by Mirage:\n“\(report.snippet)”")
        } else {
            Text(checked ? "Rate not stated" : "Reading card…")
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.primary.opacity(0.05), in: Capsule())
                .help(checked ? "This model's card gives no measured refusal rate." : "")
        }
    }
}

struct ChatModelRow: View {
    let model: HFModel
    let search: ChatModelSearch
    @State private var settings = AppSettings.shared

    var body: some View {
        let bytes = search.sizes[model.id]
        let fit = bytes.map { MemoryPlanner.chatFit(weightBytes: $0, memoryLimitGB: settings.memoryLimitGB) }
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id.split(separator: "/").last.map(String.init) ?? model.id).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(model.id.split(separator: "/").first.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary)
                    if let q = model.quantLabel { Tag(text: q) }
                    if let bytes { Tag(text: Format.bytes(bytes)) }
                    Label(Format.count(model.downloads ?? 0), systemImage: "arrow.down.to.line").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if search.customCode.contains(model.id) {
                Label("Runs its own code", systemImage: "exclamationmark.shield").font(.caption.weight(.medium))
                    .foregroundStyle(.orange).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3).background(.orange.opacity(0.14), in: Capsule())
                    .help("This model ships program code that runs on your Mac when it loads. Mirage has not reviewed it.")
            }
            RefusalBadge(report: search.refusals[model.id], checked: search.checked.contains(model.id))
            if let fit { FitBadge(fit: fit, compact: true) }
            Button("Model Card", systemImage: "safari") { NSWorkspace.shared.open(HFClient.pageURL(model.id)) }
                .buttonStyle(IconButtonStyle(size: 26)).help("Open this model's card on Hugging Face")
            DownloadControl(repo: model.id, title: model.id.split(separator: "/").last.map(String.init) ?? model.id,
                            tags: model.tags, library: model.libraryName,
                            blocked: fit == .tooLarge && !settings.unlockLimits)
                .frame(width: 200)
        }
        .padding(.vertical, 4)
        .task { await search.size(for: model.id) }
    }
}
