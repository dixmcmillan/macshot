import Foundation
import CoreGraphics

/// The animatable spatial state of a drawing or overlay: a translation in
/// content-normalized units (top-left origin), a uniform scale and a rotation
/// (radians, clockwise on screen) about the item's own pivot, and an opacity
/// multiplier.
nonisolated struct VideoTransformValue: Equatable, Sendable {
    var offset: CGPoint = .zero
    var scale: Double = 1
    var rotation: Double = 0
    var opacity: Double = 1

    static let identity = VideoTransformValue()
}

/// One keyframe. `time` is seconds from the start of the segment it belongs
/// to, on that segment's own clock (source clock for drawings, output clock
/// for overlays). `easing` shapes the motion from this keyframe to the next.
nonisolated struct VideoKeyframe: Codable, Equatable, Sendable {

    enum Easing: String, Codable, CaseIterable, Sendable {
        case linear, easeIn, easeOut, easeInOut, hold
    }

    var id: UUID
    var time: Double
    var value: VideoTransformValue
    var easing: Easing

    init(id: UUID = UUID(), time: Double, value: VideoTransformValue, easing: Easing = .easeInOut) {
        self.id = id
        self.time = time
        self.value = value
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, offset, scale, rotation, opacity, easing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        let t = c.decode(.time, or: 0.0)
        time = t.isFinite ? max(0, t) : 0
        let offset = c.decode(.offset, or: CGPoint.zero)
        let scale = c.decode(.scale, or: 1.0), rotation = c.decode(.rotation, or: 0.0), opacity = c.decode(.opacity, or: 1.0)
        value = VideoTransformValue(
            offset: offset.x.isFinite && offset.y.isFinite ? offset : .zero,
            scale: scale.isFinite ? min(VideoKeyframes.maxScale, max(VideoKeyframes.minScale, scale)) : 1,
            rotation: rotation.isFinite ? rotation : 0,
            opacity: opacity.isFinite ? min(1, max(0, opacity)) : 1)
        easing = c.decode(.easing, or: .easeInOut)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        try c.encode(value.offset, forKey: .offset)
        try c.encode(value.scale, forKey: .scale)
        try c.encode(value.rotation, forKey: .rotation)
        try c.encode(value.opacity, forKey: .opacity)
        try c.encode(easing, forKey: .easing)
    }
}

/// Pure keyframe sampling, shared by the renderer (off the main actor), the
/// stage and the inspector so every view of the timeline agrees.
nonisolated enum VideoKeyframes {
    static let minScale: Double = 0.1
    static let maxScale: Double = 10
    /// Keyframes closer than this (seconds) are the same keyframe.
    static let timeTolerance: Double = 1.0 / 120

    /// Value at segment-local `time`. Before the first keyframe the first
    /// value holds; after the last, the last holds. `keyframes` need not be
    /// sorted. Nil when there are none (the item is not animated).
    static func sample(_ keyframes: [VideoKeyframe], at time: Double) -> VideoTransformValue? {
        guard !keyframes.isEmpty else { return nil }
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard time.isFinite, time > sorted[0].time else { return sorted[0].value }
        guard let nextIndex = sorted.firstIndex(where: { $0.time > time }) else { return sorted[sorted.count - 1].value }
        let a = sorted[nextIndex - 1], b = sorted[nextIndex]
        let span = b.time - a.time
        guard span > 0 else { return b.value }
        let p = ease(a.easing, (time - a.time) / span)
        return interpolate(a.value, b.value, p)
    }

    static func ease(_ easing: VideoKeyframe.Easing, _ x: Double) -> Double {
        let t = min(1, max(0, x))
        switch easing {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .hold: return 0
        }
    }

    static func interpolate(_ a: VideoTransformValue, _ b: VideoTransformValue, _ p: Double) -> VideoTransformValue {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
        return VideoTransformValue(
            offset: CGPoint(x: mix(a.offset.x, b.offset.x), y: mix(a.offset.y, b.offset.y)),
            // Scale interpolates geometrically so zooming 1→4 passes 2 at the midpoint.
            scale: exp(mix(log(max(a.scale, minScale)), log(max(b.scale, minScale)))),
            rotation: mix(a.rotation, b.rotation),
            opacity: mix(a.opacity, b.opacity))
    }

    /// Sets the keyframe at `time` (within `timeTolerance`) to `value`, or
    /// inserts one. Returns the keyframes sorted by time.
    static func setting(_ value: VideoTransformValue, at time: Double, in keyframes: [VideoKeyframe]) -> [VideoKeyframe] {
        var result = keyframes
        if let i = result.firstIndex(where: { abs($0.time - time) <= timeTolerance }) {
            result[i].value = value
        } else {
            let easing = result.last(where: { $0.time < time })?.easing ?? .easeInOut
            result.append(VideoKeyframe(time: max(0, time), value: value, easing: easing))
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Keyframes decoded from a segment, dropping any past `duration`.
    static func clamped(_ keyframes: [VideoKeyframe], duration: Double) -> [VideoKeyframe] {
        keyframes.filter { $0.time <= duration + timeTolerance }.sorted { $0.time < $1.time }
    }
}
