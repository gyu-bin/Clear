import SwiftUI

/// Label over a value; no container.
struct MetricView: View {
    let title: String
    let value: String
    var detail: String? = nil
    var valueColor: Color = ClearColor.textPrimary
    var font: Font = ClearFont.figureSmall

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
            Text(value).font(font).foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            if let detail { Text(detail).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(2) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Legacy name used by a few screens: a metric without decoration.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var symbol: String = ""
    var tint: Color = ClearColor.textPrimary

    var body: some View {
        MetricView(title: title, value: value, detail: caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapacitySegment: Identifiable, Hashable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    var restricted = false
}

/// Single horizontal capacity bar. Segments are drawn in order; the rest is track.
struct CapacityBar: View {
    let segments: [CapacitySegment]
    let total: Int64
    var height: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    let fraction = total > 0 ? CGFloat(Double(seg.bytes) / Double(total)) : 0
                    Rectangle().fill(seg.color)
                        .frame(width: max(seg.bytes > 0 ? 2 : 0, geo.size.width * fraction))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(ClearColor.track)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            .animation(Motion.gentle(reduceMotion), value: segments)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(segments.map { "\($0.title) \($0.bytes.formattedBytes)" }.joined(separator: ", "))
    }
}

/// Legend entry: dot, title, value.
struct LegendItem: View {
    let segment: CapacitySegment

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            Circle().fill(segment.color).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(ClearColor.textTertiary, lineWidth: segment.id == "free" ? 1 : 0))
            Text(segment.title).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
            Text(segment.restricted ? "접근 제한" : segment.bytes.formattedBytes)
                .font(ClearFont.numericSmall).foregroundStyle(segment.restricted ? ClearColor.warning : ClearColor.textPrimary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One line in a size ranking: name, proportional bar, value.
struct ProportionRow: View {
    let title: String
    let bytes: Int64?
    let fraction: Double
    var color: Color = ClearColor.accentBright
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: Space.m) {
            if let symbol { SymbolTile(symbol: symbol) }
            Text(title).font(ClearFont.body).foregroundStyle(ClearColor.textPrimary).lineLimit(1)
                .frame(minWidth: 110, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(ClearColor.track)
                    Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 4)
            Text(bytes?.formattedBytes ?? "접근 제한").font(ClearFont.numeric)
                .foregroundStyle(bytes == nil ? ClearColor.warning : ClearColor.textPrimary)
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ByteFigure: View {
    let bytes: Int64
    var font: Font = ClearFont.figure
    var color: Color = ClearColor.textPrimary

    var body: some View {
        Text(bytes.formattedBytes).font(font).foregroundStyle(color)
            .contentTransition(.numericText(value: Double(bytes)))
    }
}
