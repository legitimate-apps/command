//
//  AttachmentsSection.swift
//  Command
//
//  The shared Attachments UI for note and assignment detail pages: a List Section showing
//  each file (image thumbnail or doc icon + name + size), tap → QuickLook preview, and —
//  unless read-only — add via photo library or the Files document picker, delete via swipe
//  or context menu. Bytes are fetched on demand; thumbnails cache in-memory per store.
//

import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AttachmentsStore {
    let entityKind: String
    let entityId: Int
    /// Delegatee mode: read-only surface under /api/my.
    let delegatee: Bool

    var attachments: [Attachment] = []
    var thumbnails: [Int: UIImage] = [:]
    var uploading = false
    var errorMessage: String?

    init(entityKind: String, entityId: Int, delegatee: Bool = false) {
        self.entityKind = entityKind
        self.entityId = entityId
        self.delegatee = delegatee
    }

    func load(client: APIClient) async {
        do {
            let listed: [Attachment] = delegatee
                ? try await client.myAssignmentAttachments(assignmentId: entityId)
                : try await client.listAttachments(entityKind: entityKind, entityId: entityId)
            withAnimation(.snappy) { attachments = listed }
            await loadThumbnails(client: client)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadThumbnails(client: APIClient) async {
        for att in attachments where att.isImage && thumbnails[att.id] == nil {
            guard let data = try? await client.downloadAttachment(id: att.id, delegatee: delegatee),
                  let image = UIImage(data: data) else { continue }
            // Downscale before caching — a 12 MP photo as a 44 pt row thumbnail wastes memory.
            let side: CGFloat = 120
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: target)
            thumbnails[att.id] = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        }
    }

    func upload(filename: String, mime: String, data: Data, client: APIClient) async {
        uploading = true
        defer { uploading = false }
        do {
            let saved = try await client.uploadAttachment(
                entityKind: entityKind, entityId: entityId,
                filename: filename, mime: mime, data: data)
            withAnimation(.snappy) { attachments.append(saved) }
            errorMessage = nil
            await loadThumbnails(client: client)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ attachment: Attachment, client: APIClient) async {
        do {
            try await client.deleteAttachment(id: attachment.id)
            withAnimation(.snappy) { attachments.removeAll { $0.id == attachment.id } }
            thumbnails[attachment.id] = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Import a photo-library pick: read bytes + best-guess name/MIME, then upload.
    func importPhoto(_ item: PhotosPickerItem, client: APIClient) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't read that photo."
            return
        }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let mime = type?.preferredMIMEType ?? "image/jpeg"
        let stamp = Int(Date().timeIntervalSince1970)
        await upload(filename: "photo-\(stamp).\(ext)", mime: mime, data: data, client: client)
    }

    /// Import a Files-app pick. The URL is security-scoped; without start/stop the read
    /// fails silently.
    func importFile(_ url: URL, client: APIClient) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read that file."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        await upload(filename: url.lastPathComponent, mime: mime, data: data, client: client)
    }

    /// Download to a temp file (named with the original filename so QuickLook picks the right
    /// renderer + shows the right title) and return its URL.
    func previewURL(for attachment: Attachment, client: APIClient) async -> URL? {
        do {
            let data = try await client.downloadAttachment(id: attachment.id, delegatee: delegatee)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("attachments-\(attachment.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(attachment.filename)
            try data.write(to: url)
            return url
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}

struct AttachmentsSection: View {
    @Environment(AppState.self) private var app
    @State private var store: AttachmentsStore
    @State private var photoPick: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var previewURL: URL?
    private let readOnly: Bool

    init(entityKind: String, entityId: Int, readOnly: Bool = false, delegatee: Bool = false) {
        self.readOnly = readOnly || delegatee
        _store = State(initialValue: AttachmentsStore(
            entityKind: entityKind, entityId: entityId, delegatee: delegatee))
    }

    var body: some View {
        Section {
            if let error = store.errorMessage {
                Text(error).font(Typeface.body(13)).foregroundStyle(.red)
            }
            ForEach(store.attachments) { att in
                row(att)
            }
            if !readOnly {
                addControls
            } else if store.attachments.isEmpty {
                Text("No attachments")
                    .font(Typeface.body(15)).foregroundStyle(Palette.inkSecondary)
            }
        } header: {
            Text("Attachments")
        }
        .listRowBackground(Palette.surface)
        .task { await store.load(client: app.client) }
        .onChange(of: photoPick) { _, item in
            guard let item else { return }
            photoPick = nil
            Task { await importPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ att: Attachment) -> some View {
        Button {
            Haptics.light()
            Task { previewURL = await store.previewURL(for: att, client: app.client) }
        } label: {
            HStack(spacing: 12) {
                if let thumb = store.thumbnails[att.id] {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: att.isImage ? "photo" : "doc")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 44, height: 44)
                        .background(Palette.ink.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(att.filename)
                        .font(Typeface.body(15)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(att.sizeBytes),
                                                   countStyle: .file))
                        .font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attachment \(att.filename)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !readOnly {
                Button(role: .destructive) {
                    Task { await store.delete(att, client: app.client) }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            if !readOnly {
                Button(role: .destructive) {
                    Task { await store.delete(att, client: app.client) }
                } label: { Label("Delete Attachment", systemImage: "trash") }
            }
        }
    }

    private var addControls: some View {
        HStack(spacing: 16) {
            PhotosPicker(selection: $photoPick, matching: .images) {
                Label("Add Photo", systemImage: "photo.badge.plus")
                    .font(Typeface.body(15)).foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            Button {
                showFileImporter = true
            } label: {
                Label("Add File", systemImage: "paperclip")
                    .font(Typeface.body(15)).foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            if store.uploading {
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        await store.importPhoto(item, client: app.client)
    }

    private func importFile(_ url: URL) async {
        await store.importFile(url, client: app.client)
    }
}

/// The note editor's presentation: a compact horizontal strip of existing attachment chips
/// under the editor. DISPLAY-ONLY — the add buttons live in the editor's top-left navbar
/// (operator feedback 2026-07-20: the bottom band read as clutter); the strip renders
/// nothing at all while the note has no attachments. Tap a chip to preview, long-press
/// to delete.
struct AttachmentsStrip: View {
    @Environment(AppState.self) private var app
    let store: AttachmentsStore
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.errorMessage {
                Text(error).font(Typeface.body(12)).foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.attachments) { att in
                            chip(att)
                        }
                        if store.uploading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            } else if store.uploading {
                HStack { ProgressView().controlSize(.small) }
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task { await store.load(client: app.client) }
        .quickLookPreview($previewURL)
    }

    private func chip(_ att: Attachment) -> some View {
        Button {
            Haptics.light()
            Task { previewURL = await store.previewURL(for: att, client: app.client) }
        } label: {
            HStack(spacing: 6) {
                if let thumb = store.thumbnails[att.id] {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: att.isImage ? "photo" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.accent)
                }
                Text(att.filename)
                    .font(Typeface.body(13)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 140)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.ink.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attachment \(att.filename)")
        .contextMenu {
            Button(role: .destructive) {
                Task { await store.delete(att, client: app.client) }
            } label: { Label("Delete Attachment", systemImage: "trash") }
        }
    }
}
