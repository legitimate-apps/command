//
//  FlowLayout.swift
//  Command
//
//  A wrapping flow layout for chip clouds and tag rows. Lays subviews out left-to-right,
//  top-to-bottom like text, with a fixed horizontal gap and configurable vertical row spacing.
//  Width is the proposed width; height grows to fit the wrapped rows. iOS 17+.
//

import SwiftUI

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = layout(in: width, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: .unspecified
            )
        }
    }

    private struct Row {
        var subviews: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct LayoutResult {
        var size: CGSize = .zero
        var placements: [CGPoint] = []
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> LayoutResult {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needsSpacing = !current.subviews.isEmpty
            let occupied = x + (needsSpacing ? horizontalSpacing : 0) + size.width

            if occupied > width && !current.subviews.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }

            if needsSpacing { x += horizontalSpacing }
            current.subviews.append(index)
            current.width = x + size.width
            current.height = max(current.height, size.height)
            x = current.width
        }
        if !current.subviews.isEmpty { rows.append(current) }

        var placements = Array(repeating: CGPoint.zero, count: subviews.count)
        var y: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (rowIndex, row) in rows.enumerated() {
            let rowY = y
            let leadingOffset: CGFloat
            switch alignment {
            case .center: leadingOffset = max(0, (width - row.width) / 2)
            case .trailing: leadingOffset = max(0, width - row.width)
            default: leadingOffset = 0
            }

            var itemX: CGFloat = leadingOffset
            for index in row.subviews {
                let size = subviews[index].sizeThatFits(.unspecified)
                placements[index] = CGPoint(x: itemX, y: rowY + (row.height - size.height) / 2)
                itemX += size.width + horizontalSpacing
            }

            y += row.height
            if rowIndex < rows.count - 1 { y += verticalSpacing }
            totalHeight = y
        }

        return LayoutResult(size: CGSize(width: width, height: totalHeight), placements: placements)
    }
}
