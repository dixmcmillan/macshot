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
