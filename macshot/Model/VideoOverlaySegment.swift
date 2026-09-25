import Foundation
import CoreGraphics

/// A media file composited over the video: an animated graphic with an alpha
/// channel (ProRes 4444 or HEVC-with-alpha `.mov`) or a still image (PNG).
/// Typical use is a motion graphic exported from Premiere/After Effects/Motion.
///
/// Placement follows the content like text boxes: `rect` is normalized to
/// the upright source (origin top-left) and moves through crop and zoom.
///
/// Timing is anchored to the content but plays in real time: the overlay
/// appears when the timeline reaches source time `startTime`, then plays for
/// `duration` seconds of *output* time, so it keeps animating over a freeze
/// frame and isn't sped up by a speed segment. An overlay whose start falls
/// inside a cut is not shown.
final class VideoOverlaySegment: Codable {

    enum Kind: String, Codable {
        case video, image
    }

    static let minDuration: Double = 0.2
    static let defaultImageDuration: Double = 3.0
    static let defaultFade: Double = 0

    var id: UUID
    var kind: Kind
    /// File name inside the project directory (the import copies it there).
    var fileName: String
    /// Name of the file the user picked, for display.
    var displayName: String
    /// Source-clock time at which the overlay appears.
    var startTime: Double
    /// Output-clock seconds the overlay stays on screen.
    var duration: Double
    /// Seconds skipped at the head of a video overlay (trimmed in-point).
    var mediaStart: Double
    /// Length of the media file (0 for images).
    var mediaDuration: Double
    /// Upright pixel size of the media, for aspect-correct resizing.
    var mediaSize: CGSize
    var rect: CGRect
    var opacity: Double
    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(), kind: Kind, fileName: String, displayName: String, startTime: Double,
         duration: Double, mediaStart: Double = 0, mediaDuration: Double, mediaSize: CGSize,
         rect: CGRect, opacity: Double = 1, fadeIn: Double = defaultFade, fadeOut: Double = defaultFade) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.displayName = displayName
        self.startTime = startTime
        self.duration = duration
        self.mediaStart = mediaStart
        self.mediaDuration = mediaDuration
        self.mediaSize = mediaSize
        self.rect = rect
        self.opacity = opacity
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, fileName, displayName, startTime, duration, mediaStart, mediaDuration, mediaSize
        case rect, opacity, fadeIn, fadeOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        kind = c.decode(.kind, or: .video)
        fileName = c.decode(.fileName, or: "")
        displayName = c.decode(.displayName, or: fileName)
        startTime = c.decode(.startTime, or: 0)
        let media = c.decode(.mediaDuration, or: 0.0)
        mediaDuration = media.isFinite ? max(0, media) : 0
        let head = c.decode(.mediaStart, or: 0.0)
        mediaStart = head.isFinite ? max(0, head) : 0
        let length = c.decode(.duration, or: Self.defaultImageDuration)
        duration = length.isFinite ? max(Self.minDuration, length) : Self.defaultImageDuration
        let size = c.decode(.mediaSize, or: CGSize(width: 1, height: 1))
        mediaSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            ? size : CGSize(width: 1, height: 1)
        rect = VideoProjectLimits.normalizedRect(c.decode(.rect, or: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))
        let alpha = c.decode(.opacity, or: 1.0)
        opacity = alpha.isFinite ? min(1, max(0, alpha)) : 1
        fadeIn = c.decode(.fadeIn, or: Self.defaultFade)
        fadeOut = c.decode(.fadeOut, or: Self.defaultFade)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(duration, forKey: .duration)
        try c.encode(mediaStart, forKey: .mediaStart)
        try c.encode(mediaDuration, forKey: .mediaDuration)
        try c.encode(mediaSize, forKey: .mediaSize)
        try c.encode(rect, forKey: .rect)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
    }

    /// Longest the overlay can play without running out of media. Images
    /// have no limit.
    var maxDuration: Double {
        kind == .image ? .greatestFiniteMagnitude : max(Self.minDuration, mediaDuration - mediaStart)
    }

    /// Opacity at `local` seconds after the overlay appeared.
    func opacity(atLocal local: Double) -> CGFloat {
        CGFloat(opacity) * VideoEffectTiming.opacity(at: local, start: 0, end: duration, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Content-normalized rect of height `height` centered on the frame,
    /// with the media's aspect ratio in a source of `contentSize` pixels.
    static func defaultRect(mediaSize: CGSize, contentSize: CGSize, height: CGFloat = 0.3) -> CGRect {
        let aspect = mediaSize.width / max(mediaSize.height, 1)
        let contentAspect = contentSize.width / max(contentSize.height, 1)
        var h = height
        var w = h * aspect / max(contentAspect, 0.0001)
        if w > 0.9 { h *= 0.9 / w; w = 0.9 }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}
