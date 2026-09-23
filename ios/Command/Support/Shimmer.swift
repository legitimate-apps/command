//
//  Shimmer.swift
//  Command
//
//  A branded shimmer placeholder for loading list rows. Uses Palette.surface and a moving
//  hairline-highlight gradient; pauses under Reduce Motion. Apply as a placeholder to a
//  small stack of row-shaped blocks during first-load states.
//

import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    let gradient = LinearGradient(
                        colors: [
                            Palette.surface.opacity(0.45),
                            Palette.hairline.opacity(0.55),
                            Palette.surface.opacity(0.45)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    gradient
                        .offset(x: -w + (2 * w * phase))
                        .frame(width: w * 3, height: geo.size.height)
                }
                .mask(content)
            )
            .onAppear {
                guard !reduceMotion else { phase = 0.5; return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce {
                    phase = 0.5
                } else {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

/// A placeholder row shaped like the app's list cards. Use 3–4 of these inside a branded loading state.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Palette.hairline).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.hairline)
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.hairline)
                    .frame(width: 100, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shimmer()
    }
}

struct SkeletonList: View {
    let count: Int

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { _ in
                    SkeletonRow()
                }
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
    }
}

#Preview {
    SkeletonList(count: 4)
}
