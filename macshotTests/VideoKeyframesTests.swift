import AppKit
import XCTest

/// `VideoKeyframes.sample` is the one place both `VideoAnnotationSegment`
/// (source clock) and `VideoOverlaySegment` (output clock) get their
/// animated transform from, and the one the renderer samples directly for
/// each animated `AnnotationLayerSnapshot`/`VideoOverlayLayer`. These tests
/// cover the pure model: sampling, easing, geometric scale, `setting`, and
/// lenient decoding of both a single keyframe and the segments that own
/// keyframe lists.
final class VideoKeyframesTests: XCTestCase {

    private func kf(_ time: Double, offset: CGPoint = .zero, scale: Double = 1, rotation: Double = 0,
                    opacity: Double = 1, easing: VideoKeyframe.Easing = .linear) -> VideoKeyframe {
        VideoKeyframe(time: time, value: VideoTransformValue(offset: offset, scale: scale, rotation: rotation, opacity: opacity),
                     easing: easing)
    }

    // MARK: - sample: no keyframes / before-first / after-last

    func testSampleIsNilWithNoKeyframes() {
        XCTAssertNil(VideoKeyframes.sample([], at: 1))
    }

    func testSampleHoldsTheFirstValueBeforeIt() {
        let a = kf(2, offset: CGPoint(x: 1, y: 0))
        let b = kf(5, offset: CGPoint(x: 2, y: 0))
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 0)?.offset, CGPoint(x: 1, y: 0))
        // Exactly at the first keyframe's own time also holds it (not an
        // interpolation with itself).
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 2)?.offset, CGPoint(x: 1, y: 0))
    }

    func testSampleHoldsTheLastValueAfterIt() {
        let a = kf(0, offset: CGPoint(x: 1, y: 0))
        let b = kf(3, offset: CGPoint(x: 2, y: 0))
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 100)?.offset, CGPoint(x: 2, y: 0))
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 3)?.offset, CGPoint(x: 2, y: 0))
    }

    func testSampleWithASingleKeyframeIsConstantEverywhere() {
        let only = kf(2, offset: CGPoint(x: 5, y: 5))
        XCTAssertEqual(VideoKeyframes.sample([only], at: -10)?.offset, CGPoint(x: 5, y: 5))
        XCTAssertEqual(VideoKeyframes.sample([only], at: 10)?.offset, CGPoint(x: 5, y: 5))
    }

    // MARK: - Unsorted input

    func testSampleSortsUnorderedKeyframesByTime() {
        let late = kf(5, offset: CGPoint(x: 10, y: 0))
        let early = kf(0, offset: CGPoint(x: 0, y: 0))
        // Passed in reverse order — sample must still treat `early` as first.
        let midpoint = VideoKeyframes.sample([late, early], at: 2.5)
        XCTAssertEqual(midpoint?.offset.x ?? -1, 5, accuracy: 1e-9)
    }

    // MARK: - Easing curves, each one

    func testLinearEasingIsProportional() {
        let a = kf(0, opacity: 0, easing: .linear)
        let b = kf(10, opacity: 1)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 2.5)?.opacity ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 5)?.opacity ?? -1, 0.5, accuracy: 1e-9)
    }

    func testEaseInStartsSlow() {
        let a = kf(0, opacity: 0, easing: .easeIn)
        let b = kf(10, opacity: 1)
        // t^3 at 0.5 is 0.125 — well under the linear 0.5.
        let value = VideoKeyframes.sample([a, b], at: 5)?.opacity ?? -1
        XCTAssertEqual(value, 0.125, accuracy: 1e-9)
        XCTAssertLessThan(value, 0.5)
    }

    func testEaseOutEndsSlow() {
        let a = kf(0, opacity: 0, easing: .easeOut)
        let b = kf(10, opacity: 1)
        let value = VideoKeyframes.sample([a, b], at: 5)?.opacity ?? -1
        XCTAssertEqual(value, 0.875, accuracy: 1e-9)
        XCTAssertGreaterThan(value, 0.5)
    }

    func testEaseInOutIsSymmetricAboutTheMidpoint() {
        let a = kf(0, opacity: 0, easing: .easeInOut)
        let b = kf(10, opacity: 1)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 5)?.opacity ?? -1, 0.5, accuracy: 1e-9)
        let quarter = VideoKeyframes.sample([a, b], at: 2.5)?.opacity ?? -1
        let threeQuarter = VideoKeyframes.sample([a, b], at: 7.5)?.opacity ?? -1
        XCTAssertEqual(quarter, 1 - threeQuarter, accuracy: 1e-9)
        XCTAssertLessThan(quarter, 0.5, "easeInOut starts slow")
    }

    /// `hold` freezes the segment's value at the earlier keyframe right up
    /// to (but not including) the next one, then jumps.
    func testHoldEasingJumpsAtTheNextKeyframe() {
        let a = kf(0, opacity: 0, easing: .hold)
        let b = kf(10, opacity: 1)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 0)?.opacity ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 9.999)?.opacity ?? -1, 0, accuracy: 1e-9)
        // Right at/after the next keyframe, the held span is over.
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 10)?.opacity ?? -1, 1, accuracy: 1e-9)
    }

    // MARK: - Geometric scale interpolation

    /// Scale interpolates geometrically (in log space), so 1 -> 4 passes
    /// through 2 (not 2.5, the arithmetic midpoint) at the halfway point.
    func testScaleInterpolatesGeometricallyAtTheMidpoint() {
        let a = kf(0, scale: 1, easing: .linear)
        let b = kf(10, scale: 4)
        XCTAssertEqual(VideoKeyframes.sample([a, b], at: 5)?.scale ?? -1, 2, accuracy: 1e-9)
    }

    // MARK: - `setting`: insert vs update within tolerance

    func testSettingInsertsANewKeyframeOutsideTolerance() {
        let existing = [kf(0, offset: .zero), kf(5, offset: CGPoint(x: 1, y: 0))]
        let result = VideoKeyframes.setting(VideoTransformValue(offset: CGPoint(x: 2, y: 0)), at: 2.5, in: existing)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.time), [0, 2.5, 5])
        XCTAssertEqual(result[1].value.offset, CGPoint(x: 2, y: 0))
    }

    func testSettingUpdatesAnExistingKeyframeWithinTolerance() {
        let existing = [kf(0, offset: .zero), kf(5, offset: CGPoint(x: 1, y: 0))]
        let withinTolerance = 5 + VideoKeyframes.timeTolerance / 2
        let result = VideoKeyframes.setting(VideoTransformValue(offset: CGPoint(x: 9, y: 9)), at: withinTolerance, in: existing)
        XCTAssertEqual(result.count, 2, "within tolerance updates in place rather than inserting")
        XCTAssertEqual(result[1].value.offset, CGPoint(x: 9, y: 9))
        // The original keyframe's own time (not the query time) is kept.
        XCTAssertEqual(result[1].time, 5, accuracy: 1e-9)
    }

    func testSettingNewKeyframeInheritsThePrecedingEasing() {
        let existing = [kf(0, easing: .easeIn)]
        let result = VideoKeyframes.setting(.identity, at: 5, in: existing)
        XCTAssertEqual(result.last?.easing, .easeIn)
    }

    func testSettingClampsNegativeTimeToZero() {
        let result = VideoKeyframes.setting(.identity, at: -3, in: [])
        XCTAssertEqual(result.first?.time, 0)
    }

    // MARK: - `clamped`: drop keyframes past the segment's duration

    func testClampedDropsKeyframesPastDurationAndSorts() {
        let keyframes = [kf(5), kf(1), kf(10.1)]
        let result = VideoKeyframes.clamped(keyframes, duration: 10)
        XCTAssertEqual(result.map(\.time), [1, 5])
    }

    // MARK: - VideoKeyframe: lenient decode, including garbage

    func testKeyframeDecodesLenientlyFromGarbageFields() throws {
        let json = """
        {"id": "not-a-uuid", "time": "nope", "offset": "garbage", "scale": "bad",
         "rotation": null, "opacity": "x", "easing": "not-a-real-easing"}
        """
        let decoded = try JSONDecoder().decode(VideoKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.time, 0)
        XCTAssertEqual(decoded.value.offset, .zero)
        XCTAssertEqual(decoded.value.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(decoded.value.rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(decoded.value.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(decoded.easing, .easeInOut)
    }

    func testKeyframeClampsOutOfRangeScaleAndOpacityAndNegativeTime() throws {
        let json = """
        {"time": -5, "scale": 1000, "opacity": 5}
        """
        let decoded = try JSONDecoder().decode(VideoKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.time, 0, "negative time clamps to 0")
        XCTAssertEqual(decoded.value.scale, VideoKeyframes.maxScale, accuracy: 1e-9)
        XCTAssertEqual(decoded.value.opacity, 1, accuracy: 1e-9)
    }

    func testKeyframeRejectsNonFiniteNumbersEverywhere() throws {
        // NaN/Infinity aren't representable in standard JSON, so a hand-built
        // payload can't smuggle them through the decoder directly, but a
        // completely missing/mistyped object exercises the same fallback
        // path the finite-check guards against.
        let json = "{}"
        let decoded = try JSONDecoder().decode(VideoKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.value, .identity)
        XCTAssertEqual(decoded.time, 0)
        XCTAssertEqual(decoded.easing, .easeInOut)
    }

    // MARK: - VideoAnnotationSegment: keyframes field + transform(at:)

    private func arrowData() throws -> Data {
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 20), endPoint: NSPoint(x: 90, y: 60),
                               color: .red, strokeWidth: 4)
        return try XCTUnwrap(AnnotationSerializer.encode([arrow]))
    }

    func testAnnotationSegmentTransformFallsBackToStaticWhenNotAnimated() throws {
        let segment = VideoAnnotationSegment(startTime: 2, endTime: 5, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: try arrowData(), offset: CGPoint(x: 0.3, y: 0), scale: 2,
                                             rotation: .pi / 4)
        XCTAssertEqual(segment.transform(at: 3), segment.staticTransform)
    }

    func testAnnotationSegmentTransformSamplesKeyframesOnTheSourceClock() throws {
        let segment = VideoAnnotationSegment(startTime: 2, endTime: 6, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: try arrowData())
        segment.keyframes = [kf(0, offset: CGPoint(x: 0, y: 0)), kf(4, offset: CGPoint(x: 1, y: 0))]
        // Source time 2 (segment start, local 0) -> first keyframe's value.
        XCTAssertEqual(segment.transform(at: 2).offset, CGPoint(x: 0, y: 0))
        // Source time 6 (segment end, local 4) -> last keyframe's value.
        XCTAssertEqual(segment.transform(at: 6).offset, CGPoint(x: 1, y: 0))
    }

    /// A project written before keyframing existed has no `keyframes` key at
    /// all on its annotation segments — must decode to an empty (unanimated)
    /// list, not fail the whole segment.
    func testAnnotationSegmentDecodesEmptyKeyframesWhenAbsent() throws {
        let json = """
        {"sourceDuration": 5, "annotations": [
          {"startTime": 0, "endTime": 2, "annotationData": "\(try arrowData().base64EncodedString())"}
        ]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        let segment = try XCTUnwrap(project.annotations.first)
        XCTAssertEqual(segment.keyframes, [])
        XCTAssertEqual(segment.transform(at: 1), segment.staticTransform)
    }

    /// Garbage in the `keyframes` array (a value that isn't a keyframe object
    /// at all) fails the whole-array decode; the lenient `or:` fallback drops
    /// it to empty rather than losing the segment or the project.
    func testAnnotationSegmentDropsUnreadableKeyframesArray() throws {
        let json = """
        {"sourceDuration": 5, "annotations": [
          {"startTime": 0, "endTime": 2, "annotationData": "\(try arrowData().base64EncodedString())",
           "keyframes": [42, "nope", true]}
        ]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        let segment = try XCTUnwrap(project.annotations.first)
        XCTAssertEqual(segment.keyframes, [])
    }

    /// Individual keyframe objects with garbage fields still decode (each
    /// field falls back independently, per `VideoKeyframe.init(from:)`), and
    /// ones past the segment's duration are dropped.
    func testAnnotationSegmentKeepsWellFormedKeyframesWithGarbageFieldsAndDropsOutOfRangeOnes() throws {
        let json = """
        {"sourceDuration": 5, "annotations": [
          {"startTime": 0, "endTime": 2, "annotationData": "\(try arrowData().base64EncodedString())",
           "keyframes": [
             {"time": 0, "offset": [0.1, 0]},
             {"time": "garbage", "scale": "nope"},
             {"time": 100}
           ]}
        ]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        let segment = try XCTUnwrap(project.annotations.first)
        // The out-of-range keyframe (time 100 on a 2s segment) is dropped.
        // The garbage-time keyframe falls back to time 0 (its own field, in
        // isolation) rather than losing the whole array or the segment; both
        // surviving keyframes land at time 0 (`clamped` sorts but doesn't
        // dedupe), so only their values distinguish them.
        XCTAssertEqual(segment.keyframes.count, 2)
        XCTAssertTrue(segment.keyframes.allSatisfy { $0.time <= 2.01 })
        XCTAssertTrue(segment.keyframes.contains { $0.value.offset == CGPoint(x: 0.1, y: 0) })
        XCTAssertTrue(segment.keyframes.contains { $0.value.offset == .zero && $0.value.scale == 1 })
    }

    // MARK: - VideoOverlaySegment: keyframes field + transform(atLocal:)

    func testOverlaySegmentTransformFallsBackToStaticWhenNotAnimated() {
        let segment = VideoOverlaySegment(kind: .image, fileName: "a.png", displayName: "a", startTime: 0,
                                          duration: 3, mediaDuration: 0, mediaSize: CGSize(width: 10, height: 10),
                                          rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), rotation: .pi / 6)
        XCTAssertEqual(segment.transform(atLocal: 1), segment.staticTransform)
        XCTAssertEqual(segment.transform(atLocal: 1).rotation, .pi / 6, accuracy: 1e-9)
    }

    func testOverlaySegmentTransformSamplesKeyframesOnTheOutputClock() {
        let segment = VideoOverlaySegment(kind: .image, fileName: "a.png", displayName: "a", startTime: 2,
                                          duration: 4, mediaDuration: 0, mediaSize: CGSize(width: 10, height: 10),
                                          rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        segment.keyframes = [kf(0, rotation: 0), kf(4, rotation: .pi / 2)]
        // Local (output-since-appeared) time, independent of `startTime`.
        XCTAssertEqual(segment.transform(atLocal: 0).rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(segment.transform(atLocal: 4).rotation, .pi / 2, accuracy: 1e-9)
    }

    /// A project written before keyframing existed has no `keyframes` key at
    /// all on its overlay segments.
    func testOverlaySegmentDecodesEmptyKeyframesWhenAbsent() throws {
        let json = """
        {"sourceDuration": 5, "overlays": [
          {"kind": "image", "fileName": "a.png", "displayName": "a", "startTime": 0, "duration": 2,
           "mediaDuration": 0, "mediaSize": {"width": 10, "height": 10},
           "rect": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}}
        ]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        let segment = try XCTUnwrap(project.overlays.first)
        XCTAssertEqual(segment.keyframes, [])
    }
}
