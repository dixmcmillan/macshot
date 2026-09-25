import CoreGraphics

/// Pure per-frame motion for an animated `VideoAnnotationSegment` layer:
/// given a source time and the segment/layer timing, computes opacity, pop
/// scale, slide offset and (for `draw`/`wipe`) how much of the layer's
/// reveal mask to show. No AppKit/CoreImage/main-actor dependency — sampled
/// identically for scrubbing, playback and export, like `CameraPathBuilder`.
///
/// A layer is "shown" 0…1 by two independent curves that never let it be
/// more visible than either allows: the entrance (rising from 0, delayed by
/// `layerIndex * stagger`) and the exit (falling to 0 in the segment's last
/// `fadeOut` seconds, together, unstaggered). Whichever curve is currently
/// the limiting one supplies the animation preset used to render that
/// shownness — this is how "the same motion in reverse" falls out of one
/// set of formulas instead of a separate un-draw/un-pop implementation.
nonisolated enum VideoAnnotationMotion {

    struct State: Sendable, Equatable {
        /// 0 = don't draw this layer at all this frame.
        var opacity: CGFloat = 1
        /// Uniform scale about the layer's own center. 1 = no pop.
        var scale: CGFloat = 1
        /// Fraction of canvas height to offset downward (slide entrance
        /// rises from below; the caller multiplies by the actual canvas
        /// height and adds it to the layer's placed Y). 0 = no slide.
        var slideOffset: CGFloat = 0
        /// 0…1 how much of the `draw` reveal mask (polyline prefix or pie
        /// sweep) to show. `nil` when no mask needs building this frame —
        /// either the layer isn't using `draw`, or it's fully revealed/fully
        /// hidden and the mask would be a no-op.
        var revealProgress: CGFloat?
        /// Same idea as `revealProgress` for the cheap left→right `wipe`.
        var wipeProgress: CGFloat?
    }

    /// - Parameters:
    ///   - t: Source-asset seconds.
    ///   - layerIndex: Position among the segment's per-annotation layers in
    ///     drawing order (0-based). The base pixelate/blur/highlight layer
    ///     always passes 0 and a `stagger` of 0 — it isn't staggered.
    static func state(t: Double, segmentStart: Double, segmentEnd: Double,
                       layerIndex: Int, stagger: Double,
                       entrance: VideoAnnotationSegment.Animation, exit: VideoAnnotationSegment.Animation,
                       fadeIn: Double, fadeOut: Double) -> State {
        guard t.isFinite, segmentEnd > segmentStart, t >= segmentStart, t <= segmentEnd else {
            return State(opacity: 0, scale: 1, slideOffset: 0, revealProgress: nil, wipeProgress: nil)
        }
        let duration = segmentEnd - segmentStart
        let entranceStart = segmentStart + Double(max(0, layerIndex)) * stagger
        let entranceDuration = VideoEffectTiming.effectiveFade(fadeIn, duration: duration)
        let exitDuration = VideoEffectTiming.effectiveFade(fadeOut, duration: duration)
        let exitStart = segmentEnd - exitDuration

        // Shownness 0→1 as the entrance plays. `.none` has no entrance
        // animation at all — it's simply always shown, ignoring both the
        // fade duration and the stagger delay (there's nothing to stagger).
        let pEnter: CGFloat
        if entrance == .none {
            pEnter = 1
        } else if entranceDuration <= 0 {
            pEnter = t >= entranceStart ? 1 : 0
        } else if t < entranceStart {
            pEnter = 0
        } else {
            pEnter = CGFloat(min(1, (t - entranceStart) / entranceDuration))
        }

        // Shownness 1→0 as the exit plays, together for every layer. `.none`
        // stays fully shown through the segment's last valid frame.
        let pExit: CGFloat
        if exit == .none {
            pExit = 1
        } else if exitDuration <= 0 {
            pExit = t < segmentEnd ? 1 : 0
        } else if t <= exitStart {
            pExit = 1
        } else {
            pExit = CGFloat(max(0, 1 - (t - exitStart) / exitDuration))
        }

        // Whichever curve is more hidden right now owns the visual — this is
        // also how a short segment where entrance hasn't finished before the
        // exit starts degrades sensibly instead of fighting itself.
        let shown = min(pEnter, pExit)
        let animation = pEnter <= pExit ? entrance : exit
        return visualState(animation: animation, shownness: shown)
    }

    /// The shared curve set. `shownness` is 0 (hidden) … 1 (fully shown);
    /// entrance calls this rising, exit calls it falling — same formulas.
    private static func visualState(animation: VideoAnnotationSegment.Animation, shownness: CGFloat) -> State {
        let s = max(0, min(1, shownness))
        switch animation {
        case .none:
            return State(opacity: s > 0 ? 1 : 0)

        case .fade:
            return State(opacity: smoothstep(s))

        case .pop:
            if s <= 0 { return State(opacity: 0, scale: 0.5) }
            if s >= 1 { return State(opacity: 1, scale: 1) }
            // Opacity ramps in quickly; scale overshoots past 1 then settles
            // — an easeOutBack feel built from two cheap eased halves so the
            // overshoot amount (~1.08) is explicit rather than tuned via a
            // back-easing constant.
            let opacity = min(1, s / 0.4)
            let scale: CGFloat
            if s < 0.7 {
                scale = 0.5 + (1.08 - 0.5) * easeOutCubic(s / 0.7)
            } else {
                scale = 1.08 + (1.0 - 1.08) * smoothstep((s - 0.7) / 0.3)
            }
            return State(opacity: opacity, scale: scale)

        case .draw:
            if s <= 0 { return State(opacity: 0) }
            if s >= 1 { return State(opacity: 1) }
            return State(opacity: 1, revealProgress: easeInOutCubic(s))

        case .slide:
            if s <= 0 { return State(opacity: 0, slideOffset: slideDistance) }
            if s >= 1 { return State(opacity: 1, slideOffset: 0) }
            return State(opacity: smoothstep(s), slideOffset: slideDistance * (1 - easeOutCubic(s)))

        case .wipe:
            if s <= 0 { return State(opacity: 0) }
            if s >= 1 { return State(opacity: 1) }
            return State(opacity: 1, wipeProgress: easeInOutCubic(s))
        }
    }

    /// Slide entrance travel distance, as a fraction of canvas height.
    private static let slideDistance: CGFloat = 0.05

    // MARK: - Easing

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    private static func easeOutCubic(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return 1 - pow(1 - c, 3)
    }

    private static func easeInOutCubic(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }

    // MARK: - Geometry

    /// The leading prefix of `points` covering `fraction` (0…1) of its total
    /// arc length, ending with an interpolated point exactly at the cut —
    /// the shape a `draw` reveal mask strokes. Pure geometry, no CoreGraphics
    /// context needed, so it's cheap to unit test directly.
    static func prefixPolyline(_ points: [CGPoint], fraction: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let f = max(0, min(1, fraction))
        if f <= 0 { return [points[0]] }
        if f >= 1 { return points }
        var cumulative: [CGFloat] = [0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = cumulative.last ?? 0
        guard total > 0 else { return points }
        let target = total * f
        var result: [CGPoint] = [points[0]]
        for i in 1..<points.count {
            if cumulative[i] < target {
                result.append(points[i])
                continue
            }
            let segStart = cumulative[i - 1]
            let segLen = cumulative[i] - segStart
            let t = segLen > 0 ? (target - segStart) / segLen : 0
            let p0 = points[i - 1], p1 = points[i]
            result.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
            break
        }
        return result
    }
}

/// Builds the per-frame reveal mask for a `draw`/`wipe` animation: an 8-bit
/// RGBA bitmap, transparent outside the revealed region and opaque white
/// inside it, sized to the layer's own pixel extent. `CIBlendWithAlphaMask`
/// only reads the alpha channel, so the RGB values don't matter.
///
/// Plain CoreGraphics, no CoreImage — callers wrap the result in a `CIImage`.
/// Only called while a reveal is actually in progress; `VideoAnnotationMotion.State`
/// already returns `nil` progress outside `(0, 1)` so a fully-hidden or
/// fully-shown frame skips this (and its CGContext allocation) entirely.
nonisolated enum VideoAnnotationRevealMask {
    /// `reveal`'s points/center must already be in the layer's own pixel
    /// space (bottom-left origin, matching the layer image's `CIImage`
    /// extent) — see `EffectsCompositionInstruction.AnnotationLayerSnapshot`.
    static func build(reveal: EffectsCompositionInstruction.AnnotationLayerSnapshot.Reveal,
                      progress: CGFloat, pixelSize: CGSize) -> CGImage? {
        guard let ctx = makeContext(pixelSize) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        switch reveal {
        case let .path(points, width):
            strokePrefix(points, width: width, progress: progress, in: ctx)
        case let .sweep(center, rotation):
            fillWedge(center: center, rotation: rotation, progress: progress,
                     pixelSize: pixelSize, in: ctx)
        }
        return ctx.makeImage()
    }

    /// Cheap left→right reveal, independent of any tool-specific geometry.
    static func buildWipe(progress: CGFloat, pixelSize: CGSize) -> CGImage? {
        guard let ctx = makeContext(pixelSize) else { return nil }
        let w = CGFloat(pixelSize.width) * max(0, min(1, progress))
        guard w > 0 else { return ctx.makeImage() }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: pixelSize.height))
        return ctx.makeImage()
    }

    private static func makeContext(_ size: CGSize) -> CGContext? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.clear(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    private static func strokePrefix(_ points: [CGPoint], width: CGFloat, progress: CGFloat, in ctx: CGContext) {
        let prefix = VideoAnnotationMotion.prefixPolyline(points, fraction: progress)
        guard let first = prefix.first else { return }
        if prefix.count < 2 {
            // Nothing traced yet but the tool has a starting point — show a
            // round dot so the stroke appears to originate there rather than
            // popping in a full segment once progress crosses the first hop.
            let r = width / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: width, height: width))
            return
        }
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: first)
        for p in prefix.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    private static func fillWedge(center: CGPoint, rotation: CGFloat, progress: CGFloat,
                                  pixelSize: CGSize, in ctx: CGContext) {
        let radius = hypot(pixelSize.width, pixelSize.height) + 2
        // Unrotated "12 o'clock" is +Y (angle π/2); `rotation` is the
        // annotation's own counterclockwise rotation (same convention as
        // `NSAffineTransform.rotate(byRadians:)` in `Annotation.draw`), so
        // the wedge's start angle rotates the same way.
        let start = CGFloat.pi / 2 + rotation
        let end = start - 2 * .pi * max(0, min(1, progress))
        ctx.beginPath()
        ctx.move(to: center)
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.closePath()
        ctx.fillPath()
    }
}
