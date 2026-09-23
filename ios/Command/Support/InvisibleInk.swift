//
//  InvisibleInk.swift
//  Command
//
//  The invisible-ink veil over hidden captures: an opaque, shimmering ink field
//  (InvisibleInk.metal) that covers the content — the text underneath is NOT shown
//  (no blurred ghost). It appears only where the finger rubs it away.
//
//  Behaviour follows the app-wide HiddenRevealMode:
//   - keep hidden   → solid veil, no reveal.
//   - rub to reveal → rubbing clears a fading trail under the finger (like wiping fog
//                     off glass). Rub away ≥60% of a row and the veil "gives": the
//                     static blows outward, the content shows for 3s, then the static
//                     sweeps back in from the edges and re-covers it.
//   - reveal all    → no veil.
//  Honors Reduce Motion (static field) and VoiceOver (won't read veiled text until
//  revealed). Used over list rows AND inside detail views, so a tapped hidden item
//  stays censored until rubbed.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Veil this content with animated hidden ink when `hidden` is true. The reveal
    /// behaviour is read from the app-wide `AppState.hiddenRevealMode`, so a single
    /// profile picker governs every hidden surface at once.
    ///
    /// `tint` is the base "bubble" colour the white glints shimmer over — a silvery medium
    /// grey (à la iMessage), not the near-black ink that made the old veil read as dark static.
    func hiddenVeil(hidden: Bool, tint: Color = Color(red: 0.44, green: 0.46, blue: 0.50)) -> some View {
        modifier(InvisibleInkModifier(hidden: hidden, tint: tint))
    }
}

private struct InvisibleInkModifier: ViewModifier {
    let hidden: Bool
    let tint: Color

    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strokes: [InkStroke] = []
    @State private var lastPoint: CGPoint?
    @State private var start = Date()
    @State private var size: CGSize = .zero
    @State private var touched: Set<Int> = []     // grid cells rubbed this pass (60% → blow away)
    @State private var blownAway = false           // the veil has given way and fully revealed

    private var mode: HiddenRevealMode { app.hiddenRevealMode }
    private let revealRadius: CGFloat = 42
    private let density: CGFloat = 1.6                 // glint grain (points) — fine glitter
    private let feather: CGFloat = 10                  // soft fade at the veil's perimeter
    private let strokeLifetime: TimeInterval = 0.55   // seconds a rubbed dab stays clear before re-inking
    private let minStep: CGFloat = 7                  // min finger travel before laying a new rub dab
    private let coverageThreshold = 0.60              // fraction of the row that triggers the blow-away

    func body(content: Content) -> some View {
        if !hidden || mode == .revealAll {
            content
        } else {
            content
                // Keep the content for layout/sizing only — fully invisible, so no
                // readable ghost shows through the veil. Text appears solely under a rub.
                .opacity(0)
                .overlay { veil(content) }
                .background { sizeReader }
                .compositingGroup()
                .contentShape(Rectangle())
                .gesture(mode == .rubToReveal ? rub : nil)
                // VoiceOver must not read veiled text until it's revealed.
                .accessibilityElement()
                .accessibilityLabel(mode == .rubToReveal ? "Hidden. Press and rub to reveal." : "Hidden.")
        }
    }

    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { size = geo.size }
                .onChange(of: geo.size) { _, s in size = s }
        }
    }

    // The shimmer + rub-trail decay run on an animation clock (TimelineView); the
    // blow-away scale/fade are applied OUTSIDE those closures so `withAnimation` can
    // interpolate them cleanly rather than fighting the per-frame re-renders.
    @ViewBuilder private func veil(_ content: Content) -> some View {
        ZStack {
            // Sharp content shown only under the active rub trail (the local peek).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: strokes.isEmpty)) { timeline in
                if !strokes.isEmpty { content.mask(trail(now: timeline.date, base: .clear, dab: .white)) }
            }
            // The full reveal once the veil gives way — invisible (opacity 0) until then.
            content.opacity(blownAway ? 1 : 0)
            // The opaque shimmering ink on top: holes where rubbed, and on blow-away it
            // scales outward + fades, then sweeps back in from the edges to re-cover.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: reduceMotion && strokes.isEmpty)) { timeline in
                let t = Float(start.distance(to: timeline.date))
                sparkles(t).mask(clearMask(now: timeline.date))
            }
            .mask(featherMask)                      // soft, diffuse edges instead of a hard rectangle
            .scaleEffect(blownAway ? 2.6 : 1)
            .opacity(blownAway ? 0 : 1)
        }
        // Contain the blow-away scale: a 2.6× veil must never overflow its row, or it
        // widens the scroll content and the whole list starts panning horizontally.
        .clipped()
    }

    /// The animated, opaque particle field that hides the content.
    private func sparkles(_ t: Float) -> some View {
        // An opaque base ensures the layer rasterizes so colorEffect has pixels to run on;
        // the shader overwrites every pixel with the sparkle over that solid ink ground.
        Rectangle()
            .fill(tint)
            .colorEffect(ShaderLibrary.invisibleInk(.float(t), .color(tint), .float(Float(density))))
    }

    /// Opaque across the interior, fading to clear at the perimeter so the static diffuses
    /// softly into the card instead of ending on a hard rectangular edge. Safe because the
    /// text underneath is drawn at opacity 0 — the faded edge reveals the card, never words.
    /// The feather is capped to the row size so a short veil still keeps an opaque core.
    private var featherMask: some View {
        let f = max(2, min(feather, min(size.width, size.height) / 4))
        return Rectangle().fill(.white).padding(f).blur(radius: f)
    }

    /// Opaque everywhere except the rubbed trail (which it punches out of the ink).
    private func clearMask(now: Date) -> some View {
        Rectangle().fill(.white)
            .overlay { trail(now: now, base: .clear, dab: .black).blendMode(.destinationOut) }
            .compositingGroup()
    }

    /// The union of recent rub dabs, each fading as it ages — `dab` where rubbed, `base`
    /// elsewhere. Shared by the reveal mask (white dabs) and the ink punch-out (black dabs).
    private func trail(now: Date, base: Color, dab: Color) -> some View {
        ZStack {
            base
            ForEach(strokes) { stroke in
                let age = stroke.birth.distance(to: now)
                let strength = max(0, 1 - age / strokeLifetime)
                Circle()
                    .fill(RadialGradient(colors: [dab, dab, dab.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: revealRadius))
                    .frame(width: revealRadius * 2, height: revealRadius * 2)
                    .position(stroke.point)
                    .opacity(strength)
            }
        }
    }

    /// A brief touch initiates the rub (which lets the row win the touch from the enclosing
    /// ScrollView — Apple's drag-in-scroll pattern); dragging then wipes the veil along the
    /// finger's path; lifting lets it re-form. Each dab fires a soft haptic.
    ///
    /// `maximumDistance` is unbounded ON PURPOSE: a LongPressGesture *fails the instant the
    /// finger moves past ~10pt* (its default), so a natural rub — which is movement — cancelled
    /// the press before it ever armed the drag, and nothing revealed. Letting the finger move
    /// freely during the brief press is what makes rubbing actually work.
    private var rub: some Gesture {
        LongPressGesture(minimumDuration: 0.1, maximumDistance: 10_000)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value { addDab(at: drag.location) }
            }
            .onEnded { _ in
                lastPoint = nil
                // Once the trail has fully re-inked, drop the spent dabs so the animation
                // clock can idle again (matters under Reduce Motion, which otherwise pins it).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(strokeLifetime + 0.1))
                    guard !blownAway else { return }
                    let now = Date()
                    strokes.removeAll { $0.birth.distance(to: now) > strokeLifetime }
                    if strokes.isEmpty { touched.removeAll() }
                }
            }
    }

    /// Lay a new rub dab if the finger has travelled far enough, pruning faded ones so the
    /// stroke list stays small. Throttling by distance also paces the haptic.
    private func addDab(at point: CGPoint) {
        guard !blownAway else { return }
        if let last = lastPoint, hypot(point.x - last.x, point.y - last.y) < minStep { return }
        lastPoint = point
        let now = Date()
        strokes.append(InkStroke(point: point, birth: now))
        strokes.removeAll { $0.birth.distance(to: now) > strokeLifetime }
        if strokes.count > 80 { strokes.removeFirst(strokes.count - 80) }
        InkHaptics.rub()
        markCoverage(at: point)
    }

    /// Mark the grid cells under this dab and, once ≥60% of the row has been rubbed, let
    /// the veil give way: blow the static outward, hold the reveal, then re-form.
    private func markCoverage(at point: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        let cell: CGFloat = 28
        let cols = max(1, Int((size.width / cell).rounded()))
        let rows = max(1, Int((size.height / cell).rounded()))
        let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let center = CGPoint(x: (CGFloat(c) + 0.5) * cw, y: (CGFloat(r) + 0.5) * ch)
                if hypot(center.x - point.x, center.y - point.y) <= revealRadius {
                    touched.insert(r * cols + c)
                }
            }
        }
        if Double(touched.count) / Double(cols * rows) >= coverageThreshold { blowAway() }
    }

    private func blowAway() {
        guard !blownAway else { return }
        InkHaptics.giveWay()
        withAnimation(.easeOut(duration: 0.55)) { blownAway = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))                 // hold the reveal
            withAnimation(.easeIn(duration: 0.7)) { blownAway = false }   // sweep back in from the edges
            try? await Task.sleep(for: .seconds(0.75))
            strokes.removeAll()
            touched.removeAll()
            lastPoint = nil
        }
    }
}

/// One dab of rubbing: where the finger was and when, so the veil can fade it back in.
private struct InkStroke: Identifiable {
    let id = UUID()
    let point: CGPoint
    let birth: Date
}

/// Pooled, low-intensity haptics for the rub. No-op where UIKit isn't available.
private enum InkHaptics {
    #if canImport(UIKit)
    private static let soft: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .soft); g.prepare(); return g
    }()
    private static let medium: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g
    }()
    #endif

    /// A faint tick per rub dab.
    static func rub() {
        #if canImport(UIKit)
        soft.impactOccurred(intensity: 0.45)
        soft.prepare()
        #endif
    }

    /// A firmer thump when the veil gives way at the 60% threshold.
    static func giveWay() {
        #if canImport(UIKit)
        medium.impactOccurred()
        medium.prepare()
        #endif
    }
}
