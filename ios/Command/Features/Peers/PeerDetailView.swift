//
//  PeerDetailView.swift
//  Command
//
//  Edit a connected peer's token, enable/disable it, refresh its card, or remove it.
//

import SwiftUI

struct PeerDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let peer: Peer
    var onUpdate: (Peer) -> Void = { _ in }
    var onDelete: (Peer) -> Void = { _ in }

    @State private var current: Peer
    @State private var refreshing = false
    @State private var savingEnabled = false
    @State private var showTokenEntry = false
    @State private var tokenInput = ""
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var error: String?

    init(peer: Peer, onUpdate: @escaping (Peer) -> Void = { _ in }, onDelete: @escaping (Peer) -> Void = { _ in }) {
        self.peer = peer
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _current = State(initialValue: peer)
    }

    var body: some View {
        Form {
            headerSection
            endpointSection
            toggleSection
            tokenSection
            deleteSection
        }
        .brandedForm()
        .navigationTitle(current.card.name)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showTokenEntry) {
            TokenEntrySheet(token: $tokenInput, title: current.hasToken ? "Replace token" : "Add token") { save in
                if save { setToken(tokenInput) } else { tokenInput = "" }
            }
            .macSheet()
        }
        .alert("Could not update peer", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Remove \(current.card.name)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your assistant will no longer be able to reach this agent.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(current.card.name)
                    .font(Typeface.display(22, .semibold))
                    .foregroundStyle(Palette.ink)
                if let description = current.card.description, !description.isEmpty {
                    Text(description)
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(nil)
                }
                if let version = current.card.version, !version.isEmpty {
                    Text("Version \(version)")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary)
                }
                Text("Verified \(RelativeTime.ago(current.cardFetchedAt))")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 2)

                Button {
                    refresh()
                } label: {
                    HStack(spacing: 6) {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        }
                        Text(refreshing ? "Refreshing card…" : "Refresh card")
                    }
                    .font(Typeface.body(15, .medium))
                }
                .tint(Palette.accent)
                .disabled(refreshing)
                .padding(.top, 6)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var endpointSection: some View {
        Section {
            Text(current.url)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
        } header: {
            Text("Endpoint")
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var toggleSection: some View {
        Section {
            Toggle("Enabled", isOn: Binding(
                get: { current.enabled },
                set: { newValue in
                    guard newValue != current.enabled else { return }
                    let previous = current.enabled
                    withAnimation(.easeInOut(duration: 0.2)) {
                        current = makePeer(enabled: newValue)
                    }
                    setEnabled(newValue, revertTo: previous)
                }
            ))
            .disabled(savingEnabled)
        } footer: {
            Text("Disabled peers stay connected but your assistant will not send work to them.")
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        Section {
            if current.hasToken {
                HStack {
                    Label("Token saved", systemImage: "key.fill")
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                }
                Button("Replace token…") {
                    tokenInput = ""
                    showTokenEntry = true
                }
                .tint(Palette.accent)
                Button("Remove token", role: .destructive) {
                    setToken(nil)
                }
            } else {
                Button("Add token…") {
                    tokenInput = ""
                    showTokenEntry = true
                }
                .tint(Palette.accent)
            }
        } header: {
            Text("Authentication")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("A bearer token Command sends when it talks to this agent. The server never returns the saved token; you can only replace or remove it.")
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button("Remove peer", role: .destructive) {
                showDeleteConfirm = true
            }
            .disabled(deleting)
        }
    }

    // MARK: - Actions

    private func refresh() {
        Task {
            refreshing = true
            defer { refreshing = false }
            do {
                let updated = try await app.client.refreshPeer(name: current.name)
                current = updated
                onUpdate(updated)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func setEnabled(_ enabled: Bool, revertTo previous: Bool) {
        Task {
            savingEnabled = true
            defer { savingEnabled = false }
            do {
                let updated = try await app.client.setPeerEnabled(name: current.name, enabled: enabled)
                current = updated
                onUpdate(updated)
            } catch {
                current = makePeer(enabled: previous)
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func setToken(_ token: String?) {
        Task {
            do {
                let updated = try await app.client.setPeerToken(name: current.name, token: token)
                current = updated
                tokenInput = ""
                showTokenEntry = false
                onUpdate(updated)
            } catch {
                tokenInput = ""
                showTokenEntry = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func delete() {
        Task {
            deleting = true
            defer { deleting = false }
            do {
                try await app.client.deletePeer(name: current.name)
                onDelete(current)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Return a copy of the current peer with only `enabled` changed, for optimistic updates.
    private func makePeer(enabled: Bool) -> Peer {
        Peer(id: current.id,
             name: current.name,
             cardUrl: current.cardUrl,
             url: current.url,
             card: current.card,
             cardFetchedAt: current.cardFetchedAt,
             hasToken: current.hasToken,
             enabled: enabled)
    }
}

// MARK: - Token entry sheet

private struct TokenEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var token: String
    let title: String
    let onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Bearer token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Bearer token")
                } footer: {
                    Text("The token is stored on the server and never shown again.")
                }
            }
            .brandedForm()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(false); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onDone(true); dismiss() }
                        .fontWeight(.semibold)
                        .tint(Palette.accent)
                        .disabled(token.isEmpty)
                }
            }
        }
    }
}
