import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk). Values must be sorted
/// in descending order; zero values get empty rects.
enum TreemapLayout {
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0 * scale) }
        var remaining = rect
        var i = 0

        func worst(_ row: [Int], side: Double) -> Double {
            let s = row.reduce(0.0) { $0 + areas[$1] }
            guard s > 0, side > 0 else { return .infinity }
            var w = 0.0
            for k in row where areas[k] > 0 {
                let r = areas[k]
                w = max(w, max(side * side * r / (s * s), (s * s) / (side * side * r)))
            }
            return w
        }

        while i < areas.count {
            if areas[i] <= 0 { i += 1; continue }
            let side = Double(min(remaining.width, remaining.height))
            var row = [i]
            var best = worst(row, side: side)
            var j = i + 1
            while j < areas.count, areas[j] > 0 {
                let candidate = row + [j]
                let w = worst(candidate, side: side)
                if w <= best { row = candidate; best = w; j += 1 } else { break }
            }
            let rowArea = row.reduce(0.0) { $0 + areas[$1] }
            if remaining.width >= remaining.height {
                let w = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for k in row {
                    let h = CGFloat(areas[k]) / w
                    result[k] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for k in row {
                    let w = CGFloat(areas[k]) / h
                    result[k] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(0, remaining.height - h))
            }
            i = j
        }
        return result
    }
}
