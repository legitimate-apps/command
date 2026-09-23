//
//  AssistantColumn.swift
//  Command
//
//  Content column (iPad / Mac split) for the Assistant. Unlike the compact iPhone path — which
//  shows a single chat plus a history *sheet* — the regular-width shell uses the canvas like every
//  other section: the conversation list lives here in the content column, and the active chat lives
//  in the detail column (AgentChatView). The AI gate (loading → consent → paywall → ready) is shown
//  here too, so an un-consented user sees the disclosure at a comfortable width rather than a chat
//  crammed into a narrow pane beside a dead detail column.
//

import SwiftUI

struct AssistantColumn: View {
    @Environment(AppState.self) private var app
    @State private var searchText = ""
    private var store: AgentStore { app.agent }
    private var filteredThreads: [AgentThread] {
        guard !searchText.isEmpty else { return store.threads }
        return store.threads.filter {
            $0.displayTitle.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        switch app.assistantGateResolved {
        case .loading: loading
        case .consent: AIConsentView()
        case .paywall: PaywallView()
        case .ready:   threadList
        }
    }

    private var loading: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            ProgressView().controlSize(.large).tint(Palette.accent)
        }
        .task { if app.entitlement == nil { await app.refreshEntitlement() } }
    }

    private var threadList: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) {
                        Task { await store.loadThreads(client: app.client) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, store.threads.isEmpty ? 8 : 0)
                }

                if store.errorMessage != nil && store.threads.isEmpty {
                    Spacer()
                } else if store.threads.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a conversation and it'll appear here.")
                    )
                } else if filteredThreads.isEmpty {
                    CommandEmptyState(
                        icon: "magnifyingglass",
                        title: "No matching chats",
                        message: "Try a different search."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredThreads) { thread in
                            let selected = thread.id == store.currentThreadId
                            Button {
                                Task { await store.openThread(thread.id, client: app.client) }
                            } label: {
                                row(thread, selected: selected)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selected ? Palette.accentSoft : Palette.surface)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Palette.paper)
                }
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.newChat() } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                            .font(Typeface.body(14, .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    .frame(minHeight: 44)
                    .hoverEffect()
                }
            }
            .task { await store.loadThreads(client: app.client) }
        }
    }

    private func row(_ thread: AgentThread, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.displayTitle)
                    .font(Typeface.body(16, .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(RelativeTime.ago(thread.updatedAt))
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .hoverEffect()
    }
}
