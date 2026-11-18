// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Airmai’s SimaiDetailedTimeline. See SOURCE_PROVENANCE.json.
import SwiftUI

/// Airmai's preview timeline, with note density, source notation and scrubbing.
/// Pass the same presentation time used for the playfield, in seconds.
public struct SimaiPreviewTimeline: View {
    private let chart: SimaiChart
    private let currentTime: TimeInterval
    private let onScrub: (TimeInterval) -> Void
    private let onScrubEnded: (TimeInterval) -> Void

    public init(
        chart: SimaiChart, currentTime: TimeInterval, onScrub: @escaping (TimeInterval) -> Void,
        onScrubEnded: @escaping (TimeInterval) -> Void
    ) {
        self.chart = chart
        self.currentTime = currentTime.isFinite ? max(0, min(currentTime, chart.duration)) : 0
        self.onScrub = onScrub
        self.onScrubEnded = onScrubEnded
    }

    private var selectedEvent: SimaiNoteEvent? {
        guard let index = chart.eventIndex(at: currentTime), chart.events.indices.contains(index) else { return nil }
        return chart.events[index]
    }

    private var simultaneousEvents: ArraySlice<SimaiNoteEvent> {
        guard let selectedEvent else { return chart.events[0..<0] }
        return chart.events(from: selectedEvent.time - 0.000_1, through: selectedEvent.time + 0.000_1)
    }

    public var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text("M\(chart.measureNumber(at: currentTime))").font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(0.62))

                if let selectedEvent {
                    Text(selectedSourceText).font(.caption.monospaced().weight(.bold)).foregroundStyle(
                        color(for: selectedEvent)
                    ).modifier(SimaiTimelineSingleLine()).padding(.horizontal, 8).frame(minHeight: 26).background(
                        color(for: selectedEvent).opacity(0.13), in: RoundedRectangle(cornerRadius: 8)
                    ).overlay {
                        RoundedRectangle(cornerRadius: 8).stroke(color(for: selectedEvent).opacity(0.26), lineWidth: 1)
                    }
                }

                Spacer(minLength: 4)

                Text("\(timeText(currentTime)) / \(timeText(chart.duration))").font(
                    .caption2.monospacedDigit().weight(.semibold)
                ).foregroundStyle(.white.opacity(0.68)).fixedSize()
            }

            HStack(spacing: 8) {
                Text(selectedEventDescription).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(
                    .white.opacity(0.72)
                ).modifier(SimaiTimelineSingleLine())
                Spacer(minLength: 4)
                Text("\(simultaneousEvents.count) NOTES").font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(0.52)).fixedSize()
            }

            GeometryReader { proxy in
                Canvas(rendersAsynchronously: true) { context, size in drawTimeline(context: &context, size: size) }
                    .contentShape(Rectangle()).gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            onScrub(time(at: value.location.x, width: proxy.size.width))
                        }.onEnded { value in onScrubEnded(time(at: value.location.x, width: proxy.size.width)) })
            }.frame(height: 108).accessibilityElement(children: .ignore).accessibilityLabel("谱面时间轴").accessibilityValue(
                "\(timeText(currentTime)) \(selectedEventDescription)"
            ).accessibilityIdentifier("simai-preview-timeline").accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onScrubEnded(min(currentTime + 5, chart.duration))
                case .decrement: onScrubEnded(max(currentTime - 5, 0))
                @unknown default: break
                }
            }

            HStack(spacing: 10) {
                ForEach(SimaiTimelineCategory.allCases) { category in
                    HStack(spacing: 4) {
                        Circle().fill(category.color).frame(width: 6, height: 6)
                        Text(category.title).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(
                            .white.opacity(0.58)
                        ).lineLimit(1)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(11)// Keep chart colors and white chart labels legible in custom hosts.
            .background(.black, in: RoundedRectangle(cornerRadius: 16)).overlay {
                RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }

    private var selectedEventDescription: String {
        guard let event = selectedEvent else { return "NO NOTE" }
        let types = Set(simultaneousEvents.map { SimaiTimelineCategory.category(for: $0).title }).sorted().joined(
            separator: " + ")
        let location: String
        if event.location.ring == .lane {
            location = "KEY \(event.location.index)"
        } else {
            location = "\(event.location.ring.rawValue.uppercased())\(event.location.index)"
        }
        return "\(types)  \(location)"
    }

    private var selectedSourceText: String {
        let values = simultaneousEvents.map(\.source)
        return values.isEmpty ? "—" : values.joined(separator: " / ")
    }

    private func drawTimeline(context: inout GraphicsContext, size: CGSize) {
        let buckets = chart.timelineNoteBuckets
        guard !buckets.isEmpty, size.width > 0, size.height > 0 else { return }

        let labelHeight: CGFloat = 16
        let plotTop = labelHeight + 3
        let plotBottom = size.height - 10
        let plotHeight = max(plotBottom - plotTop, 1)
        let maximumCount = max(buckets.map(\.total).max() ?? 1, 1)
        let slotWidth = size.width / CGFloat(buckets.count)
        let barWidth = max(slotWidth * 0.76, 1)
        let currentProgress = max(0, min(currentTime / max(chart.duration, 0.001), 1))

        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plotBottom - plotHeight * fraction
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.white.opacity(fraction == 0 ? 0.18 : 0.075)), lineWidth: 1)
        }

        let markerInterval = timeMarkerInterval(for: chart.duration)
        if markerInterval > 0 {
            var marker = 0.0
            while marker <= chart.duration + 0.001 {
                let x = CGFloat(marker / max(chart.duration, 0.001)) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: plotTop))
                tick.addLine(to: CGPoint(x: x, y: plotBottom))
                context.stroke(tick, with: .color(.white.opacity(0.08)), lineWidth: 1)

                var label = context.resolve(
                    Text(timeText(marker)).font(.system(size: 9, weight: .semibold, design: .monospaced)))
                label.shading = .color(.white.opacity(0.46))
                let anchor: UnitPoint =
                    marker == 0 ? .topLeading : (marker + markerInterval > chart.duration ? .topTrailing : .top)
                context.draw(label, at: CGPoint(x: x, y: 0), anchor: anchor)
                marker += markerInterval
            }
        }

        for (index, bucket) in buckets.enumerated() where bucket.total > 0 {
            let totalRatio = sqrt(CGFloat(bucket.total) / CGFloat(maximumCount))
            let totalHeight = max(plotHeight * totalRatio, 2)
            let x = CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2
            var y = plotBottom
            for category in SimaiTimelineCategory.allCases {
                let value = category.value(in: bucket)
                guard value > 0 else { continue }
                let segmentHeight = totalHeight * CGFloat(value) / CGFloat(bucket.total)
                y -= segmentHeight
                let rect = CGRect(x: x, y: y, width: barWidth, height: max(segmentHeight, 0.75))
                let bucketProgress = Double(index) / Double(max(buckets.count - 1, 1))
                let opacity = bucketProgress <= currentProgress ? 0.96 : 0.72
                context.fill(Path(rect), with: .color(category.color.opacity(opacity)))
            }
        }

        let cursorX = min(max(CGFloat(currentProgress) * size.width, 1), max(size.width - 1, 1))
        var cursor = Path()
        cursor.move(to: CGPoint(x: cursorX, y: plotTop - 1))
        cursor.addLine(to: CGPoint(x: cursorX, y: plotBottom + 3))
        context.stroke(cursor, with: .color(.white.opacity(0.94)), lineWidth: 2)
        context.fill(
            Path(ellipseIn: CGRect(x: cursorX - 4, y: plotBottom - 4, width: 8, height: 8)), with: .color(.white))
    }

    private func color(for event: SimaiNoteEvent) -> Color { SimaiTimelineCategory.category(for: event).color }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return max(0, min(Double(x / width) * chart.duration, chart.duration))
    }

    private func timeMarkerInterval(for duration: TimeInterval) -> TimeInterval {
        if duration <= 90 { return 15 }
        if duration <= 240 { return 30 }
        if duration <= 480 { return 60 }
        return 120
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// Keep longer authored chords readable even on narrow phones.
private struct SimaiTimelineSingleLine: ViewModifier {
    func body(content: Content) -> some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) { content.fixedSize(horizontal: true, vertical: false) }.scrollIndicators(.hidden)
        }
    }
}

private enum SimaiTimelineCategory: String, CaseIterable, Identifiable {
    case tap
    case hold
    case slide
    case touch
    case breakNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: return "TAP"
        case .hold: return "HOLD"
        case .slide: return "SLIDE"
        case .touch: return "TOUCH"
        case .breakNote: return "BREAK"
        }
    }

    var color: Color {
        switch self {
        case .tap: return Color(red: 1, green: 105 / 255, blue: 180 / 255)
        case .hold: return Color(red: 1, green: 217 / 255, blue: 0)
        case .slide: return Color(red: 0, green: 0.92, blue: 1)
        case .touch: return Color(red: 0.18, green: 0.82, blue: 0.66)
        case .breakNote: return Color(red: 1, green: 113 / 255, blue: 0)
        }
    }

    func value(in bucket: SimaiTimelineNoteBucket) -> Int {
        switch self {
        case .tap: return bucket.tap
        case .hold: return bucket.hold
        case .slide: return bucket.slide
        case .touch: return bucket.touch
        case .breakNote: return bucket.breakNote
        }
    }

    static func category(for event: SimaiNoteEvent) -> SimaiTimelineCategory {
        if event.flags.contains(.breakNote) { return .breakNote }
        switch event.kind {
        case .tap: return .tap
        case .hold, .touchHold: return .hold
        case .slide: return .slide
        case .touch: return .touch
        }
    }
}
