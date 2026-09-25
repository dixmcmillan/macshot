import Foundation
import CoreGraphics

/// A timeline region that overlays screenshot-style annotations (arrows,
/// shapes, lines, numbers, text, …) on the video. The drawing is made with
/// the screenshot editor over a paused frame; this segment stores it and the
/// time range it is visible for.
///
/// `startTime`/`endTime` are seconds on the source-asset clock, like every
/// other segment. The annotations are stored in `canvasSize` points with the
/// AppKit bottom-left origin the editor draws in; `canvasSize` has the aspect
/// ratio of the upright source video, so a canvas point maps to the content
/// with `contentRect(forCanvas:)`. Drawings follow the content through crop
/// and zoom, exactly like text boxes.
final class VideoAnnotationSegment: Codable {

    /// How each annotation enters or leaves. `draw` traces strokes on (lines,
    /// arrows, freehand, shape outlines); tools with nothing to trace pop.
    /// Exits play the same motion in reverse.
    enum Animation: String, Codable, CaseIterable {
        case none, fade, pop, draw, slide, wipe
    }

    static let minDuration: Double = 0.3
    static let defaultDuration: Double = 3.0
    static let defaultFade: Double = 0.2
    /// Entrance length for new drawings; a draw-on needs longer than a fade.
    static let defaultEntranceDuration: Double = 0.5
    static let defaultStagger: Double = 0.25
    static let maxStagger: Double = 2

    var id: UUID
    var startTime: Double
    var endTime: Double
    /// Size of the editor canvas the annotations were drawn on, in points.
    var canvasSize: CGSize
    /// `AnnotationSerializer`-encoded `[Annotation]` in canvas points.
    var annotationData: Data
    /// Entrance and exit lengths in seconds (per annotation), whatever the
    /// animation. The names predate the animation presets.
    var fadeIn: Double
    var fadeOut: Double
    var entrance: Animation
    var exit: Animation
    /// Delay between consecutive annotations' entrances, in drawing order,
    /// so "1… 2… 3…" build up one at a time. Exits stay together.
    var stagger: Double

    init(id: UUID = UUID(), startTime: Double, endTime: Double, canvasSize: CGSize,
         annotationData: Data, fadeIn: Double = defaultFade, fadeOut: Double = defaultFade,
         entrance: Animation = .fade, exit: Animation = .fade, stagger: Double = 0) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.canvasSize = canvasSize
        self.annotationData = annotationData
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.entrance = entrance
        self.exit = exit
        self.stagger = Self.clampedStagger(stagger)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, canvasSize, annotationData, fadeIn, fadeOut, entrance, exit, stagger
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        startTime = c.decode(.startTime, or: 0)
        endTime = c.decode(.endTime, or: 0)
        let size = c.decode(.canvasSize, or: CGSize.zero)
        canvasSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            ? size : CGSize(width: 1920, height: 1080)
        annotationData = c.decode(.annotationData, or: Data())
        fadeIn = c.decode(.fadeIn, or: Self.defaultFade)
        fadeOut = c.decode(.fadeOut, or: Self.defaultFade)
        // Drawings saved before the presets existed keep their plain fades.
        entrance = c.decode(.entrance, or: .fade)
        exit = c.decode(.exit, or: .fade)
        stagger = Self.clampedStagger(c.decode(.stagger, or: 0))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(canvasSize, forKey: .canvasSize)
        try c.encode(annotationData, forKey: .annotationData)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(entrance, forKey: .entrance)
        try c.encode(exit, forKey: .exit)
        try c.encode(stagger, forKey: .stagger)
    }

    static func clampedStagger(_ s: Double) -> Double { s.isFinite ? min(maxStagger, max(0, s)) : 0 }

    var duration: Double { max(0, endTime - startTime) }

    /// Decoded drawing. Fresh instances on every call; callers own them.
    var annotations: [Annotation] { AnnotationSerializer.decode(annotationData) ?? [] }

    func opacity(at t: Double) -> CGFloat {
        VideoEffectTiming.opacity(at: t, start: startTime, end: endTime, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Source time at which every annotation has finished entering. A
    /// freeze placed here holds the video while the whole drawing is shown.
    var holdTime: Double {
        let count = max(1, annotations.count)
        let entering = entrance == .none ? 0 : VideoEffectTiming.effectiveFade(fadeIn, duration: duration)
        return min(endTime, startTime + stagger * Double(count - 1) + entering)
    }

    /// Canvas rect (points, bottom-left origin) → normalized content rect
    /// (top-left origin), the space `VideoSceneLayout` works in.
    func contentRect(forCanvas r: CGRect) -> CGRect {
        let w = max(canvasSize.width, 1), h = max(canvasSize.height, 1)
        return CGRect(x: r.minX / w, y: 1 - r.maxY / h, width: r.width / w, height: r.height / h)
    }

    /// Editor canvas for a source of `contentSize` pixels: Retina-sized
    /// recordings get point-sized canvases so default stroke widths and
    /// font sizes look the same as on a screenshot of the same screen.
    static func canvasSize(forContent contentSize: CGSize) -> CGSize {
        let scale: CGFloat = contentSize.height > 1440 ? 2 : 1
        return CGSize(width: max(1, (contentSize.width / scale).rounded()),
                      height: max(1, (contentSize.height / scale).rounded()))
    }

    /// Short timeline label, e.g. "Arrow" or "Arrow +2".
    var summary: String {
        let list = annotations
        guard let first = list.first else { return L("Annotation") }
        let raw = String(describing: first.tool)
        let name = raw.prefix(1).uppercased() + raw.dropFirst()
        return list.count > 1 ? "\(name) +\(list.count - 1)" : name
    }
}
