//
//  AddPeerSheet.swift
//  Command
//
//  Add a connected agent by its A2A URL.
//

import SwiftUI

struct AddPeerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var onAdded: (Peer) -> Void = { _ in }

    @State private var url = ""
    @State private var token = ""
    @State private var phase: Phase = .form
    @State private var connecting = false
    @State private var deleting = false
    @State private var serverError: String?

    private enum Phase: Equatable {
        case form
        case confirming(Peer)
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasToken: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .form:
                    formSection
                case .confirming(let peer):
                    confirmationSection(peer: peer)
                }
            }
            .brandedForm()
            .animation(.easeInOut(duration: 0.2), value: phase)
            .navigationTitle("Add agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var formSection: some View {
        Section {
            TextField("https://pantry.example.com", text: $url)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(connecting)
                .accessibilityLabel("Agent URL")
            SecureField("Bearer token (optional)", text: $token)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(connecting)
                .accessibilityLabel("Bearer token (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste the agent's address. Command fetches its card and shows you what it is before your assistant can talk to it.")
                if let serverError {
                    Text(serverError)
                        .foregroundStyle(Palette.danger)
                }
            }
        }

        Section {
            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if connecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(connecting ? "Connecting…" : "Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Palette.accent)
            .foregroundStyle(.white)
            .disabled(trimmedURL.isEmpty || connecting)
        }
    }

    // MARK: - Confirmation

    @ViewBuilder
    private func confirmationSection(peer: Peer) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.sage)
                        .accessibilityHidden(true)
                    Text("Connected")
                        .font(Typeface.display(20, .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text(peer.card.name)
                    .font(Typeface.body(17, .semibold))
                    .foregroundStyle(Palette.ink)
                if let description = peer.card.description, !description.isEmpty {
                    Text(description)
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(nil)
                }
                if let version = peer.card.version, !version.isEmpty {
                    Text("Version \(version)")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Agent card")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("The peer is saved. Tap Done to return to the list, or Remove if this wasn't the right agent.")
        }

        Section {
            Button("Done") {
                onAdded(peer)
                dismiss()
            }
            .fontWeight(.semibold)
            .tint(Palette.accent)
            Button("Remove", role: .destructive) {
                remove(peer)
            }
            .disabled(deleting)
        }
    }

    // MARK: - Actions

    private func connect() {
        Task {
            connecting = true
            serverError = nil
            defer { connecting = false }
            do {
                let peer = try await app.client.addPeer(
                    cardURL: trimmedURL,
                    token: hasToken ? token.trimmingCharacters(in: .whitespaces) : nil)
                phase = .confirming(peer)
            } catch let error as APIError {
                serverError = error.errorDescription ?? error.localizedDescription
            } catch {
                serverError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func remove(_ peer: Peer) {
        Task {
            deleting = true
            defer { deleting = false }
            do {
                try await app.client.deletePeer(name: peer.name)
                dismiss()
            } catch {
                serverError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .form
            }
        }
    }
}
