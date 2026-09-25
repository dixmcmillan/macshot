import AVFoundation
import CoreMedia
import ImageIO
import XCTest

/// `VideoOverlayEditing` is the pure geometry/timing math behind overlay
/// clips' timeline trim handles and aspect-locked stage resize, factored out
/// of `VideoTimelineView`/`VideoStageView` so it can be tested without
/// AppKit or a live document.
final class VideoOverlayEditingTests: XCTestCase {

    // MARK: - Right-edge resize (duration only)

    func testResizedDurationClampsToModelRange() {
        XCTAssertEqual(VideoOverlayEditing.resizedDuration(proposedEnd: 12, startTime: 5, minDuration: 0.2, maxDuration: 20),
                       7, accuracy: 1e-9)
        XCTAssertEqual(VideoOverlayEditing.resizedDuration(proposedEnd: 5.05, startTime: 5, minDuration: 0.2, maxDuration: 20),
                       0.2, accuracy: 1e-9, "can't shrink past the model minimum")
        XCTAssertEqual(VideoOverlayEditing.resizedDuration(proposedEnd: 100, startTime: 5, minDuration: 0.2, maxDuration: 20),
                       20, accuracy: 1e-9, "can't grow past however much media is left")
    }

    func testResizedDurationFallsBackOnNonFiniteInput() {
        XCTAssertEqual(VideoOverlayEditing.resizedDuration(proposedEnd: .nan, startTime: 5, minDuration: 0.2, maxDuration: 20), 0.2)
    }

    // MARK: - Left-edge resize (head trim)

    func testVideoHeadTrimAdvancesMediaStartWithStartTime() {
        // 10s clip starting at t=5 with 2s already trimmed off its head;
        // dragging the left edge 2s later should trim 2 more seconds off the
        // head and shrink duration by the same amount, leaving the end (15)
        // exactly where it was.
        let trim = VideoOverlayEditing.trimHead(kind: .video, proposedStart: 7, originalStart: 5,
                                                originalMediaStart: 2, originalDuration: 10, minDuration: 0.2)
        XCTAssertEqual(trim.startTime, 7, accuracy: 1e-9)
        XCTAssertEqual(trim.mediaStart, 4, accuracy: 1e-9)
        XCTAssertEqual(trim.duration, 8, accuracy: 1e-9)
    }

    func testVideoHeadTrimClampsMediaStartAtZero() {
        // Dragging left further than the media has been trimmed can't reveal
        // media before the file starts: mediaStart floors at 0, and the
        // startTime/duration move only as far as that allows.
        let trim = VideoOverlayEditing.trimHead(kind: .video, proposedStart: 1, originalStart: 5,
                                                originalMediaStart: 2, originalDuration: 10, minDuration: 0.2)
        XCTAssertEqual(trim.mediaStart, 0, accuracy: 1e-9)
        XCTAssertEqual(trim.startTime, 3, accuracy: 1e-9)
        XCTAssertEqual(trim.duration, 12, accuracy: 1e-9)
    }

    func testVideoHeadTrimClampsAtMinimumDuration() {
        let trim = VideoOverlayEditing.trimHead(kind: .video, proposedStart: 6.5, originalStart: 5,
                                                originalMediaStart: 2, originalDuration: 1, minDuration: 0.2)
        XCTAssertEqual(trim.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(trim.startTime, 5.8, accuracy: 1e-9)
        XCTAssertEqual(trim.mediaStart, 2.8, accuracy: 1e-9)
    }

    func testImageHeadTrimOnlyMovesStartAndKeepsMediaStartZero() {
        let trim = VideoOverlayEditing.trimHead(kind: .image, proposedStart: 7, originalStart: 5,
                                                originalMediaStart: 0, originalDuration: 10, minDuration: 0.2)
        XCTAssertEqual(trim.startTime, 7, accuracy: 1e-9)
        XCTAssertEqual(trim.mediaStart, 0, accuracy: 1e-9)
        XCTAssertEqual(trim.duration, 8, accuracy: 1e-9)
    }

    func testImageHeadTrimClampsToZeroAndToMinimumDuration() {
        let draggedNegative = VideoOverlayEditing.trimHead(kind: .image, proposedStart: -3, originalStart: 5,
                                                           originalMediaStart: 0, originalDuration: 10, minDuration: 0.2)
        XCTAssertEqual(draggedNegative.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(draggedNegative.duration, 15, accuracy: 1e-9)

        let draggedPastEnd = VideoOverlayEditing.trimHead(kind: .image, proposedStart: 20, originalStart: 5,
                                                          originalMediaStart: 0, originalDuration: 10, minDuration: 0.2)
        XCTAssertEqual(draggedPastEnd.startTime, 14.8, accuracy: 1e-9)
        XCTAssertEqual(draggedPastEnd.duration, 0.2, accuracy: 1e-9)
    }

    // MARK: - Inspector size slider

    func testScaledRectGrowsAboutItsOwnCenter() {
        let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        let scaled = VideoOverlayEditing.scaledRect(rect, by: 2)
        XCTAssertEqual(scaled, CGRect(x: 0, y: 0.2, width: 0.8, height: 0.4))
        XCTAssertEqual(scaled.midX, rect.midX, accuracy: 1e-9)
        XCTAssertEqual(scaled.midY, rect.midY, accuracy: 1e-9)
    }

    func testScaledRectIgnoresInvalidFactors() {
        let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        XCTAssertEqual(VideoOverlayEditing.scaledRect(rect, by: 0), rect)
        XCTAssertEqual(VideoOverlayEditing.scaledRect(rect, by: -1), rect)
        XCTAssertEqual(VideoOverlayEditing.scaledRect(rect, by: .nan), rect)
    }

    // MARK: - Aspect-locked stage resize

    func testNormalizedAspectMatchesSquareCanvas() {
        XCTAssertEqual(VideoOverlayEditing.normalizedAspect(mediaSize: CGSize(width: 1920, height: 1080),
                                                             canvasSize: CGSize(width: 1920, height: 1080)), 1, accuracy: 1e-9)
    }

    func testNormalizedAspectAccountsForPortraitMediaOnLandscapeCanvas() {
        let aspect = VideoOverlayEditing.normalizedAspect(mediaSize: CGSize(width: 1080, height: 1920),
                                                          canvasSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(aspect, 0.31640625, accuracy: 1e-9)
    }

    func testNormalizedAspectFallsBackToOneForDegenerateSizes() {
        XCTAssertEqual(VideoOverlayEditing.normalizedAspect(mediaSize: .zero, canvasSize: CGSize(width: 1920, height: 1080)), 1)
        XCTAssertEqual(VideoOverlayEditing.normalizedAspect(mediaSize: CGSize(width: 100, height: 100), canvasSize: .zero), 1)
    }

    func testAspectLockedCornerPicksTheLargerImpliedBox() {
        // Dragging mostly horizontally: the width delta wins, height follows.
        let wide = VideoOverlayEditing.aspectLockedCorner(anchor: .zero, freeCorner: CGPoint(x: 0.3, y: 0.1), aspect: 2)
        XCTAssertEqual(wide.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(wide.y, 0.15, accuracy: 1e-9)

        // Dragging mostly vertically: the height delta (times aspect) wins.
        let tall = VideoOverlayEditing.aspectLockedCorner(anchor: .zero, freeCorner: CGPoint(x: 0.1, y: 0.3), aspect: 2)
        XCTAssertEqual(tall.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(tall.y, 0.3, accuracy: 1e-9)
    }

    func testAspectLockedCornerGrowsAwayFromTheAnchorInEitherDirection() {
        let corner = VideoOverlayEditing.aspectLockedCorner(anchor: CGPoint(x: 1, y: 1), freeCorner: CGPoint(x: 0.7, y: 0.9), aspect: 1)
        XCTAssertEqual(corner.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 0.7, accuracy: 1e-9)
    }

    func testAspectLockedCornerIgnoresInvalidAspect() {
        let free = CGPoint(x: 0.3, y: 0.1)
        XCTAssertEqual(VideoOverlayEditing.aspectLockedCorner(anchor: .zero, freeCorner: free, aspect: 0), free)
        XCTAssertEqual(VideoOverlayEditing.aspectLockedCorner(anchor: .zero, freeCorner: free, aspect: -1), free)
        XCTAssertEqual(VideoOverlayEditing.aspectLockedCorner(anchor: .zero, freeCorner: free, aspect: .nan), free)
    }

    // MARK: - Alpha detection

    func testImagePropertiesAlphaDetection() {
        XCTAssertTrue(VideoOverlayEditing.hasAlpha(imageProperties: [kCGImagePropertyHasAlpha: true]))
        XCTAssertFalse(VideoOverlayEditing.hasAlpha(imageProperties: [kCGImagePropertyHasAlpha: false]))
        XCTAssertFalse(VideoOverlayEditing.hasAlpha(imageProperties: [:]), "no key present means the probe couldn't tell — treat as opaque")
    }

    private func formatDescription(subtype: FourCharCode, extensions: [CFString: Any]? = nil) -> CMFormatDescription {
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Video,
                                               mediaSubType: subtype, extensions: extensions.map { $0 as CFDictionary },
                                               formatDescriptionOut: &description)
        precondition(status == noErr, "failed to build a test CMFormatDescription")
        return description!
    }

    func testProRes4444IsAlwaysConsideredToHaveAlpha() {
        XCTAssertTrue(VideoOverlayEditing.hasAlpha(formatDescriptions: [formatDescription(subtype: kCMVideoCodecType_AppleProRes4444)]))
        XCTAssertTrue(VideoOverlayEditing.hasAlpha(formatDescriptions: [formatDescription(subtype: kCMVideoCodecType_AppleProRes4444XQ)]))
    }

    func testHEVCAlphaComesFromTheContainsAlphaChannelExtension() {
        let withAlpha = formatDescription(subtype: kCMVideoCodecType_HEVC,
                                          extensions: [kCMFormatDescriptionExtension_ContainsAlphaChannel: true])
        XCTAssertTrue(VideoOverlayEditing.hasAlpha(formatDescriptions: [withAlpha]))

        let declaredOpaque = formatDescription(subtype: kCMVideoCodecType_HEVC,
                                               extensions: [kCMFormatDescriptionExtension_ContainsAlphaChannel: false])
        XCTAssertFalse(VideoOverlayEditing.hasAlpha(formatDescriptions: [declaredOpaque]))

        let noExtensionAtAll = formatDescription(subtype: kCMVideoCodecType_HEVC)
        XCTAssertFalse(VideoOverlayEditing.hasAlpha(formatDescriptions: [noExtensionAtAll]))
    }

    func testHasAlphaWithNoFormatsIsFalse() {
        XCTAssertFalse(VideoOverlayEditing.hasAlpha(formatDescriptions: []))
    }
}

/// `RotatedBoxEditing` is the pure geometry behind the stage's rotate/scale
/// handles for annotation drawings and overlay rotation: hit-testing, handle
/// placement, and drag math, all in view-space (top-left, y-down) points.
final class RotatedBoxEditingTests: XCTestCase {

    // MARK: - Rotation direction

    /// A point due "north" of center, rotated a quarter turn, lands "east" —
    /// the clockwise-as-seen-on-screen convention this type documents.
    func testRotateIsClockwiseInViewSpace() {
        let center = CGPoint(x: 10, y: 10)
        let north = CGPoint(x: 10, y: 0) // smaller y = up, in y-down space
        let rotated = RotatedBoxEditing.rotate(north, around: center, by: .pi / 2)
        XCTAssertEqual(rotated.x, 20, accuracy: 1e-6)
        XCTAssertEqual(rotated.y, 10, accuracy: 1e-6)
    }

    func testRotateByZeroIsIdentity() {
        let p = CGPoint(x: 3, y: 4)
        XCTAssertEqual(RotatedBoxEditing.rotate(p, around: CGPoint(x: 1, y: 1), by: 0), p)
    }

    // MARK: - Corners

    func testCornersOfUnrotatedRectAreItsOwnCorners() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 20)
        let corners = RotatedBoxEditing.corners(of: rect, rotation: 0)
        XCTAssertEqual(corners, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 0, y: 20)])
    }

    func testCornersStayEquidistantFromCenterWhenRotated() {
        let rect = CGRect(x: -5, y: -5, width: 10, height: 10)
        let corners = RotatedBoxEditing.corners(of: rect, rotation: 0.7)
        for corner in corners {
            XCTAssertEqual(hypot(corner.x, corner.y), hypot(5.0, 5.0), accuracy: 1e-6)
        }
    }

    // MARK: - Hit testing

    func testContainsFindsPointsInsideAnUnrotatedRect() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(RotatedBoxEditing.contains(CGPoint(x: 5, y: 5), in: rect, rotation: 0))
        XCTAssertFalse(RotatedBoxEditing.contains(CGPoint(x: 15, y: 5), in: rect, rotation: 0))
    }

    /// A point just past the unrotated square's right edge (outside) sits
    /// along the direction of the rotated square's vertex once it's spun
    /// 45° — a diamond's vertices reach `side/√2` farther than its edges —
    /// so the same point falls inside once rotation is accounted for.
    func testContainsRespectsRotation() {
        let rect = CGRect(x: -5, y: -5, width: 10, height: 10)
        let justPastTheEdge = CGPoint(x: 6, y: 0)
        XCTAssertFalse(RotatedBoxEditing.contains(justPastTheEdge, in: rect, rotation: 0))
        XCTAssertTrue(RotatedBoxEditing.contains(justPastTheEdge, in: rect, rotation: .pi / 4))
    }

    // MARK: - Rotation handle position <-> drag angle round-trip

    func testRotationHandleRestsAboveAnUnrotatedBox() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let handle = RotatedBoxEditing.rotationHandlePosition(for: rect, rotation: 0, distance: 20)
        XCTAssertEqual(handle.x, 5, accuracy: 1e-6)
        XCTAssertEqual(handle.y, -20, accuracy: 1e-6)
    }

    func testRotationHandlePositionAndDragAngleAreInverses() {
        let rect = CGRect(x: -20, y: -30, width: 40, height: 60)
        let center = RotatedBoxEditing.center(of: rect)
        for angle: CGFloat in stride(from: -3, through: 3, by: 0.5) {
            let handle = RotatedBoxEditing.rotationHandlePosition(for: rect, rotation: angle, distance: 25)
            let recovered = RotatedBoxEditing.rotation(fromCenter: center, to: handle, snap: false)
            XCTAssertEqual(recovered, angle, accuracy: 1e-5, "angle \(angle) round-tripped to \(recovered)")
        }
    }

    func testRotationSnapsToFifteenDegreeSteps() {
        let center = CGPoint(x: 0, y: 0)
        // 5° east of north (well inside the 0° step) should snap to 0°;
        // 10° (well inside the 15° step) should snap to 15°.
        let angle5 = CGFloat(5) * .pi / 180
        let towards5 = CGPoint(x: sin(angle5), y: -cos(angle5))
        XCTAssertEqual(RotatedBoxEditing.rotation(fromCenter: center, to: towards5, snap: true), 0, accuracy: 1e-6)
        let angle10 = CGFloat(10) * .pi / 180
        let towards10 = CGPoint(x: sin(angle10), y: -cos(angle10))
        XCTAssertEqual(RotatedBoxEditing.rotation(fromCenter: center, to: towards10, snap: true),
                       .pi / 12, accuracy: 1e-6)
    }

    func testSnapped15RoundsToNearestStep() {
        XCTAssertEqual(RotatedBoxEditing.snapped15(0.05), 0, accuracy: 1e-9)
        XCTAssertEqual(RotatedBoxEditing.snapped15(.pi / 12 + 0.05), .pi / 12, accuracy: 1e-9)
        XCTAssertEqual(RotatedBoxEditing.snapped15(.pi / 4), .pi / 4, accuracy: 1e-9, "45° is already a 15° multiple")
    }

    // MARK: - Corner drag scale

    func testCornerDragScaleIsTheDistanceRatioFromThePivot() {
        let pivot = CGPoint(x: 0, y: 0)
        let originalCorner = CGPoint(x: 10, y: 0)
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: originalCorner,
                                                         draggedPoint: CGPoint(x: 20, y: 0), range: 0.1...10), 2, accuracy: 1e-9)
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: originalCorner,
                                                         draggedPoint: CGPoint(x: 5, y: 0), range: 0.1...10), 0.5, accuracy: 1e-9)
    }

    /// Uniform scale doesn't care which direction the corner is dragged in —
    /// only its distance from the pivot, so rotating the same drag doesn't
    /// change the resulting scale.
    func testCornerDragScaleIsRotationIndependent() {
        let pivot = CGPoint(x: 2, y: 3)
        let originalCorner = CGPoint(x: 12, y: 3)
        let dragged = RotatedBoxEditing.rotate(CGPoint(x: 22, y: 3), around: pivot, by: 0.9)
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: originalCorner,
                                                         draggedPoint: dragged, range: 0.1...10), 2, accuracy: 1e-6)
    }

    func testCornerDragScaleClampsToRange() {
        let pivot = CGPoint.zero
        let originalCorner = CGPoint(x: 10, y: 0)
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: originalCorner,
                                                         draggedPoint: CGPoint(x: 200, y: 0), range: 0.1...10), 10)
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: originalCorner,
                                                         draggedPoint: CGPoint(x: 0.1, y: 0), range: 0.1...10), 0.1)
    }

    func testCornerDragScaleFallsBackOnDegenerateOriginalDistance() {
        let pivot = CGPoint.zero
        XCTAssertEqual(RotatedBoxEditing.cornerDragScale(pivot: pivot, originalCorner: pivot,
                                                         draggedPoint: CGPoint(x: 5, y: 5), range: 0.2...8), 0.2)
    }

    // MARK: - Arrow-key nudge

    func testNudgeMapsMacOSArrowKeyCodesToDirections() {
        XCTAssertEqual(RotatedBoxEditing.nudge(forArrowKeyCode: 123, amount: 1), CGPoint(x: -1, y: 0), "left")
        XCTAssertEqual(RotatedBoxEditing.nudge(forArrowKeyCode: 124, amount: 1), CGPoint(x: 1, y: 0), "right")
        XCTAssertEqual(RotatedBoxEditing.nudge(forArrowKeyCode: 125, amount: 1), CGPoint(x: 0, y: 1), "down")
        XCTAssertEqual(RotatedBoxEditing.nudge(forArrowKeyCode: 126, amount: 1), CGPoint(x: 0, y: -1), "up")
    }

    func testNudgeScalesByAmount() {
        XCTAssertEqual(RotatedBoxEditing.nudge(forArrowKeyCode: 124, amount: 10), CGPoint(x: 10, y: 0))
    }

    func testNudgeIsNilForNonArrowKeys() {
        XCTAssertNil(RotatedBoxEditing.nudge(forArrowKeyCode: 49, amount: 1), "space bar")
    }
}
