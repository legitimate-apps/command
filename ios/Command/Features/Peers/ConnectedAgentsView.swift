//
//  ConnectedAgentsView.swift
//  Command
//
//  List connected A2A peers and show this account's inbound agent address.
//

import SwiftUI

struct ConnectedAgentsView: View {
    @Environment(AppState.self) private var app

    @State private var peers: [Peer] = []
    @State private var inboundInfo: PeerInboundInfo?
    @State private var loading = false
    @State private var inboundLoading = false
    @State private var error: String?
    @State private var inboundError: String?
    @State private var showAdd = false
    @State private var peerToDelete: Peer?
    @State private var copiedAddress = false

    var body: some View {
        // Pushed from AccountView's stack — no NavigationStack of its own
        // (a nested stack in a push destination breaks the nav bar).
        Group {
            if loading && peers.isEmpty {
                ProgressView("Loading connected agents…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if peers.isEmpty && !loading {
                        emptySection
                    } else {
                        peersSection
                    }
                    inboundSection
                }
                .brandedForm()
            }
        }
            .navigationTitle("Connected agents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Palette.accent)
                    .accessibilityLabel("Add peer")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddPeerSheet { added in
                    peers.append(added)
                }
                .macSheet()
            }
            .alert("Could not load agents", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .alert("Could not load inbound address", isPresented: Binding(
                get: { inboundError != nil }, set: { if !$0 { inboundError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(inboundError ?? "") }
            .confirmationDialog(deleteTitle, isPresented: Binding(
                get: { peerToDelete != nil }, set: { if !$0 { peerToDelete = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let peer = peerToDelete { delete(peer) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your assistant will no longer be able to reach it.")
            }
            .task {
                await loadPeers()
                await loadInbound()
            }
            .refreshable {
                await loadPeers()
                await loadInbound()
            }
    }

    // MARK: - Sections

    @ViewBuilder
    private var emptySection: some View {
        Section {
            CommandEmptyState(
                icon: "link.badge.plus",
                title: "No connected agents yet",
                message: "Add another app’s AI agent so your assistant can send work to it and receive results back.",
                actionLabel: "Add agent"
            ) { showAdd = true }
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var peersSection: some View {
        Section {
            ForEach(peers) { peer in
                NavigationLink {
                    PeerDetailView(peer: peer) { updated in
                        if let idx = peers.firstIndex(where: { $0.id == updated.id }) {
                                    peers[idx] = updated
                        }
                    } onDelete: { deleted in
                        withAnimation {
                            peers.removeAll { $0.id == deleted.id }
                        }
                    }
                } label: {
                    PeerRow(peer: peer)
                }
                .swipeActions(edge: .trailing) {
                    Button("Remove", role: .destructive) {
                        peerToDelete = peer
                    }
                    .tint(Palette.danger)
                }
                // A trailing swipe is a touch/trackpad gesture with no mouse equivalent, so on Mac
                // this row's only destructive action was unreachable with a pointer. Right-click
                // (long-press on iOS) gets the same action.
                .contextMenu {
                    Button("Remove", role: .destructive) { peerToDelete = peer }
                }
            }
        } header: {
            Text("Peers")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Tap a peer to edit its token, enable or disable it, or refresh its card.")
        }
    }

    @ViewBuilder
    private var inboundSection: some View {
        if let info = inboundInfo {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("A2A endpoint") {
                        Text(info.a2aUrl)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    LabeledContent("Agent card") {
                        Text(info.cardUrl)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    copyButton(info: info)
                }
            } header: {
                Text("Your agent’s address")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Paste the A2A endpoint into the other app. It will need your access token (from Account → MCP access token) as its bearer.")
            }
        } else if inboundLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading…")
                    Spacer()
                }
            } header: {
                Text("Your agent’s address")
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private func copyButton(info: PeerInboundInfo) -> some View {
        Button {
            UIPasteboard.general.string = "Endpoint: \(info.a2aUrl)\nCard: \(info.cardUrl)"
            withAnimation(.easeInOut(duration: 0.2)) { copiedAddress = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeInOut(duration: 0.2)) { copiedAddress = false }
            }
        } label: {
            Label(copiedAddress ? "Copied" : "Copy address", systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                .font(Typeface.body(15, .medium))
        }
        .tint(Palette.accent)
    }

    private var deleteTitle: String {
        if let name = peerToDelete?.card.name {
            return "Remove \(name)?"
        }
        return "Remove peer?"
    }

    // MARK: - Actions

    private func loadPeers() async {
        loading = true
        defer { loading = false }
        do {
            peers = try await app.client.listPeers()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadInbound() async {
        inboundLoading = true
        defer { inboundLoading = false }
        do {
            inboundInfo = try await app.client.peerInboundInfo()
        } catch {
            inboundError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ peer: Peer) {
        Task {
            do {
                try await app.client.deletePeer(name: peer.name)
                Haptics.delete()
                withAnimation {
                    peers.removeAll { $0.id == peer.id }
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Peer row

private struct PeerRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.card.name)
                    .font(Typeface.body(16, .semibold))
                    .foregroundStyle(peer.enabled ? Palette.ink : Palette.inkSecondary)
                if let description = peer.card.description, !description.isEmpty {
                    Text(description)
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !peer.enabled {
                    Text("Off")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.inkSecondary.opacity(0.12))
                        .foregroundStyle(Palette.inkSecondary)
                        .clipShape(Capsule())
                }
                if peer.hasToken {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.7))
                        .accessibilityLabel("Token saved")
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(peer.enabled ? 1 : 0.75)
    }
}
