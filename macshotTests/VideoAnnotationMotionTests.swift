import CoreGraphics
import XCTest

/// Pure motion-math tests for animated annotation layers — no rendering, no
/// main actor, just `VideoAnnotationMotion`'s formulas.
final class VideoAnnotationMotionTests: XCTestCase {

    private func state(t: Double, start: Double = 0, end: Double = 4, layerIndex: Int = 0, stagger: Double = 0,
                       entrance: VideoAnnotationSegment.Animation = .fade, exit: VideoAnnotationSegment.Animation = .fade,
                       fadeIn: Double = 1, fadeOut: Double = 1) -> VideoAnnotationMotion.State {
        VideoAnnotationMotion.state(t: t, segmentStart: start, segmentEnd: end, layerIndex: layerIndex, stagger: stagger,
                                    entrance: entrance, exit: exit, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Old projects decode to entrance/exit `.fade` with the pre-existing
    /// `fadeIn`/`fadeOut` fields — a single, unstaggered layer must render
    /// identically to the pre-animation `VideoEffectTiming.opacity` curve.
    func testFadeParityWithOldProjects() {
        for t in stride(from: 0.0, through: 4.0, by: 0.25) {
            let expected = VideoEffectTiming.opacity(at: t, start: 0, end: 4, fadeIn: 1, fadeOut: 1)
            let got = state(t: t, fadeIn: 1, fadeOut: 1).opacity
            XCTAssertEqual(got, expected, accuracy: 1e-9, "t=\(t)")
        }
        // Scale/offset/reveal must stay at their no-op defaults for fade.
        let mid = state(t: 2, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(mid.scale, 1)
        XCTAssertEqual(mid.slideOffset, 0)
        XCTAssertNil(mid.revealProgress)
        XCTAssertNil(mid.wipeProgress)
    }

    func testNoneAnimationIsInstantlyFullyShown() {
        let atStart = state(t: 0, entrance: .none, exit: .none, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(atStart.opacity, 1)
        let atEnd = state(t: 4, entrance: .none, exit: .none, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(atEnd.opacity, 1)
        let outside = state(t: 10, entrance: .none, exit: .none)
        XCTAssertEqual(outside.opacity, 0, "outside the segment's time range is always hidden")
    }

    /// Layer 1's entrance starts `stagger` seconds after layer 0's — at a
    /// time inside layer 0's fade but before layer 1's window even opens,
    /// layer 1 must be fully hidden while layer 0 is already animating in.
    func testStaggerDelaysLaterLayersEntrance() {
        let first = state(t: 0.5, layerIndex: 0, stagger: 1, entrance: .fade, fadeIn: 1)
        let second = state(t: 0.5, layerIndex: 1, stagger: 1, entrance: .fade, fadeIn: 1)
        XCTAssertGreaterThan(first.opacity, 0)
        XCTAssertEqual(second.opacity, 0)
        // Once layer 1's own staggered window is running, it behaves exactly
        // like layer 0 did at the equivalent offset into its own window.
        let secondRunning = state(t: 1.5, layerIndex: 1, stagger: 1, entrance: .fade, fadeIn: 1)
        XCTAssertEqual(secondRunning.opacity, first.opacity, accuracy: 1e-9)
    }

    /// The exit plays the same curve in reverse: sampling `fadeOut` before
    /// the end at the same relative offset as sampling `fadeIn` after the
    /// start produces the identical visual state, for every preset with a
    /// scale/offset/reveal component.
    func testExitReversesEntrance() {
        for animation: VideoAnnotationSegment.Animation in [.fade, .pop, .draw, .slide, .wipe] {
            let entering = state(t: 0.2, start: 0, end: 10, entrance: animation, exit: animation, fadeIn: 1, fadeOut: 1)
            let exiting = state(t: 9.8, start: 0, end: 10, entrance: animation, exit: animation, fadeIn: 1, fadeOut: 1)
            let label = "\(animation)"
            XCTAssertEqual(entering.opacity, exiting.opacity, accuracy: 1e-6, label)
            XCTAssertEqual(entering.scale, exiting.scale, accuracy: 1e-6, label)
            XCTAssertEqual(entering.slideOffset, exiting.slideOffset, accuracy: 1e-6, label)
            XCTAssertEqual(entering.revealProgress ?? -1, exiting.revealProgress ?? -1, accuracy: 1e-6, label)
            XCTAssertEqual(entering.wipeProgress ?? -1, exiting.wipeProgress ?? -1, accuracy: 1e-6, label)
        }
    }

    /// `pop` ramps opacity in quickly, overshoots scale past 1, then settles
    /// — a frame partway through entrance is smaller than the fully-entered
    /// annotation.
    func testPopEntranceScalesUpWithOvershoot() {
        let early = state(t: 0.2, entrance: .pop, fadeIn: 1)
        let full = state(t: 1, entrance: .pop, fadeIn: 1)
        XCTAssertLessThan(early.scale, full.scale)
        XCTAssertEqual(full.scale, 1, accuracy: 1e-9)
        let peak = state(t: 0.7, entrance: .pop, fadeIn: 1)
        XCTAssertGreaterThan(peak.scale, 1, "pop should overshoot past full scale before settling")
    }

    /// `draw`/`wipe` only report a reveal/wipe progress while mid-animation;
    /// before the entrance starts or after it completes there's nothing to
    /// mask, so the renderer can skip building one.
    func testRevealProgressOnlyReportedWhileInProgress() {
        let notStarted = state(t: 0, start: 0, end: 4, entrance: .draw, fadeIn: 1)
        XCTAssertEqual(notStarted.opacity, 0)
        XCTAssertNil(notStarted.revealProgress)
        let midway = state(t: 0.5, start: 0, end: 4, entrance: .draw, fadeIn: 1)
        XCTAssertNotNil(midway.revealProgress)
        let done = state(t: 1, start: 0, end: 4, entrance: .draw, fadeIn: 1)
        XCTAssertEqual(done.opacity, 1)
        XCTAssertNil(done.revealProgress, "fully drawn — no mask needed")
    }

    // MARK: - prefixPolyline

    func testPrefixPolylineBoundaries() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertEqual(VideoAnnotationMotion.prefixPolyline(line, fraction: 0), [CGPoint(x: 0, y: 0)])
        XCTAssertEqual(VideoAnnotationMotion.prefixPolyline(line, fraction: 1), line)
        let half = VideoAnnotationMotion.prefixPolyline(line, fraction: 0.5)
        XCTAssertEqual(half.last?.x ?? -1, 5, accuracy: 1e-9)
    }

    func testPrefixPolylineAcrossMultipleSegments() {
        // Three equal-length segments (total 30); 40% of the length lands
        // partway through the second segment.
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0)]
        let prefix = VideoAnnotationMotion.prefixPolyline(path, fraction: 0.4)
        XCTAssertEqual(prefix, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 12, y: 0)])
    }
}
