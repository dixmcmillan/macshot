import AppKit
import XCTest

/// Video annotations are screenshot drawings pinned to a time range. The
/// drawing has to survive the project file and land on the same spot of the
/// video it was drawn over.
final class VideoAnnotationSegmentTests: XCTestCase {

    private func arrowData() throws -> Data {
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 20), endPoint: NSPoint(x: 90, y: 60),
                               color: .red, strokeWidth: 4)
        return try XCTUnwrap(AnnotationSerializer.encode([arrow]))
    }

    func testProjectRoundTripKeepsTheDrawing() throws {
        let project = VideoProject(sourceDuration: 30, look: VideoLook())
        project.annotations = [VideoAnnotationSegment(startTime: 2, endTime: 5, canvasSize: CGSize(width: 200, height: 100),
                                                      annotationData: try arrowData())]
        let copy = try XCTUnwrap(project.copy())
        XCTAssertEqual(copy.encoded(), project.encoded())
        XCTAssertTrue(copy.hasEdits)
        let drawing = copy.annotations[0].annotations
        XCTAssertEqual(drawing.map(\.tool), [.arrow])
        XCTAssertEqual(drawing[0].endPoint, NSPoint(x: 90, y: 60))
        XCTAssertEqual(copy.annotations[0].summary, "Arrow")
    }

    func testMissingFieldsDecodeLenientlyAndEmptyDrawingsAreDropped() throws {
        let data = try arrowData().base64EncodedString()
        let json = """
        {"sourceDuration": 20, "annotations": [
          {"startTime": 1, "endTime": 3, "annotationData": "\(data)"},
          {"startTime": 4, "endTime": 6},
          {"startTime": 25, "endTime": 30, "annotationData": "\(data)"},
          "garbage"]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        XCTAssertEqual(project.annotations.count, 1, "empty and out-of-range drawings are dropped")
        let segment = project.annotations[0]
        XCTAssertEqual(segment.canvasSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(segment.fadeIn, VideoAnnotationSegment.defaultFade)
    }

    func testCanvasRectsMapToTopLeftNormalizedContent() {
        let segment = VideoAnnotationSegment(startTime: 0, endTime: 1, canvasSize: CGSize(width: 200, height: 100),
                                             annotationData: Data())
        // Bottom-left quarter of the canvas is the bottom-left quarter of the video.
        XCTAssertEqual(segment.contentRect(forCanvas: CGRect(x: 0, y: 0, width: 100, height: 50)),
                       CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(segment.contentRect(forCanvas: CGRect(x: 0, y: 0, width: 200, height: 100)),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testHoldLandsAfterTheFadeIn() {
        let segment = VideoAnnotationSegment(startTime: 2, endTime: 5, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: Data(), fadeIn: 0.2)
        XCTAssertEqual(segment.holdTime, 2.2, accuracy: 1e-9)
        XCTAssertEqual(segment.opacity(at: segment.holdTime), 1, accuracy: 1e-6)
    }

    func testRetinaRecordingsGetPointSizedCanvases() {
        XCTAssertEqual(VideoAnnotationSegment.canvasSize(forContent: CGSize(width: 3024, height: 1964)),
                       CGSize(width: 1512, height: 982))
        XCTAssertEqual(VideoAnnotationSegment.canvasSize(forContent: CGSize(width: 1920, height: 1080)),
                       CGSize(width: 1920, height: 1080))
    }

    // MARK: - Remembered animation style

    func testRememberedAnimationStyleRoundTrips() throws {
        withDefaults(["videoAnnotationLastUsedStyle": nil]) {
            let seg = VideoAnnotationSegment(startTime: 0, endTime: 3, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: Data(), entrance: .wipe, exit: .slide, stagger: 0.4)
            seg.fadeIn = 1.1
            seg.fadeOut = 0.6
            seg.rememberAnimationStyle()

            // A brand new drawing picks up exactly what was just remembered,
            // without waiting for the debounced UserDefaults write.
            let remembered = VideoAnnotationSegment.lastUsedAnimationDefaults()
            XCTAssertEqual(remembered.entrance, .wipe)
            XCTAssertEqual(remembered.exit, .slide)
            XCTAssertEqual(remembered.fadeIn, 1.1, accuracy: 1e-9)
            XCTAssertEqual(remembered.fadeOut, 0.6, accuracy: 1e-9)
            XCTAssertEqual(remembered.stagger, 0.4, accuracy: 1e-9)
        }
    }

    func testRememberedStaggerIsClamped() {
        withDefaults(["videoAnnotationLastUsedStyle": nil]) {
            let seg = VideoAnnotationSegment(startTime: 0, endTime: 3, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: Data())
            seg.stagger = VideoAnnotationSegment.maxStagger + 5 // bypasses the initializer's clamp
            seg.rememberAnimationStyle()
            XCTAssertEqual(VideoAnnotationSegment.lastUsedAnimationDefaults().stagger, VideoAnnotationSegment.maxStagger)
        }
    }

    // MARK: - Hold freeze follows holdTime

    func testHoldFreezeFollowsHoldTimeChanges() {
        let segment = VideoAnnotationSegment(startTime: 2, endTime: 5, canvasSize: CGSize(width: 10, height: 10),
                                             annotationData: Data(), fadeIn: 0.2)
        let freeze = VideoFreezeSegment(atTime: segment.holdTime, holdDuration: 2)
        let unrelated = VideoFreezeSegment(atTime: 20, holdDuration: 1)
        let oldHold = segment.holdTime

        // Changing the entrance duration moves `holdTime`; the freeze that
        // was sitting on it moves with it, in place. A freeze elsewhere is
        // untouched — its `atTime` doesn't match the old hold time.
        segment.fadeIn = 0.6
        XCTAssertGreaterThan(abs(segment.holdTime - oldHold), 1e-9, "the entrance duration change should move holdTime")
        VideoAnnotationSegment.relocateHoldFreeze(in: [freeze, unrelated], from: oldHold, to: segment.holdTime, tolerance: 1e-6)
        XCTAssertEqual(freeze.atTime, segment.holdTime, accuracy: 1e-9)
        XCTAssertEqual(unrelated.atTime, 20, accuracy: 1e-9)

        // No freeze at all sitting at the old time: nothing to move.
        let none: [VideoFreezeSegment] = []
        VideoAnnotationSegment.relocateHoldFreeze(in: none, from: 100, to: 200, tolerance: 1e-6)

        // Within the half-frame tolerance still counts as "the same freeze".
        let close = VideoFreezeSegment(atTime: oldHold + 0.004, holdDuration: 1)
        VideoAnnotationSegment.relocateHoldFreeze(in: [close], from: oldHold, to: 9, tolerance: 0.01)
        XCTAssertEqual(close.atTime, 9, accuracy: 1e-9)

        // Outside the tolerance, it's not considered the same freeze.
        let far = VideoFreezeSegment(atTime: oldHold + 0.5, holdDuration: 1)
        VideoAnnotationSegment.relocateHoldFreeze(in: [far], from: oldHold, to: 9, tolerance: 0.01)
        XCTAssertEqual(far.atTime, oldHold + 0.5, accuracy: 1e-9)
    }
}
