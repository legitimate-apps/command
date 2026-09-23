//
//  SubscriptionStore.swift
//  Command
//
//  The app's thin wrapper over RevenueCat: configure once, tie RevenueCat's
//  identity to the signed-in server account (so the purchase webhook maps back to
//  it), load the current offering, and run purchase / restore. `isSubscribed`
//  mirrors the "pro" entitlement from RevenueCat's `CustomerInfo` for instant local
//  UI; the server's own entitlement (mirrored from RevenueCat's webhook) remains the
//  authority that gates the agent endpoint.
//

import Foundation
import Observation
import RevenueCat

@MainActor
@Observable
final class SubscriptionStore {
    /// "pro" entitlement active per RevenueCat's local `CustomerInfo` — fast UI signal.
    private(set) var isSubscribed = false
    private(set) var offering: Offering?
    private(set) var monthlyPackage: Package?
    /// Free-trial days THIS Apple ID can actually get on the monthly package: 0 when the product
    /// has no free trial or StoreKit says the user already used it; nil until known. The paywall
    /// promises a trial only from this — a lapsed subscriber shown "7-day free trial" would be
    /// charged on the spot (and it's a 3.1.2 review risk).
    private(set) var eligibleTrialDays: Int?
    private(set) var purchasing = false
    private(set) var restoring = false
    var lastError: String?

    private var configured = false
    private var observer: Task<Void, Never>?

    /// Localized App Store price of the monthly package once StoreKit resolves it
    /// (e.g. "$19.99"); nil until the offering loads. The paywall falls back to the
    /// server's `priceDisplay` copy when this is nil.
    var localizedPrice: String? { monthlyPackage?.localizedPriceString }

    /// True once a purchasable package is in hand.
    var canPurchase: Bool { monthlyPackage != nil }

    /// Configure RevenueCat exactly once (call at app launch). Idempotent. Also
    /// starts observing `customerInfoStream` so external changes (renewals,
    /// expirations, family sharing) keep `isSubscribed` current.
    func configureIfNeeded() {
        guard !configured else { return }
        #if DEBUG
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: BillingConfig.revenueCatPublicKey)
        configured = true
        observer = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
    }

    /// Bind RevenueCat to the signed-in account (`appUserId` is the server's `billing_user_id`,
    /// which is what the RevenueCat → server webhook keys on). Then load the offering. Safe to
    /// call repeatedly. The bare account id used to be the identity, and every self-hosted
    /// server's first account is id 1 — so unrelated users shared one RevenueCat customer.
    func identify(appUserId: String) async {
        guard configured else { return }
        do {
            let (info, _) = try await Purchases.shared.logIn(appUserId)
            apply(info)
        } catch {
            lastError = friendly(error)
        }
        await loadOffering()
    }

    /// Detach the RevenueCat identity (revert to an anonymous id) on sign-out.
    func signOut() async {
        guard configured else { return }
        _ = try? await Purchases.shared.logOut()
        isSubscribed = false
        offering = nil
        monthlyPackage = nil
        eligibleTrialDays = nil
    }

    /// Length of the product's free-trial intro offer in days, if this user is eligible for it.
    private static func trialDays(for product: StoreProduct?) async -> Int? {
        guard let product else { return nil }
        guard let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial else { return 0 }
        let status = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
        guard status == .eligible else { return 0 }
        let period = intro.subscriptionPeriod
        switch period.unit {
        case .day: return period.value
        case .week: return period.value * 7
        case .month: return period.value * 30
        case .year: return period.value * 365
        @unknown default: return 0
        }
    }

    func loadOffering() async {
        guard configured else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            offering = offerings.current
            monthlyPackage = offerings.current?.monthly ?? offerings.current?.availablePackages.first
            eligibleTrialDays = await Self.trialDays(for: monthlyPackage?.storeProduct)
        } catch {
            // Offering-fetch failures (StoreKit/config/network) aren't user-actionable —
            // never surface RevenueCat's raw troubleshooting text on the paywall. If
            // there's still no package when the user taps buy, purchase() shows a
            // friendly "unavailable" message instead.
            monthlyPackage = nil
        }
    }

    /// Buy the monthly package. Returns true only when the purchase completes and the
    /// entitlement is active. A user cancel returns false with no surfaced error.
    @discardableResult
    func purchase() async -> Bool {
        guard configured, let pkg = monthlyPackage else {
            lastError = "Subscriptions are unavailable right now. Please try again in a moment."
            return false
        }
        purchasing = true
        defer { purchasing = false }
        do {
            let (_, info, userCancelled) = try await Purchases.shared.purchase(package: pkg)
            apply(info)
            if userCancelled { return false }
            lastError = nil
            return isSubscribed
        } catch ErrorCode.purchaseCancelledError {
            return false                      // user backed out — benign, no error UI
        } catch {
            lastError = friendly(error)
            return false
        }
    }

    /// Restore an existing subscription (e.g. new device / reinstall).
    @discardableResult
    func restore() async -> Bool {
        guard configured else { return false }
        restoring = true
        defer { restoring = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            lastError = nil
            return isSubscribed
        } catch {
            lastError = friendly(error)
            return false
        }
    }

    private func apply(_ info: CustomerInfo) {
        isSubscribed = info.entitlements[BillingConfig.entitlementID]?.isActive == true
    }

    private func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
