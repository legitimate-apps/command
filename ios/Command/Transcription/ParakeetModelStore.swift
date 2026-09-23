//
//  ParakeetModelStore.swift
//  Command
//
//  Manages the on-device NVIDIA Parakeet v3 CoreML model via FluidAudio: presence
//  check, ~480 MB download (with progress), warm AsrManager, and deletion.
//  Apple-Silicon only, iOS 17+. API verified against FluidAudio v0.15.3.
//

import FluidAudio
import Foundation
import Observation

@MainActor
@Observable
final class ParakeetModelStore {
    enum State: Equatable {
        case unknown
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    var state: State = .unknown
    private var manager: AsrManager?

    /// Cheap on-disk presence check (no network).
    func refresh() {
        if case .ready = state { return }
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        state = AsrModels.modelsExist(at: dir, version: .v3) ? .ready : .notDownloaded
    }

    /// Download (~480 MB) the v3 model set, then load a warm manager.
    func download() async {
        state = .downloading(0)
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { [weak self] progress in
                Task { @MainActor in self?.state = .downloading(progress.fractionCompleted) }
            })
            state = .loading
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            manager = mgr
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Return a warm manager if the model is present (loading it on first use).
    func ensureManager() async -> AsrManager? {
        if let manager { return manager }
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        guard AsrModels.modelsExist(at: dir, version: .v3) else { return nil }
        do {
            let models = try await AsrModels.load(from: dir, version: .v3)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            manager = mgr
            state = .ready
            return mgr
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    func delete() {
        ModelHub.clearCache(for: .parakeetV3, directory: AsrModels.defaultCacheDirectory(for: .v3))
        manager = nil
        state = .notDownloaded
    }
}
