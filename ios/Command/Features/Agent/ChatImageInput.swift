//
//  ChatImageInput.swift
//  Command
//
//  Image input for the Assistant: downscale-and-encode a picked/captured photo into
//  a ChatAttachment (so the send path is a cheap base64 step), plus a camera capture
//  controller (photos only). The PhotosPicker (library) is wired directly in the chat
//  view; both funnel through `ChatImageProcessing.attachment(from:)`.
//

import SwiftUI
import UIKit

enum ChatImageProcessing {
    /// Longest-edge cap and JPEG quality for an attachment. Images are sent inline
    /// (base64) in the chat body and read by the model for one turn only, so they're
    /// kept small — well under the server's 6 MB/image ceiling — without visibly
    /// hurting legibility of text/diagrams the user is likely photographing.
    static let maxDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.6

    /// Downscale (preserving aspect) and JPEG-encode into a ChatAttachment. Returns
    /// nil only if encoding fails (e.g. a zero-size image).
    static func attachment(from image: UIImage) -> ChatAttachment? {
        guard let data = downscaledJPEG(image) else { return nil }
        return ChatAttachment(jpeg: data)
    }

    static func downscaledJPEG(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // target is already in pixels; don't multiply by screen scale
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: jpegQuality)
    }
}

/// A photos-only camera capture. Gated behind `UIImagePickerController.isSourceTypeAvailable(.camera)`
/// at the call site, so it never appears on Mac Catalyst / camera-less devices.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]   // photos only — never video
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
