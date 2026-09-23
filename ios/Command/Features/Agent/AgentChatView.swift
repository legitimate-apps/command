//
//  AgentChatView.swift
//  Command
//
//  The AI assistant tab: a streaming chat over the user's planning data. Renders
//  the active thread's transcript with live tool-status chips and token-by-token
//  text, a slim monthly-budget meter, history, and a "new chat" action. Same
//  "paper-and-ink" language as the rest of the app.
//

import PhotosUI
import SwiftUI
import UIKit

struct AgentChatView: View {
    /// On iPhone (compact) the chat owns its own history + new-chat toolbar buttons. In the
    /// iPad/Mac split the conversation list lives in the content column, so the detail-column
    /// chat hides those controls to avoid duplicating them.
    var showsThreadControls = true

    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    @State private var draft = ""
    @State private var showHistory = false
    @State private var showRecording = false
    @State private var voiceLaunchIsPrepared = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    // Edit-and-resend (E3): the user bubble being edited + its working draft, surfaced in an alert.
    @State private var editingId: UUID?
    @State private var editDraft = ""
    // Tappable tool chip (E2a): the entity a completed chip opened, shown as a detail sheet.
    @State private var openedEntity: DetailSubject?
    @State private var entityError: String?
    @FocusState private var fieldFocused: Bool

    private var store: AgentStore { app.agent }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    budgetMeter
                    transcript
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)   // transparent bar; content shows through
            .toolbar { toolbarItems }
            .safeAreaInset(edge: .bottom) { inputBar }
            .sheet(isPresented: $showHistory) {
                AgentThreadsView(onPick: { id in
                    Task { await store.openThread(id, client: app.client) }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .macSheet(.page)
            }
            .sheet(isPresented: $showRecording) {
                voiceRecordingSheet
            }
            // "Ask the assistant" from elsewhere in the app arrives as a seeded draft. Appended
            // rather than assigned, so it can never silently discard something already typed.
            .onChange(of: nav?.assistantSeed, initial: true) { _, seed in
                guard let seed, !seed.isEmpty else { return }
                draft = draft.isEmpty ? seed : draft + " " + seed
                fieldFocused = true
                nav?.assistantSeed = nil
            }
            .onChange(of: nav?.startVoiceConversation, initial: true) { _, requested in
                guard requested == true else { return }
                app.agent.newChat()
                voiceLaunchIsPrepared = true
                showRecording = true
                nav?.startVoiceConversation = false
            }
            .photosPicker(
                isPresented: $showLibrary, selection: $photoItems,
                maxSelectionCount: max(1, AgentStore.maxImages - store.pendingImages.count),
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                photoItems = []
                Task { await loadPicked(picked) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in addImage(image) }
                    .ignoresSafeArea()
            }
            // Edit-and-resend a past user turn (E3). Replies after it are dropped and the edited
            // message is re-sent through the same race-safe generation counter as a fresh send.
            .alert("Edit & resend", isPresented: Binding(
                get: { editingId != nil },
                set: { if !$0 { editingId = nil } }
            )) {
                TextField("Message", text: $editDraft, axis: .vertical)
                Button("Resend") {
                    if let id = editingId { store.editAndResend(messageId: id, newText: editDraft, client: app.client) }
                    editingId = nil
                }
                Button("Cancel", role: .cancel) { editingId = nil }
            } message: {
                Text("Send an edited version of this message. Anything after it is removed.")
            }
            // A completed tool chip opened its entity (E2a) — show it as a detail sheet, which
            // works in both the compact (iPhone) and split (iPad/Mac) shells without a detail column.
            .sheet(item: $openedEntity) { subject in
                NavigationStack { EntityDetailView(subject: subject) }.macSheet(.page)
            }
            .alert("Couldn't open that", isPresented: Binding(
                get: { entityError != nil }, set: { if !$0 { entityError = nil } }
            )) {
                Button("OK", role: .cancel) { entityError = nil }
            } message: { Text(entityError ?? "") }
            .task {
                await store.loadThreads(client: app.client)
                await store.loadUsage(client: app.client)
                #if DEBUG
                // Screenshot hook: `-COMMAND_AGENT_DEMO "ask…"` auto-sends one message
                // so a live streamed conversation can be captured. Debug builds only.
                if let demo = UserDefaults.standard.string(forKey: "COMMAND_AGENT_DEMO"),
                   !demo.isEmpty, store.transcript.isEmpty, !store.isStreaming {
                    store.send(demo, client: app.client)
                }
                #endif
            }
        }
    }

    private var voiceRecordingSheet: some View {
        RecordingSheet(
            onUse: acceptTranscription,
            requiresPreparedPermission: voiceLaunchIsPrepared,
            useImmediatelyAfterTranscription: voiceLaunchIsPrepared
        )
        .macSheet()
    }

    private func acceptTranscription(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if voiceLaunchIsPrepared {
            _ = store.send(cleaned, client: app.client)
            voiceLaunchIsPrepared = false
        } else {
            draft = draft.isEmpty ? cleaned : draft + " " + cleaned
            fieldFocused = true
        }
    }

    private var navTitle: String {
        guard let id = store.currentThreadId,
              let t = store.threads.first(where: { $0.id == id })?.title,
              !t.isEmpty else { return "Assistant" }
        return t
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if showsThreadControls {
            ToolbarItem(placement: .topBarLeading) {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.accent)
                }
                .accessibilityLabel("Chat history")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.newChat()
                    fieldFocused = true
                } label: {
                    Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                }
                .accessibilityLabel("New chat")
                .disabled(store.transcript.isEmpty && store.currentThreadId == nil)
            }
        }
    }

    // MARK: Budget meter

    @ViewBuilder
    private var budgetMeter: some View {
        if let u = store.usage {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Palette.accent).accessibilityHidden(true)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.hairline)
                        Capsule().fill(Palette.accent)
                            .frame(width: max(4, geo.size.width * store.budgetFraction))
                    }
                }
                .frame(height: 4)
                // Credits are a ×3 display of the real backend USD budget for subscribers;
                // dev/comp/flat-cap accounts show the raw remaining dollars (decision 2026-07-06).
                Text("$\(u.displayRemaining, specifier: "%.2f") left")
                    .font(Typeface.body(11, .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.transcript.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(store.transcript.enumerated()), id: \.element.id) { index, message in
                            ChatBubble(
                                message: message,
                                isLast: index == store.transcript.count - 1,
                                isStreaming: store.isStreaming,
                                onOpenEntity: { openEntity($0) },
                                onEdit: { beginEdit($0) },
                                onRegenerate: { store.regenerateLast(client: app.client) },
                                onConfirm: { store.send("Yes, do it.", client: app.client) },
                                onCancel: { store.send("No — cancel that, don't delete anything.", client: app.client) }
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.transcript.count) { _, _ in scrollDown(proxy) }
            .onChange(of: store.transcript.last?.text.count ?? 0) { _, _ in scrollDown(proxy, animated: false) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !store.transcript.isEmpty else { return }
        if animated { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        else { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
                .padding(.top, 48)
            Text("Your planning assistant")
                .font(Typeface.display(24))
                .foregroundStyle(Palette.ink)
            Text("Ask me to turn your notes into goals and tasks, delegate to your people, or look something up.")
                .font(Typeface.body(15))
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 10) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        draft = example
                        fieldFocused = true
                    } label: {
                        HStack {
                            Text(example).font(Typeface.body(14)).foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .cardSurface(cornerRadius: 14, elevated: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private static let examples = [
        "Review my notes and suggest goals",
        "What should I delegate this week?",
        "Plan a dinner party for 8 on Saturday",
    ]

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { modelPicker; hiddenToggle; Spacer() }
            if !store.pendingImages.isEmpty { attachmentPreview }
            queuedIndicator
            chatField
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.paper)
    }

    // MARK: Image attachments

    /// Horizontal strip of staged image thumbnails, each removable. Shown above the
    /// field only while images are pending and the model can read them.
    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.pendingImages) { attachment in
                    thumbnail(attachment)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 64)
    }

    @ViewBuilder
    private func thumbnail(_ attachment: ChatAttachment) -> some View {
        if let image = UIImage(data: attachment.jpeg) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Button {
                        store.pendingImages.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove image")
                }
        }
    }

    /// Camera + photo-library entry. Every tier is multimodal now (Fast is Haiku 4.5), so
    /// this shows on all of them. Disabled at the attachment cap or mid-stream.
    private var attachButton: some View {
        let canAttach = store.pendingImages.count < AgentStore.maxImages && !store.isStreaming
        return Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        } label: {
            Image(systemName: "photo.badge.plus").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.inkSecondary).frame(width: 40, height: 40)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .disabled(!canAttach)
        .accessibilityLabel("Attach image")
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            if store.pendingImages.count >= AgentStore.maxImages { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let attachment = ChatImageProcessing.attachment(from: image) else { continue }
            store.pendingImages.append(attachment)
        }
    }

    private func addImage(_ image: UIImage) {
        guard store.pendingImages.count < AgentStore.maxImages,
              let attachment = ChatImageProcessing.attachment(from: image) else { return }
        store.pendingImages.append(attachment)
    }

    private var modelPicker: some View {
        Menu {
            Picker("Model", selection: Binding(get: { store.modelChoice }, set: { store.modelChoice = $0 })) {
                ForEach(AgentModelChoice.allCases) { choice in
                    Text("\(choice.label) — \(choice.detail)").tag(choice)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.modelChoice.icon).font(.system(size: 11)).accessibilityHidden(true)
                Text(store.modelChoice.label).font(Typeface.body(12, .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).accessibilityHidden(true)
            }
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .disabled(store.isStreaming)
    }

    /// Per-chat switch: may the assistant read the user's hidden (invisible-ink) items?
    /// Defaults off every new chat (AgentStore.allowHidden); the eye symbol conveys state.
    private var hiddenToggle: some View {
        Button { store.allowHidden.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: store.allowHidden ? "eye" : "eye.slash").font(.system(size: 11)).accessibilityHidden(true)
                Text("Hidden").font(Typeface.body(12, .semibold))
            }
            .foregroundStyle(store.allowHidden ? Palette.accent : Palette.inkSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(store.allowHidden ? Palette.accentSoft : Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(store.allowHidden ? Palette.accent.opacity(0.4) : Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverEffect()   // Mac/iPad pointer feedback
        .disabled(store.isStreaming)
        .accessibilityLabel(store.allowHidden ? "Assistant can read hidden items" : "Assistant cannot read hidden items")
    }

    /// "2 queued · Clear" — queued turns are invisible otherwise, and an invisible queue that
    /// spends money when the current turn ends is a nasty surprise.
    @ViewBuilder private var queuedIndicator: some View {
        if store.queuedCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(store.queuedCount) queued")
                    .font(Typeface.body(12))
                Button("Clear") { store.clearQueue() }
                    .font(Typeface.body(12).weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
            }
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .accessibilityLabel("\(store.queuedCount) messages queued")
        }
    }

    private var chatField: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your assistant…", text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .font(Typeface.body(16))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...6)
                .focused($fieldFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )

            // Stop and Send both stay present while streaming, and Send keeps its position.
            // Previously Send was REPLACED by Stop the instant a turn began, so a second tap
            // landed on Stop under the user's finger — the "Stopped." mid-transcript came from
            // exactly that. Stop sits before Send so it never takes over the send position.
            if store.isStreaming {
                Button { store.cancelStreaming() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(Palette.inkSecondary, in: Circle())
                }
                .accessibilityLabel("Stop")
            } else {
                if store.modelChoice.supportsImages { attachButton }
                micButton
            }
            Button { send() } label: {
                Image(systemName: store.isStreaming ? "arrow.up.to.line" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white).frame(width: 40, height: 40)
                    .background(canSend ? Palette.accent : Palette.inkSecondary.opacity(0.4), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel(store.isStreaming ? "Queue message" : "Send")
        }
    }

    /// Dictate into the input — the same Parakeet-tiered recording flow as note capture,
    /// but the transcript lands in the chat field (to edit + send) instead of saving a note.
    private var micButton: some View {
        Button { showRecording = true } label: {
            Image(systemName: "mic.fill").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.inkSecondary).frame(width: 40, height: 40)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel("Dictate")
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingImages.isEmpty
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingImages.isEmpty else { return }
        // Clear the field ONLY once the store has actually taken the turn. It used to clear
        // unconditionally, so a turn refused mid-stream took the user's typing with it.
        guard store.send(text, client: app.client) else { return }
        draft = ""
    }

    /// Begin editing a past user turn — prefill the alert's draft with the current text.
    private func beginEdit(_ message: ChatMessage) {
        editDraft = message.text
        editingId = message.id
    }

    /// Open the entity a completed tool chip references. Only assignment/goal have an
    /// `EntityDetailView` path today; note/person are left non-tappable in `ToolChip` (TODO:
    /// add DetailSubject cases + single-entity fetchers for those, then extend this switch).
    private func openEntity(_ ref: AgentEntityRef) {
        Task { @MainActor in
            do {
                switch ref.kind {
                case "assignment": openedEntity = .assignment(try await app.client.assignment(id: ref.id))
                case "goal":       openedEntity = .goal(try await app.client.goal(id: ref.id))
                default:           break
                }
            } catch {
                entityError = "\(ref.label) couldn't be opened — it may have changed since."
            }
        }
    }
}

// MARK: - Bubble

private struct ChatBubble: View {
    let message: ChatMessage
    var isLast = false
    var isStreaming = false
    var onOpenEntity: (AgentEntityRef) -> Void = { _ in }
    var onEdit: (ChatMessage) -> Void = { _ in }
    var onRegenerate: () -> Void = { }
    var onConfirm: () -> Void = { }
    var onCancel: () -> Void = { }

    /// The assistant is parked on a destructive-op confirmation (a delete tool ran but nothing
    /// was deleted — the needs_confirm round-trip). Only the freshest, settled turn qualifies.
    private var awaitingConfirmation: Bool {
        isLast && !isStreaming && !message.isUser && !message.pending
            && message.tools.contains(where: \.isAwaitingConfirmation)
    }

    /// Offer "Regenerate" beneath the last settled assistant turn (including a failed one, so a
    /// transient error is one tap to retry) — but not while it's asking for a delete confirmation.
    private var canRegenerate: Bool {
        isLast && !isStreaming && !message.isUser && !message.pending && !awaitingConfirmation
    }

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if !message.images.isEmpty {
                    attachedImages
                }
                if !message.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.tools) { ToolChip(event: $0, onOpen: onOpenEntity) }
                    }
                }
                if message.pending && message.text.isEmpty {
                    if message.tools.isEmpty { TypingIndicator() }
                } else if !message.text.isEmpty {
                    bubbleBody
                }
                if awaitingConfirmation { confirmRow }
                if let caption = caption {
                    Text(caption).font(Typeface.body(11)).foregroundStyle(Palette.inkSecondary)
                        .padding(.horizontal, 4)
                }
                if canRegenerate { regenerateButton }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        let content = Group {
            if message.isUser {
                // Short user turns: plain text (tap to edit — see below), keeps the amber bubble crisp.
                Text(message.text)
                    .font(Typeface.body(16))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Assistant turns render full block markdown (tables/headings/lists/code/rules).
                MarkdownView(text: message.text, tint: message.failed ? Palette.danger : Palette.ink)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(bubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(message.isUser ? Color.clear : Palette.hairline, lineWidth: 1)
        )

        if message.isUser {
            content
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture { onEdit(message) }
                .contextMenu {
                    Button { onEdit(message) } label: { Label("Edit & Resend", systemImage: "pencil") }
                    Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .accessibilityHint("Double-tap to edit and resend")
        } else {
            content
                .contextMenu {
                    Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if canRegenerate {
                        Button { onRegenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    }
                }
        }
    }

    /// Explicit Confirm / Cancel affordance for a destructive op (E4), so the user never has to
    /// know to type "yes." Confirm re-sends an affirmation; the agent then completes the delete
    /// with the confirm-token it's holding in context.
    private var confirmRow: some View {
        HStack(spacing: 10) {
            Button(action: onConfirm) {
                Label("Confirm", systemImage: "checkmark")
                    .font(Typeface.body(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Palette.danger, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(Typeface.body(13, .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private var regenerateButton: some View {
        Button(action: onRegenerate) {
            Label(message.failed ? "Retry" : "Regenerate", systemImage: "arrow.clockwise")
                .font(Typeface.body(12, .medium))
                .foregroundStyle(Palette.inkSecondary)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .padding(.horizontal, 4).padding(.top, 2)
        .accessibilityLabel(message.failed ? "Retry" : "Regenerate response")
    }

    /// Thumbnails of the images sent with this turn (live transcript only — images
    /// aren't persisted server-side, so a reopened thread shows text alone).
    private var attachedImages: some View {
        let columns = min(message.images.count, 3)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: columns),
            spacing: 6
        ) {
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
    }

    private var bubbleFill: Color {
        if message.failed { return Palette.danger.opacity(0.08) }
        return message.isUser ? Palette.accentSoft : Palette.surface
    }

    private var caption: String? {
        guard !message.isUser, !message.pending, let model = message.model else { return nil }
        var parts = [AgentModelLabel.short(model)]
        if let cost = message.costUsd, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tool chip

private struct ToolChip: View {
    let event: ChatToolEvent
    var onOpen: (AgentEntityRef) -> Void = { _ in }

    /// The entity this completed chip can open. Only assignment/goal have an in-app detail
    /// path (EntityDetailView); note/person don't yet (shown, not tappable). A delete/remove
    /// chip is never openable — the thing it references is gone.
    private var openable: AgentEntityRef? {
        guard event.done, let e = event.entity,
              e.kind == "assignment" || e.kind == "goal",
              !event.name.hasPrefix("delete"), !event.name.hasPrefix("remove")
        else { return nil }
        return e
    }

    /// "Creating a task: Make saffron milk" / "Reading your notes: 'meals'". Falls back to the
    /// bare verb when the tool has no subject.
    private var label: String {
        let base = AgentToolLabel.describe(event.name)
        guard let target = (event.detail ?? event.entity?.label)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else { return base }
        if event.name == "search_notes" || event.name == "web_search" {
            return "\(base): \u{201C}\(target)\u{201D}"
        }
        return "\(base): \(target)"
    }

    var body: some View {
        if let entity = openable {
            Button { onOpen(entity) } label: { chip(openable: true) }
                .buttonStyle(.plain)
                .hoverEffect()
                .accessibilityHint("Opens \(entity.label)")
        } else {
            chip(openable: false)
        }
    }

    private func chip(openable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: AgentToolLabel.icon(event.name))
                .font(.system(size: 11)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            Text(label)
                .font(Typeface.body(12, .medium)).foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            if event.done {
                if openable {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent).accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.sage).accessibilityHidden(true)
                }
            } else {
                ProgressView().controlSize(.mini).tint(Palette.accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(openable ? Palette.accentSoft : Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(openable ? Palette.accent.opacity(0.4) : Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Palette.inkSecondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == Double(i) ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: false)) { phase = 2 }
        }
    }
}

// MARK: - Labels

enum AgentToolLabel {
    static func describe(_ name: String) -> String {
        switch name {
        case "search_notes": return "Reading your notes"
        case "create_note": return "Saving a note"
        case "list_assignments": return "Checking your tasks"
        case "create_assignment": return "Creating a task"
        case "update_assignment": return "Updating a task"
        case "set_assignment_status": return "Updating a task"
        case "delete_assignment": return "Deleting a task"
        case "list_people": return "Checking your people"
        case "upsert_person": return "Adding a person"
        case "remove_person": return "Removing a person"
        case "list_goals": return "Reviewing your goals"
        case "create_goal": return "Creating a goal"
        case "delete_goal": return "Deleting a goal"
        case "search_activities": return "Reviewing activity"
        case "delete_activity": return "Deleting an entry"
        case "web_search": return "Searching the web"
        case "fetch_url": return "Reading a link"
        case "get_today_agenda": return "Checking today"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "web_search": return "globe"
        case "fetch_url": return "link"
        case "search_notes", "create_note": return "note.text"
        case "create_goal", "list_goals", "delete_goal": return "target"
        case "create_assignment", "update_assignment", "list_assignments",
             "set_assignment_status", "delete_assignment", "get_today_agenda": return "checklist"
        case "list_people", "upsert_person", "remove_person": return "person.2"
        case "search_activities", "delete_activity": return "clock.arrow.circlepath"
        default: return "wrench.and.screwdriver"
        }
    }
}

enum AgentModelLabel {
    /// A friendly short name from an OpenRouter slug ("anthropic/claude-sonnet-5" → "Sonnet").
    /// Matches on the family, not the version, so a tier bump needs no client change.
    /// Non-Anthropic alternates (GLM / Kimi / GPT) are named here too; anything
    /// unrecognized falls back to the slug's trailing path component.
    static func short(_ slug: String) -> String {
        let s = slug.lowercased()
        if s.contains("opus") { return "Opus" }
        if s.contains("sonnet") { return "Sonnet" }
        if s.contains("haiku") { return "Haiku" }
        if s.contains("glm") { return "GLM" }
        if s.contains("kimi") { return "Kimi" }
        if s.hasPrefix("openai/") || s.contains("gpt") { return "GPT" }
        return slug.split(separator: "/").last.map(String.init) ?? slug
    }
}
