//
//  AuthView.swift
//  Command
//

import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var app
    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var busy = false
    @State private var showServer = false
    @State private var showInvite = false
    @FocusState private var focus: Field?

    private enum Field { case username, displayName, password }

    /// Sign-in needs a username + any password; registration enforces the 8-char
    /// floor up front so the disabled state is explained by the inline hint below.
    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8
    }
    private var showPasswordHint: Bool { !password.isEmpty && password.count < 8 }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                brandMark
                Text("Command")
                    .font(Typeface.display(40))
                    .foregroundStyle(Palette.ink)
                    // A wordmark must never break mid-word: at the largest Dynamic Type
                    // sizes it scales down to stay on one line instead.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 18)
                Text("Plan it. Delegate it. Done.")
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 4)

                VStack(spacing: 12) {
                    field(icon: "person", id: .username) {
                        TextField("Username", text: $username)
                            .textContentType(.username)                 // → Keychain autofill (iOS + macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = isRegister ? .displayName : .password }
                    }

                    if isRegister {
                        field(icon: "textformat", id: .displayName) {
                            TextField("Display name (optional)", text: $displayName)
                                .textContentType(.name)
                                .submitLabel(.next)
                                .focused($focus, equals: .displayName)
                                .onSubmit { focus = .password }
                        }
                    }

                    field(icon: "lock", id: .password) {
                        SecureField("Password", text: $password)
                            // .newPassword triggers Strong Password on register; .password
                            // offers the saved Keychain entry on sign-in.
                            .textContentType(isRegister ? .newPassword : .password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit { if canSubmit { submit() } }
                    }

                    if showPasswordHint {
                        Label("Use at least 8 characters", systemImage: "info.circle")
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 28)

                if let err = app.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                primaryButton.padding(.top, 20)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { app.lastError = nil; isRegister.toggle() }
                } label: {
                    Text(isRegister ? "Have an account? Sign in" : "New here? Create an account")
                        .font(Typeface.body(14, .medium))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)

                Button {
                    app.lastError = nil
                    showInvite = true
                } label: {
                    Text("I have an invite")
                        .font(Typeface.body(14, .medium))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

                Spacer(minLength: 24)

                Button { showServer = true } label: {
                    Label("Server settings", systemImage: "gearshape")
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: isRegister)
            .animation(.easeOut(duration: 0.18), value: showPasswordHint)
        }
        .sheet(isPresented: $showServer) { ServerURLSheet().macSheet() }
        .sheet(isPresented: $showInvite) { InviteRedeemSheet().macSheet() }
        // A command://invite/<token> deep link parks its token on AppState; open the redeem
        // sheet for it whether the app was already on this screen or is just arriving here.
        .onAppear { if app.pendingInviteToken != nil { showInvite = true } }
        .onChange(of: app.pendingInviteToken) { _, token in
            if token != nil { app.lastError = nil; showInvite = true } }
        #if DEBUG
        // Screenshot hook: `-COMMAND_PREVIEW_SERVER_SHEET YES` opens the server sheet.
        .onAppear { if UserDefaults.standard.bool(forKey: "COMMAND_PREVIEW_SERVER_SHEET") { showServer = true } }
        #endif
    }

    // MARK: - Pieces

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.accentSoft)
                .frame(width: 80, height: 80)
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
        }
    }

    /// Wraps the shared `FieldCard` chrome, binding its focus highlight + tap-to-focus
    /// to this screen's `@FocusState`.
    private func field(icon: String, id: Field,
                       @ViewBuilder content: () -> some View) -> some View {
        FieldCard(icon: icon, isActive: focus == id, content: content)
            .contentShape(Rectangle())
            .onTapGesture { focus = id }
    }

    private var primaryButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(isRegister ? "Create account" : "Sign in")
                    .font(Typeface.body(16, .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Dim the whole control when not submittable — preserves white-on-amber
            // contrast (vs a washed-out tint that turns the label illegible).
            .opacity(canSubmit && !busy ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || busy)
        .keyboardShortcut(.defaultAction)   // ⏎ submits on Mac / hardware keyboard
        .animation(.easeOut(duration: 0.15), value: canSubmit)
    }

    private func submit() {
        focus = nil
        Task {
            busy = true
            defer { busy = false }
            if isRegister {
                await app.register(username: username, password: password, displayName: displayName)
            } else {
                await app.login(username: username, password: password)
            }
        }
    }
}

struct InviteRedeemSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste the invite token you received to see only the work assigned to you.")
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.inkSecondary)

                    FieldCard(icon: "ticket", isActive: focused) {
                        TextField("inv-…", text: $token)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { if !trimmedToken.isEmpty { redeem() } }
                    }

                    if let error = app.lastError {
                        ErrorBanner(message: error, retry: nil)
                    }

                    Button(action: redeem) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small).tint(.white) }
                            Text("Open My Work").font(Typeface.body(16, .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(trimmedToken.isEmpty || busy ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedToken.isEmpty || busy)
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Use an invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { app.lastError = nil; dismiss() }.fixedSize()
                }
            }
            .onAppear {
                // Deep-linked invite: consume the parked token and redeem it straight away —
                // the user tapped a link whose whole meaning is "join". On failure the sheet
                // stays up with the token editable and the server's error shown.
                if let pending = app.pendingInviteToken {
                    app.pendingInviteToken = nil
                    token = pending
                    redeem()
                } else {
                    focused = true
                }
            }
        }
    }

    private func redeem() {
        focused = false
        Task {
            busy = true
            defer { busy = false }
            await app.redeemInvite(token: trimmedToken)
        }
    }
}

struct ServerURLSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Server URL")
                        .font(Typeface.body(12, .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                    FieldCard(icon: "link", isActive: focused) {
                        TextField("https://…", text: $text)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(save)
                    }
                    Text("The Command server your app and Claude Code talk to.")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.danger)
                    }
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // .fixedSize stops Catalyst from squeezing the leading sheet button to "C…".
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.fixedSize() }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button("Save", action: save).fontWeight(.semibold).fixedSize()
                    }
                }
            }
            .tint(Palette.accent)
            .onAppear { text = app.serverURLString; focused = true }
        }
    }

    /// Check the address before committing it, exactly as onboarding does. Saving an unchecked
    /// typo used to strand the app on "Can't reach Command" with no way back.
    private func save() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            let result = await app.probeServer(text)
            if case .found(let url) = result {
                await app.setServerURL(url.absoluteString)
                dismiss()
            } else {
                error = result.message
            }
            checking = false
        }
    }
}
