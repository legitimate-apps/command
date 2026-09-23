//
//  PaywallView.swift
//  Command
//
//  Command Pro paywall. Display copy (trial length, price) comes from the server
//  entitlement so it renders correctly even before StoreKit resolves the product;
//  the purchase/restore actions go through RevenueCat. Doubles as a tab gate (no
//  close button) and as a sheet from Account (pass `onClose`). Paper-and-ink styling.
//

import SwiftUI

struct PaywallView: View {
    @Environment(AppState.self) private var app
    /// When set, the screen is a dismissible sheet (shows an ✕ and closes on success).
    /// When nil, it's the Assistant tab's gate and the gate itself swaps it out.
    var onClose: (() -> Void)? = nil

    private var sub: SubscriptionStore { app.subscription }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Palette.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    features
                    trialCard
                }
                .padding(.horizontal, 22)
                .padding(.top, onClose == nil ? 44 : 16)
                .padding(.bottom, 16)
                // Cap + center on a wide iPad/Mac canvas instead of stretching edge to edge.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { buyBar }

            if let onClose {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Palette.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                }
                .padding(.top, 6)
                .padding(.trailing, 10)
                .accessibilityLabel("Close")
            }
        }
        .task {
            sub.lastError = nil                      // fresh slate; only buy/restore set it
            if sub.offering == nil { await sub.loadOffering() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
                .frame(width: 72, height: 72)
                .background(Palette.accentSoft, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            Text("Command Pro")
                .font(Typeface.display(30))
                .foregroundStyle(Palette.ink)
            Text("Your planning assistant, on call.")
                .font(Typeface.body(16))
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaywallFeature(icon: "wand.and.stars",
                           text: "Turn your notes into goals and tasks, automatically")
            PaywallFeature(icon: "person.2",
                           text: "Delegate to the right person with enough lead time")
            PaywallFeature(icon: "globe",
                           text: "Web search and reasoning across everything you've planned")
            PaywallFeature(icon: "bolt.fill",
                           text: "Up to $10 of AI usage included every month")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 18)
    }

    // MARK: Trial / price card

    private var trialCard: some View {
        VStack(spacing: 6) {
            if trialDays > 0 {
                Text("\(trialDays)-day free trial")
                    .font(Typeface.display(24))
                    .foregroundStyle(Palette.ink)
                Text("then \(priceLine) · cancel anytime")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                Text(priceLine)
                    .font(Typeface.display(24))
                    .foregroundStyle(Palette.ink)
                Text("cancel anytime")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1))
    }

    // MARK: Buy bar

    private var buyBar: some View {
        VStack(spacing: 10) {
            if let err = sub.lastError {
                Text(err)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
            }
            Button(action: subscribe) {
                HStack(spacing: 8) {
                    if sub.purchasing { ProgressView().controlSize(.small).tint(.white) }
                    Text(ctaTitle)
                        .font(Typeface.body(17, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(sub.purchasing || sub.restoring)

            Button(action: restore) {
                Text(sub.restoring ? "Restoring…" : "Restore Purchases")
                    .font(Typeface.body(14, .medium))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .disabled(sub.purchasing || sub.restoring)

            HStack(spacing: 4) {
                Link("Terms", destination: BillingConfig.termsURL)
                Text("·").foregroundStyle(Palette.inkSecondary)
                Link("Privacy", destination: BillingConfig.privacyURL)
            }
            .font(Typeface.body(12, .medium))
            .tint(Palette.accent)

            Text("Billed through your Apple ID. Auto-renews monthly until cancelled in Settings.")
                .font(Typeface.body(11))
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Palette.paper)
    }

    // MARK: Copy (server-driven, StoreKit-preferred)

    /// Only what StoreKit confirms this Apple ID can get. Until that's known (or if the user
    /// already had a trial) the paywall shows the plain price rather than promising "free".
    private var trialDays: Int { sub.eligibleTrialDays ?? 0 }

    /// Prefer StoreKit's localized price ("$19.99/month"); fall back to the server's
    /// display string ("$19.99/mo") so the paywall reads correctly even offline/early.
    private var priceLine: String {
        if let p = sub.localizedPrice { return "\(p)/month" }
        return app.entitlement?.priceDisplay ?? "Monthly subscription"
    }

    private var ctaTitle: String {
        if sub.purchasing { return "Starting…" }
        return trialDays > 0 ? "Start Free Trial" : "Subscribe"
    }

    // MARK: Actions

    private func subscribe() {
        Task {
            let ok = await sub.purchase()
            if ok {
                await app.refreshEntitlement()
                onClose?()
                // Close immediately — the purchase IS done — but keep waiting for the server's
                // mirror of it. One refresh races RevenueCat's webhook and usually loses, and
                // losing means the first assistant turn tells someone who just paid to
                // subscribe. See `awaitEntitlementActivation`.
                await app.awaitEntitlementActivation()
            }
        }
    }

    private func restore() {
        Task {
            let ok = await sub.restore()
            if ok {
                await app.refreshEntitlement()
                onClose?()
                await app.awaitEntitlementActivation()
            } else if sub.lastError == nil {
                sub.lastError = "No purchases to restore on this Apple ID."
            }
        }
    }
}

/// One paywall benefit line (amber check + text).
private struct PaywallFeature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 24, height: 24)
            Text(text)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
