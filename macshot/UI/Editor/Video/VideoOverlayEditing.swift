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
