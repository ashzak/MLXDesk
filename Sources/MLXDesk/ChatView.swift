import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool
    // Whether the bottom of the transcript is currently on screen. Driven by the
    // sentinel's onAppear/onDisappear below (LazyVStack mounts/unmounts children
    // as they scroll in and out of view, so this tracks real visibility, not just
    // "did the user drag"). Streaming only autoscrolls while this stays true, so
    // scrolling up to reread earlier text is never fought by the next token.
    @State private var pinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = model.conversations.selected, !conversation.messages.isEmpty {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(spacing: 18) {
                                ForEach(conversation.messages) { message in
                                    MessageBubble(
                                        message: message,
                                        isStreaming: model.isGenerating && message.id == conversation.messages.last?.id
                                    )
                                    .id(message.id)
                                }
                                if model.isGenerating { ThinkingIndicator(modelName: model.selectedModel.displayName).id("thinking") }
                                Color.clear.frame(height: 1).id("bottomAnchor")
                                    .onAppear { pinnedToBottom = true }
                                    .onDisappear { pinnedToBottom = false }
                            }
                            .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: 920)
                            .frame(maxWidth: .infinity)
                        }
                        .onChange(of: conversation.messages.last?.content) { _, _ in
                            guard pinnedToBottom else { return }
                            let target: AnyHashable? = model.isGenerating ? AnyHashable("thinking") : conversation.messages.last.map { AnyHashable($0.id) }
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                        .onChange(of: model.isGenerating) { wasGenerating, isGenerating in
                            // A message just started (either the user's own send, or a
                            // resumed/retried generation): snap back to the bottom even if
                            // the previous turn had scrolled away, matching what a user
                            // expects when they act on the conversation.
                            guard !wasGenerating, isGenerating else { return }
                            pinnedToBottom = true
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                        .onAppear {
                            // .onChange above only fires on a CHANGE, never for the value a
                            // view already holds the moment it appears. The very first time a
                            // conversation goes from empty to non-empty (e.g. sending the
                            // first message), this ScrollView is created fresh with both
                            // messages already in it -- no "change" ever happens, so without
                            // this the view just sits at SwiftUI's default top-anchored
                            // position instead of the bottom, reading as a blank/wrong screen
                            // until the user manually scrolls. Same story when switching to a
                            // conversation that already has messages.
                            let target: AnyHashable? = model.isGenerating ? AnyHashable("thinking") : conversation.messages.last.map { AnyHashable($0.id) }
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                        if !pinnedToBottom {
                            Button {
                                pinnedToBottom = true
                                let target: AnyHashable? = model.isGenerating ? AnyHashable("thinking") : conversation.messages.last.map { AnyHashable($0.id) }
                                withAnimation { proxy.scrollTo(target, anchor: .bottom) }
                            } label: {
                                Label("Jump to Latest", systemImage: "arrow.down.circle.fill").labelStyle(.iconOnly).font(.title2)
                            }
                            .buttonStyle(.borderedProminent).clipShape(Circle())
                            .padding(16)
                            .help("Jump to the latest message")
                            .accessibilityLabel("Jump to latest message")
                            .accessibilityIdentifier("chat.jumpToLatest")
                        }
                    }
                }
            } else {
                EmptyChatView(model: model)
            }
            Divider()
            if model.runtime != .running {
                RuntimeActionPanel(model: model)
            }
            ComposerView(model: model, focused: $composerFocused)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear { composerFocused = true }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    var isUser: Bool { message.role == .user }
    @State private var copied = false
    @State private var downloaded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 80) }
            if !isUser { Image(systemName: "sparkles").foregroundStyle(.tint).frame(width: 28, height: 28).background(.tint.opacity(0.12), in: Circle()) }
            VStack(alignment: .leading, spacing: 10) {
                Text(isUser ? "You" : "Assistant").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if message.content.isEmpty { ProgressView().controlSize(.small).accessibilityLabel("Generating response") }
                else { MessageContentText(message.content).textSelection(.enabled).font(.body).lineSpacing(3) }
                if !message.content.isEmpty {
                    Divider()
                    HStack(spacing: 14) {
                        Button { copyMessage() } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help(copied ? "Copied to clipboard" : isUser ? "Copy prompt" : "Copy response")
                        .accessibilityLabel(copied ? "Copied" : isUser ? "Copy prompt" : "Copy response")
                        .accessibilityIdentifier("message.copy.\(message.id.uuidString)")

                        if !isUser {
                            Button { downloadResponse() } label: {
                                Label(downloaded ? "Saved" : "Download", systemImage: downloaded ? "checkmark" : "arrow.down.to.line")
                            }
                            .help(downloaded ? "Response saved" : "Save response as Markdown")
                            .accessibilityLabel(downloaded ? "Response saved" : "Download response")
                            .accessibilityIdentifier("message.download.\(message.id.uuidString)")
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
            .padding(14)
            .background(isUser ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(isUser ? "You" : "Assistant") message")
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func downloadResponse() {
        let panel = NSSavePanel()
        panel.title = "Save LLM Response"
        panel.nameFieldStringValue = MessageExport.filename(for: message.content)
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try message.content.write(to: url, atomically: true, encoding: .utf8)
            downloaded = true
            Task { try? await Task.sleep(for: .seconds(1.5)); downloaded = false }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "The response couldn’t be saved"
            alert.runModal()
        }
    }
}

/// Renders chat content with light inline Markdown (bold, italic, code spans, links)
/// applied identically while streaming and once finished, so the bubble never visibly
/// changes shape the instant generation completes.
///
/// Deliberately uses `AttributedString(markdown:)`, not `Text(LocalizedStringKey)`: the
/// latter also performs a lookup against this app's own `Localizable.strings` tables, so
/// model output that happened to match a localization key verbatim (or contained `%`-style
/// format specifiers, as generated code often does) could be silently reinterpreted.
/// `AttributedString(markdown:)` only ever parses Markdown and falls back to the exact
/// literal string if parsing throws.
struct MessageContentText: View {
    private let content: String
    init(_ content: String) { self.content = content }

    /// A chunk of message content: either prose (rendered with full block-aware
    /// Markdown -- headers, lists, bold, etc.) or a fenced code block (rendered
    /// verbatim in a monospaced view, since Markdown's soft-break rule would
    /// otherwise collapse a multi-line code sample's newlines into spaces and
    /// leave the ``` fences showing as literal text).
    private enum Segment { case text(String), code(language: String?, code: String) }

    /// Parsing content into segments (fence-splitting) and, per text segment,
    /// into an `AttributedString` (full CommonMark-ish Markdown) is real work --
    /// and `body` runs far more often than once per visible change: SwiftUI
    /// proposes multiple candidate sizes while laying out a flexible-width
    /// ScrollView, and any change to an `@Observable` property an ancestor view
    /// reads (e.g. `isGenerating` toggling on every send) can trigger a fresh
    /// body evaluation across the whole message list. Redoing both parses for
    /// every message in a real conversation (76 messages, several with large
    /// code blocks) on every such pass reproduced a genuine multi-minute SwiftUI
    /// layout hang -- confirmed live via `sample`: pegged inside the
    /// AttributeGraph/layout engine, not actually deadlocked, just repeating
    /// this work forever. Caching both by the exact content string sidesteps
    /// that regardless of how many times SwiftUI calls in: a still-streaming
    /// message's content changes on every token and so naturally invalidates
    /// its own entry, while every complete, unchanging message reuses its
    /// parse instantly. NSCache (not a plain dictionary) evicts under memory
    /// pressure, so a very long session doesn't grow this unboundedly.
    private static let segmentCache = NSCache<NSString, SegmentBox>()
    private final class SegmentBox { let segments: [Segment]; init(_ segments: [Segment]) { self.segments = segments } }
    private static let attributedCache = NSCache<NSString, AttributedBox>()
    private final class AttributedBox { let value: AttributedString?; init(_ value: AttributedString?) { self.value = value } }

    private static func attributedString(for text: String) -> AttributedString? {
        let key = text as NSString
        if let cached = attributedCache.object(forKey: key) { return cached.value }
        let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))
        attributedCache.setObject(AttributedBox(value), forKey: key)
        return value
    }

    /// Splits on ``` fences. A fence left open at the end of `content` (the
    /// model is still streaming inside it) is still treated as code, not left
    /// as a dangling literal fence marker in the prose.
    private static func segments(of content: String) -> [Segment] {
        let cacheKey = content as NSString
        if let cached = segmentCache.object(forKey: cacheKey) { return cached.segments }
        var result: [Segment] = []
        var textLines: [String] = []
        func flushText() {
            guard !textLines.isEmpty else { return }
            result.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll()
        }
        let lines = content.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                flushText()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index]); index += 1
                }
                result.append(.code(language: language.isEmpty ? nil : language, code: codeLines.joined(separator: "\n")))
                index += 1
            } else {
                textLines.append(line); index += 1
            }
        }
        flushText()
        segmentCache.setObject(SegmentBox(result), forKey: cacheKey)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(of: content).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    if let attributed = Self.attributedString(for: text) {
                        Text(attributed)
                    } else {
                        Text(text)
                    }
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(6)
            .help("Copy code")
            .accessibilityLabel("Copy code")
        }
    }
}

enum MessageExport {
    static func filename(for content: String) -> String {
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "LLM Response"
        let safe = firstLine
            .replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((safe.isEmpty ? "LLM Response" : safe).prefix(60)) + ".md"
    }
}

struct ComposerView: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding
    @State private var isTargetedForDrop = false
    var canSend: Bool {
        (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty) && !model.isGenerating
            && (model.runtime == .running || ProcessInfo.processInfo.environment["MLX_DESK_UI_TESTING"] == "1")
    }

    var body: some View {
        VStack(spacing: 8) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { presentFilePicker() } label: { Image(systemName: "paperclip").frame(width: 28, height: 28) }
                    .buttonStyle(.bordered)
                    .help("Attach files as context")
                    .accessibilityLabel("Attach files").accessibilityIdentifier("composer.attach")
                TextField("Ask \(model.selectedModel.displayName)…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...8).focused(focused).font(.body)
                    .onSubmit { if canSend { model.send() } }
                    .accessibilityIdentifier("composer.input")
                if model.isGenerating {
                    Button { model.stopGeneration() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).tint(.red).help("Stop generating")
                        .accessibilityLabel("Stop generating").accessibilityIdentifier("composer.stop")
                } else if canSend {
                    Button { model.send() } label: { Image(systemName: "arrow.up").frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Command-Return)").accessibilityLabel("Send message").accessibilityIdentifier("composer.send")
                } else {
                    // A disabled .borderedProminent still renders at close to full
                    // saturation on macOS, so it visually reads as "ready to send" even
                    // when it isn't (e.g. before the model has been loaded); a gray tint on
                    // a prominent button just renders near-black, which is worse. Plain
                    // .bordered while disabled reads clearly as inactive instead.
                    Button { model.send() } label: { Image(systemName: "arrow.up").frame(width: 28, height: 28) }
                        .buttonStyle(.bordered).disabled(true).keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Command-Return)").accessibilityLabel("Send message").accessibilityIdentifier("composer.send")
                }
            }
            HStack {
                Text(composerHint).font(.caption).foregroundStyle(model.runtime == .running ? .tertiary : .secondary)
                Spacer()
                if let first = model.timeToFirstToken {
                    Text("First token \(first, format: .number.precision(.fractionLength(1)))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let speed = model.tokensPerSecond {
                    Text("· \(speed, format: .number.precision(.fractionLength(1))) tok/s decode").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isTargetedForDrop ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: isTargetedForDrop ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addAttachments(from: urls) }
            return true
        } isTargeted: { isTargetedForDrop = $0 }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // No allowedContentTypes restriction: addAttachments already skips anything
        // that doesn't decode as UTF-8 text, which is a more accurate filter than any
        // extension/UTType allowlist (e.g. a .log or extensionless file is still text).
        guard panel.runModal() == .OK else { return }
        Task { await model.addAttachments(from: panel.urls) }
    }

    private var composerHint: String {
        switch model.runtime {
        case .running: "⌘↩ to send · Return for a new line"
        case .downloading: "You can write your prompt while the model downloads"
        case .starting: "You can write your prompt while the model loads"
        case .checking: "Checking the local MLX runtime…"
        case .unavailable: "Set up MLX-LM before sending"
        case .ready: "Start the selected model before sending"
        case .failed: "Resolve the model issue before sending"
        }
    }
}

struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.caption)
            Text(attachment.filename).font(.caption).lineLimit(1)
            if attachment.truncated {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    .help("Only the first part of this file was attached")
            }
            Button { remove() } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Remove \(attachment.filename)")
                .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.5)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.attachment.\(attachment.filename)")
    }
}

struct RuntimeActionPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if case .downloading(let percent) = model.runtime {
                    LinearProgressRow(label: "Downloading \(model.selectedModel.displayName)", percent: percent >= 0 ? percent : nil, accessibilityID: "runtime.downloadProgress")
                        .padding(.top, 2)
                }
                if model.runtime == .starting {
                    LinearProgressRow(label: model.runtimePhase.label, percent: model.runtimePhase.stepProgress.map { Int($0 * 100) }, accessibilityID: "runtime.loadProgress")
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            if let actionTitle {
                Button(actionTitle) { performAction() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("runtime.primaryAction")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runtime.actionPanel")
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.runtime {
        case .downloading:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        case .checking:
            ProgressView().controlSize(.small)
        case .starting:
            Image(systemName: "bolt.fill").foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.blue)
        case .ready:
            Image(systemName: "cpu").foregroundStyle(.tint)
        case .running:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var title: String {
        switch model.runtime {
        case .checking: "Checking MLX"
        case .unavailable: "MLX-LM needs setup"
        case .ready: "Model is ready to load"
        case .downloading: "Downloading \(model.selectedModel.displayName)"
        case .starting: model.runtimePhase.label
        case .failed: "The model needs attention"
        case .running: "Model online"
        }
    }

    private var detail: String {
        switch model.runtime {
        case .checking: "This usually takes only a moment."
        case .unavailable: "Install the local engine to run models privately on this Mac."
        case .ready: model.selectedModelDownloaded ? "Already downloaded; startup should be quick." : "The first start downloads \(model.selectedModel.size). Progress will appear here."
        case .downloading: model.runtimeDetail.isEmpty ? "Keep this window open. You can prepare your prompt in the meantime." : model.runtimeDetail
        case .starting: model.runtimeDetail.isEmpty ? "Preparing the local server. A 30B model can take up to 90 seconds to warm up." : model.runtimeDetail
        case .failed: "Open the error details or retry the selected model."
        case .running: "Ready for prompts."
        }
    }

    private var actionTitle: String? {
        switch model.runtime {
        case .unavailable: "Set Up"
        case .ready, .failed: model.inspectorPresented ? nil : "Open Model Settings"
        default: nil
        }
    }

    private func performAction() {
        switch model.runtime {
        case .unavailable: model.setupPresented = true
        case .ready, .failed: model.inspectorPresented = true
        default: break
        }
    }
}

/// A plain horizontal progress bar with a label and percentage -- used for both
/// download progress and model-loading (startup) progress. Deliberately just
/// `ProgressView(.linear)`, not a custom shape: a filling-bottle metaphor has to
/// be learned, a standard progress bar reads instantly. `percent == nil` (the
/// `unknownDownloadPercent` sentinel, or a startup phase with no step mapped)
/// renders as indeterminate rather than guessing a number.
struct LinearProgressRow: View {
    let label: String
    let percent: Int?
    var accessibilityID: String = "progress.bar"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let percent {
                    Text("\(percent)%").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let percent {
                ProgressView(value: Double(percent), total: 100).progressViewStyle(.linear).tint(.accentColor)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(percent.map { "\($0) percent" } ?? "in progress")
        .accessibilityIdentifier(accessibilityID)
    }
}

struct EmptyChatView: View {
    @Bindable var model: AppModel
    let prompts = ["Explain a piece of code", "Plan a new feature", "Find a likely bug"]
    var body: some View {
        ContentUnavailableView {
            Label("What are we building?", systemImage: "chevron.left.forwardslash.chevron.right")
        } description: {
            Text("\(model.selectedModel.displayName) runs privately on your Mac. Start with a task or paste some code below.")
        } actions: {
            ViewThatFits {
                HStack { promptButtons }
                VStack { promptButtons }
            }
        }
    }

    @ViewBuilder private var promptButtons: some View {
        ForEach(prompts, id: \.self) { prompt in
            Button(prompt) { model.draft = prompt }
                .accessibilityIdentifier("prompt.\(prompt)")
        }
    }
}

struct ThinkingIndicator: View {
    let modelName: String
    @State private var pulse = false
    var body: some View {
        HStack { ProgressView().controlSize(.small); Text("\(modelName) is working…").foregroundStyle(.secondary); Spacer() }
            .padding(.horizontal, 40).opacity(pulse ? 0.65 : 1).onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
            .accessibilityLabel("\(modelName) is generating a response")
    }
}
