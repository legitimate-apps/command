//
//  FeatureFlags.swift
//  Command
//
//  Single source of truth for in-progress features that ship dark. Every flag defaults to
//  OFF, so a release build behaves exactly like the last shipped build until a flag is turned
//  on. Resolution order: in-memory dev override (the DEBUG toggles screen) → a UserDefaults
//  value (set by a `-COMMAND_FF_<name> YES` launch argument or the toggles screen) → the
//  compile-time default (false). The OFF branch at each call site must be the existing code
//  path, never a reimplementation — flipping a flag should be the only behavioural change.
//

import Foundation
import Observation

enum FeatureFlag: String, CaseIterable, Identifiable {
    case ipadLayout      // adaptive NavigationSplitView on regular width (iPad)
    case deviceLock      // per-user PIN + auto-lock-on-background
    case multiUser       // local account roster + user switcher
    case credits         // pay-per-token credit UI
    case detailPages     // tap an assignment/goal/log → detail page (notes + checklist + context)

    var id: String { rawValue }

    /// Human label for the DEBUG toggles screen.
    var label: String {
        switch self {
        case .ipadLayout: return "iPad split layout"
        case .deviceLock: return "Device PIN lock"
        case .multiUser:  return "Multi-user roster"
        case .credits:    return "Pay-per-token credits"
        case .detailPages: return "Entity detail pages"
        }
    }

    /// UserDefaults / launch-argument key (e.g. `-COMMAND_FF_multiUser YES`).
    var defaultsKey: String { "COMMAND_FF_\(rawValue)" }

    /// Compile-time default. `detailPages` ships ON (its backend is deployed and it's an additive,
    /// non-leaking surface); `ipadLayout` ships ON now that the iPad/Mac split-view shell is built
    /// + verified — and it's only consulted on regular width, so the iPhone (compact) path always
    /// uses MainTabView and is unaffected. The rest ship dark until their own backends/UX are done.
    var defaultValue: Bool {
        switch self {
        case .detailPages, .ipadLayout: return true
        default: return false
        }
    }
}

@MainActor
@Observable
final class FeatureFlags {
    /// In-memory overrides set by the DEBUG toggles screen (also persisted to UserDefaults).
    private var overrides: [FeatureFlag: Bool] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isOn(_ flag: FeatureFlag) -> Bool {
        if let override = overrides[flag] { return override }
        // A launch arg (`-COMMAND_FF_x YES`) or a persisted toggle lands here as a real value;
        // `object(forKey:)` distinguishes "set to false" from "never set".
        if defaults.object(forKey: flag.defaultsKey) != nil {
            return defaults.bool(forKey: flag.defaultsKey)
        }
        return flag.defaultValue
    }

    /// Toggle at runtime (DEBUG toggles screen). Persists so it survives relaunch on the sim/device.
    func set(_ flag: FeatureFlag, _ on: Bool) {
        overrides[flag] = on
        defaults.set(on, forKey: flag.defaultsKey)
    }

    /// Reset a flag back to its compile-time default.
    func reset(_ flag: FeatureFlag) {
        overrides[flag] = nil
        defaults.removeObject(forKey: flag.defaultsKey)
    }
}
