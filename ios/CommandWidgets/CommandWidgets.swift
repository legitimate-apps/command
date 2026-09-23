import AppIntents
import SwiftUI
import WidgetKit

private struct AgendaEntry: TimelineEntry {
    let date: Date
    /// The agenda as of `date` — today / next up / overdue recomputed for this entry's instant
    /// from the app's multi-day snapshot, not frozen at the moment the app last wrote it.
    let snapshot: WidgetAgenda

    init(date: Date, from stored: WidgetAgendaSnapshot) {
        self.date = date
        self.snapshot = stored.agenda(at: date)
    }
}

private struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: Date(), from: .empty())
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        let now = Date()
        completion(AgendaEntry(date: now, from: WidgetAgendaStore.load(now: now)))
    }

    /// One entry now plus one at every instant the agenda changes over the next day (an item
    /// starting, a one-off falling overdue, midnight). The app reloads the timeline whenever the
    /// underlying data changes; after the last entry WidgetKit asks for a fresh timeline.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let now = Date()
        let stored = WidgetAgendaStore.load(now: now)
        let dates = [now] + stored.timelineDates(after: now)
        completion(Timeline(
            entries: dates.map { AgendaEntry(date: $0, from: stored) },
            policy: .after(now.addingTimeInterval(24 * 60 * 60))
        ))
    }
}

private struct AgendaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(inlineText)
            case .accessoryCircular:
                VStack(spacing: 1) {
                    Text("\(entry.snapshot.today.count)").font(.title2.bold())
                    Text("today").font(.caption2)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command").font(.caption.bold())
                    Text(entry.snapshot.nextUp?.title ?? entry.snapshot.summary).lineLimit(2)
                    if entry.snapshot.overdueCount > 0 {
                        Text("\(entry.snapshot.overdueCount) overdue").font(.caption2)
                    }
                }
            default:
                homeView
            }
        }
        .containerBackground(.background, for: .widget)
        // Routed by CommandApp's onOpenURL to the Calendar destination.
        .widgetURL(URL(string: "command://calendar"))
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Today", systemImage: "calendar").font(.headline)
                Spacer()
                if entry.snapshot.overdueCount > 0 {
                    Text("\(entry.snapshot.overdueCount) overdue").font(.caption).foregroundStyle(.orange)
                }
            }
            if let next = entry.snapshot.nextUp {
                Text("NEXT UP").font(.caption2.bold()).foregroundStyle(.secondary)
                Text(next.title).font(.headline).lineLimit(2)
                Text(next.start, style: .time).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(entry.snapshot.summary).foregroundStyle(.secondary)
            }
            if family != .systemSmall {
                ForEach(entry.snapshot.today.prefix(family == .systemLarge ? 5 : 2)) { item in
                    HStack {
                        Text(item.start, style: .time).font(.caption).monospacedDigit()
                        Text(item.title).font(.caption).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineText: String {
        if let next = entry.snapshot.nextUp { return "Next: \(next.title)" }
        return entry.snapshot.summary
    }
}

private struct CommandAgendaWidget: Widget {
    let kind = WidgetAgendaStore.agendaKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
        }
        .configurationDisplayName("Command Agenda")
        .description("See today's agenda, what is next, and overdue work.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

@available(iOS 26.0, *)
private struct CommandVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "CommandVoice") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "command://voice")!)) {
                Label("Talk to Command", systemImage: "waveform.circle")
            }
        }
        .displayName("Talk to Command")
        .description("Open Command directly into voice capture.")
    }
}

@main
struct CommandWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommandAgendaWidget()
        if #available(iOS 26.0, *) {
            CommandVoiceControl()
        }
    }
}
