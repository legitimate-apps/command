//
//  InkPreview.swift
//  Command
//
//  DEBUG-only harness for eyeballing the invisible-ink veil without app data. Launch with
//  `-COMMAND_INK_PREVIEW YES` to land straight on a page of veiled sample rows so the shader
//  can be tuned against real on-device rendering (and screen-recorded for the motion). Not
//  compiled into Release.
//

#if DEBUG
import SwiftUI

struct InkPreviewView: View {
    @Environment(AppState.self) private var app
    private let samples = [
        "Idea: secure human-in-the-loop CAPTCHAs",
        "Alice wants a unicorn tattoo on her left shoulder",
        "Yogurt lemon chicken marinade for Sunday",
        "Goal: get past CAPTCHAs without me on the phone",
    ]

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Invisible-ink preview")
                    .font(Typeface.display(22)).foregroundStyle(Palette.ink)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.accent).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(line).font(Typeface.display(17)).foregroundStyle(Palette.ink)
                            Text("supporting detail line that wraps to show a taller veil region here")
                                .font(.system(size: 14)).foregroundStyle(Palette.inkSecondary)
                                .lineLimit(2)
                        }
                        .hiddenVeil(hidden: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 16)
                }
                Spacer()
            }
            .padding(16)
        }
        .onAppear { app.hiddenRevealMode = .rubToReveal }
    }
}


/// DEBUG-only render check for the device-lock screen. `-COMMAND_LOCK_PREVIEW YES` (with
/// `-COMMAND_UI_PREVIEW YES`) seeds a stub PIN and lands locked so the unlock UI can be eyeballed.
struct LockPreviewView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        LockScreenView()
            .task {
                let id = app.account?.id ?? 0
                app.flags.set(.deviceLock, true)
                app.lock.setPin("123456", account: id)
                app.lock.configure(accountId: id, lockNow: true)
            }
    }
}

/// DEBUG-only render check for the entity detail page. `-COMMAND_DETAIL_PREVIEW YES`.
struct DetailPreviewView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        NavigationStack {
            EntityDetailView(subject: .assignment(Assignment(
                id: 1, accountId: 0, goalId: nil, title: "Plan Alice's birthday dinner",
                details: "Italian place she likes", assigneeId: nil, scheduleKind: "sporadic",
                rrule: nil, scheduledStart: "2026-07-01T18:00:00Z", scheduledEnd: nil, timezone: nil,
                leadTimeMinutes: 1440, status: "todo", priority: 0, hidden: false, archivedAt: nil,
                notes: "Not booked yet — confirm headcount with Alice, then call the restaurant.",
                origin: "manual", createdAt: "2026-06-26T12:00:00Z", updatedAt: "2026-06-26T12:00:00Z")))
        }
        .onAppear { app.flags.set(.detailPages, true) }
    }
}

/// DEBUG-only render check for the single-field note editor. `-COMMAND_NOTE_PREVIEW YES` seeds a
/// note exercising every markdown construct so the live styling can be eyeballed in one screen.
struct NotePreviewView: View {
    private static let sample = """
    Trip plan — Big Sur
    ## Logistics
    Leave **Friday** by *3pm*; the drive is ~`5h` with one stop.

    ### Packing
    - [x] tent + poles
    - [ ] the good sleeping bag
    - [ ] `headlamp` batteries

    ### Notes
    > Reserve the site early — it fills up.

    Ranger line: [recreation.gov](https://recreation.gov)

    | Day | Miles |
    | --- | --- |
    | Sat | 8 |
    | Sun | 4 |

    ---
    ~~Skip the coast road~~ take the 1.
    """

    var body: some View {
        NoteDetailView(note: Note(
            id: 1, accountId: 0,
            body: Self.sample,
            title: "Trip plan — Big Sur", titleStatus: "user", source: "text", engine: nil,
            locale: nil, processedAt: nil, archivedAt: nil, hidden: false,
            createdAt: "2026-07-04T09:08:00Z", updatedAt: "2026-07-04T09:08:00Z"))
    }
}

/// DEBUG-only render check for the redaction reveal gate. `-COMMAND_PRIVACY_PREVIEW YES`
/// shows the passcode-entry challenge (a stub PIN is seeded); add
/// `-COMMAND_PRIVACY_PREVIEW_SETUP YES` to instead show the "set a passcode first" prompt.
struct PrivacyChallengePreview: View {
    @Environment(AppState.self) private var app
    private var wantsSetup: Bool { UserDefaults.standard.bool(forKey: "COMMAND_PRIVACY_PREVIEW_SETUP") }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            Text("Redaction gate preview")
                .font(Typeface.display(18)).foregroundStyle(Palette.inkSecondary)
        }
        // The simulator's unsigned debug build can't persist a Keychain PIN, so pair the entry
        // variant with `-COMMAND_FORCE_PIN_ENTRY YES`; the setup variant needs no PIN.
        .privacyChallenge()
        .task {
            while app.account == nil { try? await Task.sleep(for: .milliseconds(30)) }  // let bootstrap seed the stub account
            let id = app.account?.id ?? 0
            if wantsSetup { app.lock.removePin(account: id) } else { app.lock.setPin("123456", account: id) }
            app.lock.configure(accountId: id, lockNow: false)
            _ = await app.privacy.authenticate(reason: "Reveal this note")
        }
    }
}
#endif
