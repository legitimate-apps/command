//
//  AgentThreadsView.swift
//  Command
//
//  The assistant's conversation history, presented as a sheet. Tap a thread to
//  reopen it; "New" starts a fresh chat.
//

import SwiftUI

struct AgentThreadsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    let onPick: (Int) -> Void

    private var store: AgentStore { app.agent }
    private var filteredThreads: [AgentThread] {
        guard !searchText.isEmpty else { return store.threads }
        return store.threads.filter {
            $0.displayTitle.localizedStandardContains(searchText)
        }
    }

    var body: some View {
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
                        description: Text("Your conversations with the assistant will appear here.")
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
                            Button {
                                onPick(thread.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.displayTitle)
                                        .font(Typeface.body(16, .medium))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(RelativeTime.ago(thread.updatedAt))
                                        .font(Typeface.body(12))
                                        .foregroundStyle(Palette.inkSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Palette.paper)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newChat()
                        dismiss()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .tint(Palette.accent)
                }
            }
            .task { await store.loadThreads(client: app.client) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
