//
//  LogView.swift
//  Command
//
//  The activity log: facts you (or a delegatee) did, newest first, with an audit
//  summary up top. Lives as a segment in the Tasks tab — the record beside the
//  plan. Tap a row to re-time, re-attribute, categorize, or delete it.
//

import SwiftUI

struct LogView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    @State private var editing: Activity?
    @State private var detail: DetailSubject?

    var body: some View {
        Group {
            if app.log.activities.isEmpty {
                if app.log.isLoading {
                    ProgressView().controlSize(.large)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel("Loading activity log")
                } else if let error = app.log.errorMessage {
                    ErrorBanner(message: error) {
                        Task { await app.log.load(client: app.client) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                } else {
                    emptyState
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if !app.log.summary.isEmpty { SummaryCard(rows: app.log.summary) }
                        ForEach(app.log.activities) { activity in
                            ActivityRow(activity: activity, style: .full)
                                .tappableRow { open(activity) }
                                .hoverEffect()
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task { await app.log.load(client: app.client) }
        .refreshable { await app.log.load(client: app.client) }
        .sheet(item: $editing) { ActivityEditSheet(activity: $0).macSheet() }
        .sheet(item: $detail) { subject in NavigationStack { EntityDetailView(subject: subject) }.macSheet(.page) }
    }

    // Hidden logs always keep the veiled edit sheet (no leak into a detail column). A
    // non-hidden log routes into the shared detail column in the iPad/Mac split shell
    // (Navigator present) — matching Notes/Tasks/People/Calendar — else the flag-gated
    // sheet on iPhone.
    private func open(_ activity: Activity) {
        if activity.hidden ?? false {
            editing = activity
        } else if let nav, nav.hasDetailColumn {
            nav.select(.log(activity))
        } else if app.flags.isOn(.detailPages) {
            detail = .log(activity)
        } else {
            editing = activity
        }
    }

    private var emptyState: some View {
        CommandEmptyState(
            icon: "checklist.checked",
            title: "Nothing logged yet",
            message: "Switch the capture bar to “Log” on the Calendar to record what got done — yours or a delegatee's. Completing an assignment logs itself here too."
        )
    }
}

/// A logged fact. `.compact` for the calendar day agenda, `.full` for the log list.
struct ActivityRow: View {
    enum Style { case compact, full }
    @Environment(AppState.self) private var app
    let activity: Activity
    var style: Style = .full
    @State private var confirmHide = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activity.isCompletion ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: style == .compact ? 9 : 11))
                .foregroundStyle(Palette.sage)
                .padding(.top, style == .compact ? 5 : 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .font(Typeface.body(style == .compact ? 14 : 16, .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(activity.actorName ?? "—").fontWeight(.medium)
                    Text(timeText)
                    if let mins = activity.durationMinutes { Text("· \(mins)m") }
                    if let cat = activity.category, !cat.isEmpty { categoryChip(cat) }
                }
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            }
            .hiddenVeil(hidden: activity.hidden ?? false)
            Spacer(minLength: 0)
        }
        .padding(style == .compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: style == .compact ? 14 : 16)
        .contextMenu {
            HideMenuItems(isHidden: activity.hidden ?? false, reason: "Reveal this log entry",
                            setHidden: { hide in
                await app.log.setHidden(id: activity.id, hidden: hide, client: app.client)
            }, requestHide: { confirmHide = true })
        }
        .hideConfirmation(isPresented: $confirmHide, what: "log entry") {
            Task { await app.log.setHidden(id: activity.id, hidden: true, client: app.client) }
        }
    }

    private func categoryChip(_ text: String) -> some View {
        Text(text)
            .font(Typeface.body(10, .medium))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Palette.accentSoft, in: Capsule())
    }

    private var timeText: String {
        guard let date = PlannerFormat.parse(activity.occurredAt) else { return "" }
        return style == .compact ? Self.timeOnly.string(from: date) : Self.dateTime.string(from: date)
    }
    private static let timeOnly: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"; return f }()
}

/// The audit rollup: who did what, how often, busiest first.
struct SummaryCard: View {
    let rows: [ActivitySummaryRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTIVITY")
                .font(Typeface.body(11, .semibold)).tracking(1.1)
                .foregroundStyle(Palette.accent)
            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 6) {
                    Text(row.actorName ?? "Everyone").font(Typeface.body(14, .medium)).foregroundStyle(Palette.ink)
                    if let cat = row.category, !cat.isEmpty {
                        Text("· \(cat)").foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(row.count)×").font(Typeface.body(13, .semibold)).foregroundStyle(Palette.accent)
                    if row.totalMinutes > 0 {
                        Text(Self.minutes(row.totalMinutes)).font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .font(Typeface.body(13))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private static func minutes(_ m: Int) -> String {
        if m >= 60 { let h = m / 60, r = m % 60; return r == 0 ? "\(h)h" : "\(h)h \(r)m" }
        return "\(m)m"
    }
}
