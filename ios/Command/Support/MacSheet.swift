//
//  MacSheet.swift
//  Command
//
//  Mac Catalyst presents every SwiftUI `.sheet` as a UIKit form sheet with a small fixed default
//  size (~440×390pt), regardless of what the content wants. On Mac our sheets therefore opened as
//  cramped cards with the form clipped mid-row — worst of all the Account screen, which is also the
//  ⌘, settings surface and hosts Connected Agents, the calendar subscription and Command Pro.
//  iOS/iPadOS size sheets themselves and are already correct, so this is Catalyst-only.
//
//  Sizing a Catalyst form sheet means setting `preferredContentSize` on the *presented* view
//  controller. SwiftUI doesn't surface that, and a content `.frame(idealWidth:idealHeight:)` is
//  ignored (verified on macOS 26 — the sheet stayed 440pt wide), so this drops a zero-size
//  representable into the sheet's background that walks up to the presented controller and sets it.
//
//  Applied at the `.sheet` call sites rather than inside the presented views, because several of
//  those views (NoteDetailView, EntityDetailView) also render directly in the split shell's detail
//  column, where a sheet-sized frame would be wrong.
//

import SwiftUI
import UIKit

/// How much room a sheet's content wants on Mac. Both stay inside the 900×600 minimum window.
enum MacSheetSize {
    /// Short editors and pickers — a person, a goal, a token, an assignee list.
    case form
    /// Long scrolling surfaces — Account/settings, an entity detail, a note, the paywall.
    case page

    /// UIKit clamps a form sheet to the window, so these can exceed the 900×600 minimum window
    /// safely — they're the size the sheet gets in the roomy default 1400×880 window.
    var cgSize: CGSize {
        switch self {
        case .form: return CGSize(width: 620, height: 640)
        case .page: return CGSize(width: 860, height: 740)
        }
    }
}

extension View {
    /// Give a sheet a usable size on Mac Catalyst. No-op on iOS and iPadOS.
    @ViewBuilder
    func macSheet(_ size: MacSheetSize = .form) -> some View {
        #if targetEnvironment(macCatalyst)
        background(MacSheetSizer(size: size.cgSize).frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Invisible probe that sets `preferredContentSize` on whichever controller is actually being
/// presented, which is what a Catalyst form sheet sizes itself from.
private struct MacSheetSizer: UIViewControllerRepresentable {
    let size: CGSize

    func makeUIViewController(context: Context) -> Sizer { Sizer(size: size) }
    func updateUIViewController(_ controller: Sizer, context: Context) { controller.apply(size) }

    final class Sizer: UIViewController {
        private var target: CGSize

        init(size: CGSize) {
            target = size
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(target)
        }

        // The hosting controller can still be settling into the hierarchy at `viewWillAppear`;
        // re-applying here is what makes the very first presentation come up at the right size.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(target)
        }

        /// Walk to the outermost ancestor — the controller UIKit actually presented — and size it.
        func apply(_ size: CGSize) {
            target = size
            var controller: UIViewController = self
            while let parent = controller.parent { controller = parent }
            guard controller !== self, controller.presentingViewController != nil else { return }
            if controller.preferredContentSize != size { controller.preferredContentSize = size }
        }
    }
}
#endif
