import AppKit
import CoreImage
import XCTest

final class VideoSceneRendererTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let contentSize = CGSize(width: 400, height: 200)

    /// Red frame with a blue square in its top-left corner.
    private var content: CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: contentSize))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 150, width: 50, height: 50))
        return blue.composited(over: red)
    }

    private func layout(padding: Double = 0.1, radius: Double = 0, enabled: Bool = true) -> VideoSceneLayout {
        var frame = VideoFrameStyle()
        frame.enabled = enabled
        frame.padding = padding
        frame.cornerRadius = radius
        return VideoSceneGeometry.layout(contentSize: contentSize, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         frame: frame)!
    }

    private func scene(_ layout: VideoSceneLayout, camera: CameraPath = .empty,
                       cursor: VideoCursorLayer? = nil) -> VideoSceneSnapshot {
        let background = layout.drawsBackground
            ? CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(origin: .zero, size: layout.canvasSize))
            : nil
        return VideoSceneSnapshot(layout: layout, background: background, foreground: nil, camera: camera,
                                  cameraMotionBlur: 0, cursor: cursor, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
                                  captions: [], captionStyle: VideoCaptionStyle(), webcam: nil)
    }

    /// RGBA bytes at a top-left pixel coordinate.
    private func pixel(_ image: CIImage, _ x: Int, _ yTop: Int) -> [UInt8] {
        let extent = image.extent
        var bytes = [UInt8](repeating: 0, count: 4)
        let y = Int(extent.height) - 1 - yTop
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func assertColor(_ rgba: [UInt8], _ r: UInt8, _ g: UInt8, _ b: UInt8,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Int(rgba[0]), Int(r), accuracy: 12, "red", file: file, line: line)
        XCTAssertEqual(Int(rgba[1]), Int(g), accuracy: 12, "green", file: file, line: line)
        XCTAssertEqual(Int(rgba[2]), Int(b), accuracy: 12, "blue", file: file, line: line)
    }

    func testFramePlacesRecordingOverBackground() {
        let layout = layout()
        let image = VideoSceneRenderer.render(content: content, time: 0, scene: scene(layout), censors: [], texts: [])
        XCTAssertEqual(image.extent.size, layout.canvasSize)
        assertColor(pixel(image, 2, 2), 0, 255, 0)
        assertColor(pixel(image, Int(layout.videoRect.midX), Int(layout.videoRect.midY)), 255, 0, 0)
        // Top-left of the recording is the blue marker (orientation preserved).
        assertColor(pixel(image, Int(layout.videoRect.minX) + 5, Int(layout.videoRect.minY) + 5), 0, 0, 255)
    }

    func testRoundedCornersRevealTheBackground() {
        let layout = layout(radius: 400)
        XCTAssertGreaterThan(layout.cornerRadius, 20)
        let image = VideoSceneRenderer.render(content: content, time: 0, scene: scene(layout), censors: [], texts: [])
        assertColor(pixel(image, Int(layout.videoRect.maxX) - 1, Int(layout.videoRect.maxY) - 1), 0, 255, 0)
        assertColor(pixel(image, Int(layout.videoRect.midX), Int(layout.videoRect.maxY) - 2), 255, 0, 0)
    }

    func testCameraZoomFillsTheOutputWithTheRecording() {
        let layout = layout(padding: 0.05)
        let path = CameraPathBuilder.build(zooms: [.init(start: 0, end: 10, level: 3, center: CGPoint(x: 0.5, y: 0.5),
                                                         follows: false, rampIn: 0, rampOut: 0)],
                                           layout: layout, cursor: nil, connect: false)
        let image = VideoSceneRenderer.render(content: content, time: 5, scene: scene(layout, camera: path),
                                              censors: [], texts: [])
        for (x, y) in [(1, 1), (Int(layout.canvasSize.width) - 2, Int(layout.canvasSize.height) - 2)] {
            assertColor(pixel(image, x, y), 255, 0, 0)
        }
    }

    func testCameraMotionBlurPreservesBrightness() {
        let layout = layout(enabled: false)
        let solid = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: contentSize))
        // Two zooms far apart: the connected pan between them moves fast.
        let path = CameraPathBuilder.build(zooms: [
            .init(start: 0, end: 1, level: 3, center: CGPoint(x: 0.1, y: 0.1), follows: false, rampIn: 0, rampOut: 0),
            .init(start: 1.1, end: 3, level: 3, center: CGPoint(x: 0.9, y: 0.9), follows: false, rampIn: 0, rampOut: 0),
        ], layout: layout, cursor: nil, connect: true)
        let snapshot = VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: path,
                                          cameraMotionBlur: 1, cursor: nil, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
                                          captions: [], captionStyle: VideoCaptionStyle(), webcam: nil)
        let image = VideoSceneRenderer.render(content: solid, time: 1.2, scene: snapshot, censors: [], texts: [])
        assertColor(pixel(image, 200, 100), 204, 102, 51)
    }

    func testCensorObscuresContentAnchoredRect() throws {
        let layout = layout(enabled: false)
        let segment = VideoCensorSegment(startTime: 0, endTime: 5, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                                         style: .solid)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout),
                                              censors: [VideoCensorSnapshot(segment)], texts: [])
        assertColor(pixel(image, 300, 100), 0, 0, 0)
        assertColor(pixel(image, 100, 100), 255, 0, 0)
    }

    /// Builds the single `AnnotationLayerSnapshot` for one annotation drawn
    /// alone in a segment. Defaults to entrance/exit `.none` so it's simply
    /// on or off — most placement tests don't care about the animation
    /// curves; animation tests pass `fadeIn`/`entrance`/`exit` explicitly.
    @MainActor
    private func annotationLayer(_ annotation: Annotation, layout: VideoSceneLayout, start: Double = 1, end: Double = 4,
                                 fadeIn: Double = 0, fadeOut: Double = 0,
                                 entrance: VideoAnnotationSegment.Animation = .none,
                                 exit: VideoAnnotationSegment.Animation = .none) throws -> EffectsCompositionInstruction.AnnotationLayerSnapshot {
        let segment = VideoAnnotationSegment(startTime: start, endTime: end, canvasSize: contentSize,
                                             annotationData: try XCTUnwrap(AnnotationSerializer.encode([annotation])),
                                             fadeIn: fadeIn, fadeOut: fadeOut, entrance: entrance, exit: exit)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let spec = VideoAnnotationRasterizer.spec(for: segment, pixelSize: layout.canvasRect(forContent: full).size)
        let rendered = try XCTUnwrap(VideoAnnotationRasterizer.render(segment, spec))
        let layer = try XCTUnwrap(rendered.layers.first)
        return EffectsCompositionInstruction.AnnotationLayerSnapshot(
            segmentID: segment.id, startTime: start, endTime: end, rect: layer.contentRect,
            image: CIImage(cgImage: layer.image), layerIndex: 0, fadeIn: fadeIn, fadeOut: fadeOut,
            entrance: entrance, exit: exit, stagger: 0, reveal: layer.reveal)
    }

    /// A drawing made over the paused frame lands on the same spot of the
    /// rendered video, and only while its segment is on screen.
    @MainActor
    func testAnnotationDrawingLandsWhereItWasDrawn() throws {
        let layout = layout(enabled: false)
        // Canvas matches the content aspect; AppKit bottom-left origin, so
        // y 150…200 is the top edge — the same corner as the blue marker.
        let square = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 350, y: 150),
                                endPoint: NSPoint(x: 400, y: 200),
                                color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let layer = try annotationLayer(square, layout: layout)

        let shown = VideoSceneRenderer.render(content: content, time: 2, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: [layer])
        assertColor(pixel(shown, 390, 10), 0, 255, 0)
        assertColor(pixel(shown, 10, 10), 0, 0, 255)
        assertColor(pixel(shown, 390, 190), 255, 0, 0)

        let hidden = VideoSceneRenderer.render(content: content, time: 5, scene: scene(layout), censors: [], texts: [],
                                               annotationLayers: [layer])
        assertColor(pixel(hidden, 390, 10), 255, 0, 0)
    }

    /// A `draw` entrance reveals an arrow from its tail: at 50% only the
    /// half nearer the start point is visible.
    @MainActor
    func testDrawEntranceRevealsArrowFromItsStart() throws {
        let layout = layout(enabled: false)
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 20, y: 100), endPoint: NSPoint(x: 380, y: 100),
                               color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 3)
        // fadeIn = 1s over a 0…4s segment (no clamping): sampling at half
        // that (t=0.5) lands exactly on the easeInOut curve's midpoint,
        // where progress == shownness == 0.5 — half the arc length drawn.
        let layer = try annotationLayer(arrow, layout: layout, start: 0, end: 4, fadeIn: 1, entrance: .draw, exit: .none)
        let image = VideoSceneRenderer.render(content: content, time: 0.5, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: [layer])
        assertColor(pixel(image, 60, 100), 0, 255, 0)
        assertColor(pixel(image, 340, 100), 255, 0, 0)
    }

    /// A `draw` entrance on an ellipse sweeps a wedge clockwise from 12
    /// o'clock: at the halfway point the wedge has swept through 3 o'clock
    /// to 6 o'clock, covering the whole right side but none of the left.
    @MainActor
    func testDrawEntranceSweepsEllipseClockwiseFromTop() throws {
        let layout = layout(enabled: false)
        let ellipse = Annotation(tool: .ellipse, startPoint: NSPoint(x: 100, y: 20), endPoint: NSPoint(x: 300, y: 180),
                                 color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 6)
        ellipse.rectFillStyle = .fill
        let layer = try annotationLayer(ellipse, layout: layout, start: 0, end: 4, fadeIn: 1, entrance: .draw, exit: .none)
        let image = VideoSceneRenderer.render(content: content, time: 0.5, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: [layer])
        // Points 60/40 canvas-points off the ellipse's (200, 100) center,
        // well inside its fill. `pixel()` measures from the top of the
        // frame, so a canvas y of 140 (above center, AppKit bottom-left) is
        // `200 - 140 = 60` from the top. Top-right and bottom-right (the
        // swept right half) are revealed; top-left and bottom-left
        // (not yet swept) stay background.
        assertColor(pixel(image, 260, 60), 0, 255, 0)
        assertColor(pixel(image, 260, 140), 0, 255, 0)
        assertColor(pixel(image, 140, 60), 255, 0, 0)
        assertColor(pixel(image, 140, 140), 255, 0, 0)
    }

    /// `pop` scales up from small; mid-entrance is visibly smaller than the
    /// fully-entered size.
    @MainActor
    func testPopEntranceIsSmallerMidway() throws {
        let layout = layout(enabled: false)
        let square = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 150, y: 50),
                                endPoint: NSPoint(x: 250, y: 150),
                                color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        // fadeIn = 1s over 0…4s: sample at 20% of the entrance (s = 0.2,
        // still well before the overshoot peak) — scale is visibly < 1, so
        // pixels near the square's own edge (but outside its shrunk size)
        // stay background-colored, while the untouched center still shows.
        let segment = VideoAnnotationSegment(startTime: 0, endTime: 4, canvasSize: contentSize,
                                             annotationData: try XCTUnwrap(AnnotationSerializer.encode([square])),
                                             fadeIn: 1, fadeOut: 0, entrance: .pop, exit: .none)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let spec = VideoAnnotationRasterizer.spec(for: segment, pixelSize: layout.canvasRect(forContent: full).size)
        let rendered = try XCTUnwrap(VideoAnnotationRasterizer.render(segment, spec))
        let raw = try XCTUnwrap(rendered.layers.first)
        let layer = EffectsCompositionInstruction.AnnotationLayerSnapshot(
            segmentID: segment.id, startTime: 0, endTime: 4, rect: raw.contentRect,
            image: CIImage(cgImage: raw.image), layerIndex: 0, fadeIn: 1, fadeOut: 0,
            entrance: .pop, exit: .none, stagger: 0, reveal: raw.reveal)
        // t = 0.2 → s = 0.2 (20% into the 1s fadeIn).
        let midway = VideoSceneRenderer.render(content: content, time: 0.2, scene: scene(layout), censors: [], texts: [],
                                               annotationLayers: [layer])
        let full1 = VideoSceneRenderer.render(content: content, time: 4, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: [layer])
        // Just inside the square's original top-right corner: fully shown
        // once entered, still background while shrunk around its center.
        assertColor(pixel(full1, 245, 55), 0, 255, 0)
        assertColor(pixel(midway, 245, 55), 255, 0, 0)
    }

    // MARK: - Stage transform (offset/scale/rotation), applied as a group about the drawing's pivot

    /// Builds every `AnnotationLayerSnapshot` for a segment with possibly
    /// several annotations, all sharing the segment's own pivot (the center
    /// of the union of their tight content bounds) and stage transform —
    /// exactly what `VideoRenderPlanner.annotationLayers` produces, without
    /// needing a whole `VideoEditorDocument`.
    @MainActor
    private func annotationLayers(_ annotations: [Annotation], layout: VideoSceneLayout,
                                  offset: CGPoint = .zero, scale: Double = 1, rotation: Double = 0,
                                  start: Double = 0, end: Double = 4) throws -> [EffectsCompositionInstruction.AnnotationLayerSnapshot] {
        let segment = VideoAnnotationSegment(startTime: start, endTime: end, canvasSize: contentSize,
                                             annotationData: try XCTUnwrap(AnnotationSerializer.encode(annotations)),
                                             fadeIn: 0, fadeOut: 0, entrance: .none, exit: .none,
                                             offset: offset, scale: scale, rotation: rotation)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let spec = VideoAnnotationRasterizer.spec(for: segment, pixelSize: layout.canvasRect(forContent: full).size)
        let rendered = try XCTUnwrap(VideoAnnotationRasterizer.render(segment, spec))
        let pivot = try XCTUnwrap(rendered.pivot)
        return rendered.layers.enumerated().map { index, layer in
            EffectsCompositionInstruction.AnnotationLayerSnapshot(
                segmentID: segment.id, startTime: start, endTime: end, rect: layer.contentRect,
                image: CIImage(cgImage: layer.image), layerIndex: index, fadeIn: 0, fadeOut: 0,
                entrance: .none, exit: .none, stagger: 0, reveal: layer.reveal,
                pivot: pivot, offset: segment.offset, scale: segment.scale, rotation: segment.rotation)
        }
    }

    /// `offset` shifts every layer of the drawing by the same amount,
    /// content-normalized (a fraction of the *full* content size) — a
    /// drawing moved 10% of the content width lands exactly 10% of the
    /// content width away on screen, following crop/zoom the same way a
    /// text box's `rect` would.
    @MainActor
    func testOffsetMovesTheDrawingByAContentNormalizedAmount() throws {
        let layout = layout(enabled: false) // contentSize == canvasSize, 1:1 pixels
        let square = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 40, y: 80),
                                endPoint: NSPoint(x: 80, y: 120), // canvas points, bottom-left origin
                                color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let unmoved = try annotationLayers([square], layout: layout)
        let moved = try annotationLayers([square], layout: layout, offset: CGPoint(x: 0.1, y: 0))

        let before = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout), censors: [], texts: [],
                                               annotationLayers: unmoved)
        let after = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: moved)
        // Square center at canvas (60, 100) -> top-left pixel (60, 100).
        // offset.x = 0.1 of the 400-wide content -> +40 canvas pixels.
        assertColor(pixel(before, 60, 100), 0, 255, 0)
        // The square should have moved away from its old spot...
        assertColor(pixel(after, 60, 100), 255, 0, 0)
        // ...and landed 40px to the right.
        assertColor(pixel(after, 100, 100), 0, 255, 0)
    }

    /// `scale` grows every layer of the drawing uniformly about the shared
    /// pivot (the union of the layers' own tight bounds) — not about each
    /// layer's own center — so two annotations move apart from each other,
    /// not just grow individually. Two squares placed symmetrically about a
    /// point double their distance from it at `scale == 2`.
    @MainActor
    func testScaleDoublesExtentAboutTheSharedPivot() throws {
        let layout = layout(enabled: false)
        // Two 40x40 squares, mirrored around canvas point (200, 100) (which
        // is also the exact canvas center here) — their union's pivot lands
        // exactly on that point regardless of the gap between them.
        let left = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 100, y: 80), endPoint: NSPoint(x: 140, y: 120),
                              color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let right = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 260, y: 80), endPoint: NSPoint(x: 300, y: 120),
                               color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let unscaled = try annotationLayers([left, right], layout: layout)
        let scaled = try annotationLayers([left, right], layout: layout, scale: 2)

        let before = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout), censors: [], texts: [],
                                               annotationLayers: unscaled)
        let after = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: scaled)
        // `left`'s center (120, 100) is 80px left of the pivot (200, 100);
        // doubled, it's 160px left -> (40, 100). Still green there, and the
        // original spot is no longer covered by the (now-bigger, but still
        // not reaching back that far) square. `right` mirrors to (360, 100).
        assertColor(pixel(before, 120, 100), 0, 255, 0)
        assertColor(pixel(after, 40, 100), 0, 255, 0)
        assertColor(pixel(after, 360, 100), 0, 255, 0)
    }

    /// A 90° (clockwise, as seen on screen) rotation swings each layer
    /// around the shared pivot: two squares mirrored east/west of the pivot
    /// end up north/south of it (clockwise: north -> east -> south -> west).
    /// Each square is left as an axis-aligned 40x40 box after the turn, so
    /// this checks exact pixels rather than an anti-aliased diagonal edge.
    @MainActor
    func testNinetyDegreeRotationSwingsLayersAroundThePivot() throws {
        let layout = layout(enabled: false)
        let west = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 100, y: 80), endPoint: NSPoint(x: 140, y: 120),
                              color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let east = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 260, y: 80), endPoint: NSPoint(x: 300, y: 120),
                              color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), strokeWidth: 2)
        let rotated = try annotationLayers([west, east], layout: layout, rotation: .pi / 2)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout), censors: [], texts: [],
                                              annotationLayers: rotated)
        // Pivot (200, 100). `west`'s center (120, 100, dx=-80) swings to
        // north of the pivot: (200, 20). `east`'s center (280, 100, dx=+80)
        // swings to south: (200, 180).
        assertColor(pixel(image, 200, 20), 0, 255, 0)
        assertColor(pixel(image, 200, 180), 0, 255, 0)
        // Neither square is anywhere near its old, un-rotated spot anymore.
        assertColor(pixel(image, 120, 100), 255, 0, 0)
        assertColor(pixel(image, 280, 100), 255, 0, 0)
    }

    func testCursorIsDrawnAtItsHotspotAndHonorsVisibility() {
        let layout = layout(enabled: false)
        let white = CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let sprite = CursorSprite(image: white, hotspot: .zero, size: CGSize(width: 10, height: 10))
        let header = CursorTelemetry.Header(sourcePointSize: contentSize, pixelSize: contentSize, frameRate: 30,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        let recording = CursorRecording(header: header, events: [.start(time: 0), .move(time: 0, x: 0.5, y: 0.5)])
        let track = CursorMotion.buildTrack(from: recording, smoothing: 0)
        var style = VideoCursorStyle()
        style.size = 1
        style.motionBlur = 0
        style.pressBounce = false
        style.clickEffect = .none
        func cursorLayer(_ style: VideoCursorStyle) -> VideoCursorLayer {
            VideoCursorLayer(track: track, shapeTimes: [], shapeIDs: [], sprites: [:], fallback: sprite, style: style,
                             pixelsPerPoint: 1, clicks: [], keyTimes: [], rippleSprite: white, ringSprite: white,
                             loopRange: nil)
        }
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout, cursor: cursorLayer(style)),
                                              censors: [], texts: [])
        assertColor(pixel(image, 204, 104), 255, 255, 255)
        assertColor(pixel(image, 196, 96), 255, 0, 0)
        assertColor(pixel(image, 215, 104), 255, 0, 0)
        style.show = false
        let hidden = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout, cursor: cursorLayer(style)),
                                               censors: [], texts: [])
        assertColor(pixel(hidden, 204, 104), 255, 0, 0)
    }

    func testKeystrokeLabelRendersOnScreen() {
        let layout = layout(enabled: false)
        let snapshot = VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: .empty,
                                          cameraMotionBlur: 0, cursor: nil,
                                          keystrokes: [.init(start: 0, end: 5, text: "⌘ C")],
                                          keystrokeStyle: VideoKeystrokeStyle(), captions: [],
                                          captionStyle: VideoCaptionStyle(), webcam: nil)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot, censors: [], texts: [])
        // The pill darkens the bottom center of the red frame.
        let bottom = pixel(image, 200, Int(layout.canvasSize.height) - 16)
        XCTAssertLessThan(Int(bottom[0]), 200)
    }

    func testTextCacheReturnsSameImageForSameLabel() {
        let cache = OverlayTextCache()
        let a = cache.pill(text: "⌘ ⇧ 4", fontSize: 30, maxWidth: 800, light: false, weight: .semibold)
        let b = cache.pill(text: "⌘ ⇧ 4", fontSize: 30, maxWidth: 800, light: false, weight: .semibold)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b)
        XCTAssertNotNil(cache.caption(text: "A caption that is long enough to wrap onto more than one line",
                                      fontSize: 40, maxWidth: 300, background: true))
    }
}

final class VideoIconButtonLayoutTests: XCTestCase {
    /// Highlights fill `bounds`; if the frame outgrows the constrained size,
    /// neighbouring rail buttons' hover and selection fills overlap.
    func testIconButtonFrameMatchesItsConstrainedSize() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        var buttons: [VideoIconButton] = []
        for symbol in ["photo.on.rectangle", "cursorarrow.rays", "plus.magnifyingglass"] {
            let button = VideoIconButton(symbol: symbol, size: 16, tooltip: symbol, target: nil, action: nil)
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 60, height: 300)
        stack.layoutSubtreeIfNeeded()
        for button in buttons { XCTAssertEqual(button.frame.size, NSSize(width: 38, height: 38)) }
        for (upper, lower) in zip(buttons, buttons.dropFirst()) {
            XCTAssertEqual(abs(upper.frame.minY - lower.frame.maxY), 6, accuracy: 0.01, "highlights must not touch")
        }
    }
}
