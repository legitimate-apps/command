//
//  BillingConfig.swift
//  Command
//
//  Constants for in-app subscriptions (Command Pro, sold via RevenueCat).
//

import Foundation

enum BillingConfig {
    /// RevenueCat **public** iOS SDK key. Public by design — it ships in every app
    /// binary and only permits client-side purchase/restore for this one app — so
    /// it is safe to commit. The *secret* key is configured server-side only.
    static let revenueCatPublicKey = "appl_MdOMdFHhjwmcSAhmgRhOZOTTHoj"

    /// The entitlement identifier configured in RevenueCat that Command Pro grants.
    /// A customer is "Pro" when this entitlement is active in their `CustomerInfo`.
    static let entitlementID = "pro"

    /// First-party legal/support pages on the publisher's own domain. Apple requires functional
    /// Terms (EULA) + Privacy links on a subscription + AI app; these back the links on the
    /// paywall, the consent gate, and Account.
    ///
    /// They live on the publisher's domain, not on any app server: a self-hosted server's
    /// hostname is its owner's business, and legal links must work for every user.
    /// Keep these in step with the App Store listing's privacyPolicyUrl / supportUrl /
    /// marketingUrl.
    static let privacyURL = URL(string: "https://legitimateapps.com/privacy")!
    static let termsURL = URL(string: "https://legitimateapps.com/terms")!
    static let supportURL = URL(string: "https://legitimateapps.com/support")!

    /// Apple's subscription-management surface (manage / cancel).
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
}
