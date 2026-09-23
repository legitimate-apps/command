//
//  TranscriptionSettingsView.swift
//  Command
//
//  Manage on-device voice transcription: see which engine is active, download or
//  remove the high-quality Parakeet v3 model, and read the required attribution.
//  Reached from Account → Voice & models.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var app

    private var parakeet: ParakeetModelStore { app.transcription.parakeet }

    var body: some View {
        Form {
            Section {
                LabeledContent("Active engine") {
                    Text(app.transcription.activeEngineName)
                        .foregroundStyle(Palette.accent)
                        .fontWeight(.medium)
                }
            } header: {
                Text("Now using")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Dictated notes are transcribed entirely on your device — nothing is sent to a server. Command always picks the highest-quality engine you have installed.")
            }

            parakeetSection

            Section {
                if #available(iOS 26.0, *) {
                    tierRow(
                        title: "On-device Speech",
                        detail: "Apple SpeechAnalyzer · broad language coverage",
                        systemImage: "waveform")
                }
                tierRow(
                    title: "System dictation",
                    detail: "Apple Speech · universal fallback",
                    systemImage: "mic")
            } header: {
                Text("Always available")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Parakeet TDT v3 by NVIDIA, licensed under CC-BY-4.0. Speech recognition runs through the FluidAudio framework (Apache-2.0). Command thanks both projects.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                    Link("NVIDIA Parakeet model card",
                         destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!)
                        .font(.footnote)
                    Link("FluidAudio on GitHub",
                         destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                        .font(.footnote)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Credits")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .navigationTitle("Voice & Models")
        .brandedForm()
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Parakeet

    @ViewBuilder
    private var parakeetSection: some View {
        Section {
            switch parakeet.state {
            case .unknown, .notDownloaded:
                Button {
                    Task { await app.transcription.downloadParakeet() }
                } label: {
                    Label("Download model (~480 MB)", systemImage: "arrow.down.circle")
                }

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress) {
                        Text("Downloading…")
                    }
                    .tint(Palette.accent)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.inkSecondary)
                }
                .padding(.vertical, 2)

            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading model…").foregroundStyle(Palette.inkSecondary)
                }

            case .ready:
                LabeledContent("Status") {
                    Label("Installed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Palette.sage)
                        .labelStyle(.titleAndIcon)
                }
                Button("Remove model", role: .destructive) {
                    app.transcription.deleteParakeet()
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't load the model", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.accent)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Button("Try again") {
                    Task { await app.transcription.downloadParakeet() }
                }
            }
        } header: {
            Text("Parakeet v3 · highest quality")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("A 25-language neural model that runs locally for the most accurate transcripts. Needs a recent iPhone (Apple-Silicon Neural Engine) and about 480 MB of space. Optional — the engines below always work without it.")
        }
    }

    private func tierRow(title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityHidden(true)
        }
    }
}
