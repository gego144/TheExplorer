import SwiftUI

/// Squarified treemap of one folder's children. Click selects, double-click drills in.
struct TreemapView: View {
    let nodes: [SizeNode]
    let total: Int64
    @Binding var selection: SizeNode.ID?
    let onDrill: (SizeNode) -> Void

    @State private var hovered: SizeNode.ID?

    /// Beyond this many tiles, the rest are merged into a single "smaller items" tile.
    private static let maxTiles = 60

    private static let palette = Theme.palette

    var body: some View {
        GeometryReader { proxy in
            let tiles = Self.tiles(for: nodes)
            let rects = Treemap.layout(tiles.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    if rect.width > 1 && rect.height > 1 {
                        TileView(tile: tile, total: total, color: color(for: tile, index: index),
                                 isSelected: tile.node.map { $0.id == selection } ?? false,
                                 isHovered: tile.node.map { $0.id == hovered } ?? false)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .onHover { inside in
                                if inside { hovered = tile.node?.id } else if hovered == tile.node?.id { hovered = nil }
                            }
                            .onTapGesture(count: 2) {
                                if let node = tile.node { onDrill(node) }
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                selection = tile.node?.id
                            })
                            .help(tile.tooltip(total: total))
                    }
                }
            }
        }
        .overlay {
            if nodes.allSatisfy({ $0.size == 0 }) {
                Text("Empty").foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for tile: Tile, index: Int) -> Color {
        guard let node = tile.node, node.kind == .folder else { return Theme.textSecondary }
        return Self.palette[index % Self.palette.count]
    }

    struct Tile: Identifiable {
        let id: String
        let node: SizeNode?
        let name: String
        let size: Int64
        let isFolder: Bool

        func tooltip(total: Int64) -> String {
            "\(name)\n\(Format.bytes(size)) · \(Format.percent(size, of: total))"
        }
    }

    private static func tiles(for nodes: [SizeNode]) -> [Tile] {
        let sorted = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        var tiles = sorted.prefix(maxTiles).map {
            Tile(id: $0.path + "#\($0.kind)", node: $0.kind == .otherFiles ? nil : $0, name: $0.name, size: $0.size, isFolder: $0.isFolder)
        }
        let rest = sorted.dropFirst(maxTiles)
        if !rest.isEmpty {
            tiles.append(Tile(id: "rest", node: nil, name: "\(rest.count) smaller items",
                              size: rest.reduce(0) { $0 + $1.size }, isFolder: false))
        }
        return tiles
    }
}

private struct TileView: View {
    let tile: TreemapView.Tile
    let total: Int64
    let color: Color
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        GeometryReader { proxy in
            let showsLabel = proxy.size.width > 64 && proxy.size.height > 36
            let showsPercent = proxy.size.width > 110 && proxy.size.height > 54
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(tile.isFolder ? (isHovered ? 0.30 : 0.18) : (isHovered ? 0.16 : 0.08)))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color.opacity(isSelected ? 1 : (isHovered ? 0.7 : 0.38)), lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if showsLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tile.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(Format.bytes(tile.size))
                                .font(Theme.monoSmall)
                                .foregroundStyle(color)
                        }
                        .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsPercent {
                        Text(Format.percent(tile.size, of: total))
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color.opacity(0.55))
                            .padding(8)
                    }
                }
        }
        .contentShape(.rect)
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = areas[start]
            var best = worst(areas[start..<end], sum: rowSum, side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidate = worst(areas[start...end], sum: candidateSum, side: side)
                if candidate > best { break }
                best = candidate
                rowSum = candidateSum
                end += 1
            }

            let thickness = side > 0 ? rowSum / side : 0
            if remaining.width >= remaining.height {
                // Lay the row as a column on the left.
                var y = Double(remaining.minY)
                for index in start..<end {
                    let height = thickness > 0 ? areas[index] / thickness : 0
                    result[index] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                // Lay the row along the top.
                var x = Double(remaining.minX)
                for index in start..<end {
                    let width = thickness > 0 ? areas[index] / thickness : 0
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }

    /// Worst aspect ratio in a row; lower is squarer.
    private static func worst(_ row: ArraySlice<Double>, sum: Double, side: Double) -> Double {
        guard let largest = row.max(), let smallest = row.min(), smallest > 0, sum > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
