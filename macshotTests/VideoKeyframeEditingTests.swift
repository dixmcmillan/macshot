import CoreGraphics
import XCTest

/// `VideoKeyframeEditing` is the pure logic behind the video editor's
/// keyframing UI: local-time mapping (drawing/overlay, and the overlay's
/// inverse used to seek), auto-keying (folding a partial edit into whatever's
/// already sampled), the keyframe navigator (prev/next/toggle), and the
/// trim-shift rules that keep keyframes anchored to the same absolute moment
/// when a segment's start edge moves. No AppKit, no `VideoEditorDocument`.
final class VideoKeyframeEditingTests: XCTestCase {

    private func kf(_ time: Double, offset: CGPoint = .zero, scale: Double = 1, rotation: Double = 0,
                    opacity: Double = 1, easing: VideoKeyframe.Easing = .linear) -> VideoKeyframe {
        VideoKeyframe(time: time, value: VideoTransformValue(offset: offset, scale: scale, rotation: rotation, opacity: opacity),
                     easing: easing)
    }

    // MARK: - isAnimated (the auto-key decision)

    func testIsAnimatedIsFalseForEmptyKeyframes() {
        XCTAssertFalse(VideoKeyframeEditing.isAnimated([]))
    }

    func testIsAnimatedIsTrueOnceThereIsAnyKeyframe() {
        XCTAssertTrue(VideoKeyframeEditing.isAnimated([kf(0)]))
    }

    // MARK: - Drawing local time (source clock)

    func testDrawingLocalTimeSubtractsStartAndClamps() {
        XCTAssertEqual(VideoKeyframeEditing.drawingLocalTime(sourceTime: 12, startTime: 10, duration: 5), 2, accuracy: 1e-9)
        XCTAssertEqual(VideoKeyframeEditing.drawingLocalTime(sourceTime: 4, startTime: 10, duration: 5), 0, accuracy: 1e-9,
                      "before the segment starts clamps to 0")
        XCTAssertEqual(VideoKeyframeEditing.drawingLocalTime(sourceTime: 999, startTime: 10, duration: 5), 5, accuracy: 1e-9,
                      "past the segment's end clamps to duration")
    }

    func testDrawingLocalTimeIsZeroForNonFiniteOrZeroDuration() {
        XCTAssertEqual(VideoKeyframeEditing.drawingLocalTime(sourceTime: .nan, startTime: 0, duration: 5), 0)
        XCTAssertEqual(VideoKeyframeEditing.drawingLocalTime(sourceTime: 3, startTime: 0, duration: 0), 0)
    }

    // MARK: - Overlay local time (output/composition clock) and its inverse

    func testOverlayLocalTimeUsesCompositionTimeDifference() {
        // A 2x speed-up between the overlay's start and the playhead: 4
        // composition seconds elapse for every 2 source seconds.
        let compositionTime: (Double) -> Double = { source in source * 2 }
        let local = VideoKeyframeEditing.overlayLocalTime(sourceTime: 13, overlayStartTime: 10, duration: 20,
                                                          compositionTime: compositionTime)
        XCTAssertEqual(local, 6, accuracy: 1e-9)
    }

    func testOverlayLocalTimeClampsToDuration() {
        let identity: (Double) -> Double = { $0 }
        XCTAssertEqual(VideoKeyframeEditing.overlayLocalTime(sourceTime: 9, overlayStartTime: 10, duration: 5,
                                                             compositionTime: identity), 0, "before it appears clamps to 0")
        XCTAssertEqual(VideoKeyframeEditing.overlayLocalTime(sourceTime: 1000, overlayStartTime: 10, duration: 5,
                                                             compositionTime: identity), 5, "past its play time clamps to duration")
    }

    func testOverlaySourceTimeInvertsOverlayLocalTime() {
        // An affine (speed-ramped) source↔composition mapping — exact
        // inverses of each other — round-trips through both directions.
        func compositionTime(_ source: Double) -> Double { source * 1.5 + 2 }
        func sourceTime(_ composition: Double) -> Double { (composition - 2) / 1.5 }
        let overlayStart = 4.0
        let local = 3.0
        let seekTarget = VideoKeyframeEditing.overlaySourceTime(forLocal: local, overlayStartTime: overlayStart,
                                                                compositionTime: compositionTime, sourceTime: sourceTime)
        let roundTrip = VideoKeyframeEditing.overlayLocalTime(sourceTime: seekTarget, overlayStartTime: overlayStart,
                                                              duration: 100, compositionTime: compositionTime)
        XCTAssertEqual(roundTrip, local, accuracy: 1e-9)
    }

    // MARK: - Timeline diamond position (mixes source `start` with the
    // keyframe's own clock the same way the pill's own end edge does)

    func testTimelinePositionAddsKeyframeTimeToItemStart() {
        XCTAssertEqual(VideoKeyframeEditing.timelinePosition(itemStart: 10, keyframeTime: 2.5), 12.5, accuracy: 1e-9)
    }

    func testKeyframeTimeForTimelinePositionInvertsIt() {
        let x = VideoKeyframeEditing.timelinePosition(itemStart: 10, keyframeTime: 2.5)
        XCTAssertEqual(VideoKeyframeEditing.keyframeTime(forTimelinePosition: x, itemStart: 10), 2.5, accuracy: 1e-9)
    }

    // MARK: - autoKeyed: folds a partial edit into what's already sampled

    func testAutoKeyedPreservesOtherComponentsWhenEditingOneField() {
        let existing = [kf(0, offset: CGPoint(x: 1, y: 2), scale: 3, rotation: 0.5, opacity: 0.8)]
        let result = VideoKeyframeEditing.autoKeyed(existing, at: 0) { $0.offset = CGPoint(x: 9, y: 9) }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value.offset, CGPoint(x: 9, y: 9))
        XCTAssertEqual(result[0].value.scale, 3, accuracy: 1e-9, "unedited fields keep the sampled value")
        XCTAssertEqual(result[0].value.rotation, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].value.opacity, 0.8, accuracy: 1e-9)
    }

    func testAutoKeyedInsertsANewKeyframeAtAnUnkeyedTime() throws {
        let existing = [kf(0, scale: 2)]
        let result = VideoKeyframeEditing.autoKeyed(existing, at: 5) { $0.rotation = 1 }
        XCTAssertEqual(result.count, 2)
        let inserted = try XCTUnwrap(result.first { $0.time > 0.001 })
        XCTAssertEqual(inserted.value.scale, 2, accuracy: 1e-9, "started from the value sampled (held) at time 5")
        XCTAssertEqual(inserted.value.rotation, 1, accuracy: 1e-9)
    }

    func testAutoKeyedStartsFromIdentityWithNoExistingKeyframes() {
        let result = VideoKeyframeEditing.autoKeyed([], at: 2) { $0.scale = 4 }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value.scale, 4, accuracy: 1e-9)
        XCTAssertEqual(result[0].value.offset, .zero)
    }

    // MARK: - Navigator: previous/next/hasKeyframe

    func testPreviousAndNextKeyframeTime() {
        let keyframes = [kf(0), kf(2), kf(5)]
        XCTAssertEqual(VideoKeyframeEditing.previousKeyframeTime(before: 3, in: keyframes), 2)
        XCTAssertEqual(VideoKeyframeEditing.nextKeyframeTime(after: 3, in: keyframes), 5)
        XCTAssertNil(VideoKeyframeEditing.previousKeyframeTime(before: 0, in: keyframes), "nothing before the first")
        XCTAssertNil(VideoKeyframeEditing.nextKeyframeTime(after: 5, in: keyframes), "nothing after the last")
    }

    func testHasKeyframeUsesTolerance() {
        let keyframes = [kf(2)]
        XCTAssertTrue(VideoKeyframeEditing.hasKeyframe(at: 2, in: keyframes))
        XCTAssertTrue(VideoKeyframeEditing.hasKeyframe(at: 2 + VideoKeyframes.timeTolerance / 2, in: keyframes))
        XCTAssertFalse(VideoKeyframeEditing.hasKeyframe(at: 2.5, in: keyframes))
    }

    // MARK: - Toggling (the ◆ navigator button)

    func testTogglingKeyframeAddsWhenNoneIsThere() {
        let result = VideoKeyframeEditing.togglingKeyframe(at: 3, in: [kf(0, scale: 2)])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { abs($0.time - 3) < 0.001 })
    }

    func testTogglingKeyframeRemovesAnExistingOne() {
        let result = VideoKeyframeEditing.togglingKeyframe(at: 3, in: [kf(0), kf(3)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].time, 0, accuracy: 1e-9)
    }

    func testTogglingKeyframeNeverRemovesTheOnlyOne() {
        // The only way to fully stop animating is the Animate toggle, with
        // its confirmation — the ◆ button alone can't empty the array.
        let result = VideoKeyframeEditing.togglingKeyframe(at: 0, in: [kf(0)])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Moving and deleting by id

    func testMovingKeyframeRetimesAndResorts() {
        let a = kf(0), b = kf(5)
        let result = VideoKeyframeEditing.movingKeyframe(id: a.id, to: 8, in: [a, b])
        XCTAssertEqual(result.map(\.id), [b.id, a.id], "resorted by time")
        XCTAssertEqual(result.last!.time, 8, accuracy: 1e-9)
    }

    func testMovingKeyframeClampsNegativeTimeToZero() {
        let a = kf(2)
        let result = VideoKeyframeEditing.movingKeyframe(id: a.id, to: -3, in: [a])
        XCTAssertEqual(result.first?.time, 0)
    }

    func testDeletingKeyframeRemovesOnlyThatOne() {
        let a = kf(0), b = kf(3)
        let result = VideoKeyframeEditing.deletingKeyframe(id: a.id, in: [a, b])
        XCTAssertEqual(result.map(\.id), [b.id])
    }

    // MARK: - Easing: "at or before" and setting it

    func testKeyframeAtOrBeforeFindsTheLatestOneNotAfter() {
        let a = kf(0), b = kf(3), c = kf(7)
        XCTAssertEqual(VideoKeyframeEditing.keyframeAtOrBefore(5, in: [a, b, c])?.id, b.id)
        XCTAssertEqual(VideoKeyframeEditing.keyframeAtOrBefore(7, in: [a, b, c])?.id, c.id, "exactly at a keyframe uses it")
    }

    func testKeyframeAtOrBeforeFallsBackToTheFirstWhenBeforeEverything() {
        let a = kf(4), b = kf(9)
        XCTAssertEqual(VideoKeyframeEditing.keyframeAtOrBefore(0, in: [a, b])?.id, a.id)
    }

    func testSettingEasingChangesOnlyTheTargetedKeyframe() {
        let a = kf(0, easing: .linear), b = kf(5, easing: .linear)
        let result = VideoKeyframeEditing.settingEasing(.hold, forKeyframeAtOrBefore: 2, in: [a, b])
        XCTAssertEqual(result.first { $0.id == a.id }?.easing, .hold)
        XCTAssertEqual(result.first { $0.id == b.id }?.easing, .linear, "the later keyframe is untouched")
    }

    // MARK: - Trim shift

    func testShiftedForStartTrimKeepsKeysAtTheSameAbsoluteMoment() {
        // Trimming the start edge 3s later: a keyframe that was 5s in is now
        // only 2s from the (later) start, since it sits at the same moment.
        let result = VideoKeyframeEditing.shiftedForStartTrim([kf(5)], delta: 3)
        XCTAssertEqual(result.first!.time, 2, accuracy: 1e-9)
    }

    func testShiftedForStartTrimDropsKeysBeforeTheNewStart() {
        let result = VideoKeyframeEditing.shiftedForStartTrim([kf(1), kf(5)], delta: 3)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first!.time, 2, accuracy: 1e-9)
    }

    func testShiftedForStartTrimHandlesTrimmingEarlier() {
        // A negative delta (dragging the start handle earlier) moves every
        // keyframe later by the same absolute amount.
        let result = VideoKeyframeEditing.shiftedForStartTrim([kf(2)], delta: -3)
        XCTAssertEqual(result.first!.time, 5, accuracy: 1e-9)
    }

    func testTrimmedForEndTrimDropsKeysPastTheNewDuration() {
        let result = VideoKeyframeEditing.trimmedForEndTrim([kf(1), kf(4), kf(8)], newDuration: 5)
        XCTAssertEqual(result.map(\.time), [1, 4])
    }

    // MARK: - Animated-overlay placement geometry

    func testTransformedRectShiftsCenterAndScalesAboutIt() {
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let result = VideoOverlayEditing.transformedRect(rect, offset: CGPoint(x: 0.1, y: -0.05), scale: 2)
        XCTAssertEqual(result.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(result.height, 0.2, accuracy: 1e-9)
        XCTAssertEqual(result.midX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(result.midY, 0.4, accuracy: 1e-9)
    }

    func testMoveOffsetInvertsTransformedRectsTranslation() {
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let offset = CGPoint(x: 0.1, y: -0.05)
        let moved = VideoOverlayEditing.transformedRect(rect, offset: offset, scale: 1)
        let recovered = VideoOverlayEditing.moveOffset(newCenter: CGPoint(x: moved.midX, y: moved.midY), rect: rect)
        XCTAssertEqual(recovered.x, offset.x, accuracy: 1e-9)
        XCTAssertEqual(recovered.y, offset.y, accuracy: 1e-9)
    }
}
