import Foundation

// MARK: - Last-used animation memory
//
// Mirrors `VideoTextSegment`'s "last-used style" memory (see
// `VideoTextSegment.swift`): only the reusable animation preferences are
// persisted, not the drawing, timing or canvas of whichever segment last
// changed them, so a freshly pause-and-annotated drawing starts with
// whatever entrance/exit/stagger the user settled on last time.

extension VideoAnnotationSegment {
    private static let lastStyleKey = "videoAnnotationLastUsedStyle"
    private static var cachedStyle: RememberedStyle?
    private static var pendingStyleWrite: Task<Void, Never>?

    private struct RememberedStyle: Codable {
        let entrance: Animation
        let exit: Animation
        let fadeIn: Double
        let fadeOut: Double
        let stagger: Double

        init(_ segment: VideoAnnotationSegment) {
            entrance = segment.entrance
            exit = segment.exit
            fadeIn = segment.fadeIn
            fadeOut = segment.fadeOut
            stagger = segment.stagger
        }
    }

    /// Entrance/exit animation, their durations and the stagger to use for a
    /// newly pause-and-annotated drawing: whatever the user set last time, or
    /// the shipped preset (draw / fade / 0.5s / 0.2s / default stagger) the
    /// first time.
    static func lastUsedAnimationDefaults()
        -> (entrance: Animation, exit: Animation, fadeIn: Double, fadeOut: Double, stagger: Double) {
        let fallback: RememberedStyle? = nil
        let style: RememberedStyle?
        if let cachedStyle {
            style = cachedStyle
        } else if let data = UserDefaults.standard.data(forKey: lastStyleKey),
                  let saved = try? JSONDecoder().decode(RememberedStyle.self, from: data) {
            cachedStyle = saved
            style = saved
        } else {
            style = fallback
        }
        guard let style else {
            return (.draw, .fade, defaultEntranceDuration, defaultFade, defaultStagger)
        }
        return (style.entrance, style.exit, style.fadeIn, style.fadeOut, Self.clampedStagger(style.stagger))
    }

    /// Persist this segment's entrance/exit animation, durations and stagger
    /// as the default for the next new drawing.
    func rememberAnimationStyle() {
        let style = RememberedStyle(self)
        Self.cachedStyle = style
        Self.pendingStyleWrite?.cancel()
        // Sliders emit many continuous changes. Keep the latest style in
        // memory immediately so the next drawing inherits it, but coalesce
        // preference encoding/writes until the interaction settles.
        Self.pendingStyleWrite = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let data = try? JSONEncoder().encode(style) else { return }
            UserDefaults.standard.set(data, forKey: Self.lastStyleKey)
        }
    }
}

// MARK: - Keeping a "hold" freeze attached to holdTime

extension VideoAnnotationSegment {
    /// Moves the freeze sitting at `oldHoldTime` (within `tolerance`, e.g.
    /// half a frame) to `newHoldTime`, in place. Shared by every place a
    /// drawing's `holdTime` can move — its entrance, entrance duration,
    /// stagger or start changing (inspector edits, timeline drag/resize),
    /// or its annotation count changing (Edit Drawing) — so "hold video
    /// while shown" stays attached instead of being left behind. A no-op
    /// when nothing moved or no freeze sits at the old time.
    static func relocateHoldFreeze(in freezes: [VideoFreezeSegment], from oldHoldTime: Double, to newHoldTime: Double,
                                   tolerance: Double) {
        guard abs(oldHoldTime - newHoldTime) > tolerance,
              let freeze = freezes.first(where: { abs($0.atTime - oldHoldTime) <= tolerance }) else { return }
        freeze.atTime = newHoldTime
    }
}
