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
