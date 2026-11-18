// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import AVFAudio
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// Rendering geometry and judgement timing in this file are a native Swift port
// of Project-Fukakai/simai_flutter (MIT), rather than an approximation of simai.

public struct SimaiChartRenderer: View {
    public init(
        chart: SimaiChart, currentTime: TimeInterval, settings: SimaiPlaybackSettings = .init(),
        judgedEventIDs: Set<Int> = [], resolvedHeadEventIDs: Set<Int> = [],
        headFeedbackByEventID: [Int: SimaiJudgementFeedback] = [:], judgementFeedback: [SimaiJudgementFeedback] = [],
        pressedHoldEventIDs: Set<Int> = [], slideVisualProgress: [String: [Double]] = [:], isGameplay: Bool = false
    ) {
        self.chart = chart
        self.currentTime = currentTime
        self.settings = settings
        self.judgedEventIDs = judgedEventIDs
        self.resolvedHeadEventIDs = resolvedHeadEventIDs
        self.headFeedbackByEventID = headFeedbackByEventID
        self.judgementFeedback = judgementFeedback
        self.pressedHoldEventIDs = pressedHoldEventIDs
        self.slideVisualProgress = slideVisualProgress
        self.isGameplay = isGameplay
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let chart: SimaiChart
    public let currentTime: TimeInterval
    public let settings: SimaiPlaybackSettings
    public let judgedEventIDs: Set<Int>
    public let resolvedHeadEventIDs: Set<Int>
    public let headFeedbackByEventID: [Int: SimaiJudgementFeedback]
    public let judgementFeedback: [SimaiJudgementFeedback]
    public let pressedHoldEventIDs: Set<Int>
    public let slideVisualProgress: [String: [Double]]
    public let isGameplay: Bool

    public var body: some View {
        // Keep the playfield in the same SwiftUI presentation transaction as
        // its fixed parent. An asynchronous Canvas can surface a variably old
        // backing frame under the simulator's 60 Hz clock, which makes the
        // entire circular playfield appear to jump by a few pixels.
        Canvas(rendersAsynchronously: false) { context, size in
            #if DEBUG
            let renderStart = SimaiGameplayDiagnostics.shared.start()
            defer { SimaiGameplayDiagnostics.shared.record("canvas_cpu_ms", since: renderStart) }
            #endif
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.425
            drawField(context: &context, center: center, radius: radius)
            drawSlidePaths(context: &context, center: center, radius: radius)
            if settings.showEffects {
                drawHitEffects(context: &context, center: center, radius: radius)
                drawFireworks(context: &context, center: center, radius: radius)
            }
            drawNotes(context: &context, center: center, radius: radius)
            if settings.showEffects { drawJudgementFeedback(context: &context, center: center, radius: radius) }
        }.aspectRatio(1, contentMode: .fit).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func drawField(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let backgroundRect = CGRect(
            x: center.x - radius * 1.05, y: center.y - radius * 1.05, width: radius * 2.1, height: radius * 2.1)
        context.fill(Path(ellipseIn: backgroundRect), with: .color(.black.opacity(0.66)))

        if !isGameplay {
            var sensorLayer = context
            sensorLayer.opacity = 0.32
            sensorLayer.draw(sensorLayer.resolve(Image("SimaiSensor")), in: backgroundRect)
        }

        let judgeRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(
            Path(ellipseIn: judgeRect), with: .color(.white.opacity(settings.showApproachLine ? 0.40 : 0.20)),
            lineWidth: max(radius / 150, 1))

        for lane in 1...8 {
            let location = SimaiLocation(ring: .lane, index: lane)
            let point = screenPoint(location.normalizedPoint(mirror: settings.mirror), center: center, radius: radius)
            let dotRadius = max(radius * 8 / 300, 3)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - dotRadius, y: point.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(.white.opacity(0.92)))
        }
    }

    private func drawNotes(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let renderTime = currentTime + settings.audioTimingOffset
        let approachTime = settings.approachTime
        let candidates = chart.events(
            from: renderTime - chart.maximumEventDuration - SimaiTiming.touchLateWindow,
            through: renderTime + approachTime)
        let visibleEvents = candidates.filter { event in
            guard !event.flags.contains(.invalidate), !judgedEventIDs.contains(event.id) else { return false }
            if event.hasHoldHead { return renderTime < event.headScoreTime && event.time - renderTime <= approachTime }
            let lateWindow: TimeInterval
            if isGameplay {
                lateWindow = event.location.ring == .lane ? SimaiTiming.tapWindow : SimaiTiming.touchLateWindow
            } else {
                lateWindow = 0
            }
            return event.time - renderTime <= approachTime && renderTime <= event.time + lateWindow
        }
        for event in visibleEvents {
            if event.kind == .slide, !event.hasHoldHead, resolvedHeadEventIDs.contains(event.id) { continue }
            let isEach = chart.eachEventIDs.contains(event.id)
            if event.location.ring == .lane {
                let state = approachState(for: event, renderTime: renderTime, radius: radius, center: center)
                guard state.progress >= 0 else { continue }
                let color = noteColor(for: event, isEach: isEach)
                if state.progress < 1 {
                    drawApproachArc(
                        context: &context, center: center, radius: state.currentRadius, angle: state.angle, color: color
                    )
                }

                if event.hasHoldHead {
                    drawHold(
                        context: &context, event: event, state: state, renderTime: renderTime, center: center,
                        radius: radius, color: color)
                } else if event.flags.contains(.star) && !event.flags.contains(.normalHead) {
                    let path = event.slidePaths.first
                    let length = path.map {
                        SimaiSlidePathGeometry.geometry(for: $0, mirror: settings.mirror).branches.first?.length ?? 0
                    }
                    drawStar(
                        context: &context, at: state.position, radius: radius * 0.125 * state.scale,
                        rotation: CGFloat(
                            SimaiNoteMotion.headStarRotation(
                                elapsed: renderTime - event.time + approachTime, pathLength: length.map(Double.init),
                                duration: path?.duration, spinning: event.flags.contains(.spinningStar),
                                rotates: settings.rotateSlideStar)), color: color,
                        highlighted: event.flags.contains(.ex))
                } else {
                    drawTap(
                        context: &context, at: state.position, radius: radius * 0.125 * state.scale, color: color,
                        highlighted: event.flags.contains(.ex))
                }
            } else {
                drawTouch(
                    context: &context, event: event, renderTime: renderTime, center: center, radius: radius,
                    isEach: isEach)
            }
        }
    }

    private func drawSlidePaths(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let renderTime = currentTime + settings.audioTimingOffset
        let approachTime = settings.approachTime
        let candidates = chart.events(
            from: renderTime - chart.maximumEventDuration - SimaiTiming.slideWindow, through: renderTime + approachTime)
        let visible = candidates.filter {
            $0.kind == .slide && !$0.flags.contains(.invalidate) && !judgedEventIDs.contains($0.id)
                && renderTime >= $0.time - approachTime
                && renderTime <= $0.endTime + (isGameplay ? SimaiTiming.slideWindow : 0)
        }
        for event in visible {
            let isEach = chart.eachEventIDs.contains(event.id)
            let fade = renderTime < event.time ? max(0, min(1, 1 - (event.time - renderTime) / approachTime)) : 1

            for (slideIndex, slide) in event.slidePaths.enumerated() {
                let color =
                    slide.isBreak
                    ? SimaiPalette.breakOrange : (isEach ? SimaiPalette.eachYellow : SimaiPalette.slideCyan)
                let geometry = SimaiSlidePathGeometry.geometry(for: slide, mirror: settings.mirror)
                let timedProgress =
                    renderTime < slide.startTime
                    ? 0 : max(0, min(1, (renderTime - slide.startTime) / max(slide.duration, 0.001)))
                if !isGameplay, timedProgress >= 1 { continue }
                let touchedProgress = slideVisualProgress["\(event.id):\(slideIndex)"]
                let clearedProgress = geometry.branches.indices.map { branchIndex in
                    isGameplay ? touchedProgress?[safe: branchIndex] ?? 0 : timedProgress
                }

                if slide.containsFan, geometry.branches.count >= 3 {
                    drawFanArrows(
                        context: &context, geometry: geometry, progress: clearedProgress, center: center,
                        radius: radius, color: color.opacity(fade))
                } else {
                    for (branchIndex, branch) in geometry.branches.enumerated() {
                        let firstDistance = branch.length * radius * clearedProgress[branchIndex]
                        drawSlideArrows(
                            context: &context, polyline: branch, center: center, radius: radius,
                            startDistance: firstDistance, color: color.opacity(fade))
                    }
                }

                let guide = SimaiNoteMotion.guideState(
                    time: renderTime, headTime: event.time, start: slide.startTime, end: slide.endTime)
                guard guide.opacity > 0 else { continue }
                for branch in geometry.branches {
                    // The guide star is authored by the chart's start time and
                    // duration. Touch progress clears the trail and judges the
                    // Slide, but must never become the star's playback clock:
                    // releasing halfway should not freeze it halfway down-path.
                    let sample = branch.sample(at: CGFloat(timedProgress))
                    drawStar(
                        context: &context, at: screenPoint(sample.point, center: center, radius: radius),
                        radius: radius * 0.125 * guide.scale,
                        rotation: settings.rotateSlideStar ? sample.angle : -.pi / 2,
                        color: color.opacity(guide.opacity), highlighted: false)
                }
            }
        }
    }

    private func drawHitEffects(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let renderTime = currentTime + settings.audioTimingOffset
        let candidates = chart.events(from: renderTime - chart.maximumEventDuration - 0.36, through: renderTime)
        for event in candidates where !event.flags.contains(.invalidate) {
            let feedback: SimaiJudgementFeedback
            let holdDuration: TimeInterval
            let holdPressed: Bool
            if isGameplay {
                guard let stored = headFeedbackByEventID[event.id] else { continue }
                feedback = stored
                holdDuration = event.kind == .hold || event.kind == .touchHold ? event.duration : 0
                holdPressed = pressedHoldEventIDs.contains(event.id)
                if stored.judgement == .miss, holdDuration <= 0 || !holdPressed { continue }
            } else {
                let potentialHoldDuration = event.kind == .hold || event.kind == .touchHold ? event.duration : 0
                let elapsed = renderTime - event.time
                guard elapsed >= 0, elapsed < potentialHoldDuration + 0.36 else { continue }
                feedback = SimaiJudgementFeedback(
                    eventID: event.id, pathIndex: nil, judgement: .perfect, targetTime: event.time,
                    judgedTime: event.time, offset: 0, location: event.location, isHead: true)
                holdDuration = potentialHoldDuration
                holdPressed = true
            }

            let judgedPresentationTime = feedback.judgedTime + (isGameplay ? settings.visualTimingOffset : 0)
            let elapsed = renderTime - judgedPresentationTime
            let effectiveHoldDuration = holdPressed ? holdDuration : 0
            let pulseAges = hitEffectPulseAges(elapsed: elapsed, holdDuration: effectiveHoldDuration)
            guard !pulseAges.isEmpty else { continue }
            let point = screenPoint(
                feedback.location.normalizedPoint(mirror: settings.mirror), center: center, radius: radius)
            for (phase, age) in pulseAges.enumerated() {
                drawHitEffectPulse(
                    context: &context, at: point, baseRadius: radius * 0.125, age: age, phase: phase,
                    color: feedback.judgement.effectColor)
            }
        }
    }

    private func drawFireworks(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard !chart.fireworkEvents.isEmpty else { return }
        let renderTime = currentTime + settings.audioTimingOffset
        var visibleCount = 0
        if isGameplay {
            // Feedback is already bounded by the session. Never walk the
            // growing head-feedback dictionary or create another effect clock.
            for feedback in judgementFeedback.reversed() {
                guard let event = chart.eventByID[feedback.eventID],
                    let start = SimaiFireworkEffect.startTime(for: event, feedback: feedback, isGameplay: true),
                    let age = SimaiFireworkEffect.age(at: renderTime, since: start + settings.visualTimingOffset)
                else { continue }
                drawFirework(context: &context, event: event, age: age, center: center, radius: radius)
                visibleCount += 1
                if visibleCount == SimaiFireworkEffect.maximumVisibleBursts { break }
            }
        } else {
            let events = chart.fireworks(from: renderTime - SimaiFireworkEffect.duration, through: renderTime)
            for event in events.suffix(SimaiFireworkEffect.maximumVisibleBursts) {
                guard let start = SimaiFireworkEffect.startTime(for: event, feedback: nil, isGameplay: false),
                    let age = SimaiFireworkEffect.age(at: renderTime, since: start)
                else { continue }
                drawFirework(context: &context, event: event, age: age, center: center, radius: radius)
            }
        }
    }

    private func drawFirework(
        context: inout GraphicsContext, event: SimaiNoteEvent, age: TimeInterval, center: CGPoint, radius: CGFloat
    ) {
        let position = screenPoint(
            event.location.normalizedPoint(mirror: settings.mirror), center: center, radius: radius)
        let progress = age / SimaiFireworkEffect.duration
        let opacity = pow(1 - progress, 1.4)
        let scale = radius * 0.24
        let palette = SimaiFireworkEffect.colors
        var trails = Array(repeating: Path(), count: palette.count)
        var tips = Array(repeating: Path(), count: palette.count)
        let rotation = Double(event.id % 12) * .pi / 18
        let cosine = cos(rotation)
        let sine = sin(rotation)

        for spark in SimaiFireworkEffect.sparks {
            let state = SimaiFireworkEffect.sample(spark, age: age, reducedMotion: reduceMotion)
            func point(_ normalized: CGPoint) -> CGPoint {
                CGPoint(
                    x: position.x + (normalized.x * cosine - normalized.y * sine) * scale,
                    y: position.y + (normalized.x * sine + normalized.y * cosine) * scale)
            }
            let tip = point(state.tip)
            trails[spark.colorIndex].move(to: point(state.tail))
            trails[spark.colorIndex].addLine(to: tip)
            let dotRadius = max(radius * 0.008 * (1 - progress * 0.45), 0.6)
            tips[spark.colorIndex].addEllipse(in: circle(center: tip, radius: dotRadius))
        }
        // Batch 24 sparks into four colors; no per-particle blur/shadow or
        // offscreen glass layers in this frame-critical drawing path.
        for index in palette.indices {
            context.stroke(
                trails[index], with: .color(palette[index].opacity(opacity * 0.80)),
                style: StrokeStyle(lineWidth: max(radius * 0.010, 1), lineCap: .round))
            context.fill(tips[index], with: .color(palette[index].opacity(opacity)))
        }
    }

    private func drawJudgementFeedback(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let renderTime = currentTime + settings.audioTimingOffset
        let feedback: [SimaiJudgementFeedback]
        if isGameplay {
            feedback = judgementFeedback
        } else {
            var automatic: [SimaiJudgementFeedback] = []
            let candidates = chart.events(from: renderTime - chart.maximumEventDuration - 0.5, through: renderTime)
            for event in candidates where !event.flags.contains(.invalidate) && renderTime - event.time < 0.5 {
                automatic.append(
                    SimaiJudgementFeedback(
                        eventID: event.id, pathIndex: nil, judgement: .perfect, targetTime: event.time,
                        judgedTime: event.time, offset: 0, location: event.location, isHead: true))
            }
            for event in candidates where !event.flags.contains(.invalidate) && event.kind == .slide {
                for (pathIndex, path) in event.slidePaths.enumerated()
                where renderTime >= path.endTime && renderTime - path.endTime < 0.5 {
                    automatic.append(
                        SimaiJudgementFeedback(
                            eventID: event.id, pathIndex: pathIndex, judgement: .perfect, targetTime: path.endTime,
                            judgedTime: path.endTime, offset: 0, location: path.end, isHead: false))
                }
            }
            feedback = automatic
        }

        for item in feedback {
            let judgedPresentationTime = item.judgedTime + (isGameplay ? settings.visualTimingOffset : 0)
            let age = renderTime - judgedPresentationTime
            guard age >= 0, age < 0.5 else { continue }
            let animation = judgementAnimation(age: age)
            guard animation.opacity > 0.001 else { continue }
            let location = settings.mirror.map(location: item.location)
            let normalized = location.normalizedPoint()
            let directionLength = max(hypot(normalized.x, normalized.y), 0.001)
            let displayRadius: CGFloat = location.ring == .lane ? 0.79 : min(max(directionLength + 0.11, 0.34), 0.76)
            let direction = CGPoint(x: normalized.x / directionLength, y: normalized.y / directionLength)
            let position = CGPoint(
                x: center.x + direction.x * radius * displayRadius, y: center.y + direction.y * radius * displayRadius)
            let rotation: CGFloat
            if location.ring == .lane {
                let angle = atan2(position.y - center.y, position.x - center.x)
                var laneRotation = angle + .pi / 2
                if laneRotation > .pi / 2 { laneRotation -= .pi }
                if laneRotation < -.pi / 2 { laneRotation += .pi }
                rotation = laneRotation
            } else {
                rotation = 0
            }
            drawJudgementText(
                context: &context, feedback: item, at: position, rotation: rotation, radius: radius,
                opacity: animation.opacity, scale: animation.scale)
        }
    }

    private func approachState(for event: SimaiNoteEvent, renderTime: TimeInterval, radius: CGFloat, center: CGPoint)
        -> SimaiApproachState
    {
        let progress = 1 - (event.time - renderTime) / max(settings.approachTime, 0.001)
        let motion = SimaiNoteMotion.ringState(progress: progress)
        let currentRadius = radius * CGFloat(motion.radius)
        let scale = CGFloat(motion.scale)
        let mirrored = settings.mirror.map(location: event.location)
        let angle = SimaiSlidePathGeometry.angle(for: mirrored)
        return SimaiApproachState(
            progress: progress, currentRadius: currentRadius, scale: scale, angle: angle,
            position: CGPoint(x: center.x + cos(angle) * currentRadius, y: center.y + sin(angle) * currentRadius))
    }

    private func drawTap(
        context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color, highlighted: Bool
    ) {
        guard radius > 0 else { return }
        if highlighted {
            context.stroke(
                Path(ellipseIn: circle(center: center, radius: radius + radius * 0.16)),
                with: .color(color.opacity(0.40)), lineWidth: max(radius * 0.32, 2))
        }
        let innerRadius = radius * 0.65
        var body = Path()
        body.addEllipse(in: circle(center: center, radius: radius))
        body.addEllipse(in: circle(center: center, radius: innerRadius))
        context.fill(body, with: .color(color), style: FillStyle(eoFill: true))
        let stroke = max(radius / 18.75, 1)
        context.stroke(Path(ellipseIn: circle(center: center, radius: radius)), with: .color(.white), lineWidth: stroke)
        context.stroke(
            Path(ellipseIn: circle(center: center, radius: innerRadius)), with: .color(.white), lineWidth: stroke)
        context.fill(Path(ellipseIn: circle(center: center, radius: radius * 4 / 37.5)), with: .color(color))
    }

    private func drawStar(
        context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, rotation: CGFloat, color: Color,
        highlighted: Bool
    ) {
        guard radius > 0 else { return }
        if highlighted {
            context.stroke(
                starPath(center: center, radius: radius + radius * 0.16, rotation: rotation),
                with: .color(color.opacity(0.40)),
                style: StrokeStyle(lineWidth: max(radius * 0.32, 2), lineJoin: .round))
        }
        let outer = starPath(center: center, radius: radius, rotation: rotation)
        let inner = starPath(center: center, radius: radius * 0.6, rotation: rotation)
        var body = Path()
        body.addPath(outer)
        body.addPath(inner)
        context.fill(body, with: .color(color), style: FillStyle(eoFill: true))
        let stroke = max(radius / 18.75, 1)
        context.stroke(outer, with: .color(.white), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
        context.stroke(inner, with: .color(.white), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
    }

    private func drawHold(
        context: inout GraphicsContext, event: SimaiNoteEvent, state: SimaiApproachState, renderTime: TimeInterval,
        center: CGPoint, radius: CGFloat, color: Color
    ) {
        guard renderTime < event.headScoreTime else { return }
        let tailProgress = 1 - (event.headScoreTime - renderTime) / max(settings.approachTime, 0.001)
        let tailRadius = radius * SimaiNoteMotion.ringState(progress: tailProgress).radius
        let tail = CGPoint(
            x: center.x + CGFloat(Foundation.cos(Double(state.angle))) * tailRadius,
            y: center.y + CGFloat(Foundation.sin(Double(state.angle))) * tailRadius)
        let outerRadius = radius * 0.125 * state.scale
        guard outerRadius > 0 else { return }
        let angle =
            hypot(state.position.x - tail.x, state.position.y - tail.y) < 0.001
            ? state.angle : atan2(state.position.y - tail.y, state.position.x - tail.x)
        let outer = holdHull(head: state.position, tail: tail, radius: outerRadius, angle: angle)
        let inner = holdHull(head: state.position, tail: tail, radius: outerRadius * 0.7, angle: angle)

        if event.flags.contains(.ex) {
            context.stroke(
                outer, with: .color(color.opacity(0.40)),
                style: StrokeStyle(lineWidth: max(radius * 12 / 300 * state.scale, 2), lineJoin: .round))
        }

        var body = Path()
        body.addPath(outer)
        body.addPath(inner)
        context.fill(body, with: .color(color), style: FillStyle(eoFill: true))
        let stroke = max(radius * 2 / 300 * state.scale, 1)
        context.stroke(outer, with: .color(.white), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
        context.stroke(inner, with: .color(.white), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
        let dotRadius = max(radius * 5 / 300 * state.scale, 1)
        context.fill(Path(ellipseIn: circle(center: state.position, radius: dotRadius)), with: .color(color))
        context.fill(Path(ellipseIn: circle(center: tail, radius: dotRadius)), with: .color(color))
    }

    private func drawTouch(
        context: inout GraphicsContext, event: SimaiNoteEvent, renderTime: TimeInterval, center: CGPoint,
        radius: CGFloat, isEach: Bool
    ) {
        let remaining = event.time - renderTime
        let approach = max(settings.approachTime * 0.9, 0.001)
        guard remaining <= approach else { return }
        if event.kind == .touch, remaining <= 0, !isGameplay { return }
        if event.kind == .touchHold, renderTime >= event.endTime { return }

        var fade = 1.0
        if remaining > approach * 0.95 { fade = 1 - (remaining - approach * 0.95) / (approach * 0.05) }
        var convergence = 1.0
        if remaining > 0, remaining < approach {
            let elapsed = approach - remaining
            if elapsed < 0.15 { convergence = elapsed / 0.15 }
        }
        let opacity = max(0, min(1, fade * convergence))
        let target = screenPoint(
            event.location.normalizedPoint(mirror: settings.mirror), center: center, radius: radius)
        let scale = radius / 300
        let unit = 40 * scale
        let startDistance = unit + 18 * scale
        let distance: CGFloat
        if remaining > 0, remaining <= approach {
            let progress = 1 - remaining / approach
            distance = startDistance - (startDistance - unit) * pow(progress, 4)
        } else {
            distance = unit
        }

        let isHold = event.kind == .touchHold
        let baseColor =
            event.flags.contains(.breakNote)
            ? SimaiPalette.breakOrange : (isEach ? SimaiPalette.eachYellow : SimaiPalette.slideCyan)
        let holdColors: [Color] = [.red, .yellow, .green, .blue]
        let angles: [CGFloat] = [-.pi / 4, .pi / 4, .pi * 3 / 4, -.pi * 3 / 4]
        let rotation = isHold ? 0 : -CGFloat.pi / 4
        let petals = angles.map { baseAngle -> (tip: CGPoint, left: CGPoint, right: CGPoint) in
            let angle = baseAngle + rotation
            let petal = CGPoint(x: target.x + cos(angle) * distance, y: target.y + sin(angle) * distance)
            return (
                CGPoint(x: petal.x - cos(angle) * unit, y: petal.y - sin(angle) * unit),
                CGPoint(x: petal.x + cos(angle + .pi / 2) * unit, y: petal.y + sin(angle + .pi / 2) * unit),
                CGPoint(x: petal.x + cos(angle - .pi / 2) * unit, y: petal.y + sin(angle - .pi / 2) * unit)
            )
        }

        if isHold, remaining < 0, event.duration > 0 {
            drawTouchHoldProgressDiamond(
                context: &context, center: target, corners: petals.flatMap { [$0.left, $0.right] }, colors: holdColors,
                progress: max(0, min(1, -remaining / event.duration)), scale: scale, opacity: opacity)
        }

        for index in petals.indices {
            let tip = petals[index].tip
            let left = petals[index].left
            let right = petals[index].right
            let outer = roundedTriangle(tip, left, right, radius: 8 * scale)
            let fillColor = isHold ? holdColors[index] : baseColor

            if isHold {
                context.fill(outer, with: .color(fillColor.opacity(opacity)))
            } else {
                let centroid = CGPoint(x: (tip.x + left.x + right.x) / 3, y: (tip.y + left.y + right.y) / 3)
                let inner = roundedTriangle(
                    interpolate(centroid, tip, 0.4), interpolate(centroid, left, 0.4),
                    interpolate(centroid, right, 0.4), radius: 3.2 * scale)
                var body = Path()
                body.addPath(outer)
                body.addPath(inner)
                context.fill(body, with: .color(fillColor.opacity(opacity)), style: FillStyle(eoFill: true))
                context.stroke(inner, with: .color(.white.opacity(opacity)), lineWidth: max(3 * scale, 1))
            }
            context.stroke(
                outer, with: .color(.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: max(3 * scale, 1), lineJoin: .round))
        }

        let dotRadius = max(8 * scale, 2)
        context.fill(
            Path(ellipseIn: circle(center: target, radius: dotRadius)), with: .color(baseColor.opacity(opacity)))
        context.stroke(
            Path(ellipseIn: circle(center: target, radius: dotRadius)), with: .color(.white.opacity(opacity)),
            lineWidth: max(3 * scale, 1))
    }

    private func drawTouchHoldProgressDiamond(
        context: inout GraphicsContext, center: CGPoint, corners: [CGPoint], colors: [Color], progress: Double,
        scale: CGFloat, opacity: Double
    ) {
        guard !corners.isEmpty, progress > 0 else { return }
        let top = corners.min(by: { $0.y < $1.y }) ?? center
        let right = corners.max(by: { $0.x < $1.x }) ?? center
        let bottom = corners.max(by: { $0.y < $1.y }) ?? center
        let left = corners.min(by: { $0.x < $1.x }) ?? center
        let vertices = [top, right, bottom, left].map { point -> CGPoint in
            let dx = point.x - center.x
            let dy = point.y - center.y
            let length = max(hypot(dx, dy), 0.001)
            let outward = 18 * scale
            return CGPoint(x: point.x + dx / length * outward, y: point.y + dy / length * outward)
        }

        var clipped = context
        clipped.clip(to: roundedPolygon(vertices, radius: 8 * scale))
        let sweep = CGFloat(max(0, min(1, progress))) * .pi * 2
        if sweep < .pi * 2 {
            let radius = (vertices.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0) * 1.1
            var sector = Path()
            sector.move(to: center)
            sector.addLine(to: CGPoint(x: center.x, y: center.y - radius))
            sector.addArc(
                center: center, radius: radius, startAngle: .radians(-.pi / 2), endAngle: .radians(-.pi / 2 + sweep),
                clockwise: false)
            sector.closeSubpath()
            clipped.clip(to: sector)
        }

        for index in vertices.indices {
            var quadrant = Path()
            quadrant.move(to: center)
            quadrant.addLine(to: vertices[index])
            quadrant.addLine(to: vertices[(index + 1) % vertices.count])
            quadrant.closeSubpath()
            clipped.fill(quadrant, with: .color(colors[index].opacity(opacity)))
        }
    }

    private func drawApproachArc(
        context: inout GraphicsContext, center: CGPoint, radius: CGFloat, angle: CGFloat, color: Color
    ) {
        guard settings.showApproachLine, radius > 0 else { return }
        var arc = Path()
        arc.addArc(
            center: center, radius: radius, startAngle: .radians(angle - .pi / 4), endAngle: .radians(angle + .pi / 4),
            clockwise: false)
        context.stroke(
            arc, with: .color(color.opacity(0.84)), style: StrokeStyle(lineWidth: max(radius / 188, 1), lineCap: .round)
        )
    }

    private func drawSlideArrows(
        context: inout GraphicsContext, polyline: SimaiPolyline, center: CGPoint, radius: CGFloat,
        startDistance: CGFloat, color: Color
    ) {
        let spacing = radius * 25 / 300
        let first = max(0, Int(ceil(startDistance / max(spacing, 0.001))))
        guard first < polyline.slideArrows.count else { return }
        // The exact same authored chevrons, in unit playfield coordinates.
        // Only their cleared suffix changes; no path sampling/trig/CGPath
        // construction is necessary on the frame's main-thread hot path.
        var layer = context
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: radius, y: radius)
        var index = first
        var distance = CGFloat(first) * spacing
        // Keep the old screen-space termination rule. Floating-point rounding
        // at an exact endpoint must not add/remove the final arrow on resize.
        while distance < polyline.length * radius, index < polyline.slideArrows.count {
            layer.fill(polyline.slideArrows[index], with: .color(color))
            index += 1
            distance += spacing
        }
    }

    private func drawFanArrows(
        context: inout GraphicsContext, geometry: SimaiSlideGeometry, progress: [Double], center: CGPoint,
        radius: CGFloat, color: Color
    ) {
        let branches = geometry.branches
        guard branches.count >= 3, progress.count >= 3 else { return }
        let centerBranch = branches[0]
        guard centerBranch.length > 0 else { return }

        // A WiFi slide is one connected fan, not three ordinary slide ribbons.
        // Keep each crossbar visible until the least-complete branch passes it,
        // matching the three-branch behavior in simai_flutter/MajdataPlay.
        let firstProgress = max(0, min(1, progress.prefix(3).min() ?? 0))
        let spacing = max(radius * 40 / 300, 1)
        let totalLength = centerBranch.length * radius
        var distance = ceil(totalLength * firstProgress / spacing) * spacing
        let lineWidth = max(radius * 12 / 300, 2)

        if radius >= 7.5 {
            let first = max(0, Int(ceil(totalLength * firstProgress / spacing)))
            guard first < geometry.fanCrossbars.count else { return }
            let transform = CGAffineTransform(a: radius, b: 0, c: 0, d: radius, tx: center.x, ty: center.y)
            var index = first
            while distance < totalLength, index < geometry.fanCrossbars.count {
                context.stroke(
                    geometry.fanCrossbars[index].applying(transform), with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                index += 1
                distance += spacing
            }
            return
        }

        while distance < totalLength {
            let sampleProgress = distance / totalLength
            let centerPoint = screenPoint(branches[0].sample(at: sampleProgress).point, center: center, radius: radius)
            let leftPoint = screenPoint(branches[1].sample(at: sampleProgress).point, center: center, radius: radius)
            let rightPoint = screenPoint(branches[2].sample(at: sampleProgress).point, center: center, radius: radius)
            var crossbar = Path()
            crossbar.move(to: leftPoint)
            crossbar.addLine(to: centerPoint)
            crossbar.addLine(to: rightPoint)
            context.stroke(
                crossbar, with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            distance += spacing
        }
    }

    private func hitEffectPulseAges(elapsed: TimeInterval, holdDuration: TimeInterval) -> [TimeInterval] {
        let pulseDuration: TimeInterval = 0.36
        let interval: TimeInterval = 0.14
        guard elapsed.isFinite, elapsed >= 0 else { return [] }
        let duration = holdDuration.isFinite ? max(holdDuration, 0) : 0
        guard duration > 0 else { return elapsed < pulseDuration ? [elapsed] : [] }
        let last = Int(floor(min(elapsed, duration) / interval))
        let first = max(0, Int(ceil((elapsed - pulseDuration) / interval)))
        guard first <= last else { return [] }
        return (first...last).compactMap { index in
            let age = elapsed - Double(index) * interval
            return age >= 0 && age < pulseDuration ? age : nil
        }
    }

    private func drawHitEffectPulse(
        context: inout GraphicsContext, at position: CGPoint, baseRadius: CGFloat, age: TimeInterval, phase: Int,
        color: Color
    ) {
        let progress = max(0, min(1, age / 0.36))
        let eased = 1 - pow(1 - progress, 3)
        let pulseRadius = baseRadius * CGFloat(0.55 + (1.5 - 0.55) * eased)
        let fade = pow(1 - progress, 1.35)
        let fadeIn = min(max(progress / 0.08, 0), 1)
        let opacity = fade * (0.38 + 0.62 * fadeIn)
        guard opacity > 0.001 else { return }
        let variation = phase.isMultiple(of: 2) ? 1.0 : 0.92

        var glow = context
        glow.addFilter(.blur(radius: baseRadius * 0.32))
        glow.stroke(
            Path(ellipseIn: circle(center: position, radius: pulseRadius)),
            with: .color(color.opacity(0.45 * opacity * variation)),
            lineWidth: max(baseRadius * CGFloat(0.5 - progress * 0.12), 1))
        context.stroke(
            Path(ellipseIn: circle(center: position, radius: pulseRadius)),
            with: .color(color.opacity(0.92 * opacity * variation)),
            lineWidth: max(baseRadius * CGFloat(0.24 - progress * 0.05), 1))
        context.stroke(
            Path(ellipseIn: circle(center: position, radius: pulseRadius - baseRadius * 0.06)),
            with: .color(Color(red: 1, green: 240 / 255, blue: 160 / 255).opacity(0.69 * opacity * variation)),
            lineWidth: max(baseRadius * 0.055, 1))
    }

    private func judgementAnimation(age: TimeInterval) -> (opacity: Double, scale: CGFloat) {
        guard age >= 0, age < 0.5 else { return (0, 1) }
        if age < 0.1 {
            let linear = age / 0.1
            let eased = 1 - pow(1 - linear, 3)
            return (eased, CGFloat(1 + 0.55 * (1 - eased)))
        }
        if age <= 0.3 { return (1, 1) }
        let progress = max(0, min(1, (age - 0.3) / 0.2))
        return (1 - progress * progress, 1)
    }

    private func drawJudgementText(
        context: inout GraphicsContext, feedback: SimaiJudgementFeedback, at position: CGPoint, rotation: CGFloat,
        radius: CGFloat, opacity: Double, scale: CGFloat
    ) {
        var transformed = context
        transformed.translateBy(x: position.x, y: position.y)
        transformed.rotate(by: .radians(Double(rotation)))
        transformed.scaleBy(x: scale, y: scale)
        transformed.addFilter(.shadow(color: .black.opacity(0.85 * opacity), radius: max(radius * 0.012, 2)))

        let fontSize = min(max(radius * 0.064, 13), 22)
        var grade = transformed.resolve(
            Text(feedback.judgement.displayTitle).font(.system(size: fontSize, weight: .black, design: .rounded)))
        grade.shading = .color(feedback.judgement.effectColor.opacity(opacity))
        transformed.draw(grade, at: CGPoint(x: 0, y: 0), anchor: .center)

        guard feedback.judgement == .perfect || feedback.judgement == .great || feedback.judgement == .good,
            abs(feedback.offset) > SimaiTiming.frame
        else { return }
        let isFast = feedback.offset < 0
        var timing = transformed.resolve(
            Text(isFast ? "FAST" : "LATE").font(
                .system(size: max(fontSize * 0.58, 9), weight: .black, design: .rounded)))
        timing.shading = .color((isFast ? Color.blue : Color.red).opacity(opacity))
        transformed.draw(timing, at: CGPoint(x: 0, y: fontSize * 0.88), anchor: .center)
    }

    private func noteColor(for event: SimaiNoteEvent, isEach: Bool) -> Color {
        if event.flags.contains(.breakNote) || event.flags.contains(.mine) { return SimaiPalette.breakOrange }
        if isEach { return SimaiPalette.eachYellow }
        return event.kind == .slide ? SimaiPalette.slideCyan : SimaiPalette.tapPink
    }

    private func holdHull(head: CGPoint, tail: CGPoint, radius: CGFloat, angle: CGFloat) -> Path {
        func vertices(_ center: CGPoint) -> [CGPoint] {
            (0..<6).map { index in
                let theta = angle + CGFloat(index) * .pi / 3
                return CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
            }
        }
        let h = vertices(head)
        let t = vertices(tail)
        let points = [t[2], h[2], h[1], h[0], h[5], t[5], t[4], t[3]]
        var path = Path()
        for (index, point) in points.enumerated() { index == 0 ? path.move(to: point) : path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func starPath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> Path {
        var path = Path()
        for index in 0..<10 {
            let pointRadius = index.isMultiple(of: 2) ? radius : radius * 0.5
            let angle = rotation + CGFloat(index) * .pi / 5
            let point = CGPoint(x: center.x + cos(angle) * pointRadius, y: center.y + sin(angle) * pointRadius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func roundedTriangle(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, radius: CGFloat) -> Path {
        roundedPolygon([p0, p1, p2], radius: radius)
    }

    private func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> Path {
        guard points.count >= 3 else { return Path() }
        var starts = Array(repeating: CGPoint.zero, count: points.count)
        var ends = Array(repeating: CGPoint.zero, count: points.count)
        for index in points.indices {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let before = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
            let after = CGVector(dx: next.x - current.x, dy: next.y - current.y)
            let beforeLength = max(hypot(before.dx, before.dy), 0.001)
            let afterLength = max(hypot(after.dx, after.dy), 0.001)
            let corner = min(radius, beforeLength / 2, afterLength / 2)
            starts[index] = CGPoint(
                x: current.x + before.dx / beforeLength * corner, y: current.y + before.dy / beforeLength * corner)
            ends[index] = CGPoint(
                x: current.x + after.dx / afterLength * corner, y: current.y + after.dy / afterLength * corner)
        }
        var path = Path()
        path.move(to: ends[0])
        for index in 1...points.count {
            let next = index % points.count
            path.addLine(to: starts[next])
            path.addQuadCurve(to: ends[next], control: points[next])
        }
        path.closeSubpath()
        return path
    }

    private func screenPoint(_ point: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + point.x * radius, y: center.y + point.y * radius)
    }

    private func circle(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private func interpolate(_ start: CGPoint, _ end: CGPoint, _ progress: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }
}

extension Array { fileprivate subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }

private struct SimaiApproachState {
    let progress: Double
    let currentRadius: CGFloat
    let scale: CGFloat
    let angle: CGFloat
    let position: CGPoint
}

private enum SimaiPalette {
    static let tapPink = Color(red: 1, green: 105 / 255, blue: 180 / 255)
    static let eachYellow = Color(red: 1, green: 217 / 255, blue: 0)
    static let breakOrange = Color(red: 1, green: 113 / 255, blue: 0)
    static let slideCyan = Color(red: 0, green: 1, blue: 1)
}

public enum SimaiSlidePathGeometry {
    private static let centerRadiusRatio: CGFloat = 0.39
    private static let edgeCurveRadiusScale: CGFloat = 1.2
    private static let edgeCurveCenterRadiusRatio: CGFloat = 0.4662
    private static let edgeCurveCenterAngle: CGFloat = 3 * .pi / 8
    private static let defaultWrapThreshold: CGFloat = .pi / 16
    private static let edgeCurveWrapThreshold: CGFloat = .pi / 2

    private struct CacheKey: Hashable {
        // Shape depends on authored segments/mirror, not song timing, grade
        // or BREAK colour. Repeated paths share one immutable geometry.
        let segments: [SimaiSlideSegment]
        let mirror: SimaiMirrorMode
    }

    private static let cacheLock = NSLock()
    private static var geometryCache: [CacheKey: SimaiSlideGeometry] = [:]

    public static func geometry(for slide: SimaiSlidePath, mirror: SimaiMirrorMode) -> SimaiSlideGeometry {
        let key = CacheKey(segments: slide.segments, mirror: mirror)
        cacheLock.lock()
        if let cached = geometryCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let geometry = makeGeometry(for: slide, mirror: mirror)
        cacheLock.lock()
        geometryCache[key] = geometry
        cacheLock.unlock()
        return geometry
    }

    public static func prepare(chart: SimaiChart, mirror: SimaiMirrorMode) {
        for event in chart.events {
            for slide in event.slidePaths {
                let geometry = geometry(for: slide, mirror: mirror)
                _ = SimaiInputMapper.slideGroups(for: slide, geometry: geometry, mirror: mirror)
            }
        }
    }

    private static func makeGeometry(for slide: SimaiSlidePath, mirror: SimaiMirrorMode) -> SimaiSlideGeometry {
        var mainPoints: [CGPoint] = []
        for segment in slide.segments {
            let mapped = SimaiSlideSegment(
                shape: mirror.map(shape: segment.shape), start: mirror.map(location: segment.start),
                end: mirror.map(location: segment.end), via: segment.via.map { mirror.map(location: $0) })
            let generated = points(for: mapped)
            if mapped.shape == .fan { return SimaiSlideGeometry(branches: generated.map(SimaiPolyline.init(points:))) }
            guard let points = generated.first else { continue }
            if mainPoints.isEmpty {
                mainPoints.append(contentsOf: points)
            } else {
                mainPoints.append(contentsOf: points.dropFirst())
            }
        }
        return SimaiSlideGeometry(branches: [SimaiPolyline(points: mainPoints)])
    }

    public static func normalizedPoint(for slide: SimaiSlidePath, progress: CGFloat, mirror: SimaiMirrorMode) -> CGPoint
    { geometry(for: slide, mirror: mirror).branches.first?.sample(at: progress).point ?? .zero }

    public static func angle(for location: SimaiLocation) -> CGFloat {
        let base = -CGFloat.pi * 3 / 8 + CGFloat(location.index - 1) * .pi / 4
        return location.ring == .d || location.ring == .e ? base - .pi / 8 : base
    }

    private static func points(for segment: SimaiSlideSegment) -> [[CGPoint]] {
        let shape = segment.shape
        let start = startPoint(for: segment)
        let end = slidePoint(for: segment.end)
        switch shape {
        case .straight: return [[start, end]]
        case .centerFold: return [[start, .zero, end]]
        case .edgeFold: return [[start, segment.via.map(slidePoint(for:)) ?? .zero, end]]
        case .clockwise, .counterclockwise:
            let clockwise = shape == .clockwise
            let startAngle = angle(for: segment.start)
            let endAngle = angle(for: segment.end)
            let startRadius = slideRadius(for: segment.start)
            let endRadius = slideRadius(for: segment.end)
            let span = angleSpan(
                start: startAngle, end: endAngle, clockwise: clockwise, threshold: defaultWrapThreshold)
            let count = max(16, Int(ceil(span / (.pi / 64))))
            return [
                (0...count).map { index in
                    let progress = CGFloat(index) / CGFloat(count)
                    let theta = startAngle + (clockwise ? span : -span) * progress
                    let radius = startRadius + (endRadius - startRadius) * progress
                    return CGPoint(x: cos(theta) * radius, y: sin(theta) * radius)
                }
            ]
        case .curveLeft, .curveRight:
            let clockwise = shape == .curveRight
            let curveRadius = centerRadiusRatio
            let startRotation = angle(for: segment.start)
            let endRotation = angle(for: segment.end)
            let tangentDelta = acos(min(max(curveRadius, -1), 1))
            let tangentInRotation = clockwise ? startRotation + tangentDelta : startRotation - tangentDelta
            let tangentOutRotation = clockwise ? endRotation - tangentDelta : endRotation + tangentDelta
            let tangentIn = radialPoint(angle: tangentInRotation, radius: curveRadius)
            let span = angleSpan(
                start: tangentInRotation, end: tangentOutRotation, clockwise: clockwise, threshold: defaultWrapThreshold
            )
            var result = [start, tangentIn]
            let count = max(12, Int(ceil(span / (.pi / 64))))
            for index in 1...count {
                let progress = CGFloat(index) / CGFloat(count)
                let theta = tangentInRotation + (clockwise ? span : -span) * progress
                result.append(radialPoint(angle: theta, radius: curveRadius))
            }
            result.append(end)
            return [result]
        case .edgeCurveLeft, .edgeCurveRight:
            let clockwise = shape == .edgeCurveRight
            let curveRadius = centerRadiusRatio * edgeCurveRadiusScale
            let startRotation = angle(for: segment.start)
            let curveCenterRotation =
                clockwise ? startRotation - edgeCurveCenterAngle : startRotation + edgeCurveCenterAngle
            let curveCenter = radialPoint(angle: curveCenterRotation, radius: edgeCurveCenterRadiusRatio)
            let relativeStart = atan2(start.y - curveCenter.y, start.x - curveCenter.x)
            let relativeEnd = atan2(end.y - curveCenter.y, end.x - curveCenter.x)
            let startMagnitude = max(hypot(start.x - curveCenter.x, start.y - curveCenter.y), 0.001)
            let endMagnitude = max(hypot(end.x - curveCenter.x, end.y - curveCenter.y), 0.001)
            let startDelta = acos(min(max(curveRadius / startMagnitude, -1), 1))
            let endDelta = acos(min(max(curveRadius / endMagnitude, -1), 1))
            let tangentInRotation = clockwise ? relativeStart + startDelta : relativeStart - startDelta
            let tangentOutRotation = clockwise ? relativeEnd - endDelta : relativeEnd + endDelta
            let tangentIn = CGPoint(
                x: curveCenter.x + cos(tangentInRotation) * curveRadius,
                y: curveCenter.y + sin(tangentInRotation) * curveRadius)
            let span = angleSpan(
                start: tangentInRotation, end: tangentOutRotation, clockwise: clockwise,
                threshold: edgeCurveWrapThreshold)
            var result = [start, tangentIn]
            let count = max(12, Int(ceil(span / (.pi / 64))))
            for index in 1...count {
                let progress = CGFloat(index) / CGFloat(count)
                let theta = tangentInRotation + (clockwise ? span : -span) * progress
                result.append(
                    CGPoint(x: curveCenter.x + cos(theta) * curveRadius, y: curveCenter.y + sin(theta) * curveRadius))
            }
            result.append(end)
            return [result]
        case .zigzagLeft, .zigzagRight:
            let isZ = shape == .zigzagRight
            let offset = isZ ? CGFloat.pi / 2 : -CGFloat.pi / 2
            let first = radialPoint(angle: angle(for: segment.start) + offset, radius: centerRadiusRatio)
            let second = radialPoint(angle: angle(for: segment.end) + offset, radius: centerRadiusRatio)
            return [[start, first, second, end]]
        case .fan:
            let startIndex = segment.start.index
            let left = SimaiLocation(ring: segment.start.ring, index: wrappedLane(startIndex + 3))
            let middle = SimaiLocation(ring: segment.start.ring, index: wrappedLane(startIndex + 4))
            let right = SimaiLocation(ring: segment.start.ring, index: wrappedLane(startIndex + 5))
            // Keep the branch order identical to simai_flutter's precomputed
            // WiFi data: center, left, right. Rendering and judgement then share
            // the same stable three-star identity for the entire slide.
            return [
                [start, slidePoint(for: middle)], [start, slidePoint(for: left)], [start, slidePoint(for: right)],
            ]
        case .arc: return [[start, end]]
        }
    }

    private static func startPoint(for segment: SimaiSlideSegment) -> CGPoint {
        switch segment.shape {
        case .curveLeft, .curveRight, .edgeCurveLeft, .edgeCurveRight, .zigzagLeft, .zigzagRight:
            return radialPoint(angle: angle(for: segment.start), radius: 1)
        default: return slidePoint(for: segment.start)
        }
    }

    private static func slidePoint(for location: SimaiLocation) -> CGPoint {
        radialPoint(angle: angle(for: location), radius: slideRadius(for: location))
    }

    private static func slideRadius(for location: SimaiLocation) -> CGFloat {
        switch location.ring {
        case .lane: return 1
        case .a, .d: return 0.8
        case .b: return 0.4
        case .c: return 0
        case .e: return 0.45
        }
    }

    private static func radialPoint(angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private static func angleSpan(start: CGFloat, end: CGFloat, clockwise: Bool, threshold: CGFloat) -> CGFloat {
        let tau = CGFloat.pi * 2
        var span =
            clockwise
            ? (end - start).truncatingRemainder(dividingBy: tau) : (start - end).truncatingRemainder(dividingBy: tau)
        if span < 0 { span += tau }
        if span <= threshold { span += tau }
        return span
    }

    private static func wrappedLane(_ index: Int) -> Int { ((index - 1) % 8 + 8) % 8 + 1 }
}

public struct SimaiSlideGeometry {
    public let branches: [SimaiPolyline]
    public let fanCrossbars: [Path]

    public init(branches: [SimaiPolyline]) {
        self.branches = branches
        var crossbars: [Path] = []
        if branches.count >= 3, branches[0].length > 0 {
            let spacing: CGFloat = 40 / 300
            for index in 0...Int(ceil(branches[0].length / spacing)) {
                let distance = CGFloat(index) * spacing
                let progress = distance / branches[0].length
                var path = Path()
                path.move(to: branches[1].sample(at: progress).point)
                path.addLine(to: branches[0].sample(at: progress).point)
                path.addLine(to: branches[2].sample(at: progress).point)
                crossbars.append(path)
            }
        }
        fanCrossbars = crossbars
    }
}

public struct SimaiPolyline {
    public let points: [CGPoint]
    public let distances: [CGFloat]
    public let length: CGFloat
    public let bounds: CGRect
    public let slideArrows: [Path]

    public init(points: [CGPoint]) {
        let safePoints = points.isEmpty ? [.zero] : points
        var values: [CGFloat] = [0]
        var total: CGFloat = 0
        if safePoints.count > 1 {
            for index in 1..<safePoints.count {
                total += hypot(
                    safePoints[index].x - safePoints[index - 1].x, safePoints[index].y - safePoints[index - 1].y)
                values.append(total)
            }
        }
        self.points = safePoints
        distances = values
        length = total
        let xs = safePoints.map(\.x)
        let ys = safePoints.map(\.y)
        bounds = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0))
        let local = [
            CGPoint(x: -18.5 / 300, y: -20 / 300), CGPoint(x: -1.5 / 300, y: -20 / 300), CGPoint(x: 18.5 / 300, y: 0),
            CGPoint(x: -1.5 / 300, y: 20 / 300), CGPoint(x: -18.5 / 300, y: 20 / 300), CGPoint(x: 1.5 / 300, y: 0),
        ]
        var arrows: [Path] = []
        // A terminal template handles the endpoint rounding of every screen
        // size; drawSlideArrows still uses its original visibility condition.
        let spacing: CGFloat = 25 / 300
        for index in 0...Int(ceil(total / spacing)) where total > 0 {
            let distance = CGFloat(index) * spacing
            let sample = Self.sample(points: safePoints, distances: values, length: total, distance: distance)
            let cosine = cos(sample.angle)
            let sine = sin(sample.angle)
            var path = Path()
            for (index, point) in local.enumerated() {
                let rotated = CGPoint(
                    x: sample.point.x + point.x * cosine - point.y * sine,
                    y: sample.point.y + point.x * sine + point.y * cosine)
                index == 0 ? path.move(to: rotated) : path.addLine(to: rotated)
            }
            path.closeSubpath()
            arrows.append(path)
        }
        slideArrows = arrows
    }

    public func sample(at progress: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        sample(distance: length * max(0, min(1, progress)))
    }

    public func sample(distance rawDistance: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        Self.sample(points: points, distances: distances, length: length, distance: rawDistance)
    }

    private static func sample(points: [CGPoint], distances: [CGFloat], length: CGFloat, distance rawDistance: CGFloat)
        -> (point: CGPoint, angle: CGFloat)
    {
        guard points.count > 1, length > 0 else { return (points.first ?? .zero, 0) }
        let distance = max(0, min(length, rawDistance))
        var low = 1
        var high = distances.count
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] >= distance { high = middle } else { low = middle + 1 }
        }
        var upper = low
        upper = min(upper, points.count - 1)
        let lower = max(upper - 1, 0)
        let segmentLength = max(distances[upper] - distances[lower], 0.0001)
        let progress = (distance - distances[lower]) / segmentLength
        let first = points[lower]
        let second = points[upper]
        return (
            CGPoint(x: first.x + (second.x - first.x) * progress, y: first.y + (second.y - first.y) * progress),
            atan2(second.y - first.y, second.x - first.x)
        )
    }

    public func nearestProjection(to point: CGPoint, minimumProgress: CGFloat = 0, maximumProgress: CGFloat = 1) -> (
        progress: CGFloat, distance: CGFloat
    )? {
        guard points.count > 1, length > 0 else { return nil }
        let minimumDistance = length * max(0, min(1, minimumProgress))
        let maximumDistance = length * max(0, min(1, maximumProgress))
        guard minimumDistance <= maximumDistance else { return nil }

        var firstIndex = 1
        var low = 1
        var high = distances.count
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] >= minimumDistance { high = middle } else { low = middle + 1 }
        }
        firstIndex = min(low, points.count - 1)

        low = firstIndex
        high = distances.count
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] > maximumDistance { high = middle } else { low = middle + 1 }
        }
        let lastIndex = min(max(low, firstIndex), points.count - 1)

        var bestProgress: CGFloat?
        var bestSquaredDistance = CGFloat.greatestFiniteMagnitude
        for index in firstIndex...lastIndex {
            let segmentStart = distances[index - 1]
            let segmentEnd = distances[index]
            if segmentEnd < minimumDistance || segmentStart > maximumDistance { continue }
            let first = points[index - 1]
            let second = points[index]
            let dx = second.x - first.x
            let dy = second.y - first.y
            let squaredLength = max(dx * dx + dy * dy, 0.000_000_1)
            let raw = ((point.x - first.x) * dx + (point.y - first.y) * dy) / squaredLength
            let segmentLength = max(segmentEnd - segmentStart, 0.000_000_1)
            let lower = max(0, (minimumDistance - segmentStart) / segmentLength)
            let upper = min(1, (maximumDistance - segmentStart) / segmentLength)
            let local = max(lower, min(upper, raw))
            let projected = CGPoint(x: first.x + dx * local, y: first.y + dy * local)
            let projectedDistance = segmentStart + segmentLength * local
            let separationX = point.x - projected.x
            let separationY = point.y - projected.y
            let squaredDistance = separationX * separationX + separationY * separationY
            if squaredDistance < bestSquaredDistance {
                bestSquaredDistance = squaredDistance
                bestProgress = projectedDistance / length
            }
        }
        guard let bestProgress else { return nil }
        return (bestProgress, sqrt(bestSquaredDistance))
    }
}

public struct SimaiTouchContact: Hashable {
    public init(id: Int, point: CGPoint, timestamp: TimeInterval) {
        self.id = id
        self.point = point
        self.timestamp = timestamp
    }
    public let id: Int
    public let point: CGPoint
    public let timestamp: TimeInterval
}

public struct SimaiTouchFrame {
    public init(active: [SimaiTouchContact], changed: [SimaiTouchContact], phase: Phase) {
        self.active = active
        self.changed = changed
        self.phase = phase
    }
    public enum Phase: Equatable { case began, moved, ended, cancelled }
    public let active: [SimaiTouchContact]
    public let changed: [SimaiTouchContact]
    public let phase: Phase

    public var timestamp: TimeInterval {
        changed.lazy.map(\.timestamp).max() ?? active.lazy.map(\.timestamp).max()
            ?? ProcessInfo.processInfo.systemUptime
    }
}

#if canImport(UIKit)
public struct SimaiMultiTouchSurface: UIViewRepresentable {
    public init(onTouches: @escaping (SimaiTouchFrame) -> Void) { self.onTouches = onTouches }
    public let onTouches: (SimaiTouchFrame) -> Void

    public func makeUIView(context: Context) -> SimaiMultiTouchUIView {
        let view = SimaiMultiTouchUIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.onTouches = onTouches
        return view
    }

    public func updateUIView(_ uiView: SimaiMultiTouchUIView, context: Context) { uiView.onTouches = onTouches }
}

public final class SimaiMultiTouchUIView: UIView {
    public var onTouches: ((SimaiTouchFrame) -> Void)?
    private var activeContacts: [Int: SimaiTouchContact] = [:]

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let changed = touches.map { touch in
            let contact = contact(for: touch, id: touchID(for: touch))
            activeContacts[contact.id] = contact
            return contact
        }
        emit(changed: changed, phase: .began)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        // UIKit coalesces multiple hardware samples into one move callback. Feed
        // the complete trajectory to the Slide queue in one batch. This keeps
        // fast swipes accurate without rerunning every active Slide separately
        // for each coalesced point when several fingers are on screen.
        var changedContacts: [SimaiTouchContact] = []
        for touch in touches {
            let id = touchID(for: touch)
            let samples = touchSamples(for: touch, event: event)
            for sample in samples { changedContacts.append(contact(for: sample, id: id)) }
            if let latest = changedContacts.last(where: { $0.id == id }) { activeContacts[id] = latest }
        }
        emit(changed: changedContacts, phase: .moved)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        end(touches, event: event, phase: .ended)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        end(touches, event: event, phase: .cancelled)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { activeContacts.removeAll(keepingCapacity: true) }
    }

    private func end(_ touches: Set<UITouch>, event: UIEvent?, phase: SimaiTouchFrame.Phase) {
        var changed: [SimaiTouchContact] = []
        for touch in touches {
            let id = touchID(for: touch)
            let samples = touchSamples(for: touch, event: event)
            changed.append(contentsOf: samples.map { contact(for: $0, id: id) })
            activeContacts.removeValue(forKey: id)
        }
        emit(changed: changed, phase: phase)
    }

    private func emit(changed: [SimaiTouchContact], phase: SimaiTouchFrame.Phase) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        onTouches?(SimaiTouchFrame(active: Array(activeContacts.values), changed: changed, phase: phase))
    }

    private func touchID(for touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

    private func touchSamples(for touch: UITouch, event: UIEvent?) -> [UITouch] {
        var samples = event?.coalescedTouches(for: touch) ?? []
        if samples.isEmpty { return [touch] }
        if let latestTimestamp = samples.last?.timestamp, latestTimestamp + 0.000_001 < touch.timestamp {
            // Some iOS versions omit the current UITouch from the coalesced
            // array. Never lose the actual move/end callback.
            samples.append(touch)
        }
        return samples
    }

    private func contact(for touch: UITouch, id: Int) -> SimaiTouchContact {
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side * 0.425
        let point = touch.location(in: self)
        return SimaiTouchContact(
            id: id, point: CGPoint(x: (point.x - center.x) / radius, y: (point.y - center.y) / radius),
            timestamp: touch.timestamp)
    }
}

#endif

public enum SimaiJudgement: String, CaseIterable, Sendable {
    case criticalPerfect = "CRITICAL PERFECT"
    case perfect = "PERFECT"
    case great = "GREAT"
    case good = "GOOD"
    case miss = "MISS"

    // Keep the grading identity separate from the compact on-screen label.
    public var displayTitle: String { self == .criticalPerfect ? "CRITICAL" : rawValue }

    public var scoreWeight: Double {
        switch self {
        case .criticalPerfect, .perfect: return 1
        case .great: return 0.8
        case .good: return 0.5
        case .miss: return 0
        }
    }

    public var color: Color {
        switch self {
        case .criticalPerfect, .perfect: return Color(red: 1, green: 200 / 255, blue: 61 / 255)
        case .great: return Color(red: 1, green: 111 / 255, blue: 174 / 255)
        case .good: return Color(red: 105 / 255, green: 212 / 255, blue: 111 / 255)
        case .miss: return Color(red: 158 / 255, green: 158 / 255, blue: 158 / 255)
        }
    }

    public var effectColor: Color {
        switch self {
        case .criticalPerfect, .perfect: return Color(red: 1, green: 200 / 255, blue: 61 / 255)
        case .great: return Color(red: 1, green: 111 / 255, blue: 174 / 255)
        case .good: return Color(red: 105 / 255, green: 212 / 255, blue: 111 / 255)
        case .miss: return Color(red: 158 / 255, green: 158 / 255, blue: 158 / 255)
        }
    }
}

public struct SimaiJudgementFeedback: Identifiable, Sendable {
    public let id = UUID()
    public let eventID: Int
    public let pathIndex: Int?
    public let judgement: SimaiJudgement
    public let targetTime: TimeInterval
    public let judgedTime: TimeInterval
    public let offset: TimeInterval
    public let location: SimaiLocation
    public let isHead: Bool
}

public enum SimaiFireworkEffect {
    public static let duration: TimeInterval = 0.65
    public static let maximumVisibleBursts = 12

    public struct Spark: Sendable {
        public let direction: CGPoint
        public let reach: Double
        public let colorIndex: Int
    }

    public static let colors: [Color] = [
        Color(red: 1, green: 0.79, blue: 0.26), Color(red: 1, green: 0.43, blue: 0.65),
        Color(red: 0.30, green: 0.88, blue: 1), Color(red: 0.73, green: 1, blue: 0.56),
    ]

    // Immutable templates keep the burst deterministic during pause/seek and
    // avoid per-frame randomness, trig and persistent particle allocations.
    public static let sparks: [Spark] = (0..<24).map { index in
        let angle = Double(index) * .pi / 12
        return Spark(
            direction: CGPoint(x: cos(angle), y: sin(angle)), reach: index.isMultiple(of: 2) ? 1 : 0.67,
            colorIndex: index % colors.count)
    }

    public static func startTime(for event: SimaiNoteEvent, feedback: SimaiJudgementFeedback?, isGameplay: Bool)
        -> TimeInterval?
    {
        guard event.flags.contains(.fireworks), !event.flags.contains(.invalidate) else { return nil }
        guard isGameplay else { return event.fireworkTime }
        guard let feedback, feedback.eventID == event.id, feedback.judgement != .miss, feedback.pathIndex == nil,
            feedback.isHead == !event.hasHoldHead
        else { return nil }
        return feedback.judgedTime
    }

    public static func age(at time: TimeInterval, since start: TimeInterval) -> TimeInterval? {
        let elapsed = time - start
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        return elapsed
    }

    public static func sample(_ spark: Spark, age: TimeInterval, reducedMotion: Bool) -> (tip: CGPoint, tail: CGPoint) {
        let progress = min(max(age / duration, 0), 1)
        func position(_ time: Double) -> CGPoint {
            let distance = (reducedMotion ? 0.36 : 0.10 + 0.90 * (1 - pow(1 - time, 3))) * spark.reach
            let gravity = reducedMotion ? 0 : 0.16 * time * time
            return CGPoint(x: spark.direction.x * distance, y: spark.direction.y * distance + gravity)
        }
        return (position(progress), position(reducedMotion ? progress : max(progress - 0.065, 0)))
    }
}

private enum SimaiTiming {
    static let frame = 1.0 / 60.0
    static let tapWindow = 9 * frame
    static let touchEarlyWindow = 9 * frame
    static let touchLateWindow = 18 * frame
    static let slideWindow = 36 * frame
    // Delivery tolerance is not an extension of any judgement window. Always
    // judge with the original UITouch/coalesced-sample timestamp.
    static let inputDeliveryGrace: TimeInterval = 0.05
    static let resultFeedbackTail: TimeInterval = 0.8

    static func head(offset: TimeInterval, isTouch: Bool, isEX: Bool) -> SimaiJudgement? {
        guard offset.isFinite else { return nil }
        let epsilon = 1e-9
        if isTouch {
            guard offset >= -touchEarlyWindow - epsilon, offset <= touchLateWindow + epsilon else { return nil }
            if offset <= 9 * frame + epsilon { return .criticalPerfect }
            if offset <= 12 * frame + epsilon { return .perfect }
            if offset <= 15 * frame + epsilon { return .great }
            return .good
        }
        let absolute = abs(offset)
        guard absolute <= tapWindow + epsilon else { return nil }
        if isEX || absolute <= frame + epsilon { return .criticalPerfect }
        if absolute <= 3 * frame + epsilon { return .perfect }
        if absolute <= 6 * frame + epsilon { return .great }
        return .good
    }

    static func slide(offset: TimeInterval, finalZoneDwell: TimeInterval = 0) -> SimaiJudgement? {
        guard offset.isFinite, offset <= slideWindow + 1e-9 else { return nil }
        let criticalFrames = min(36, 14 + max(0, finalZoneDwell / frame) / 4)
        if abs(offset) <= criticalFrames * frame + 1e-9 { return .criticalPerfect }
        if abs(offset) <= 26 * frame { return .great }
        return .good
    }
}

public struct SimaiScoreSlot: Hashable, Sendable {
    public let eventID: Int
    public let pathIndex: Int?
    public let targetTime: TimeInterval
    public let type: SimaiScoringType
}

public enum SimaiJudgeBand: String, Sendable {
    case criticalPerfect, perfect1, perfect2, great1, great2, great3, good, miss
}

public struct SimaiScoreRecord: Sendable {
    public let slot: SimaiScoreSlot
    public let judgement: SimaiJudgement
    public let offset: TimeInterval
    public let band: SimaiJudgeBand

    public init(slot: SimaiScoreSlot, judgement: SimaiJudgement, offset: TimeInterval, isTouch: Bool = false) {
        self.slot = slot
        self.judgement = judgement
        self.offset = offset
        switch judgement {
        case .criticalPerfect: band = .criticalPerfect
        case .perfect: band = isTouch || abs(offset) <= 2 * SimaiTiming.frame + 1e-9 ? .perfect1 : .perfect2
        case .great:
            let frames = abs(offset) / SimaiTiming.frame
            band =
                isTouch || slot.pathIndex != nil || frames <= 4 + 1e-9
                ? .great1 : (frames <= 5 + 1e-9 ? .great2 : .great3)
        case .good: band = .good
        case .miss: band = .miss
        }
    }

    public var dxPoints: Int {
        switch judgement {
        case .criticalPerfect: return 3
        case .perfect: return 2
        case .great: return 1
        case .good, .miss: return 0
        }
    }

    public var breakExtra: Double {
        switch judgement {
        case .criticalPerfect: return 1
        case .perfect: return abs(offset) <= 2 * SimaiTiming.frame + 1e-9 ? 0.75 : 0.5
        case .great: return 0.4
        case .good: return 0.3
        case .miss: return 0
        }
    }
}

#if DEBUG
// Opt-in, bounded, timing-only measurements. No song, account, touch coordinates
// or identifiers are logged. Release builds contain neither samples nor logs.
public final class SimaiGameplayDiagnostics: @unchecked Sendable {
    public static let shared = SimaiGameplayDiagnostics()
    private let enabled = ProcessInfo.processInfo.environment["SIMAI_SWIFT_GAMEPLAY_METRICS"] == "1"
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]

    public func start() -> TimeInterval? { enabled ? ProcessInfo.processInfo.systemUptime : nil }

    public func record(_ metric: String, since start: TimeInterval?) {
        guard let start else { return }
        record(metric, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    public func record(_ metric: String, milliseconds: Double) {
        guard enabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        samples[metric, default: []].append(milliseconds)
        if samples[metric]!.count > 4_096 { samples[metric]!.removeFirst(1_024) }
        lock.unlock()
    }

    public func report() {
        guard enabled else { return }
        lock.lock()
        let snapshot = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        for key in snapshot.keys.sorted() {
            let sorted = snapshot[key]!.sorted()
            guard !sorted.isEmpty else { continue }
            let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            let line = String(
                format: "SimaiSwift gameplay %@ n=%d p50=%.3f p95=%.3f max=%.3f\n", key, sorted.count, p50, p95,
                sorted.last!)
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
#endif

private enum SimaiInputTarget: Hashable {
    case lane(Int)
    case sensor(SimaiLocation)
}

private struct SimaiPressInterval {
    let start: TimeInterval
    let end: TimeInterval
}

private struct SimaiTimedTouchContact {
    let sequence: UInt64
    let time: TimeInterval
    let contact: SimaiTouchContact
}

private struct SimaiSlideInteractionGroup {
    let targets: Set<SimaiInputTarget>
    let blocksSkip: Bool
    let pathProgress: Double
    let requiresContact: Bool

    init(targets: Set<SimaiInputTarget>, blocksSkip: Bool, pathProgress: Double = 0, requiresContact: Bool = false) {
        self.targets = targets
        self.blocksSkip = blocksSkip
        self.pathProgress = pathProgress
        self.requiresContact = requiresContact
    }
}

private struct SimaiSlideRuntime {
    let eventID: Int
    let pathIndex: Int
    let path: SimaiSlidePath
    let branches: [SimaiPolyline]
    let groups: [[SimaiSlideInteractionGroup]]
    var cursors: [Int]
    var armed: [Bool]
    var visualProgress: [Double]
    var lastProcessedTouchSequence: [UInt64]
    var branchCompletionTimes: [TimeInterval?]
    var pendingHeadActivationTargets: Set<SimaiInputTarget>
    var result: SimaiJudgement?

    var isComplete: Bool { groups.indices.allSatisfy { cursors[$0] >= groups[$0].count } }

    var remainingGroupCount: Int { groups.indices.reduce(0) { $0 + max(groups[$1].count - cursors[$1], 0) } }
}

@MainActor public final class SimaiGameplaySession: ObservableObject {
    @Published public private(set) var judgements: [Int: SimaiJudgement] = [:]
    @Published public private(set) var combo = 0
    @Published public private(set) var maxCombo = 0
    @Published public private(set) var lastJudgement: SimaiJudgement?
    @Published public private(set) var headFeedbackByEventID: [Int: SimaiJudgementFeedback] = [:]
    @Published public private(set) var judgementFeedback: [SimaiJudgementFeedback] = []
    @Published public private(set) var isFinished = false
    @Published public private(set) var slideInputRevision = 0

    public let chart: SimaiChart
    private let gameplayEventBus: GameplayEventBus
    private let headExpirationOrder: [Int]
    private let holdResolutionOrder: [Int]
    public let scoreSlots: [SimaiScoreSlot]
    private let headSlots: [Int: SimaiScoreSlot]
    private let pathSlots: [String: SimaiScoreSlot]
    private let totalScoreWeight: Double
    private let breakCount: Int
    private let contentEndTime: TimeInterval
    private var resolvedScores: [SimaiScoreSlot: SimaiScoreRecord] = [:]
    public private(set) var scoreRecords: [SimaiScoreRecord] = []
    private var scoreCommitCursor = 0
    private var earnedBreakExtras = 0.0
    private var lostBreakExtras = 0.0
    public private(set) var dxScore = 0
    public private(set) var fastCount = 0
    public private(set) var lateCount = 0
    private var manualOffsetTotal = 0.0
    private var manualOffsetCount = 0
    private var headJudgements: [Int: SimaiJudgement] = [:]
    private var pointerTargets: [Int: Set<SimaiInputTarget>] = [:]
    private var openPresses: [SimaiInputTarget: TimeInterval] = [:]
    private var pressIntervals: [SimaiInputTarget: [SimaiPressInterval]] = [:]
    private var slideRuntimes: [String: SimaiSlideRuntime] = [:]
    private var activeTargets: Set<SimaiInputTarget> = []
    private var slideMovedContactIDs: Set<Int> = []
    private var recentSlideContacts: [SimaiTimedTouchContact] = []
    private var nextSlideTouchSequence: UInt64 = 0
    private var mirror: SimaiMirrorMode = .none
    private var soundSettings = SimaiPlaybackSettings()
    private var lastChartTime: TimeInterval = 0
    private var headExpirationCursor = 0
    private var holdResolutionCursor = 0
    private var noteArrivalCursor = 0
    private var earnedScoreWeight: Double = 0
    private var lostScoreWeight: Double = 0
    public private(set) var judgedEventIDs: Set<Int> = []
    public private(set) var resolvedHeadEventIDs: Set<Int> = []
    public private(set) var slideVisualProgress: [String: [Double]] = [:]

    public init(chart: SimaiChart, gameplayEventBus: GameplayEventBus = .shared) {
        self.chart = chart
        self.gameplayEventBus = gameplayEventBus
        var heads: [Int: SimaiScoreSlot] = [:]
        var paths: [String: SimaiScoreSlot] = [:]
        var slots: [SimaiScoreSlot] = []
        for event in chart.events where event.isScorable {
            let head = SimaiScoreSlot(
                eventID: event.id, pathIndex: nil, targetTime: event.headScoreTime, type: event.headScoringType)
            heads[event.id] = head
            slots.append(head)
            for (index, path) in event.slidePaths.enumerated() {
                let slot = SimaiScoreSlot(
                    eventID: event.id, pathIndex: index, targetTime: path.endTime,
                    type: path.isBreak ? .breakNote : .slide)
                paths["\(event.id):\(index)"] = slot
                slots.append(slot)
            }
        }
        scoreSlots = slots.sorted {
            if $0.targetTime != $1.targetTime { return $0.targetTime < $1.targetTime }
            if $0.eventID != $1.eventID { return $0.eventID < $1.eventID }
            return ($0.pathIndex ?? -1) < ($1.pathIndex ?? -1)
        }
        headSlots = heads
        pathSlots = paths
        totalScoreWeight = slots.reduce(0) { $0 + $1.type.weight }
        breakCount = slots.filter { $0.type == .breakNote }.count
        contentEndTime = chart.events.map(\.endTime).max() ?? 0
        headExpirationOrder = chart.events.indices.filter { chart.events[$0].isScorable }.sorted { lhs, rhs in
            Self.headDeadline(for: chart.events[lhs]) < Self.headDeadline(for: chart.events[rhs])
        }
        holdResolutionOrder = chart.events.indices.filter {
            chart.events[$0].isScorable && chart.events[$0].hasHoldHead
        }.sorted { Self.holdResolutionTime(chart.events[$0]) < Self.holdResolutionTime(chart.events[$1]) }
    }

    public var pressedHoldEventIDs: Set<Int> {
        let activeHolds = chart.events(from: lastChartTime - chart.maximumEventDuration, through: lastChartTime)
        return Set(
            activeHolds.compactMap { event in
                guard event.hasHoldHead, lastChartTime >= event.time, lastChartTime < event.headScoreTime,
                    let head = headJudgements[event.id], head != .miss,
                    activeTargets.contains(inputTarget(for: event.location))
                else { return nil }
                return event.id
            })
    }

    public var achievement: Double {
        guard totalScoreWeight > 0 else { return 0 }
        return earnedScoreWeight / totalScoreWeight * 100
            + (breakCount > 0 ? earnedBreakExtras / Double(breakCount) : 0)
    }

    public var achievementFrom101: Double {
        guard totalScoreWeight > 0 else { return 101 }
        return max(
            0,
            101 - lostScoreWeight / totalScoreWeight * 100 - (breakCount > 0 ? lostBreakExtras / Double(breakCount) : 0)
        )
    }

    public var noteCount: Int { scoreSlots.count }
    public var judgedCount: Int { scoreRecords.count }
    public var totalDXScore: Int { noteCount * 3 }
    public var perfectCount: Int { counts(for: .criticalPerfect) + counts(for: .perfect) }
    public var averageOffsetMilliseconds: Double? {
        manualOffsetCount > 0 ? manualOffsetTotal * 1_000 / Double(manualOffsetCount) : nil
    }

    public func reset() {
        judgements.removeAll()
        headJudgements.removeAll()
        headFeedbackByEventID.removeAll()
        judgementFeedback.removeAll()
        pointerTargets.removeAll()
        openPresses.removeAll()
        pressIntervals.removeAll()
        slideRuntimes.removeAll()
        judgedEventIDs.removeAll()
        resolvedHeadEventIDs.removeAll()
        slideVisualProgress.removeAll()
        activeTargets.removeAll()
        slideMovedContactIDs.removeAll()
        recentSlideContacts.removeAll()
        nextSlideTouchSequence = 0
        slideInputRevision = 0
        combo = 0
        maxCombo = 0
        lastJudgement = nil
        lastChartTime = 0
        headExpirationCursor = 0
        holdResolutionCursor = 0
        noteArrivalCursor = 0
        earnedScoreWeight = 0
        lostScoreWeight = 0
        resolvedScores.removeAll(keepingCapacity: true)
        scoreRecords.removeAll(keepingCapacity: true)
        scoreCommitCursor = 0
        earnedBreakExtras = 0
        lostBreakExtras = 0
        dxScore = 0
        fastCount = 0
        lateCount = 0
        manualOffsetTotal = 0
        manualOffsetCount = 0
        isFinished = false
    }

    public func handle(
        frame: SimaiTouchFrame, playbackTimeAtSystemUptime: (TimeInterval) -> TimeInterval,
        settings: SimaiPlaybackSettings
    ) {
        #if DEBUG
        let judgeStart = SimaiGameplayDiagnostics.shared.start()
        SimaiGameplayDiagnostics.shared.record(
            "touch_delivery_ms", milliseconds: (ProcessInfo.processInfo.systemUptime - frame.timestamp) * 1_000)
        defer { SimaiGameplayDiagnostics.shared.record("touch_judge_cpu_ms", since: judgeStart) }
        #endif
        guard !isFinished else { return }
        soundSettings = settings
        mirror = settings.mirror
        let timingOffset = settings.audioTimingOffset - settings.visualTimingOffset
        let chartTime = playbackTimeAtSystemUptime(frame.timestamp) + timingOffset
        lastChartTime = max(lastChartTime, chartTime)
        publishNoteArrivals(through: chartTime)
        let nextTargets = Dictionary(
            uniqueKeysWithValues: frame.active.compactMap { contact in
                let targets = SimaiInputMapper.targets(at: contact.point)
                return targets.isEmpty ? nil : (contact.id, targets)
            })

        let previousRawTargets = pointerTargets.values.reduce(into: Set<SimaiInputTarget>()) { $0.formUnion($1) }
        let nextRawTargets = nextTargets.values.reduce(into: Set<SimaiInputTarget>()) { $0.formUnion($1) }
        let previousPressTargets = effectivePressTargets(from: previousRawTargets)
        let nextPressTargets = effectivePressTargets(from: nextRawTargets)

        for target in previousPressTargets.subtracting(nextPressTargets) { closePress(target, at: chartTime) }
        for target in nextPressTargets.subtracting(previousPressTargets) { openPress(target, at: chartTime) }
        let activatedTargets = nextRawTargets.subtracting(previousRawTargets).sorted {
            activationPriority($0) < activationPriority($1)
        }
        for target in activatedTargets { judgeActivatedTarget(target, at: chartTime, settings: settings) }

        pointerTargets = nextTargets
        activeTargets = nextPressTargets
        let activeIDs = Set(frame.active.map(\.id))
        let movedContacts: [SimaiTouchContact]
        switch frame.phase {
        case .began:
            slideMovedContactIDs.subtract(frame.changed.map(\.id))
            movedContacts = []
        case .moved:
            let activeMovement = frame.changed.filter { activeIDs.contains($0.id) }
            slideMovedContactIDs.formUnion(activeMovement.map(\.id))
            movedContacts = activeMovement
        case .ended:
            // Keep the final coalesced samples of a real swipe. Previously the
            // touch was removed from `active` first, so its last segment and
            // endpoint were always discarded.
            movedContacts = frame.changed.filter { slideMovedContactIDs.contains($0.id) }
            slideMovedContactIDs.subtract(frame.changed.map(\.id))
        case .cancelled:
            slideMovedContactIDs.subtract(frame.changed.map(\.id))
            movedContacts = []
        }
        if !movedContacts.isEmpty {
            // Coalesced samples are historical input points. Preserve their
            // hardware timestamps instead of judging the entire batch at the
            // later UIKit callback time, which otherwise creates a Late bias
            // whenever rendering is busy.
            for contact in movedContacts.sorted(by: {
                if $0.timestamp == $1.timestamp { return $0.id < $1.id }
                return $0.timestamp < $1.timestamp
            }) {
                nextSlideTouchSequence &+= 1
                recentSlideContacts.append(
                    SimaiTimedTouchContact(
                        sequence: nextSlideTouchSequence,
                        time: playbackTimeAtSystemUptime(contact.timestamp) + timingOffset, contact: contact))
            }
            trimRecentSlideContacts(at: chartTime)
        }
        if processSlides(at: chartTime, settings: settings) {
            // The playback clock redraws at 60 fps, but direct manipulation
            // should not have to wait for its next tick.
            slideInputRevision &+= 1
        }
    }

    public func update(time: TimeInterval, settings: SimaiPlaybackSettings) {
        #if DEBUG
        let updateStart = SimaiGameplayDiagnostics.shared.start()
        defer { SimaiGameplayDiagnostics.shared.record("judge_tick_cpu_ms", since: updateStart) }
        #endif
        guard !isFinished else { return }
        soundSettings = settings
        mirror = settings.mirror
        let chartTime = time + settings.audioTimingOffset - settings.visualTimingOffset
        lastChartTime = chartTime
        publishNoteArrivals(through: chartTime)
        _ = processSlides(at: chartTime, settings: settings)

        while headExpirationCursor < headExpirationOrder.count {
            let event = chart.events[headExpirationOrder[headExpirationCursor]]
            let deadline = Self.headDeadline(for: event)
            guard chartTime > deadline + SimaiTiming.inputDeliveryGrace else { break }
            headExpirationCursor += 1
            guard judgements[event.id] == nil, headJudgements[event.id] == nil else { continue }

            storeHeadFeedback(.miss, for: event, at: deadline)
            if event.kind == .slide {
                prepareSlides(for: event)
            } else if event.kind != .hold, event.kind != .touchHold {
                apply(.miss, to: event)
            }
        }

        while holdResolutionCursor < holdResolutionOrder.count {
            let event = chart.events[holdResolutionOrder[holdResolutionCursor]]
            guard chartTime >= Self.holdResolutionTime(event) else { break }
            holdResolutionCursor += 1
            if judgements[event.id] == nil { resolveHold(event, at: chartTime) }
        }

        resolveExpiredSlides(at: chartTime)
        if chartTime >= chart.duration
            || (judgedCount == noteCount && chartTime >= contentEndTime + SimaiTiming.resultFeedbackTail)
        {
            closeAllPresses(at: chartTime)
            isFinished = true
            #if DEBUG
            SimaiGameplayDiagnostics.shared.report()
            #endif
        }
    }

    public func releaseAllInputs(time: TimeInterval, settings: SimaiPlaybackSettings) {
        soundSettings = settings
        mirror = settings.mirror
        let chartTime = time + settings.audioTimingOffset - settings.visualTimingOffset
        lastChartTime = chartTime
        closeAllPresses(at: chartTime)
        pointerTargets.removeAll(keepingCapacity: true)
        activeTargets.removeAll(keepingCapacity: true)
        slideMovedContactIDs.removeAll(keepingCapacity: true)
        recentSlideContacts.removeAll(keepingCapacity: true)
        for key in Array(slideRuntimes.keys) {
            guard var runtime = slideRuntimes[key], runtime.result == nil else { continue }
            runtime.armed = Array(repeating: false, count: runtime.armed.count)
            slideRuntimes[key] = runtime
        }
    }

    public func counts(for judgement: SimaiJudgement) -> Int {
        scoreRecords.lazy.filter { $0.judgement == judgement }.count
    }

    @discardableResult private func judgeHead(
        for target: SimaiInputTarget, at time: TimeInterval, settings: SimaiPlaybackSettings
    ) -> SimaiNoteEvent? {
        let candidates = chart.events(
            from: time - SimaiTiming.touchLateWindow,
            through: time + max(SimaiTiming.tapWindow, SimaiTiming.touchEarlyWindow)
        ).filter { event in
            guard event.isScorable, headJudgements[event.id] == nil else { return false }
            let isTouch = event.location.ring != .lane
            let minimum = event.time - (isTouch ? SimaiTiming.touchEarlyWindow : SimaiTiming.tapWindow)
            let maximum = event.time + (isTouch ? SimaiTiming.touchLateWindow : SimaiTiming.tapWindow)
            return time >= minimum - 1e-9 && time <= maximum + 1e-9 && inputTarget(for: event.location) == target
        }
        guard let event = candidates.min(by: { abs(time - $0.time) < abs(time - $1.time) }) else { return nil }
        let judgement =
            SimaiTiming.head(
                offset: time - event.time, isTouch: event.location.ring != .lane, isEX: event.flags.contains(.ex))
            ?? .miss

        storeHeadFeedback(judgement, for: event, at: time)

        if event.hasHoldHead || event.kind == .slide {
            if event.kind == .slide { prepareSlides(for: event) }
        } else {
            apply(judgement, to: event)
        }
        return event
    }

    private func judgeActivatedTarget(
        _ target: SimaiInputTarget, at time: TimeInterval, settings: SimaiPlaybackSettings
    ) {
        switch target {
        case .lane: judgeHead(for: target, at: time, settings: settings)
        case .sensor(let location):
            if location.ring == .a {
                if let event = judgeHead(for: .lane(location.index), at: time, settings: settings), event.kind == .slide
                {
                    queueInnerSlideHeadActivation(for: event, target: .sensor(location), at: time)
                }
            }
            judgeHead(for: target, at: time, settings: settings)
        }
    }

    private func queueInnerSlideHeadActivation(
        for event: SimaiNoteEvent, target: SimaiInputTarget, at time: TimeInterval
    ) {
        prepareSlides(for: event)
        for pathIndex in event.slidePaths.indices {
            let key = slideKey(eventID: event.id, pathIndex: pathIndex)
            guard var runtime = slideRuntimes[key], time < runtime.path.startTime else { continue }
            runtime.pendingHeadActivationTargets.insert(target)
            slideRuntimes[key] = runtime
        }
    }

    private func effectivePressTargets(from rawTargets: Set<SimaiInputTarget>) -> Set<SimaiInputTarget> {
        var result = rawTargets
        for target in rawTargets {
            if case .sensor(let location) = target, location.ring == .a { result.insert(.lane(location.index)) }
        }
        return result
    }

    private func activationPriority(_ target: SimaiInputTarget) -> Int {
        switch target {
        case .sensor(let location) where location.ring == .a: return 0
        case .sensor: return 1
        case .lane: return 2
        }
    }

    private func resolveHold(_ event: SimaiNoteEvent, at time: TimeInterval) {
        guard let slot = headSlots[event.id], resolvedScores[slot] == nil else { return }
        let head = headJudgements[event.id] ?? .miss
        let isTouchHold = event.kind == .touchHold
        let shortFrames = isTouchHold ? 27.0 : 18.0
        let ratio: Double
        if event.duration < shortFrames * SimaiTiming.frame {
            ratio = head == .miss ? 0 : 1
        } else {
            let ignoredHeadFrames = isTouchHold ? 15.0 : 6.0
            let start = event.time + ignoredHeadFrames * SimaiTiming.frame
            let end = event.headScoreTime - 12 * SimaiTiming.frame
            let duration = max(end - start, 0)
            let target = inputTarget(for: event.location)
            ratio =
                duration > 0
                ? pressedDuration(for: target, from: start, to: end, now: time) / duration : (head == .miss ? 0 : 1)
        }
        let final = adjustedHoldGrade(head: head, ratio: max(0, min(1, ratio)))
        let headOffset = headFeedbackByEventID[event.id]?.offset ?? 0
        appendFeedback(
            SimaiJudgementFeedback(
                eventID: event.id, pathIndex: nil, judgement: final, targetTime: event.headScoreTime, judgedTime: time,
                offset: headOffset, location: event.location, isHead: false))
        publishGameplayEvent(
            kind: ratio >= 1 - 1e-9 && head != .miss ? .holdEnd : .holdBreak, for: event, at: time, judgement: final,
            timingOffset: time - event.endTime)
        resolveScore(slot, judgement: final, offset: headOffset)
        if event.kind == .slide { resolveSlideEventIfReady(event.id, at: time) } else { apply(final, to: event) }
    }

    private func adjustedHoldGrade(head: SimaiJudgement, ratio: Double) -> SimaiJudgement {
        if ratio >= 1 - 1e-9 {
            if head == .good { return .great }
            if head == .miss { return .good }
            return head
        }
        if ratio >= 0.67 {
            if head == .criticalPerfect || head == .perfect { return head }
            if head == .good { return .great }
            if head == .miss { return .good }
            return head
        }
        if ratio >= 0.33 {
            if head == .criticalPerfect || head == .perfect { return .great }
            if head == .miss { return .good }
            return head
        }
        if ratio >= 0.05 { return .good }
        return head == .miss || head == .good ? head : .good
    }

    private func prepareSlides(for event: SimaiNoteEvent) {
        for (index, path) in event.slidePaths.enumerated() {
            let key = slideKey(eventID: event.id, pathIndex: index)
            guard slideRuntimes[key] == nil else { continue }
            let geometry = SimaiSlidePathGeometry.geometry(for: path, mirror: mirror)
            let groups = SimaiInputMapper.slideGroups(for: path, geometry: geometry, mirror: mirror)
            slideRuntimes[key] = SimaiSlideRuntime(
                eventID: event.id, pathIndex: index, path: path, branches: geometry.branches, groups: groups,
                cursors: Array(repeating: 0, count: groups.count), armed: Array(repeating: false, count: groups.count),
                visualProgress: Array(repeating: 0, count: groups.count),
                lastProcessedTouchSequence: Array(repeating: 0, count: groups.count),
                branchCompletionTimes: Array(repeating: nil, count: groups.count), pendingHeadActivationTargets: [],
                result: nil)
            slideVisualProgress[key] = Array(repeating: 0, count: groups.count)
        }
    }

    private func processSlides(at time: TimeInterval, settings: SimaiPlaybackSettings) -> Bool {
        var didChangeVisualProgress = false
        trimRecentSlideContacts(at: time)
        let candidates = chart.events(
            from: time - chart.maximumEventDuration - SimaiTiming.slideWindow, through: time + settings.approachTime)
        for event in candidates
        where event.kind == .slide && event.isScorable && judgements[event.id] == nil
            && time >= event.time - settings.approachTime
            && time <= event.endTime + SimaiTiming.slideWindow + SimaiTiming.inputDeliveryGrace
        { prepareSlides(for: event) }

        let activeKeys = slideRuntimes.compactMap { key, runtime -> String? in
            runtime.result == nil && time >= runtime.path.startTime
                && time <= runtime.path.endTime + SimaiTiming.slideWindow + SimaiTiming.inputDeliveryGrace ? key : nil
        }.sorted { lhs, rhs in
            guard let left = slideRuntimes[lhs], let right = slideRuntimes[rhs] else { return lhs < rhs }
            if left.path.startTime != right.path.startTime { return left.path.startTime < right.path.startTime }
            if left.eventID != right.eventID { return left.eventID < right.eventID }
            return left.pathIndex < right.pathIndex
        }
        for key in activeKeys {
            guard var runtime = slideRuntimes[key], runtime.result == nil else { continue }
            let previousVisualProgress = runtime.visualProgress
            if !runtime.pendingHeadActivationTargets.isEmpty {
                let pending = runtime.pendingHeadActivationTargets
                runtime.pendingHeadActivationTargets.removeAll()
                for branchIndex in runtime.groups.indices {
                    let cursor = runtime.cursors[branchIndex]
                    guard cursor < runtime.groups[branchIndex].count else { continue }
                    let first = runtime.groups[branchIndex][cursor]
                    if !first.targets.isDisjoint(with: pending), first.targets.isDisjoint(with: activeTargets) {
                        runtime.cursors[branchIndex] += 1
                        runtime.armed[branchIndex] = false
                    }
                }
            }
            for branchIndex in runtime.groups.indices {
                let groups = runtime.groups[branchIndex]
                while time <= runtime.path.endTime + SimaiTiming.slideWindow + 1e-9,
                    runtime.cursors[branchIndex] < groups.count
                {
                    let cursor = runtime.cursors[branchIndex]
                    let current = groups[cursor]
                    let currentOn = !current.targets.isDisjoint(with: activeTargets)
                    // Earlier groups still require ordered traversal. Once the
                    // final group is reached, contact itself completes it: a
                    // stationary handoff must score at arrival, not on release
                    // or only after a moved callback runs the path fallback.
                    if currentOn, cursor == groups.count - 1 {
                        runtime.cursors[branchIndex] += 1
                        runtime.armed[branchIndex] = false
                        continue
                    }
                    if runtime.armed[branchIndex] {
                        if !currentOn {
                            runtime.cursors[branchIndex] += 1
                            runtime.armed[branchIndex] = false
                            continue
                        }
                    } else if currentOn {
                        runtime.armed[branchIndex] = true
                    }
                    if !current.blocksSkip, !current.requiresContact, cursor + 1 < groups.count,
                        !groups[cursor + 1].targets.isDisjoint(with: activeTargets)
                    {
                        runtime.cursors[branchIndex] += 1
                        runtime.armed[branchIndex] = true
                        continue
                    }
                    break
                }
                if runtime.cursors[branchIndex] >= groups.count, runtime.branchCompletionTimes[branchIndex] == nil {
                    runtime.branchCompletionTimes[branchIndex] = time
                }
                trackSlideFinger(runtime: &runtime, branchIndex: branchIndex, recentSamples: recentSlideContacts)
                updateVisualProgress(runtime: &runtime, branchIndex: branchIndex)
            }
            if runtime.visualProgress != previousVisualProgress { didChangeVisualProgress = true }

            if runtime.isComplete {
                let completedAt = runtime.branchCompletionTimes.compactMap { $0 }.max() ?? time
                runtime.result = SimaiTiming.slide(offset: completedAt - runtime.path.endTime) ?? .miss
                appendSlideFeedback(runtime: runtime, at: completedAt)
            }
            slideRuntimes[key] = runtime
            slideVisualProgress[key] = runtime.visualProgress
            resolveSlideEventIfReady(runtime.eventID, at: time)
        }
        return didChangeVisualProgress
    }

    private func trimRecentSlideContacts(at time: TimeInterval) {
        let cutoff = time - Self.slideMovementMemory
        if let firstCurrentIndex = recentSlideContacts.firstIndex(where: { $0.time >= cutoff }) {
            if firstCurrentIndex > 0 { recentSlideContacts.removeFirst(firstCurrentIndex) }
        } else if !recentSlideContacts.isEmpty {
            recentSlideContacts.removeAll(keepingCapacity: true)
        }
        if recentSlideContacts.count > Self.maximumRememberedSlideSamples {
            recentSlideContacts.removeFirst(recentSlideContacts.count - Self.maximumRememberedSlideSamples)
        }
    }

    private func resolveExpiredSlides(at time: TimeInterval) {
        for key in Array(slideRuntimes.keys) {
            guard var runtime = slideRuntimes[key], runtime.result == nil,
                time > runtime.path.endTime + SimaiTiming.slideWindow + SimaiTiming.inputDeliveryGrace
            else { continue }
            let canForgiveLastGroup =
                runtime.remainingGroupCount <= 1
                && !runtime.groups.indices.contains { branch in
                    runtime.groups[branch].dropFirst(runtime.cursors[branch]).contains(where: \.requiresContact)
                }
            runtime.result = canForgiveLastGroup ? .good : .miss
            runtime.visualProgress = runtime.groups.indices.map { branchIndex in
                let groups = runtime.groups[branchIndex]
                let cursor = runtime.cursors[branchIndex]
                guard !groups.isEmpty else { return 1 }
                return cursor > 0 ? groups[min(cursor - 1, groups.count - 1)].pathProgress : 0
            }
            appendSlideFeedback(runtime: runtime, at: runtime.path.endTime + SimaiTiming.slideWindow)
            slideRuntimes[key] = runtime
            slideVisualProgress[key] = runtime.visualProgress
            resolveSlideEventIfReady(runtime.eventID, at: time)
        }
    }

    private func resolveSlideEventIfReady(_ eventID: Int, at time: TimeInterval) {
        guard let event = chart.eventByID[eventID] else { return }
        let keys = event.slidePaths.indices.map { slideKey(eventID: eventID, pathIndex: $0) }
        let runtimes = keys.compactMap { slideRuntimes[$0] }
        guard let head = headSlots[eventID], resolvedScores[head] != nil, runtimes.count == event.slidePaths.count,
            runtimes.allSatisfy({ $0.result != nil })
        else { return }
        let pathResults = runtimes.compactMap(\.result)
        let results = pathResults + [resolvedScores[head]!.judgement]
        let final = results.min(by: { judgementRank($0) < judgementRank($1) }) ?? .miss
        publishGameplayEvent(
            kind: .slideComplete, for: event, at: time,
            judgement: pathResults.min(by: { judgementRank($0) < judgementRank($1) }) ?? .miss,
            timingOffset: time - event.endTime)
        apply(final, to: event)
        // Resolved paths never render or judge again. Dropping them keeps the
        // touch hot path proportional to the Slides currently on screen.
        for key in keys {
            slideRuntimes.removeValue(forKey: key)
            slideVisualProgress.removeValue(forKey: key)
        }
    }

    private func openPress(_ target: SimaiInputTarget, at time: TimeInterval) {
        guard openPresses[target] == nil else { return }
        openPresses[target] = time
    }

    private func closePress(_ target: SimaiInputTarget, at time: TimeInterval) {
        guard let start = openPresses.removeValue(forKey: target) else { return }
        pressIntervals[target, default: []].append(SimaiPressInterval(start: start, end: max(time, start)))
    }

    private func closeAllPresses(at time: TimeInterval) {
        for target in Array(openPresses.keys) { closePress(target, at: time) }
    }

    private func pressedDuration(
        for target: SimaiInputTarget, from start: TimeInterval, to end: TimeInterval, now: TimeInterval
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for interval in pressIntervals[target] ?? [] {
            total += max(0, min(interval.end, end) - max(interval.start, start))
        }
        if let open = openPresses[target], open < end { total += max(0, min(now, end) - max(open, start)) }
        return total
    }

    private func inputTarget(for location: SimaiLocation) -> SimaiInputTarget {
        let mapped = mirror.map(location: location)
        return mapped.ring == .lane ? .lane(mapped.index) : .sensor(mapped)
    }

    private func storeHeadFeedback(_ judgement: SimaiJudgement, for event: SimaiNoteEvent, at time: TimeInterval) {
        guard headJudgements[event.id] == nil else { return }
        headJudgements[event.id] = judgement
        resolvedHeadEventIDs.insert(event.id)
        let feedback = SimaiJudgementFeedback(
            eventID: event.id, pathIndex: nil, judgement: judgement, targetTime: event.time, judgedTime: time,
            offset: time - event.time, location: event.location, isHead: true)
        headFeedbackByEventID[event.id] = feedback
        if judgement != .miss, feedback.offset.isFinite {
            manualOffsetTotal += feedback.offset
            manualOffsetCount += 1
        }
        if !event.hasHoldHead, let slot = headSlots[event.id] {
            resolveScore(slot, judgement: judgement, offset: feedback.offset)
        }
        appendFeedback(feedback)
        publishGameplayEvent(
            kind: gameplayEventKind(for: event, judgement: judgement), for: event, at: time, judgement: judgement,
            timingOffset: time - event.time)
        if event.kind == .slide, !event.hasHoldHead { resolveSlideEventIfReady(event.id, at: time) }
    }

    private func publishNoteArrivals(through chartTime: TimeInterval) {
        guard chartTime.isFinite else { return }
        while noteArrivalCursor < chart.events.count {
            let event = chart.events[noteArrivalCursor]
            guard event.time <= chartTime else { break }
            noteArrivalCursor += 1
            guard event.isScorable else { continue }
            publishGameplayEvent(kind: .noteArrival, for: event, at: event.time, judgement: nil, timingOffset: nil)
        }
    }

    private func publishGameplayEvent(
        kind: GameplayEventKind, for event: SimaiNoteEvent, at timestamp: TimeInterval, judgement: SimaiJudgement?,
        timingOffset: TimeInterval?
    ) {
        let mappedLocation = mirror.map(location: event.location)
        let lane = mappedLocation.ring == .lane ? mappedLocation.index : nil
        let position = GameplayPosition(ring: gameplayPositionRing(mappedLocation.ring), index: mappedLocation.index)
        let duration: TimeInterval?
        switch event.kind {
        case .hold, .touchHold: duration = event.duration
        case .slide: duration = max(event.endTime - event.time, 0)
        case .tap, .touch: duration = nil
        }

        gameplayEventBus.publish(
            GameplayEvent(
                sourceNoteID: event.id, timestamp: timestamp, kind: kind, noteType: gameplayNoteType(for: event),
                baseNoteType: gameplayBaseNoteType(for: event), lane: lane, position: position,
                judge: judgement.map(gameplayJudge), timingOffsetMs: timingOffset.map { $0 * 1_000 }, duration: duration
            ))
    }

    private func gameplayEventKind(for event: SimaiNoteEvent, judgement: SimaiJudgement) -> GameplayEventKind {
        guard judgement != .miss else { return .noteHit }
        switch event.kind {
        case .tap: return .noteHit
        case .hold, .touchHold: return .holdStart
        case .slide: return .slideStart
        case .touch: return .touch
        }
    }

    private func gameplayNoteType(for event: SimaiNoteEvent) -> GameplayNoteType {
        if event.flags.contains(.breakNote) { return .breakNote }
        return gameplayBaseNoteType(for: event)
    }

    private func gameplayBaseNoteType(for event: SimaiNoteEvent) -> GameplayNoteType {
        switch event.kind {
        case .tap: return .tap
        case .hold: return .hold
        case .slide: return .slide
        case .touch: return .touch
        case .touchHold: return .touchHold
        }
    }

    private func gameplayJudge(_ judgement: SimaiJudgement) -> GameplayJudge {
        switch judgement {
        case .criticalPerfect: return .criticalPerfect
        case .perfect: return .perfect
        case .great: return .great
        case .good: return .good
        case .miss: return .miss
        }
    }

    private func gameplayPositionRing(_ ring: SimaiSensorRing) -> GameplayPositionRing {
        switch ring {
        case .lane: return .lane
        case .a: return .a
        case .b: return .b
        case .c: return .c
        case .d: return .d
        case .e: return .e
        }
    }

    private func appendSlideFeedback(runtime: SimaiSlideRuntime, at time: TimeInterval) {
        guard let judgement = runtime.result else { return }
        if let slot = pathSlots[slideKey(eventID: runtime.eventID, pathIndex: runtime.pathIndex)] {
            resolveScore(slot, judgement: judgement, offset: time - runtime.path.endTime)
        }
        appendFeedback(
            SimaiJudgementFeedback(
                eventID: runtime.eventID, pathIndex: runtime.pathIndex, judgement: judgement,
                targetTime: runtime.path.endTime, judgedTime: time, offset: time - runtime.path.endTime,
                location: runtime.path.end, isHead: false))
    }

    private func appendFeedback(_ feedback: SimaiJudgementFeedback) {
        judgementFeedback.append(feedback)
        if judgementFeedback.count > 160 { judgementFeedback.removeFirst(48) }
        lastJudgement = feedback.judgement

        if feedback.isHead, feedback.judgement != .miss, soundSettings.answerSoundEnabled {
            SimaiHitSoundEngine.shared.playAnswer(volume: soundSettings.answerSoundVolume)
        }

        if soundSettings.judgementSoundEnabled, representsFinalJudgement(feedback) {
            SimaiHitSoundEngine.shared.playJudgement(feedback.judgement, volume: soundSettings.judgementSoundVolume)
        }
    }

    private func representsFinalJudgement(_ feedback: SimaiJudgementFeedback) -> Bool {
        guard let event = chart.eventByID[feedback.eventID] else { return feedback.isHead }
        switch event.kind {
        case .tap, .touch: return feedback.isHead
        case .hold, .touchHold: return !feedback.isHead
        case .slide: return feedback.pathIndex != nil || (feedback.isHead && !event.hasHoldHead)
        }
    }

    private func updateVisualProgress(runtime: inout SimaiSlideRuntime, branchIndex: Int) {
        guard branchIndex < runtime.groups.count, branchIndex < runtime.visualProgress.count else { return }
        let groups = runtime.groups[branchIndex]
        guard !groups.isEmpty else {
            runtime.visualProgress[branchIndex] = 1
            return
        }

        let cursor = runtime.cursors[branchIndex]
        let clearedProgress = cursor >= groups.count ? 1 : (cursor > 0 ? groups[cursor - 1].pathProgress : 0)
        runtime.visualProgress[branchIndex] = max(runtime.visualProgress[branchIndex], clearedProgress)
    }

    /// Advances the cleared Slide trail from real finger movement. The guide
    /// star itself stays on the chart clock; this projection only keeps touch
    /// tracking forgiving while preserving the authored route order.
    private func trackSlideFinger(
        runtime: inout SimaiSlideRuntime, branchIndex: Int, recentSamples: [SimaiTimedTouchContact]
    ) {
        guard !recentSamples.isEmpty, branchIndex < runtime.groups.count, branchIndex < runtime.branches.count,
            branchIndex < runtime.visualProgress.count, branchIndex < runtime.lastProcessedTouchSequence.count
        else { return }

        let groups = runtime.groups[branchIndex]
        guard !groups.isEmpty else { return }
        let previousSequence = runtime.lastProcessedTouchSequence[branchIndex]
        guard let latestSequence = recentSamples.last?.sequence, latestSequence > previousSequence else { return }
        runtime.lastProcessedTouchSequence[branchIndex] = latestSequence

        // Every hardware sample is consumed once per active branch. The old
        // fallback replayed the full 0.24-second history on every display tick;
        // with several simultaneous Slides that multiplied projection work and
        // could block the next UIKit touch callback long enough to look frozen.
        let earliestAcceptedTime = runtime.path.startTime - Self.slideMovementMemory
        let freshSamples = recentSamples.filter {
            $0.sequence > previousSequence && $0.time >= earliestAcceptedTime
                && $0.time <= runtime.path.endTime + SimaiTiming.slideWindow + 1e-9
        }
        guard !freshSamples.isEmpty else { return }

        let previousProgress = runtime.visualProgress[branchIndex]
        let branch = runtime.branches[branchIndex]

        // Keep each finger on a continuous section of the route. A global nearest
        // projection can jump from the beginning of a loop to a visually adjacent
        // segment near its end, which makes a tiny circular gesture clear the whole
        // Slide. The forward window below grows with the finger's real travel, so a
        // fast swipe still catches up without allowing a stationary touch to skip.
        var trackedProgress = previousProgress
        var nextRequiredContact = groups[runtime.cursors[branchIndex]...].firstIndex(where: \.requiresContact)
        let firstRequiredContact = nextRequiredContact
        var contactProgress: [Int: Double] = [:]
        var previousPoint: [Int: CGPoint] = [:]
        for sample in recentSamples where sample.sequence <= previousSequence {
            previousPoint[sample.contact.id] = sample.contact.point
        }
        let expandedBounds = branch.bounds.insetBy(
            dx: -Self.slidePathContactTolerance, dy: -Self.slidePathContactTolerance)
        for timedSample in freshSamples {
            let sample = timedSample.contact
            let timedProgress = max(
                0, min(1, (timedSample.time - runtime.path.startTime) / max(runtime.path.duration, 0.001)))
            defer { previousPoint[sample.id] = sample.point }
            guard expandedBounds.contains(sample.point) else { continue }

            let progress = contactProgress[sample.id] ?? previousProgress
            let forwardAllowance: Double
            if let lastPoint = previousPoint[sample.id] {
                let travelled = hypot(sample.point.x - lastPoint.x, sample.point.y - lastPoint.y)
                let travelProgress = Double(travelled / max(branch.length, 0.001))
                forwardAllowance = min(
                    Self.slideMaximumSampleAdvance,
                    max(
                        Self.slideMinimumSampleAdvance,
                        travelProgress * Self.slideTravelMultiplier + Self.slideSampleSlack))
            } else {
                // The first move may arrive after UIKit has already coalesced a
                // sizeable part of the gesture. This also keeps starting slightly
                // inside the guide path forgiving without permitting an end jump.
                forwardAllowance = Self.slideInitialAcquisitionAdvance
            }

            let continuousProjection = branch.nearestProjection(
                to: sample.point, minimumProgress: CGFloat(max(0, progress - Self.slidePathBacktrackAllowance)),
                maximumProgress: CGFloat(min(1, progress + forwardAllowance)))

            var projection = continuousProjection.flatMap { $0.distance <= Self.slidePathContactTolerance ? $0 : nil }

            // Once the guide star is time-driven, a finger can legitimately
            // meet it farther along the path than the last cleared group. Use a
            // small window around the chart-authored star position to reacquire
            // that same section instead of forcing the player back to the head.
            // Keeping this window local also prevents loops/intersections from
            // turning a tiny gesture into an end-of-path jump.
            let timedMinimum = max(
                progress - Self.slidePathBacktrackAllowance, timedProgress - Self.slideTimedReacquisitionBacktrack)
            let timedMaximum = min(
                1, max(progress + forwardAllowance, timedProgress + Self.slideTimedReacquisitionLead))
            if timedMinimum <= timedMaximum,
                let timedProjection = branch.nearestProjection(
                    to: sample.point, minimumProgress: CGFloat(max(0, timedMinimum)),
                    maximumProgress: CGFloat(timedMaximum)), timedProjection.distance <= Self.slidePathContactTolerance,
                projection == nil
                    || timedProjection.distance + Self.slideTimedProjectionPreference < projection!.distance
            {
                projection = timedProjection
            }
            guard let projection else { continue }

            var projectedProgress = max(progress, Double(projection.progress))
            if let requiredIndex = nextRequiredContact {
                let required = groups[requiredIndex]
                // Projection can follow a shortcut even when the finger never
                // reaches C. Inspect the real historical touch so coalesced
                // callbacks still count a center hit between delivered frames.
                if projectedProgress + Self.slidePathProgressAllowance >= required.pathProgress,
                    !required.targets.isDisjoint(with: SimaiInputMapper.targets(at: sample.point))
                {
                    projectedProgress = max(projectedProgress, required.pathProgress)
                    nextRequiredContact = groups[(requiredIndex + 1)...].firstIndex(where: \.requiresContact)
                }
                if let nextRequiredContact {
                    projectedProgress = min(projectedProgress, groups[nextRequiredContact].pathProgress)
                }
            }
            contactProgress[sample.id] = projectedProgress
            trackedProgress = max(trackedProgress, projectedProgress)
            if nextRequiredContact == nil, let last = groups.last,
                trackedProgress + Self.slidePathCompletionAllowance >= last.pathProgress,
                runtime.branchCompletionTimes[branchIndex] == nil
            {
                runtime.branchCompletionTimes[branchIndex] = timedSample.time
            }
        }
        guard trackedProgress > previousProgress || nextRequiredContact != firstRequiredContact else { return }
        runtime.visualProgress[branchIndex] = trackedProgress

        // A moving finger on the path is accepted as continuous evidence for
        // all ordered groups it passed. Began/tap frames never enter this path,
        // so touching only the endpoint cannot complete a Slide.
        while runtime.cursors[branchIndex] < (nextRequiredContact ?? groups.endIndex) {
            let current = groups[runtime.cursors[branchIndex]]
            let allowance =
                runtime.cursors[branchIndex] == groups.count - 1
                ? Self.slidePathCompletionAllowance : Self.slidePathProgressAllowance
            guard current.pathProgress <= trackedProgress + allowance else { break }
            runtime.cursors[branchIndex] += 1
            runtime.armed[branchIndex] = false
        }
    }

    private static let slidePathContactTolerance: CGFloat = 1.50 / 4.8
    private static let slidePathProgressAllowance = 0.12
    private static let slidePathCompletionAllowance = 0.06
    private static let slidePathBacktrackAllowance = 0.14
    private static let slideInitialAcquisitionAdvance = 0.34
    private static let slideMinimumSampleAdvance = 0.012
    private static let slideMaximumSampleAdvance = 0.55
    private static let slideTravelMultiplier = 2.4
    private static let slideSampleSlack = 0.012
    private static let slideTimedReacquisitionBacktrack = 0.24
    private static let slideTimedReacquisitionLead = 0.14
    private static let slideTimedProjectionPreference: CGFloat = 0.02
    private static let slideMovementMemory: TimeInterval = 0.24
    private static let maximumRememberedSlideSamples = 192

    private func apply(_ judgement: SimaiJudgement, to event: SimaiNoteEvent) {
        guard judgements[event.id] == nil else { return }
        judgements[event.id] = judgement
        judgedEventIDs.insert(event.id)
    }

    private func resolveScore(_ slot: SimaiScoreSlot, judgement: SimaiJudgement, offset: TimeInterval) {
        guard resolvedScores[slot] == nil else { return }
        let isTouch = slot.pathIndex == nil && chart.eventByID[slot.eventID]?.location.ring != .lane
        resolvedScores[slot] = SimaiScoreRecord(slot: slot, judgement: judgement, offset: offset, isTouch: isTouch)
        // A late callback must not reorder combo around an unresolved earlier
        // note. Slots are committed in authored score-time/source order.
        while scoreCommitCursor < scoreSlots.count, let record = resolvedScores[scoreSlots[scoreCommitCursor]] {
            scoreCommitCursor += 1
            scoreRecords.append(record)
            earnedScoreWeight += record.judgement.scoreWeight * record.slot.type.weight
            lostScoreWeight += (1 - record.judgement.scoreWeight) * record.slot.type.weight
            if record.slot.type == .breakNote {
                earnedBreakExtras += record.breakExtra
                lostBreakExtras += 1 - record.breakExtra
            }
            dxScore += record.dxPoints
            if record.judgement != .miss && record.judgement != .criticalPerfect {
                if record.offset < -1e-9 { fastCount += 1 }
                if record.offset > 1e-9 { lateCount += 1 }
            }
            if record.judgement == .miss {
                combo = 0
            } else {
                combo += 1
                maxCombo = max(maxCombo, combo)
            }
        }
    }

    private static func holdResolutionTime(_ event: SimaiNoteEvent) -> TimeInterval {
        max(event.headScoreTime, headDeadline(for: event)) + SimaiTiming.inputDeliveryGrace
    }

    private static func headDeadline(for event: SimaiNoteEvent) -> TimeInterval {
        event.time + (event.location.ring == .lane ? SimaiTiming.tapWindow : SimaiTiming.touchLateWindow)
    }

    private func slideKey(eventID: Int, pathIndex: Int) -> String { "\(eventID):\(pathIndex)" }

    private func judgementRank(_ judgement: SimaiJudgement) -> Int {
        switch judgement {
        case .miss: return 0
        case .good: return 1
        case .great: return 2
        case .perfect: return 3
        case .criticalPerfect: return 4
        }
    }
}

private enum SimaiInputMapper {
    private struct Region {
        let target: SimaiInputTarget
        let polygon: [CGPoint]
        let bounds: CGRect

        init(target: SimaiInputTarget, polygon: [CGPoint]) {
            self.target = target
            self.polygon = polygon
            let xs = polygon.map(\.x)
            let ys = polygon.map(\.y)
            bounds = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    // The source implementation exposes this radius as a gameplay setting. A
    // slightly wider mobile default keeps the same judge-area topology while
    // making small-phone finger input less exacting than a point cursor.
    private static let defaultContactRadius: CGFloat = 0.72 / 4.8
    private static let touchPanelOuterRadius: CGFloat = 5.4 / 4.8
    private static let sensorExtensionOuterRadius: CGFloat = 1.20
    private static let maximumRadius: CGFloat = 1.35
    private static let meshToChartRadius: CGFloat = 100 * 0.021432761 / 4.8

    // Coordinates are copied from simai_flutter's Majdata JudgeAreas mesh port.
    private static let aPolygon: [CGPoint] = [
        .init(x: 1.430501, y: 0.410449), .init(x: 1.593672, y: 0.245906), .init(x: 2.463311, y: 0.363903),
        .init(x: 2.433419, y: 0.540234), .init(x: 2.313523, y: 0.923573), .init(x: 2.120256, y: 1.299280),
        .init(x: 2.004719, y: 1.478614), .init(x: 1.300943, y: 0.952039), .init(x: 1.300530, y: 0.727795),
        .init(x: 1.336207, y: 0.641237), .init(x: 1.371884, y: 0.554679), .init(x: 1.401192, y: 0.482564),
    ]
    private static let bPolygon: [CGPoint] = [
        .init(x: 0.633842, y: 0.267105), .init(x: 0.877328, y: 0.021679), .init(x: 0.949844, y: 0.021679),
        .init(x: 1.038919, y: 0.021679), .init(x: 1.300919, y: 0.279573), .init(x: 1.213297, y: 0.490707),
        .init(x: 1.115504, y: 0.725222), .init(x: 1.073558, y: 0.725222), .init(x: 0.756555, y: 0.725222),
        .init(x: 0.633842, y: 0.600329), .init(x: 0.633842, y: 0.490707), .init(x: 0.633842, y: 0.376373),
    ]
    private static let cHalfPolygon: [CGPoint] = [
        .init(x: 0.029968, y: -0.480311), .init(x: 0.200254, y: -0.480311), .init(x: 0.482047, y: -0.199425),
        .init(x: 0.482047, y: 0.200260), .init(x: 0.200254, y: 0.479532), .init(x: 0.029968, y: 0.479532),
    ]
    private static let dPolygon: [CGPoint] = [
        .init(x: 1.635722, y: -0.197556), .init(x: 2.067223, y: -0.263554), .init(x: 2.475411, y: -0.315664),
        .init(x: 2.491906, y: 0.000249), .init(x: 2.471876, y: 0.320876), .init(x: 2.067223, y: 0.262140),
        .init(x: 1.635153, y: 0.199343), .init(x: 1.829966, y: 0.000122),
    ]
    private static let ePolygon: [CGPoint] = [
        .init(x: 1.098899, y: 0), .init(x: 1.433727, y: -0.334828), .init(x: 1.768555, y: 0),
        .init(x: 1.433727, y: 0.334828),
    ]

    private static let sensors: [(SimaiLocation, CGPoint)] = {
        var result: [(SimaiLocation, CGPoint)] = []
        for ring in [SimaiSensorRing.a, .b, .d, .e] {
            for index in 1...8 {
                let location = SimaiLocation(ring: ring, index: index)
                result.append((location, location.normalizedPoint()))
            }
        }
        let center = SimaiLocation(ring: .c, index: 1)
        result.append((center, .zero))
        return result
    }()

    private static let contactRegions: [Region] = {
        var result: [Region] = []
        for (location, _) in sensors {
            for polygon in sensorPolygons(for: location) {
                result.append(Region(target: .sensor(location), polygon: polygon))
            }
        }
        for zeroBased in 0..<8 {
            let lane = zeroBased + 1
            let dCenter = degrees(-90 + CGFloat(zeroBased) * 45)
            result.append(
                Region(
                    target: .sensor(SimaiLocation(ring: .d, index: lane)),
                    polygon: annularSector(
                        innerRadius: touchPanelOuterRadius, outerRadius: sensorExtensionOuterRadius,
                        startAngle: dCenter - degrees(8), sweepAngle: degrees(16))))
            let aCenter = degrees(-67.5 + CGFloat(zeroBased) * 45)
            result.append(
                Region(
                    target: .sensor(SimaiLocation(ring: .a, index: lane)),
                    polygon: annularSector(
                        innerRadius: touchPanelOuterRadius, outerRadius: sensorExtensionOuterRadius,
                        startAngle: aCenter - degrees(14.5), sweepAngle: degrees(29))))
            result.append(
                Region(
                    target: .lane(lane),
                    polygon: annularSector(
                        innerRadius: sensorExtensionOuterRadius, outerRadius: maximumRadius,
                        startAngle: aCenter - degrees(14.5), sweepAngle: degrees(29))))
        }
        return result
    }()

    static func targets(at point: CGPoint) -> Set<SimaiInputTarget> {
        guard hypot(point.x, point.y) <= maximumRadius + defaultContactRadius else { return [] }
        var result: Set<SimaiInputTarget> = []
        for region in contactRegions {
            let bonus: CGFloat
            switch region.target {
            case .sensor(let location):
                switch location.ring {
                case .c: bonus = 0.25 / 4.8
                case .d: bonus = 0.20 / 4.8
                case .e: bonus = 0.10 / 4.8
                default: bonus = 0
                }
            case .lane: bonus = 0
            }
            let radius = defaultContactRadius + bonus
            guard point.x + radius >= region.bounds.minX, point.x - radius <= region.bounds.maxX,
                point.y + radius >= region.bounds.minY, point.y - radius <= region.bounds.maxY,
                circle(center: point, radius: radius, intersects: region.polygon)
            else { continue }
            result.insert(region.target)
        }
        if result.isEmpty, let direct = target(at: point) { result.insert(direct) }
        return result
    }

    private static func target(at point: CGPoint) -> SimaiInputTarget? {
        let radial = hypot(point.x, point.y)
        guard radial <= maximumRadius else { return nil }
        if radial > sensorExtensionOuterRadius {
            let target = outerRingTarget(at: point)
            if case .lane = target { return target }
            return nil
        }
        if radial > touchPanelOuterRadius {
            switch outerRingTarget(at: point) {
            case .lane(let lane): return .sensor(SimaiLocation(ring: .a, index: lane))
            case .sensor(let location): return .sensor(location)
            }
        }
        return sensor(at: point).map(SimaiInputTarget.sensor)
    }

    static func slideGroups(for path: SimaiSlidePath, geometry: SimaiSlideGeometry, mirror: SimaiMirrorMode)
        -> [[SimaiSlideInteractionGroup]]
    {
        let key = SlideGroupCacheKey(segments: path.segments, mirror: mirror)
        slideGroupCacheLock.lock()
        if let cached = slideGroupCache[key] {
            slideGroupCacheLock.unlock()
            return cached
        }
        slideGroupCacheLock.unlock()
        let groups = makeSlideGroups(for: path, geometry: geometry, mirror: mirror)
        slideGroupCacheLock.lock()
        slideGroupCache[key] = groups
        slideGroupCacheLock.unlock()
        return groups
    }

    private struct SlideGroupCacheKey: Hashable {
        let segments: [SimaiSlideSegment]
        let mirror: SimaiMirrorMode
    }
    private static let slideGroupCacheLock = NSLock()
    private static var slideGroupCache: [SlideGroupCacheKey: [[SimaiSlideInteractionGroup]]] = [:]

    private static func makeSlideGroups(for path: SimaiSlidePath, geometry: SimaiSlideGeometry, mirror: SimaiMirrorMode)
        -> [[SimaiSlideInteractionGroup]]
    {
        if path.containsFan, geometry.branches.count >= 3 {
            let start = path.start.index
            return geometry.branches.map { branch in
                let visualEnd =
                    nearestSensor(to: branch.points.last ?? .zero)?.index
                    ?? mirror.map(location: SimaiLocation(ring: .lane, index: wrapped(start + 4))).index
                let logicalEnd = mirror.map(location: SimaiLocation(ring: .lane, index: visualEnd)).index
                return groupsWithPathProgress(fanGroups(start: start, end: logicalEnd, mirror: mirror), along: branch)
            }
        }

        var fixed: [SimaiSlideInteractionGroup] = []
        var canUseFixed = true
        for (segmentIndex, segment) in path.segments.enumerated() {
            guard let segmentGroups = segmentGroups(for: segment, mirror: mirror), !segmentGroups.isEmpty else {
                canUseFixed = false
                break
            }
            let hasExplicitCenterTurn =
                segment.shape == .straight && segment.end.ring == .c && segmentIndex + 1 < path.segments.count
                && path.segments[segmentIndex + 1].shape == .straight
            for (index, group) in segmentGroups.enumerated() {
                if index == 0, fixed.last?.targets == group.targets { continue }
                fixed.append(
                    SimaiSlideInteractionGroup(
                        targets: group.targets, blocksSkip: path.segments.count == 1 && group.blocksSkip,
                        requiresContact: hasExplicitCenterTurn && index == segmentGroups.count - 1))
            }
        }
        if canUseFixed, !fixed.isEmpty {
            guard let branch = geometry.branches.first else { return [fixed] }
            return [groupsWithPathProgress(fixed, along: branch)]
        }

        return geometry.branches.map { branch in groupsWithPathProgress(sampledGroups(along: branch), along: branch) }
    }

    private static func segmentGroups(for segment: SimaiSlideSegment, mirror: SimaiMirrorMode)
        -> [SimaiSlideInteractionGroup]?
    {
        let start = segment.start.index
        let end = segment.end.index
        switch segment.shape {
        case .straight:
            let centerLeg: [(Int, SimaiSensorRing)] = [(0, .a), (0, .b), (0, .c)]
            if segment.start.ring == .lane, segment.end.ring == .c {
                return singleGroups(start: start, direction: 1, specs: centerLeg, mirror: mirror)
            }
            if segment.start.ring == .c, segment.end.ring == .lane {
                return singleGroups(start: end, direction: 1, specs: Array(centerLeg.reversed()), mirror: mirror)
            }
            switch laneDelta(start, end) {
            case 2:
                return [
                    group(start: start, direction: 1, specs: [(0, .a)], mirror: mirror),
                    group(start: start, direction: 1, specs: [(1, .a), (1, .b)], mirror: mirror, blocksSkip: true),
                    group(start: start, direction: 1, specs: [(2, .a)], mirror: mirror),
                ]
            case 3:
                return singleGroups(
                    start: start, direction: 1, specs: [(0, .a), (1, .b), (2, .b), (3, .a)], mirror: mirror)
            case 4:
                return singleGroups(
                    start: start, direction: 1, specs: [(0, .a), (0, .b), (0, .c), (4, .b), (4, .a)], mirror: mirror)
            case 5:
                return singleGroups(
                    start: start, direction: 1, specs: [(0, .a), (-1, .b), (-2, .b), (5, .a)], mirror: mirror)
            case 6:
                return [
                    group(start: start, direction: 1, specs: [(0, .a)], mirror: mirror),
                    group(start: start, direction: 1, specs: [(-1, .a), (-1, .b)], mirror: mirror, blocksSkip: true),
                    group(start: start, direction: 1, specs: [(-2, .a)], mirror: mirror),
                ]
            default: return nil
            }
        case .clockwise, .counterclockwise:
            let direction = segment.shape == .clockwise ? 1 : -1
            var steps = direction > 0 ? laneDelta(start, end) : laneDelta(end, start)
            if steps == 0 { steps = 8 }
            return (0...steps).map { step in
                group(
                    start: start, direction: direction, specs: [(step, .a)], mirror: mirror,
                    blocksSkip: (steps == 1 && step == 0) || (steps == 2 && step == 1))
            }
        case .centerFold:
            let delta = laneDelta(start, end)
            return singleGroups(
                start: start, direction: 1, specs: [(0, .a), (0, .b), (0, .c), (delta, .b), (delta, .a)], mirror: mirror
            )
        case .curveLeft, .curveRight:
            let reflected = segment.shape == .curveRight
            let actualDelta = laneDelta(start, end)
            let direction = reflected ? -1 : 1
            let tableDelta = reflected ? wrappedDelta(-actualDelta) : actualDelta
            let offsets: [Int]
            switch tableDelta {
            case 0: offsets = [-1, -2, -3, -4, 3, 2, 1]
            case 1: offsets = [-1, -2, -3, -4, 3, 2]
            case 2: offsets = [-1, -2, -3, -4, 3]
            case 3: offsets = [-1, -2, -3, -4]
            case 4: offsets = [-1, -2, -3]
            case 5: offsets = [-1, -2, -3, -4, 3, 2, 1, 0, -1, -2]
            case 6: offsets = [-1, -2, -3, -4, 3, 2, 1, 0, -1]
            default: offsets = [-1, -2, -3, -4, 3, 2, 1, 0]
            }
            let specs =
                [(0, SimaiSensorRing.a)] + offsets.map { ($0, SimaiSensorRing.b) } + [(tableDelta, SimaiSensorRing.a)]
            return singleGroups(start: start, direction: direction, specs: specs, mirror: mirror)
        case .edgeCurveLeft, .edgeCurveRight:
            return edgeCurveGroups(start: start, end: end, reflected: segment.shape == .edgeCurveRight, mirror: mirror)
        case .zigzagLeft, .zigzagRight:
            let direction = segment.shape == .zigzagRight ? -1 : 1
            return singleGroups(
                start: start, direction: direction,
                specs: [(0, .a), (-1, .b), (-2, .b), (0, .c), (2, .b), (3, .b), (4, .a)], mirror: mirror)
        case .edgeFold:
            guard let turn = segment.via?.index else { return nil }
            return edgeFoldGroups(start: start, turn: turn, end: end, mirror: mirror)
        case .fan, .arc: return nil
        }
    }

    private static func edgeCurveGroups(start: Int, end: Int, reflected: Bool, mirror: SimaiMirrorMode)
        -> [SimaiSlideInteractionGroup]
    {
        let actualDelta = laneDelta(start, end)
        let direction = reflected ? -1 : 1
        let tableDelta = reflected ? wrappedDelta(-actualDelta) : actualDelta
        let specs: [[(Int, SimaiSensorRing)]]
        switch tableDelta {
        case 0: specs = [[(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)], [(0, .a)]]
        case 1: specs = [[(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)]]
        case 2: specs = [[(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)]]
        case 3, 4:
            specs = [
                [(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)], [(0, .b)], [(0, .c)],
                [(tableDelta, .b)], [(tableDelta, .a)],
            ]
        case 5:
            specs = [
                [(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)], [(0, .b)], [(0, .c), (-1, .b)],
                [(-2, .b), (-3, .b)], [(5, .a)],
            ]
        case 6:
            specs = [
                [(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)], [(0, .b)], [(-1, .b)], [(6, .a)],
            ]
        default:
            specs = [[(0, .a)], [(0, .b)], [(0, .c)], [(3, .b)], [(2, .a)], [(1, .a)], [(0, .b), (0, .a)], [(-1, .a)]]
        }
        return specs.map { group(start: start, direction: direction, specs: $0, mirror: mirror) }
    }

    private static func edgeFoldGroups(start: Int, turn: Int, end: Int, mirror: SimaiMirrorMode)
        -> [SimaiSlideInteractionGroup]?
    {
        let turnDelta = laneDelta(start, turn)
        let actualEndDelta = laneDelta(start, end)
        let reflected = turnDelta == 2
        guard reflected || turnDelta == 6 else { return nil }
        let direction = reflected ? -1 : 1
        let tableEndDelta = reflected ? wrappedDelta(-actualEndDelta) : actualEndDelta
        var result = [
            group(start: start, direction: direction, specs: [(0, .a)], mirror: mirror),
            group(start: start, direction: direction, specs: [(-1, .b), (-1, .a)], mirror: mirror, blocksSkip: true),
            group(start: start, direction: direction, specs: [(-2, .a)], mirror: mirror),
        ]
        let suffix: [[(Int, SimaiSensorRing)]]
        switch tableEndDelta {
        case 1: suffix = [[(-1, .b)], [(0, .b)], [(1, .a)]]
        case 2: suffix = [[(-2, .b)], [(0, .c)], [(2, .b)], [(2, .a)]]
        case 3: suffix = [[(-3, .b)], [(-4, .b)], [(3, .a)]]
        case 4: suffix = [[(-3, .b), (-3, .a)], [(4, .a)]]
        default: return nil
        }
        for (index, spec) in suffix.enumerated() {
            result.append(
                group(
                    start: start, direction: direction, specs: spec, mirror: mirror,
                    blocksSkip: tableEndDelta == 4 && index == 0))
        }
        return result
    }

    private static func fanGroups(start: Int, end: Int, mirror: SimaiMirrorMode) -> [SimaiSlideInteractionGroup] {
        switch laneDelta(start, end) {
        case 3:
            return [
                group(start: start, direction: 1, specs: [(0, .a)], mirror: mirror),
                group(start: start, direction: 1, specs: [(1, .b)], mirror: mirror),
                group(start: start, direction: 1, specs: [(2, .b)], mirror: mirror),
                group(start: start, direction: 1, specs: [(3, .a), (4, .d)], mirror: mirror),
            ]
        case 5:
            return [
                group(start: start, direction: 1, specs: [(0, .a)], mirror: mirror),
                group(start: start, direction: 1, specs: [(-1, .b)], mirror: mirror),
                group(start: start, direction: 1, specs: [(-2, .b)], mirror: mirror),
                group(start: start, direction: 1, specs: [(5, .a), (5, .d)], mirror: mirror),
            ]
        default:
            return [
                group(start: start, direction: 1, specs: [(0, .a)], mirror: mirror),
                group(start: start, direction: 1, specs: [(0, .b)], mirror: mirror),
                group(start: start, direction: 1, specs: [(0, .c)], mirror: mirror),
                group(start: start, direction: 1, specs: [(4, .a), (4, .b)], mirror: mirror),
            ]
        }
    }

    private static func singleGroups(
        start: Int, direction: Int, specs: [(Int, SimaiSensorRing)], mirror: SimaiMirrorMode
    ) -> [SimaiSlideInteractionGroup] {
        specs.map { group(start: start, direction: direction, specs: [$0], mirror: mirror) }
    }

    private static func group(
        start: Int, direction: Int, specs: [(Int, SimaiSensorRing)], mirror: SimaiMirrorMode, blocksSkip: Bool = false
    ) -> SimaiSlideInteractionGroup {
        let targets = specs.map { offset, ring -> SimaiInputTarget in
            let location =
                ring == .c
                ? SimaiLocation(ring: .c, index: 1)
                : SimaiLocation(ring: ring, index: wrapped(start + direction * offset))
            return .sensor(mirror.map(location: location))
        }
        return SimaiSlideInteractionGroup(targets: Set(targets), blocksSkip: blocksSkip)
    }

    private static func sampledGroups(along polyline: SimaiPolyline) -> [SimaiSlideInteractionGroup] {
        guard polyline.length > 0 else { return [] }
        var result: [SimaiSlideInteractionGroup] = []
        let step: CGFloat = 25 / 300
        var distanceAlong: CGFloat = 0
        while distanceAlong <= polyline.length + 0.0001 {
            let point = polyline.sample(distance: min(distanceAlong, polyline.length)).point
            if let location = nearestSensor(to: point) {
                let target = SimaiInputTarget.sensor(location)
                if result.last?.targets != [target] {
                    result.append(SimaiSlideInteractionGroup(targets: [target], blocksSkip: false))
                }
            }
            distanceAlong += step
        }
        return result
    }

    private static func groupsWithPathProgress(_ groups: [SimaiSlideInteractionGroup], along polyline: SimaiPolyline)
        -> [SimaiSlideInteractionGroup]
    {
        guard !groups.isEmpty else { return [] }
        var minimumProgress: CGFloat = 0
        return groups.enumerated().map { index, group in
            var best: (progress: CGFloat, distance: CGFloat)?
            for target in group.targets {
                let point: CGPoint
                switch target {
                case .lane(let lane): point = SimaiLocation(ring: .lane, index: lane).normalizedPoint()
                case .sensor(let location): point = location.normalizedPoint()
                }
                guard let candidate = polyline.nearestProjection(to: point, minimumProgress: minimumProgress) else {
                    continue
                }
                if best == nil || candidate.distance < best!.distance { best = candidate }
            }
            var progress = best?.progress ?? CGFloat(index) / CGFloat(max(groups.count - 1, 1))
            if index == 0 { progress = 0 }
            if index == groups.count - 1 { progress = 1 }
            progress = max(minimumProgress, min(progress, 1))
            minimumProgress = progress
            return SimaiSlideInteractionGroup(
                targets: group.targets, blocksSkip: group.blocksSkip, pathProgress: Double(progress),
                requiresContact: group.requiresContact)
        }
    }

    private static func laneDelta(_ start: Int, _ end: Int) -> Int { wrappedDelta(end - start) }
    private static func wrappedDelta(_ value: Int) -> Int { ((value % 8) + 8) % 8 }
    private static func wrapped(_ value: Int) -> Int { wrappedDelta(value - 1) + 1 }

    private static func nearestSensor(to point: CGPoint) -> SimaiLocation? {
        sensors.min(by: { distance(point, $0.1) < distance(point, $1.1) })?.0
    }

    private static func sensor(at point: CGPoint) -> SimaiLocation? {
        let raw = CGPoint(x: point.x / meshToChartRadius, y: point.y / meshToChartRadius)
        let cMirror = cHalfPolygon.map { CGPoint(x: -$0.x, y: -$0.y) }
        let minCY = cHalfPolygon.map(\.y).min() ?? 0
        let maxCY = cHalfPolygon.map(\.y).max() ?? 0
        if contains(cHalfPolygon, point: raw) || contains(cMirror, point: raw)
            || (abs(raw.x) <= cHalfPolygon[0].x && raw.y >= minCY && raw.y <= maxCY)
        {
            return SimaiLocation(ring: .c, index: 1)
        }

        let aIndex = nearestIndex(angle: atan2(point.y, point.x), firstAngleDegrees: -67.5)
        let abRaw = rotate(raw, radians: degrees(90 - CGFloat(aIndex) * 45))
        if contains(aPolygon, point: abRaw) { return SimaiLocation(ring: .a, index: aIndex + 1) }
        if contains(bPolygon, point: abRaw) { return SimaiLocation(ring: .b, index: aIndex + 1) }

        let dIndex = nearestIndex(angle: atan2(point.y, point.x), firstAngleDegrees: -90)
        let deRaw = rotate(raw, radians: degrees(90 - CGFloat(dIndex) * 45))
        if contains(dPolygon, point: deRaw) { return SimaiLocation(ring: .d, index: dIndex + 1) }
        if contains(ePolygon, point: deRaw) { return SimaiLocation(ring: .e, index: dIndex + 1) }
        return nil
    }

    private static func sensorPolygons(for location: SimaiLocation) -> [[CGPoint]] {
        func transform(_ source: [CGPoint], rotation: CGFloat) -> [CGPoint] {
            source.map {
                let point = rotate($0, radians: rotation)
                return CGPoint(x: point.x * meshToChartRadius, y: point.y * meshToChartRadius)
            }
        }
        let zeroBased = CGFloat(location.index - 1)
        switch location.ring {
        case .a: return [transform(aPolygon, rotation: degrees(zeroBased * 45 - 90))]
        case .b: return [transform(bPolygon, rotation: degrees(zeroBased * 45 - 90))]
        case .c:
            let mirrored = cHalfPolygon.map { CGPoint(x: -$0.x, y: -$0.y) }
            let minY = cHalfPolygon.map(\.y).min() ?? 0
            let maxY = cHalfPolygon.map(\.y).max() ?? 0
            let bridge = [
                CGPoint(x: -cHalfPolygon[0].x, y: minY), CGPoint(x: cHalfPolygon[0].x, y: minY),
                CGPoint(x: cHalfPolygon[0].x, y: maxY), CGPoint(x: -cHalfPolygon[0].x, y: maxY),
            ]
            return [
                transform(cHalfPolygon, rotation: 0), transform(mirrored, rotation: 0), transform(bridge, rotation: 0),
            ]
        case .d: return [transform(dPolygon, rotation: degrees(zeroBased * 45 - 90))]
        case .e: return [transform(ePolygon, rotation: degrees(zeroBased * 45 - 90))]
        case .lane: return []
        }
    }

    private static func outerRingTarget(at point: CGPoint) -> SimaiInputTarget {
        let angle = atan2(point.y, point.x)
        let dIndex = nearestIndex(angle: angle, firstAngleDegrees: -90)
        let dCenter = degrees(-90 + CGFloat(dIndex) * 45)
        if angularDistance(angle, dCenter) <= degrees(8) + 1e-12 {
            return .sensor(SimaiLocation(ring: .d, index: dIndex + 1))
        }
        return .lane(nearestIndex(angle: angle, firstAngleDegrees: -67.5) + 1)
    }

    private static func nearestLane(at point: CGPoint) -> Int {
        let angle = atan2(point.y, point.x)
        let raw = Int(round((angle + .pi * 3 / 8) / (.pi / 4)))
        return ((raw % 8) + 8) % 8 + 1
    }

    private static func nearestIndex(angle: CGFloat, firstAngleDegrees: CGFloat) -> Int {
        let raw = Int(round((angle - degrees(firstAngleDegrees)) / (.pi / 4)))
        return ((raw % 8) + 8) % 8
    }

    private static func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let tau = CGFloat.pi * 2
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: tau)
        return min(difference, tau - difference)
    }

    private static func annularSector(
        innerRadius: CGFloat, outerRadius: CGFloat, startAngle: CGFloat, sweepAngle: CGFloat
    ) -> [CGPoint] {
        let count = 12
        var result: [CGPoint] = []
        for step in 0...count {
            let angle = startAngle + sweepAngle * CGFloat(step) / CGFloat(count)
            result.append(CGPoint(x: outerRadius * cos(angle), y: outerRadius * sin(angle)))
        }
        for step in stride(from: count, through: 0, by: -1) {
            let angle = startAngle + sweepAngle * CGFloat(step) / CGFloat(count)
            result.append(CGPoint(x: innerRadius * cos(angle), y: innerRadius * sin(angle)))
        }
        return result
    }

    private static func circle(center: CGPoint, radius: CGFloat, intersects polygon: [CGPoint]) -> Bool {
        if contains(polygon, point: center) { return true }
        let squaredRadius = radius * radius
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            if squaredDistance(center, start) <= squaredRadius + 1e-12
                || squaredDistanceToSegment(center, start, end) <= squaredRadius + 1e-12
            {
                return true
            }
        }
        return false
    }

    private static func squaredDistanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let edge = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = edge.x * edge.x + edge.y * edge.y
        guard lengthSquared > 1e-12 else { return squaredDistance(point, start) }
        let relative = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let projection = max(0, min(1, (relative.x * edge.x + relative.y * edge.y) / lengthSquared))
        let closest = CGPoint(x: start.x + edge.x * projection, y: start.y + edge.y * projection)
        return squaredDistance(point, closest)
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func contains(_ polygon: [CGPoint], point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let lhs = polygon[current]
            let rhs = polygon[previous]
            if isOnSegment(point, rhs, lhs) { return true }
            let crosses =
                (lhs.y > point.y) != (rhs.y > point.y)
                && point.x < (rhs.x - lhs.x) * (point.y - lhs.y) / (rhs.y - lhs.y) + lhs.x
            if crosses { inside.toggle() }
            previous = current
        }
        return inside
    }

    private static func isOnSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> Bool {
        let edgeX = end.x - start.x
        let edgeY = end.y - start.y
        let pointX = point.x - start.x
        let pointY = point.y - start.y
        let cross = edgeX * pointY - edgeY * pointX
        guard abs(cross) <= 1e-9 else { return false }
        let dot = pointX * edgeX + pointY * edgeY
        guard dot >= -1e-9 else { return false }
        return dot <= edgeX * edgeX + edgeY * edgeY + 1e-9
    }

    private static func rotate(_ point: CGPoint, radians: CGFloat) -> CGPoint {
        CGPoint(x: point.x * cos(radians) - point.y * sin(radians), y: point.x * sin(radians) + point.y * cos(radians))
    }

    private static func degrees(_ value: CGFloat) -> CGFloat { value * .pi / 180 }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
}

public final class SimaiHitSoundEngine {
    public static let shared = SimaiHitSoundEngine()

    private enum Cue: Hashable {
        case hit
        case answer
        case perfect
        case great
        case good
        case miss
    }

    private let engine = AVAudioEngine()
    private let playbackQueue = DispatchQueue(label: "org.simai.swift.hit-sound", qos: .userInteractive)
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    // One immutable gain-adjusted buffer per cue. A voice always stays at unity
    // gain: changing AVAudioPlayerNode.volume when scheduling a short transient
    // can ramp from the voice's previous gain (including its first-use 1.0).
    private var scaledBuffers: [Cue: (volume: Float, buffer: AVAudioPCMBuffer)] = [:]
    private var cursor = 0

    public init(answerData: Data? = nil) {
        // AVAudioEngine player output buses require a renderable graph format.
        // An interleaved Int16 file format is valid for storage, but some iOS
        // audio units reject it when it is assigned directly to a player node.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return }

        buffers[.hit] = Self.makeSynthesizedBuffer(cue: .hit, format: format)
        buffers[.perfect] = Self.makeSynthesizedBuffer(cue: .perfect, format: format)
        buffers[.great] = Self.makeSynthesizedBuffer(cue: .great, format: format)
        buffers[.good] = Self.makeSynthesizedBuffer(cue: .good, format: format)
        buffers[.miss] = Self.makeSynthesizedBuffer(cue: .miss, format: format)
        if let data = answerData,
            let answer = Self.makePCMBuffer(from: data, trimmingLeadingSilence: true, outputFormat: format)
        {
            buffers[.answer] = answer
        }

        if buffers[.answer] == nil { buffers[.answer] = Self.makeSynthesizedBuffer(cue: .hit, format: format) }
        guard !buffers.isEmpty else { return }
        for _ in 0..<32 {
            let player = AVAudioPlayerNode()
            player.volume = 1
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        engine.prepare()
    }

    public func prepare(hitVolume: Double = 0.2, answerVolume: Double = 0.2, judgementVolume: Double = 0.2) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            for (cue, gain) in [
                (Cue.hit, hitVolume), (.answer, answerVolume), (.perfect, judgementVolume), (.great, judgementVolume),
                (.good, judgementVolume), (.miss, judgementVolume),
            ] {
                guard gain.isFinite, gain > 0.001 else { continue }
                _ = self.scaledBuffer(for: cue, volume: Float(min(gain, 1)))
            }
            self.startIfNeeded()
        }
    }

    public func playHit(volume: Double) { play(.hit, volume: volume) }

    public func playAnswer(volume: Double) { play(.answer, volume: volume) }

    public func playJudgement(_ judgement: SimaiJudgement, volume: Double) {
        let cue: Cue
        switch judgement {
        case .criticalPerfect, .perfect: cue = .perfect
        case .great: cue = .great
        case .good: cue = .good
        case .miss: cue = .miss
        }
        play(cue, volume: volume)
    }

    private func play(_ cue: Cue, volume: Double) {
        guard volume.isFinite else { return }
        let normalizedVolume = Float(max(0, min(volume, 1)))
        guard normalizedVolume > 0.001 else { return }
        playbackQueue.async { [weak self] in self?.playPreparedSound(cue, volume: normalizedVolume) }
    }

    private func startIfNeeded() {
        guard !buffers.isEmpty, !engine.isRunning else { return }
        try? engine.start()
    }

    private func playPreparedSound(_ cue: Cue, volume: Float) {
        guard let buffer = scaledBuffer(for: cue, volume: volume), !players.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        let player = players[cursor % players.count]
        cursor += 1
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func scaledBuffer(for cue: Cue, volume: Float) -> AVAudioPCMBuffer? {
        guard let source = buffers[cue] else { return nil }
        if volume == 1 { return source }
        if let cached = scaledBuffers[cue], cached.volume == volume { return cached.buffer }
        guard let input = source.floatChannelData,
            let scaled = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength),
            let output = scaled.floatChannelData
        else { return nil }
        scaled.frameLength = source.frameLength
        for channel in 0..<Int(source.format.channelCount) {
            for frame in 0..<Int(source.frameLength) { output[channel][frame] = input[channel][frame] * volume }
        }
        // Scheduling retains each buffer. Replacing this small cache after a
        // settings change cannot alter the gain of an already playing sound.
        scaledBuffers[cue] = (volume, scaled)
        return scaled
    }

    private static func makePCMBuffer(from data: Data, trimmingLeadingSilence: Bool, outputFormat: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        let bytes = [UInt8](data)
        guard bytes.count >= 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
            String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE"
        else { return nil }

        func uint16(at offset: Int) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }

        func uint32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        var formatOffset: Int?
        var audioDataOffset: Int?
        var audioDataSize = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let identifier = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(uint32(at: offset + 4))
            let payloadOffset = offset + 8
            guard chunkSize >= 0, payloadOffset + chunkSize <= bytes.count else { return nil }
            if identifier == "fmt " {
                formatOffset = payloadOffset
            } else if identifier == "data" {
                audioDataOffset = payloadOffset
                audioDataSize = chunkSize
            }
            offset = payloadOffset + chunkSize + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard let formatOffset, let audioDataOffset, formatOffset + 16 <= bytes.count, uint16(at: formatOffset) == 1
        else { return nil }

        let channelCount = AVAudioChannelCount(uint16(at: formatOffset + 2))
        let sampleRate = Double(uint32(at: formatOffset + 4))
        let bitsPerSample = Int(uint16(at: formatOffset + 14))
        guard channelCount > 0, sampleRate > 0, bitsPerSample == 16, outputFormat.commonFormat == .pcmFormatFloat32,
            !outputFormat.isInterleaved, outputFormat.channelCount == channelCount,
            abs(outputFormat.sampleRate - sampleRate) < 0.5
        else { return nil }

        let bytesPerFrame = Int(channelCount) * bitsPerSample / 8
        let frameCount = audioDataSize / max(bytesPerFrame, 1)
        guard frameCount > 0, frameCount <= Int(AVAudioFrameCount.max) else { return nil }

        var firstFrame = 0
        if trimmingLeadingSilence {
            let threshold = 192
            search: for frame in 0..<frameCount {
                for channel in 0..<Int(channelCount) {
                    let sampleOffset = audioDataOffset + frame * bytesPerFrame + channel * 2
                    let sample = Int(Int16(bitPattern: uint16(at: sampleOffset)))
                    if abs(sample) >= threshold {
                        firstFrame = max(frame - Int(sampleRate * 0.002), 0)
                        break search
                    }
                }
            }
        }

        let trimmedFrameCount = frameCount - firstFrame
        guard trimmedFrameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(trimmedFrameCount))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(trimmedFrameCount)
        guard let destinations = buffer.floatChannelData else { return nil }
        for frame in 0..<trimmedFrameCount {
            let sourceFrame = firstFrame + frame
            for channel in 0..<Int(channelCount) {
                let sampleOffset = audioDataOffset + sourceFrame * bytesPerFrame + channel * 2
                let sample = Int16(bitPattern: uint16(at: sampleOffset))
                destinations[channel][frame] = Float(sample) / 32_768
            }
        }
        return buffer
    }

    private static func makeSynthesizedBuffer(cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration: TimeInterval
        switch cue {
        case .hit: duration = 0.032
        case .perfect: duration = 0.115
        case .great: duration = 0.100
        case .good: duration = 0.090
        case .miss: duration = 0.105
        case .answer: return nil
        }

        let frameCount = max(Int(format.sampleRate * duration), 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let samples = buffer.floatChannelData?[0] else { return nil }

        var noiseState: UInt32 = 0xA17E_2026
        for frame in 0..<frameCount {
            let time = Double(frame) / format.sampleRate
            let progress = Double(frame) / Double(max(frameCount - 1, 1))
            let attack = min(time / 0.0015, 1)
            let release = pow(max(0, 1 - progress), cue == .hit ? 3.8 : 2.2)
            let envelope = attack * release
            let value: Double

            switch cue {
            case .hit:
                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(noiseState) / Double(UInt32.max)) * 2 - 1
                let frequency = 2_850 - 1_150 * progress
                value = (sin(2 * .pi * frequency * time) * 0.30 + noise * 0.18) * envelope
            case .perfect:
                let root = 880 + 360 * progress
                value =
                    (sin(2 * .pi * root * time) * 0.28 + sin(2 * .pi * root * 1.5 * time) * 0.18 + sin(
                        2 * .pi * root * 2 * time) * 0.11) * envelope
            case .great:
                let root = 700 + 180 * progress
                value = (sin(2 * .pi * root * time) * 0.30 + sin(2 * .pi * root * 1.5 * time) * 0.14) * envelope
            case .good:
                let root = 520 - 80 * progress
                value = (sin(2 * .pi * root * time) * 0.28 + sin(2 * .pi * root * 0.75 * time) * 0.12) * envelope
            case .miss:
                let root = 190 - 55 * progress
                value = (sin(2 * .pi * root * time) * 0.24 + sin(2 * .pi * root * 0.5 * time) * 0.10) * envelope
            case .answer: value = 0
            }

            let clamped = max(-1, min(value, 1))
            samples[frame] = Float(clamped)
        }
        return buffer
    }
}
