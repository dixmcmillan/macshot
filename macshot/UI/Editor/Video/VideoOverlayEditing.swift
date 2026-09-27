import CoreGraphics
import CoreMedia
import ImageIO

/// Pure geometry and timing math for overlay clips, factored out of
/// `VideoTimelineView` (edge-drag trim) and `VideoStageView` (aspect-locked
/// resize) so it can be exercised without AppKit. No AppKit, no
/// `VideoEditorDocument` — everything here is plain values in, plain values
/// out.
enum VideoOverlayEditing {

    // MARK: Timeline trim

    /// Right-edge drag: only `duration` (the output-time span) changes;
    /// `startTime` and `mediaStart` are untouched. Clamped between the
    /// model minimum and however much media is left to play.
    static func resizedDuration(proposedEnd: Double, startTime: Double, minDuration: Double, maxDuration: Double) -> Double {
        guard proposedEnd.isFinite, startTime.isFinite else { return minDuration }
        let raw = proposedEnd - startTime
        let cappedMax = max(minDuration, maxDuration)
        return min(cappedMax, max(minDuration, raw))
    }

    struct HeadTrim: Equatable {
        var startTime: Double
        var mediaStart: Double
        var duration: Double
    }

    /// Left-edge drag. A video overlay trims the media's head: `startTime`
    /// and `mediaStart` move together (`mediaStart` clamped to `>= 0`), and
    /// `duration` shrinks or grows by the same amount so the overlay's end
    /// stays anchored where it was. An image has no media in-point, so only
    /// `startTime` moves and `duration` is recomputed to keep the end
    /// anchored instead.
    static func trimHead(kind: VideoOverlaySegment.Kind, proposedStart: Double, originalStart: Double,
                          originalMediaStart: Double, originalDuration: Double, minDuration: Double) -> HeadTrim {
        let end = originalStart + originalDuration
        guard proposedStart.isFinite else {
            return HeadTrim(startTime: originalStart, mediaStart: originalMediaStart, duration: originalDuration)
        }
        switch kind {
        case .image:
            let start = max(0, min(proposedStart, end - minDuration))
            return HeadTrim(startTime: start, mediaStart: 0, duration: end - start)
        case .video:
            var delta = proposedStart - originalStart
            // Can't trim the head past its own duration, and can't reveal
            // media before the file starts.
            delta = max(delta, -originalMediaStart)
            delta = min(delta, originalDuration - minDuration)
            let mediaStart = max(0, originalMediaStart + delta)
            let startTime = originalStart + delta
            return HeadTrim(startTime: startTime, mediaStart: mediaStart, duration: end - startTime)
        }
    }

    // MARK: Inspector size slider

    /// Scales `rect` about its own center — the aspect ratio (already baked
    /// into `rect`'s width/height) is preserved automatically.
    static func scaledRect(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        guard factor.isFinite, factor > 0 else { return rect }
        let w = rect.width * factor, h = rect.height * factor
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Animated-overlay placement

    /// `rect` after applying an animated transform's offset/scale "relative
    /// to" it — see `VideoOverlaySegment.keyframes`'s doc comment: the offset
    /// shifts the box (content-normalized, top-left origin, the same
    /// convention as `rect`'s own origin), the scale grows/shrinks it about
    /// its own center. Rotation isn't part of a rect; callers apply
    /// `VideoTransformValue.rotation` separately (it replaces `rotation`,
    /// it doesn't compose with it).
    static func transformedRect(_ rect: CGRect, offset: CGPoint, scale: Double) -> CGRect {
        let cx = rect.midX + offset.x, cy = rect.midY + offset.y
        let w = rect.width * CGFloat(scale), h = rect.height * CGFloat(scale)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The offset that places `rect`'s center at `newCenter` (content
    /// space) — the inverse of `transformedRect`'s translation, used when a
    /// drag on an animated overlay's displayed (already-offset) box needs to
    /// be written back as a keyframe offset relative to the unmoved `rect`.
    static func moveOffset(newCenter: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(x: newCenter.x - rect.midX, y: newCenter.y - rect.midY)
    }

    // MARK: Aspect-locked stage resize

    /// The canvas-normalized width/height ratio that reproduces `mediaSize`'s
    /// pixel aspect ratio when drawn on a canvas of `canvasSize` pixels.
    /// (A rect that is `fw` of the canvas width and `fh` of its height has
    /// pixel size `fw*canvasW` by `fh*canvasH`; solving for `fw/fh` to match
    /// `mediaSize.width/mediaSize.height` gives this.)
    static func normalizedAspect(mediaSize: CGSize, canvasSize: CGSize) -> CGFloat {
        guard mediaSize.width > 0, mediaSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return (mediaSize.width * canvasSize.height) / (mediaSize.height * canvasSize.width)
    }

    /// Grows `freeCorner` away from the fixed `anchor` corner so the
    /// resulting box has the given normalized `aspect` (width/height),
    /// picking whichever raw delta implies the larger box — the same feel as
    /// the existing square (aspect = 1) zoom-window resize it generalizes.
    static func aspectLockedCorner(anchor: CGPoint, freeCorner: CGPoint, aspect: CGFloat) -> CGPoint {
        guard aspect.isFinite, aspect > 0 else { return freeCorner }
        let rawW = abs(freeCorner.x - anchor.x)
        let rawH = abs(freeCorner.y - anchor.y)
        let w = max(rawW, rawH * aspect)
        let h = w / aspect
        let signX: CGFloat = freeCorner.x >= anchor.x ? 1 : -1
        let signY: CGFloat = freeCorner.y >= anchor.y ? 1 : -1
        return CGPoint(x: anchor.x + signX * w, y: anchor.y + signY * h)
    }

    // MARK: Alpha detection

    /// An ImageIO properties dictionary (`CGImageSourceCopyPropertiesAtIndex`)
    /// says whether the image has an alpha channel without decoding pixels.
    static func hasAlpha(imageProperties: [CFString: Any]) -> Bool {
        (imageProperties[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    /// ProRes 4444/4444 XQ structurally carry an alpha channel; anything else
    /// (notably HEVC) declares it with the `ContainsAlphaChannel` extension.
    static func hasAlpha(formatDescriptions: [CMFormatDescription]) -> Bool {
        for format in formatDescriptions {
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            if subtype == kCMVideoCodecType_AppleProRes4444 || subtype == kCMVideoCodecType_AppleProRes4444XQ { return true }
            if let flag = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool {
                return flag
            }
        }
        return false
    }
}

// MARK: - Keyframe editing (auto-keying, navigator, trim-shift)

/// Pure helpers for auto-keying transform edits and for navigating/trimming
/// keyframes, shared by the stage, inspector and timeline so "animated" —
/// `keyframes` non-empty — means the same thing everywhere, and so a partial
/// edit (e.g. a move) never clobbers scale/rotation/opacity keyframed
/// elsewhere. No AppKit, no `VideoEditorDocument`.
enum VideoKeyframeEditing {

    /// A segment is "animated" exactly when it has keyframes.
    static func isAnimated(_ keyframes: [VideoKeyframe]) -> Bool { !keyframes.isEmpty }

    /// A drawing's segment-local time (source clock): `sourceTime -
    /// startTime`, clamped to `[0, duration]` — matches
    /// `VideoAnnotationSegment.transform(at:)`'s own clamping via `sample`.
    static func drawingLocalTime(sourceTime: Double, startTime: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, sourceTime.isFinite else { return 0 }
        return min(duration, max(0, sourceTime - startTime))
    }

    /// An overlay's segment-local time: OUTPUT/composition seconds since it
    /// appeared — composition time of the playhead minus composition time of
    /// `overlayStartTime` — via the playback's own source↔composition
    /// mapping (injected so this stays pure and testable), clamped to
    /// `[0, duration]`. See `VideoOverlaySegment`'s doc comment.
    static func overlayLocalTime(sourceTime: Double, overlayStartTime: Double, duration: Double,
                                 compositionTime: (Double) -> Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let local = compositionTime(sourceTime) - compositionTime(overlayStartTime)
        guard local.isFinite else { return 0 }
        return min(duration, max(0, local))
    }

    /// The source time that lands exactly on an overlay's local `time` — the
    /// inverse of `overlayLocalTime`, used to seek the playhead to a
    /// keyframe (previous/next navigation, clicking a timeline diamond).
    static func overlaySourceTime(forLocal time: Double, overlayStartTime: Double,
                                  compositionTime: (Double) -> Double, sourceTime: (Double) -> Double) -> Double {
        sourceTime(compositionTime(overlayStartTime) + time)
    }

    /// Where a keyframe diamond sits on the timeline: the pill's own layout
    /// already mixes source `start` and (for overlays) output `duration`
    /// directly (`end = start + duration`), so a keyframe's position uses
    /// the same mixing for consistency with the pill and its trim handles,
    /// rather than the precise composition-clock mapping the stage uses.
    static func timelinePosition(itemStart: Double, keyframeTime: Double) -> Double { itemStart + keyframeTime }

    /// The inverse of `timelinePosition`, for dragging a diamond.
    static func keyframeTime(forTimelinePosition x: Double, itemStart: Double) -> Double { x - itemStart }

    /// Folds `edit` into the value already in effect at `localTime` (so a
    /// partial edit like "move" doesn't clobber scale/rotation/opacity
    /// keyframed elsewhere), and writes the result as the keyframe at that
    /// time — the shared "auto-key" behavior every transform edit uses once
    /// a segment is animated.
    static func autoKeyed(_ keyframes: [VideoKeyframe], at localTime: Double,
                          applying edit: (inout VideoTransformValue) -> Void) -> [VideoKeyframe] {
        var value = VideoKeyframes.sample(keyframes, at: localTime) ?? .identity
        edit(&value)
        return VideoKeyframes.setting(value, at: localTime, in: keyframes)
    }

    // MARK: Navigator

    static func previousKeyframeTime(before time: Double, in keyframes: [VideoKeyframe]) -> Double? {
        keyframes.map(\.time).filter { $0 < time - VideoKeyframes.timeTolerance }.max()
    }

    static func nextKeyframeTime(after time: Double, in keyframes: [VideoKeyframe]) -> Double? {
        keyframes.map(\.time).filter { $0 > time + VideoKeyframes.timeTolerance }.min()
    }

    /// Whether a keyframe already sits at `time`, within tolerance.
    static func hasKeyframe(at time: Double, in keyframes: [VideoKeyframe]) -> Bool {
        keyframes.contains { abs($0.time - time) <= VideoKeyframes.timeTolerance }
    }

    /// The ◆ navigator button: removes the keyframe at `time` if one exists
    /// — unless it's the only one, since a lone keyframe can only be cleared
    /// by turning Animate off (with its confirmation) — else adds one with
    /// the value already showing there.
    static func togglingKeyframe(at time: Double, in keyframes: [VideoKeyframe]) -> [VideoKeyframe] {
        if let i = keyframes.firstIndex(where: { abs($0.time - time) <= VideoKeyframes.timeTolerance }) {
            guard keyframes.count > 1 else { return keyframes }
            var result = keyframes
            result.remove(at: i)
            return result
        }
        let value = VideoKeyframes.sample(keyframes, at: time) ?? .identity
        return VideoKeyframes.setting(value, at: time, in: keyframes)
    }

    /// Moves the keyframe with `id` to `time` (dragging its diamond).
    static func movingKeyframe(id: UUID, to time: Double, in keyframes: [VideoKeyframe]) -> [VideoKeyframe] {
        var result = keyframes
        guard let i = result.firstIndex(where: { $0.id == id }) else { return result }
        result[i].time = max(0, time)
        return result.sorted { $0.time < $1.time }
    }

    static func deletingKeyframe(id: UUID, in keyframes: [VideoKeyframe]) -> [VideoKeyframe] {
        keyframes.filter { $0.id != id }
    }

    /// The keyframe governing easing "at or before" `time` — the Easing
    /// popup's selection, and `settingEasing`'s target.
    static func keyframeAtOrBefore(_ time: Double, in keyframes: [VideoKeyframe]) -> VideoKeyframe? {
        let candidates = keyframes.filter { $0.time <= time + VideoKeyframes.timeTolerance }
        if let last = candidates.max(by: { $0.time < $1.time }) { return last }
        return keyframes.min { $0.time < $1.time }
    }

    static func settingEasing(_ easing: VideoKeyframe.Easing, forKeyframeAtOrBefore time: Double,
                              in keyframes: [VideoKeyframe]) -> [VideoKeyframe] {
        guard let target = keyframeAtOrBefore(time, in: keyframes) else { return keyframes }
        var result = keyframes
        if let i = result.firstIndex(where: { $0.id == target.id }) { result[i].easing = easing }
        return result
    }

    // MARK: Trim shift

    /// Trimming a segment's start edge by `delta` seconds (positive = the
    /// segment now starts `delta` later) keeps every keyframe at the same
    /// *absolute* moment: subtract `delta` from each local time, and drop
    /// any that now fall before the new start.
    static func shiftedForStartTrim(_ keyframes: [VideoKeyframe], delta: Double) -> [VideoKeyframe] {
        guard delta != 0 else { return keyframes }
        return keyframes.compactMap { kf in
            let t = kf.time - delta
            guard t >= -VideoKeyframes.timeTolerance else { return nil }
            var shifted = kf
            shifted.time = max(0, t)
            return shifted
        }
    }

    /// Trimming a segment's end edge drops keyframes past the new duration.
    static func trimmedForEndTrim(_ keyframes: [VideoKeyframe], newDuration: Double) -> [VideoKeyframe] {
        keyframes.filter { $0.time <= newDuration + VideoKeyframes.timeTolerance }
    }
}

// MARK: - Rotated-box stage editing (annotation transform + overlay rotation)

/// Pure geometry for direct-manipulating a rotated, uniformly-scaled box on
/// the stage: hit-testing, handle placement, and the drag math for the
/// corner (scale) and rotation handles. Shared by `VideoStageOverlay`'s
/// annotation-transform and overlay-rotation handling, and kept separate
/// from AppKit so it's exercised directly with XCTest.
///
/// `rotation` throughout is radians, **clockwise as seen on screen** — a
/// plain `CGAffineTransform(rotationAngle:)`/`rotate(_:around:by:)` in the
/// stage's own top-left, y-down view space already reads this way (see the
/// derivation in `rotate(_:around:by:)`). The renderer negates the same
/// value before applying it in Core Image's bottom-left, y-up space — see
/// `VideoSceneRenderer.placeAnnotationLayer`.
enum RotatedBoxEditing {
    static func center(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Rotates `point` about `center` by `radians`, clockwise as seen on
    /// screen in a top-left/y-down space: a point due "north" of `center`
    /// (smaller y) moves towards "east" (larger x) as `radians` increases
    /// from 0, matching how a rotation handle above a box is dragged.
    static func rotate(_ point: CGPoint, around center: CGPoint, by radians: CGFloat) -> CGPoint {
        guard radians != 0 else { return point }
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(radians), s = sin(radians)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    /// The four corners of `rect` (already centered on the box's pivot),
    /// rotated about that center. Order: top-left, top-right, bottom-right,
    /// bottom-left (view space, y-down).
    static func corners(of rect: CGRect, rotation: CGFloat) -> [CGPoint] {
        let c = center(of: rect)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { rotate($0, around: c, by: rotation) }
    }

    /// True if `point` falls inside `rect` once rotated by `radians` about
    /// its own center: rotate `point` the opposite way around that same
    /// center and test against the plain, unrotated rect.
    static func contains(_ point: CGPoint, in rect: CGRect, rotation: CGFloat) -> Bool {
        rect.contains(rotate(point, around: center(of: rect), by: -rotation))
    }

    /// Where the rotation handle sits: `distance` above the box's rotated
    /// top edge, i.e. offset "north" in the box's own rotated frame.
    static func rotationHandlePosition(for rect: CGRect, rotation: CGFloat, distance: CGFloat) -> CGPoint {
        rotate(CGPoint(x: rect.midX, y: rect.minY - distance), around: center(of: rect), by: rotation)
    }

    /// Nearest 15° step — Shift-snapped rotation drags.
    static func snapped15(_ radians: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 12
        return (radians / step).rounded() * step
    }

    /// New rotation while dragging the rotation handle from the box's
    /// `center` towards `point`. The handle's rest position (straight above
    /// center) is angle 0; a "compass bearing from north, clockwise" formula
    /// (`atan2(east, north)` with `north` flipped for the y-down space)
    /// gives exactly the clockwise-positive convention this type documents,
    /// and is the exact inverse of `rotationHandlePosition`.
    static func rotation(fromCenter center: CGPoint, to point: CGPoint, snap: Bool) -> CGFloat {
        let east = point.x - center.x, north = -(point.y - center.y)
        let angle = atan2(east, north)
        return snap ? snapped15(angle) : angle
    }

    /// New uniform scale for a corner drag: how much farther `draggedPoint`
    /// is from `pivot` than `originalCorner` was, as a plain distance ratio
    /// (rotation doesn't change distance from the pivot, so it never enters
    /// this calculation — dragging any corner of a rotated box scales it
    /// uniformly about the pivot, same as an unrotated one).
    static func cornerDragScale(pivot: CGPoint, originalCorner: CGPoint, draggedPoint: CGPoint,
                                range: ClosedRange<Double>) -> Double {
        let originalDistance = hypot(originalCorner.x - pivot.x, originalCorner.y - pivot.y)
        guard originalDistance > 0.0001 else { return range.lowerBound }
        let draggedDistance = hypot(draggedPoint.x - pivot.x, draggedPoint.y - pivot.y)
        let ratio = Double(draggedDistance / originalDistance)
        guard ratio.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, ratio))
    }

    /// Arrow-key nudge vector in view-space points for a raw `keyCode`
    /// (macOS arrow codes: 123 left, 124 right, 125 down, 126 up — not to be
    /// confused with USB HID or other platforms' codes); `nil` for anything
    /// else. Per CLAUDE.md, arrows are compared by raw `keyCode`, not by
    /// character, since they're layout-independent.
    static func nudge(forArrowKeyCode keyCode: UInt16, amount: CGFloat) -> CGPoint? {
        switch keyCode {
        case 123: return CGPoint(x: -amount, y: 0)
        case 124: return CGPoint(x: amount, y: 0)
        case 125: return CGPoint(x: 0, y: amount)
        case 126: return CGPoint(x: 0, y: -amount)
        default: return nil
        }
    }
}
