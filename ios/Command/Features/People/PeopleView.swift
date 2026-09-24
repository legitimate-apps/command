//
//  PeopleView.swift
//  Command
//

import SwiftUI
import UIKit

struct PeopleView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    @State private var editorTarget: EditorTarget?
    @State private var searchText = ""
    @State private var searchActive = false   // hidden until the 🔍 button reveals it
    @State private var personToDelete: Delegatee?

    /// iPad/Mac shell (Navigator present) → the shared detail column; iPhone → editor sheet.
    private func open(_ delegatee: Delegatee) {
        if let nav, nav.hasDetailColumn { nav.selectedPersonId = delegatee.id }
        else { editorTarget = .edit(delegatee) }
    }

    /// Client-side filter over the already-loaded roster (case/diacritic-insensitive).
    private var filteredDelegatees: [Delegatee] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return app.people.delegatees }
        return app.people.delegatees.filter { $0.name.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    if searchActive {
                        InlineSearchBar(text: $searchText, prompt: "Search people") {
                            withAnimation(.easeOut(duration: 0.2)) { searchActive = false }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let error = app.people.errorMessage {
                        ErrorBanner(message: error) {
                            Task { await app.people.load(client: app.client) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    content
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { searchActive = true } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    }
                    .tint(Palette.accent)
                    .accessibilityLabel("Search people")
                    .disabled(app.people.delegatees.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorTarget = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add person")
                }
            }
            .sheet(item: $editorTarget) { DelegateeEditor(target: $0).macSheet() }
            .confirmationDialog("Remove person?", isPresented: Binding(
                get: { personToDelete != nil },
                set: { if !$0 { personToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Haptics.delete()
                    if let person = personToDelete {
                        Task { await app.people.remove(id: person.id, client: app.client) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(personToDelete?.name ?? "") will be removed from your roster.")
            }
            .task { await app.people.load(client: app.client) }
            .refreshable { await app.people.load(client: app.client) }
            // ⌘F / "Find" reveals the hidden search field.
            .onChange(of: nav?.focusSearch, initial: true) { _, want in
                if want == true { withAnimation(.easeOut(duration: 0.2)) { searchActive = true }; nav?.focusSearch = false }
            }
            #if DEBUG
            // Screenshot hook: `-COMMAND_PREVIEW_SEARCH <query>` opens search pre-filled.
            .onAppear {
                if let q = UserDefaults.standard.string(forKey: "COMMAND_PREVIEW_SEARCH"), !q.isEmpty {
                    searchText = q; searchActive = true
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.people.delegatees.isEmpty {
            if app.people.isLoading {
                SkeletonList(count: 4)
                    .accessibilityLabel("Loading people")
            } else if app.people.errorMessage != nil {
                EmptyView()
            } else {
                emptyState
            }
        } else {
            let people = filteredDelegatees
            if people.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(people) { delegatee in
                            DelegateeRow(delegatee: delegatee)
                                .tappableRow { open(delegatee) }
                                .hoverEffect()
                                .contextMenu {
                                    Button(role: .destructive) {
                                        personToDelete = delegatee
                                    } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36)).foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("No matches").font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text("No people match “\(searchText)”.")
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyState: some View {
        CommandEmptyState(
            icon: "person.2",
            title: "Build your roster",
            message: "Add the people and AI models you delegate to. Give each one the advance notice they need.",
            actionLabel: "Add someone"
        ) { editorTarget = .new }
    }
}

enum EditorTarget: Identifiable {
    case new
    case edit(Delegatee)
    var id: String { if case .edit(let d) = self { return "edit-\(d.id)" } else { return "new" } }
}

struct DelegateeRow: View {
    let delegatee: Delegatee
    private var isModel: Bool { delegatee.kind == "ai_model" }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isModel ? Palette.accentSoft : Palette.sage.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: isModel ? "cpu" : "person.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(isModel ? Palette.accent : Palette.sage)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(delegatee.name)
                    .font(Typeface.body(16, .medium))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    Text(isModel ? "AI model" : "Person")
                    if delegatee.leadTimeMinutes > 0 {
                        Text("· \(LeadTime.label(delegatee.leadTimeMinutes)) notice")
                    }
                }
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkSecondary)
                if let note = delegatee.metadata["note"]?.displayString, !note.isEmpty {
                    Text(note).font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !delegatee.active {
                Text("inactive")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.hairline, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .contentShape(Rectangle())
    }
}

struct DelegateeEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let target: EditorTarget
    /// Called with the saved delegatee after a successful create/update — lets the
    /// capture-dock assignee picker select the just-added person. No-op by default.
    var onSaved: (Delegatee) -> Void = { _ in }

    @State private var name = ""
    @State private var kind = "human"
    @State private var leadMinutes = 0
    @State private var notes = ""
    @State private var modelId = ""
    @State private var active = true
    @State private var saving = false
    @State private var inviteToken: String?
    @State private var inviteBusy = false
    @State private var inviteError: String?
    @State private var copiedInvite = false
    @State private var confirmRevoke = false

    private var existing: Delegatee? { if case .edit(let d) = target { return d } else { return nil } }

    private var leadOptions: [(label: String, minutes: Int)] {
        var opts = LeadTime.presets
        if !opts.contains(where: { $0.minutes == leadMinutes }) {
            opts.append((LeadTime.label(leadMinutes), leadMinutes))
        }
        return opts.sorted { $0.minutes < $1.minutes }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Person").tag("human")
                        Text("AI model").tag("ai_model")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Kind")
                        .accessibilityAddTraits(.isHeader)
                }
                if kind == "ai_model" {
                    Section {
                        TextField("Model id (e.g. claude-opus-5.5)", text: $modelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Model")
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Section {
                    Picker("Needs notice", selection: $leadMinutes) {
                        ForEach(leadOptions, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                } header: {
                    Text("Lead time")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("How far ahead they need to be told. The app warns when work is scheduled inside this window.")
                }
                Section {
                    TextField("Anything to remember…", text: $notes, axis: .vertical).lineLimit(2...5)
                } header: {
                    Text("Notes")
                        .accessibilityAddTraits(.isHeader)
                }
                if existing != nil {
                    Section { Toggle("Active", isOn: $active) }
                }
                if let person = existing,
                   kind == "human", active, !person.isSelf {
                    inviteSection(person)
                }
            }
            .navigationTitle(existing == nil ? "New person" : "Edit person")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.fixedSize() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .fixedSize()
                }
            }
            .onAppear(perform: populate)
            .confirmationDialog("Revoke Command access?", isPresented: $confirmRevoke,
                                titleVisibility: .visible) {
                Button("Revoke access", role: .destructive) {
                    if let person = existing { revokeInvite(for: person) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This immediately signs this person out on every device and invalidates their invite.")
            }
        }
    }

    @ViewBuilder private func inviteSection(_ person: Delegatee) -> some View {
        Section {
            if let inviteToken {
                Text(inviteToken)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Button {
                    SecretPasteboard.copy(inviteToken)
                    Haptics.success()
                    copiedInvite = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedInvite = false
                    }
                } label: {
                    Label(copiedInvite ? "Copied" : "Copy invite", systemImage: copiedInvite ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copiedInvite ? "Invite copied" : "Copy invite")

                // Share the deep link plus the raw token: with Command installed the link
                // connects to this server and opens the redeem sheet; without it, the server
                // address and pasteable token (the "I have an invite" path) still work.
                ShareLink(item: "You're invited to Command. With the app installed, tap: \(app.inviteLink(token: inviteToken))\n\nOr open Command, connect to \(app.serverURLString), choose \u{201C}I have an invite\u{201D}, and paste: \(inviteToken)") {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                }
            }

            Button(inviteToken == nil ? "Invite to Command" : "Regenerate invite") {
                createInvite(for: person)
            }
            .disabled(inviteBusy)

            Button("Revoke access", role: .destructive) { confirmRevoke = true }
                .disabled(inviteBusy)

            if inviteBusy { ProgressView().controlSize(.small) }
            if let inviteError {
                ErrorBanner(message: inviteError, retry: nil)
            }
        } header: {
            Text("Command access").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(inviteToken == nil
                 ? "Generate a private invite for this person. Regenerating replaces any prior invite and signs out their devices."
                 : "Copy or share this token now — Command cannot show it again after you leave this screen.")
        }
    }

    private func populate() {
        guard let e = existing else { return }
        name = e.name
        kind = e.kind
        leadMinutes = e.leadTimeMinutes
        notes = e.metadata["note"]?.displayString ?? ""
        modelId = e.metadata["model_id"]?.displayString ?? ""
        active = e.active
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            var meta: [String: JSONValue] = [:]
            // Preserve metadata keys we don't surface in this editor.
            if let e = existing {
                for (k, v) in e.metadata where k != "note" && k != "model_id" { meta[k] = v }
            }
            let trimmedNote = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNote.isEmpty { meta["note"] = .string(trimmedNote) }
            let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "ai_model", !trimmedModel.isEmpty { meta["model_id"] = .string(trimmedModel) }

            let saved = await app.people.upsert(
                name: name.trimmingCharacters(in: .whitespaces),
                slug: existing?.slug, kind: kind, leadTimeMinutes: leadMinutes,
                metadata: meta, active: active, client: app.client)
            if let saved {
                Haptics.success()
                onSaved(saved)
                dismiss()
            }
        }
    }

    private func createInvite(for person: Delegatee) {
        Task {
            inviteBusy = true
            defer { inviteBusy = false }
            do {
                inviteToken = try await app.client.createDelegateeInvite(id: person.id)
                inviteError = nil
                Haptics.success()
            } catch {
                inviteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.warning()
            }
        }
    }

    private func revokeInvite(for person: Delegatee) {
        Task {
            inviteBusy = true
            defer { inviteBusy = false }
            do {
                try await app.client.revokeDelegateeInvite(id: person.id)
                inviteToken = nil
                inviteError = nil
                Haptics.delete()
            } catch {
                inviteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.warning()
            }
        }
    }
}
