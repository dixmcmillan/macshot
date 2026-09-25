import AVFoundation
import AppKit

/// The preview surface: the rendered canvas centered on a dark stage, with a
/// direct-manipulation overlay for zoom windows, text boxes, blur regions
/// and cropping.
final class VideoStageView: NSView {
    private let document: VideoEditorDocument
    private let playback: VideoEditorPlayback
    private let canvasView = NSView()
    private let playerLayer: AVPlayerLayer
    let overlay: VideoStageOverlay
    private var observerID: UUID?
    private var lastCanvasAspect: CGFloat = 0

    /// Crop editing mode shows the full recording and a crop box.
    var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            var options = playback.options
            options.showUncropped = isCropping
            playback.options = options
            overlay.mode = isCropping ? .crop : .selection
            needsLayout = true
        }
    }

    init(document: VideoEditorDocument, playback: VideoEditorPlayback) {
        self.document = document
        self.playback = playback
        playerLayer = AVPlayerLayer(player: playback.player)
        overlay = VideoStageOverlay(document: document)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = VideoEditorStyle.stage.cgColor

        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor.black.cgColor
        canvasView.layer?.cornerRadius = 3
        canvasView.layer?.masksToBounds = true
        playerLayer.videoGravity = .resize
        playerLayer.frame = canvasView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        canvasView.layer?.addSublayer(playerLayer)
        addSubview(canvasView)
        overlay.stage = self
        addSubview(overlay)

        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.render) || change.contains(.selection) || change.contains(.segments) {
                self.needsLayout = true
                self.overlay.needsDisplay = true
                self.updateCameraSuspension()
            }
        }
        updateCameraSuspension()
    }

    required init?(coder: NSCoder) { fatalError() }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
        overlay.endTextEditing(commit: true)
    }

    /// Canvas aspect for the current mode (uncropped while cropping).
    var layoutForDisplay: VideoSceneLayout? {
        playback.planner.layout(for: document.project, showUncropped: isCropping)
    }

    override func layout() {
        super.layout()
        guard let layout = layoutForDisplay else { return }
        let canvas = layout.canvasSize
        let inset: CGFloat = 28
        let available = bounds.insetBy(dx: inset, dy: inset)
        guard available.width > 10, available.height > 10, canvas.width > 0 else { return }
        let fit = min(available.width / canvas.width, available.height / canvas.height)
        let size = NSSize(width: floor(canvas.width * fit), height: floor(canvas.height * fit))
        let frame = NSRect(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2),
                           width: size.width, height: size.height)
        if canvasView.frame != frame {
            canvasView.frame = frame
            overlay.frame = frame.insetBy(dx: -14, dy: -14)
        }
        // Render the preview at the canvas's on-screen pixel size.
        let backing = window?.backingScaleFactor ?? 2
        let scale = min(1, max(0.1, size.width * backing / canvas.width))
        let rounded = (scale * 20).rounded(.up) / 20
        if abs(playback.previewScale - rounded) > 0.001 { playback.previewScale = rounded }
        overlay.needsDisplay = true
    }

    /// Playback always shows the final result; editing aids appear only while
    /// paused (the convention in Screen Studio, Final Cut and CapCut).
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateCameraSuspension()
            overlay.needsDisplay = true
        }
    }

    /// Paused spatial edits show the whole canvas: the camera would move the
    /// content out from under the handles.
    private func updateCameraSuspension() {
        let spatial: Bool
        switch document.selection {
        case .zoom?, .censor?, .text?, .overlay?, .annotation?: spatial = true
        default: spatial = false
        }
        let suspend = (spatial && !isPlaying) || isCropping
        if playback.options.suspendCamera != suspend {
            var options = playback.options
            options.suspendCamera = suspend
            playback.options = options
        }
    }

    /// Canvas rect within the overlay's coordinate space.
    var canvasRectInOverlay: NSRect {
        convert(canvasView.frame, to: overlay)
    }

    override func mouseDown(with event: NSEvent) {
        // While playing, a click pauses: editing happens on a still frame.
        if isPlaying, !isCropping { playback.pause(); return }
        overlay.endTextEditing(commit: true)
        // Normally `VideoStageOverlay` claims clicks over its own handles/box
        // (including the double-click-to-edit case for annotations). This is
        // a fallback for the rare frame where an annotation is selected but
        // hasn't rasterized yet (`VideoRenderPlanner.annotationBounds`
        // returns nil), so the overlay reports no current item to hit-test.
        if event.clickCount == 2, case .annotation(let id)? = document.selection {
            (window?.windowController as? VideoEditorWindowController)?.editAnnotation(id: id)
            return
        }
        // Clicking the empty stage clears the selection.
        if !isCropping { document.select(nil) }
    }
}

/// Handles and hit-testing for spatial items. Coordinates are normalized to
/// the canvas (top-left origin).
final class VideoStageOverlay: NSView {
    enum Mode { case selection, crop }

    weak var stage: VideoStageView?
    private let document: VideoEditorDocument
    var mode: Mode = .selection { didSet { needsDisplay = true } }

    private enum Handle { case body, n, s, e, w, ne, nw, se, sw, rotate }
    private var drag: (handle: Handle, startRect: CGRect, startPoint: NSPoint)?
    /// Drag state for the rotatable items (annotations, overlays): unlike
    /// `drag`, corner handles scale uniformly about the item's own pivot
    /// instead of resizing freely/aspect-locked, and there's a rotation
    /// handle. Model values are captured once at mouse-down and every
    /// `mouseDragged` recomputes an absolute new value from them (never
    /// accumulates deltas), matching how `drag`'s `startRect` is used.
    private var rotatableDrag: (handle: Handle, startPoint: NSPoint, startViewRect: CGRect, startRotation: CGFloat,
                                annotationPivotContent: CGPoint?, annotationStartOffset: CGPoint,
                                annotationStartScale: Double, overlayStartRect: CGRect)?
    /// How far above the box's rotated top edge the rotation handle floats.
    private static let rotationHandleDistance: CGFloat = 26
    private var textEditor: InlineVideoTextView?
    private var textEditorScroll: NSScrollView?
    private var editingTextID: UUID?

    init(document: VideoEditorDocument) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks act immediately even when the editor window is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var layout: VideoSceneLayout? { stage?.layoutForDisplay }
    private var canvasRect: NSRect { stage?.canvasRectInOverlay ?? bounds }

    private func viewRect(normalized r: CGRect) -> NSRect {
        let c = canvasRect
        return NSRect(x: c.minX + r.minX * c.width, y: c.minY + r.minY * c.height,
                      width: r.width * c.width, height: r.height * c.height)
    }

    private func normalized(viewRect r: NSRect) -> CGRect {
        let c = canvasRect
        return CGRect(x: (r.minX - c.minX) / c.width, y: (r.minY - c.minY) / c.height,
                      width: r.width / c.width, height: r.height / c.height)
    }

    /// The edited item's un-rotated box, in normalized canvas coordinates,
    /// plus its rotation if it has one. `rotation == nil` (zoom, censor,
    /// text, crop) keeps the plain rect-based drawing/hit-testing/dragging
    /// below unchanged; annotations and overlays go through the rotatable
    /// path instead, with only corner (uniform-scale) handles — no free or
    /// edge resize — plus a rotation handle.
    private struct EditedItem {
        var rect: CGRect
        var color: NSColor
        var label: String
        var rotation: CGFloat?
    }

    private var stagePlanner: VideoRenderPlanner? { stagePlayback?.planner }

    private func currentItem() -> EditedItem? {
        guard let layout else { return nil }
        let canvas = layout.canvasSize
        func sceneRect(forContent r: CGRect) -> CGRect {
            let pixels = layout.canvasRect(forContent: r)
            return CGRect(x: pixels.minX / canvas.width, y: pixels.minY / canvas.height,
                          width: pixels.width / canvas.width, height: pixels.height / canvas.height)
        }
        if mode == .crop {
            return EditedItem(rect: document.project.crop, color: VideoEditorStyle.accent, label: L("Crop"), rotation: nil)
        }
        let p = document.project
        switch document.selection {
        case .zoom(let id)?:
            guard let z = p.zooms.first(where: { $0.id == id }) else { return nil }
            let f = CameraState.clampedFocus(layout.sceneNormalized(forContent: z.center), zoom: z.zoomLevel)
            let side = 1 / z.zoomLevel
            let label = z.followsCursor ? String(format: L("%.1f× · follows pointer"), z.zoomLevel)
                                        : String(format: "%.1f×", z.zoomLevel)
            return EditedItem(rect: CGRect(x: f.x - side / 2, y: f.y - side / 2, width: side, height: side),
                              color: VideoEditorStyle.zoom, label: label, rotation: nil)
        case .censor(let id)?:
            guard let c = p.censors.first(where: { $0.id == id }) else { return nil }
            return EditedItem(rect: sceneRect(forContent: c.rect), color: VideoEditorStyle.censor, label: "", rotation: nil)
        case .text(let id)?:
            guard let t = p.texts.first(where: { $0.id == id }) else { return nil }
            return EditedItem(rect: sceneRect(forContent: t.rect), color: VideoEditorStyle.text, label: "", rotation: nil)
        case .overlay(let id)?:
            guard let o = p.overlays.first(where: { $0.id == id }) else { return nil }
            return EditedItem(rect: sceneRect(forContent: o.rect), color: VideoEditorStyle.overlay, label: "",
                              rotation: CGFloat(o.rotation))
        case .annotation(let id)?:
            guard let seg = p.annotations.first(where: { $0.id == id }),
                  let bounds = stagePlanner?.annotationBounds(segmentID: id) else { return nil }
            // The drawing's current (offset-shifted) pivot and (scale-grown)
            // box, both still content-normalized — `sceneRect` below carries
            // them through crop/camera the same affine way any other rect
            // gets placed, so the scaling here is safe (it isn't a rotation,
            // which would need pixel space — see `VideoSceneRenderer`).
            let pivot = CGPoint(x: bounds.pivot.x + seg.offset.x, y: bounds.pivot.y + seg.offset.y)
            let scale = CGFloat(seg.scale)
            let box = CGRect(x: pivot.x - bounds.contentRect.width * scale / 2, y: pivot.y - bounds.contentRect.height * scale / 2,
                             width: bounds.contentRect.width * scale, height: bounds.contentRect.height * scale)
            return EditedItem(rect: sceneRect(forContent: box), color: VideoEditorStyle.accent, label: "",
                              rotation: CGFloat(seg.rotation))
        default:
            return nil
        }
    }

    /// Zoom windows keep the canvas's aspect, resizing uniformly from corner
    /// handles about the opposite corner. `nil` means free (unconstrained)
    /// resizing (censor, text). Annotations and overlays never reach this —
    /// they're rotatable, so `currentItem()` returns non-nil `rotation` and
    /// the corner-handle behavior comes from `RotatedBoxEditing` instead.
    private var lockedAspect: CGFloat? {
        guard mode == .selection, case .zoom? = document.selection else { return nil }
        return 1
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !hidesForPlayback, let item = currentItem() else { return }
        let r = viewRect(normalized: item.rect)
        if mode == .crop || (document.selection.map { if case .zoom = $0 { return true }; return false } ?? false) {
            // Dim everything outside the box.
            let outside = NSBezierPath(rect: canvasRect)
            outside.append(NSBezierPath(rect: r).reversed)
            NSColor(white: 0, alpha: 0.45).setFill()
            outside.fill()
        }
        if let rotation = item.rotation {
            let corners = RotatedBoxEditing.corners(of: r, rotation: rotation)
            let border = NSBezierPath()
            border.move(to: corners[0])
            for c in corners.dropFirst() { border.line(to: c) }
            border.close()
            border.lineWidth = 2
            item.color.setStroke()
            border.stroke()
            // Stem connecting the rotated top edge's midpoint to the
            // rotation handle, so the handle reads as part of the box.
            let topMid = RotatedBoxEditing.rotate(NSPoint(x: r.midX, y: r.minY), around: RotatedBoxEditing.center(of: r), by: rotation)
            let handle = RotatedBoxEditing.rotationHandlePosition(for: r, rotation: rotation, distance: Self.rotationHandleDistance)
            let stem = NSBezierPath()
            stem.move(to: topMid)
            stem.line(to: handle)
            stem.lineWidth = 1.5
            item.color.setStroke()
            stem.stroke()
            for (handleKind, point) in rotatableHandlePoints(for: r, rotation: rotation) {
                let radius: CGFloat = handleKind == .rotate ? 6 : 5
                let knob = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: knob).fill()
                item.color.setStroke()
                let ring = NSBezierPath(ovalIn: knob)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        } else {
            let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 2
            item.color.setStroke()
            border.stroke()
            if mode == .crop {
                // Rule-of-thirds guides.
                let guides = NSBezierPath()
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    guides.move(to: NSPoint(x: x, y: r.minY)); guides.line(to: NSPoint(x: x, y: r.maxY))
                    guides.move(to: NSPoint(x: r.minX, y: y)); guides.line(to: NSPoint(x: r.maxX, y: y))
                }
                NSColor(white: 1, alpha: 0.3).setStroke()
                guides.lineWidth = 1
                guides.stroke()
            }
            for (_, point) in handles(for: r) {
                let knob = NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: knob).fill()
                item.color.setStroke()
                let ring = NSBezierPath(ovalIn: knob)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
        if !item.label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: VideoEditorStyle.font(11, .semibold), .foregroundColor: NSColor.white]
            let size = (item.label as NSString).size(withAttributes: attrs)
            let badge = NSRect(x: r.minX, y: max(canvasRect.minY, r.minY - size.height - 10), width: size.width + 14, height: size.height + 6)
            item.color.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            (item.label as NSString).draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + 3), withAttributes: attrs)
        }
    }

    private func handles(for r: NSRect) -> [(Handle, NSPoint)] {
        var result: [(Handle, NSPoint)] = [(.nw, NSPoint(x: r.minX, y: r.minY)), (.ne, NSPoint(x: r.maxX, y: r.minY)),
                                           (.sw, NSPoint(x: r.minX, y: r.maxY)), (.se, NSPoint(x: r.maxX, y: r.maxY))]
        if lockedAspect == nil {
            result += [(.n, NSPoint(x: r.midX, y: r.minY)), (.s, NSPoint(x: r.midX, y: r.maxY)),
                       (.w, NSPoint(x: r.minX, y: r.midY)), (.e, NSPoint(x: r.maxX, y: r.midY))]
        }
        return result
    }

    /// Corner (uniform-scale) handles at their rotated positions, plus the
    /// rotation handle — the full handle set for annotations and overlays.
    private func rotatableHandlePoints(for r: NSRect, rotation: CGFloat) -> [(Handle, NSPoint)] {
        let corners = RotatedBoxEditing.corners(of: r, rotation: rotation)
        return [(.nw, corners[0]), (.ne, corners[1]), (.se, corners[2]), (.sw, corners[3]),
                (.rotate, RotatedBoxEditing.rotationHandlePosition(for: r, rotation: rotation, distance: Self.rotationHandleDistance))]
    }

    // MARK: Input

    /// Handles are hidden during playback, where the camera moves the content.
    private var hidesForPlayback: Bool { mode == .selection && stage?.isPlaying == true }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if hidesForPlayback { return nil }
        let local = convert(point, from: superview)
        if let textEditorScroll, textEditorScroll.frame.contains(local) { return super.hitTest(point) }
        guard let item = currentItem() else { return nil }
        let r = viewRect(normalized: item.rect)
        if let rotation = item.rotation {
            if RotatedBoxEditing.contains(local, in: r.insetBy(dx: -8, dy: -8), rotation: rotation) { return self }
            let handle = RotatedBoxEditing.rotationHandlePosition(for: r, rotation: rotation, distance: Self.rotationHandleDistance)
            return hypot(handle.x - local.x, handle.y - local.y) < 12 ? self : nil
        }
        return r.insetBy(dx: -8, dy: -8).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let item = currentItem() else { return }
        if event.clickCount == 2 {
            if case .text(let id)? = document.selection { beginTextEditing(id: id); return }
            // Double-clicking a selected drawing opens it for editing
            // instead of moving/scaling/rotating it.
            if case .annotation(let id)? = document.selection {
                (window?.windowController as? VideoEditorWindowController)?.editAnnotation(id: id)
                return
            }
        }
        window?.makeFirstResponder(self)
        let r = viewRect(normalized: item.rect)
        if let rotation = item.rotation {
            let handle = rotatableHandlePoints(for: r, rotation: rotation).first { hypot($0.1.x - p.x, $0.1.y - p.y) < 10 }?.0
                ?? (RotatedBoxEditing.contains(p, in: r, rotation: rotation) ? .body : nil)
            guard let handle else { return }
            var pivotContent: CGPoint?
            var startOffset = CGPoint.zero, startScale = 1.0, overlayStartRect = CGRect.zero
            switch document.selection {
            case .annotation(let id)?:
                if let seg = document.project.annotations.first(where: { $0.id == id }) {
                    startOffset = seg.offset; startScale = seg.scale
                }
                pivotContent = stagePlanner?.annotationBounds(segmentID: id)?.pivot
            case .overlay(let id)?:
                if let o = document.project.overlays.first(where: { $0.id == id }) { overlayStartRect = o.rect }
            default: break
            }
            rotatableDrag = (handle: handle, startPoint: p, startViewRect: r, startRotation: rotation,
                             annotationPivotContent: pivotContent, annotationStartOffset: startOffset,
                             annotationStartScale: startScale, overlayStartRect: overlayStartRect)
            document.beginGesture()
            return
        }
        let handle = handles(for: r).first { hypot($0.1.x - p.x, $0.1.y - p.y) < 9 }?.0 ?? .body
        drag = (handle, item.rect, p)
        document.beginGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let rd = rotatableDrag {
            applyRotatableDrag(rd, to: p, snap: event.modifierFlags.contains(.shift))
            needsDisplay = true
            return
        }
        guard let drag else { return }
        let c = canvasRect
        let dx = (p.x - drag.startPoint.x) / c.width, dy = (p.y - drag.startPoint.y) / c.height
        var r = drag.startRect
        switch drag.handle {
        case .body:
            r.origin.x += dx; r.origin.y += dy
            r.origin.x = min(max(0, r.origin.x), 1 - r.width)
            r.origin.y = min(max(0, r.origin.y), 1 - r.height)
        default:
            r = resized(drag.startRect, handle: drag.handle, dx: dx, dy: dy)
        }
        apply(r, moved: drag.handle == .body)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if rotatableDrag != nil {
            rotatableDrag = nil
            document.endGesture()
            return
        }
        guard drag != nil else { return }
        drag = nil
        document.endGesture()
    }

    /// One drag on a rotatable item's corner (uniform scale about its own
    /// pivot), rotation handle, or body (move) — recomputed as an absolute
    /// new value from the captured mouse-down state every call, never
    /// accumulated, matching `resized`'s pattern for the non-rotatable path.
    private func applyRotatableDrag(_ rd: (handle: Handle, startPoint: NSPoint, startViewRect: CGRect, startRotation: CGFloat,
                                          annotationPivotContent: CGPoint?, annotationStartOffset: CGPoint,
                                          annotationStartScale: Double, overlayStartRect: CGRect),
                                    to p: NSPoint, snap: Bool) {
        let center = RotatedBoxEditing.center(of: rd.startViewRect)
        switch rd.handle {
        case .rotate:
            applyRotation(Double(RotatedBoxEditing.rotation(fromCenter: center, to: p, snap: snap)))
        case .body:
            let c = canvasRect
            applyMove(rd, dxScene: (p.x - rd.startPoint.x) / c.width, dyScene: (p.y - rd.startPoint.y) / c.height)
        case .nw, .ne, .se, .sw:
            let corners = RotatedBoxEditing.corners(of: rd.startViewRect, rotation: rd.startRotation)
            let originalCorner: NSPoint
            switch rd.handle {
            case .nw: originalCorner = corners[0]
            case .ne: originalCorner = corners[1]
            case .se: originalCorner = corners[2]
            default: originalCorner = corners[3]
            }
            applyScale(rd, factor: RotatedBoxEditing.cornerDragScale(pivot: center, originalCorner: originalCorner,
                                                                     draggedPoint: p, range: 0.1...10))
        default:
            break
        }
    }

    private func applyMove(_ rd: (handle: Handle, startPoint: NSPoint, startViewRect: CGRect, startRotation: CGFloat,
                                  annotationPivotContent: CGPoint?, annotationStartOffset: CGPoint,
                                  annotationStartScale: Double, overlayStartRect: CGRect),
                           dxScene: CGFloat, dyScene: CGFloat) {
        guard let layout else { return }
        let startScene = normalized(viewRect: rd.startViewRect)
        let newCenterScene = CGPoint(x: startScene.midX + dxScene, y: startScene.midY + dyScene)
        switch document.selection {
        case .overlay(let id)?:
            let newRect = CGRect(x: startScene.minX + dxScene, y: startScene.minY + dyScene,
                                 width: startScene.width, height: startScene.height)
            let a = layout.contentNormalized(forScene: CGPoint(x: newRect.minX, y: newRect.minY))
            let b = layout.contentNormalized(forScene: CGPoint(x: newRect.maxX, y: newRect.maxY))
            document.edit([.render]) { project in
                project.overlays.first { $0.id == id }?.rect =
                    VideoProjectLimits.normalizedRect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
            }
        case .annotation(let id)?:
            guard let pivot = rd.annotationPivotContent else { return }
            let newCenterContent = layout.contentNormalized(forScene: newCenterScene)
            document.edit([.render]) { project in
                project.annotations.first { $0.id == id }?.offset =
                    CGPoint(x: newCenterContent.x - pivot.x, y: newCenterContent.y - pivot.y)
            }
        default:
            break
        }
    }

    private func applyScale(_ rd: (handle: Handle, startPoint: NSPoint, startViewRect: CGRect, startRotation: CGFloat,
                                   annotationPivotContent: CGPoint?, annotationStartOffset: CGPoint,
                                   annotationStartScale: Double, overlayStartRect: CGRect),
                            factor: Double) {
        switch document.selection {
        case .overlay(let id)?:
            document.edit([.render]) { project in
                project.overlays.first { $0.id == id }?.rect =
                    VideoProjectLimits.normalizedRect(VideoOverlayEditing.scaledRect(rd.overlayStartRect, by: CGFloat(factor)))
            }
        case .annotation(let id)?:
            document.edit([.render]) { project in
                project.annotations.first { $0.id == id }?.scale =
                    VideoAnnotationSegment.clampedScale(rd.annotationStartScale * factor)
            }
        default:
            break
        }
    }

    private func applyRotation(_ radians: Double) {
        switch document.selection {
        case .overlay(let id)?:
            document.edit([.render]) { project in project.overlays.first { $0.id == id }?.rotation = radians }
        case .annotation(let id)?:
            document.edit([.render]) { project in project.annotations.first { $0.id == id }?.rotation = radians }
        default:
            break
        }
    }

    // MARK: Arrow-key nudge

    /// Nudges the selected annotation/overlay by 1 source pixel (Shift: 10).
    /// Left/right arrows are already bound to frame-step/seek at the editor
    /// window level (`VideoEditorWindowController.handleKeyDown`), so this
    /// only claims them while a spatial item is selected *and* the stage
    /// itself is first responder — `handleKeyDown` checks both before this
    /// ever runs, exactly like `VideoTimelineView`'s own `keyDown` claims
    /// Delete only while the timeline has focus. Per CLAUDE.md, arrows are
    /// compared by raw `keyCode` (layout-independent), not character.
    func nudgeSelection(keyCode: UInt16, shift: Bool) -> Bool {
        guard let layout, let selection = document.selection else { return false }
        let amountSourcePixels: CGFloat = shift ? 10 : 1
        guard let sourceDelta = RotatedBoxEditing.nudge(forArrowKeyCode: keyCode, amount: amountSourcePixels) else { return false }
        // 1 source pixel -> content-normalized fraction of the content size.
        let deltaContent = CGPoint(x: sourceDelta.x / max(layout.contentSize.width, 1),
                                   y: sourceDelta.y / max(layout.contentSize.height, 1))
        switch selection {
        case .annotation(let id):
            document.beginGesture()
            document.edit([.render]) { project in
                guard let seg = project.annotations.first(where: { $0.id == id }) else { return }
                seg.offset = CGPoint(x: seg.offset.x + deltaContent.x, y: seg.offset.y + deltaContent.y)
            }
            document.endGesture()
            return true
        case .overlay(let id):
            document.beginGesture()
            document.edit([.render]) { project in
                guard let o = project.overlays.first(where: { $0.id == id }) else { return }
                o.rect = VideoProjectLimits.normalizedRect(o.rect.offsetBy(dx: deltaContent.x, dy: deltaContent.y))
            }
            document.endGesture()
            return true
        default:
            return false
        }
    }

    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .n: minY += dy
        case .s: maxY += dy
        case .w: minX += dx
        case .e: maxX += dx
        case .nw: minX += dx; minY += dy
        case .ne: maxX += dx; minY += dy
        case .sw: minX += dx; maxY += dy
        case .se: maxX += dx; maxY += dy
        case .body, .rotate: break
        }
        if let aspect = lockedAspect {
            // Resize uniformly about the opposite (anchor) corner, at the
            // locked aspect ratio (1 = the canvas's own, for zoom windows;
            // the media's, for overlays).
            let anchor: CGPoint, free: CGPoint
            switch handle {
            case .nw: anchor = CGPoint(x: maxX, y: maxY); free = CGPoint(x: minX, y: minY)
            case .ne: anchor = CGPoint(x: minX, y: maxY); free = CGPoint(x: maxX, y: minY)
            case .sw: anchor = CGPoint(x: maxX, y: minY); free = CGPoint(x: minX, y: maxY)
            default: anchor = CGPoint(x: minX, y: minY); free = CGPoint(x: maxX, y: maxY)
            }
            let corrected = VideoOverlayEditing.aspectLockedCorner(anchor: anchor, freeCorner: free, aspect: aspect)
            switch handle {
            case .nw: minX = corrected.x; minY = corrected.y
            case .ne: maxX = corrected.x; minY = corrected.y
            case .sw: minX = corrected.x; maxY = corrected.y
            default: maxX = corrected.x; maxY = corrected.y
            }
        }
        let minSize: CGFloat = 0.03
        minX = max(0, min(minX, maxX - minSize)); minY = max(0, min(minY, maxY - minSize))
        maxX = min(1, max(maxX, minX + minSize)); maxY = min(1, max(maxY, minY + minSize))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Writes a normalized canvas rect back to the selected item.
    private func apply(_ rect: CGRect, moved: Bool = false) {
        guard let layout else { return }
        let canvas = layout.canvasSize
        func contentRect(_ r: CGRect) -> CGRect {
            let a = layout.contentNormalized(forScene: CGPoint(x: r.minX, y: r.minY))
            let b = layout.contentNormalized(forScene: CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        _ = canvas
        if mode == .crop {
            document.edit([.render]) { $0.crop = VideoProjectLimits.normalizedRect(rect) }
            return
        }
        switch document.selection {
        case .zoom(let id)?:
            document.edit([.render, .segments]) { project in
                guard let z = project.zooms.first(where: { $0.id == id }) else { return }
                let side = max(rect.width, rect.height, 0.0001)
                z.zoomLevel = min(VideoZoomSegment.maxZoom, max(VideoZoomSegment.minZoom, 1 / side))
                let f = CameraState.clampedFocus(CGPoint(x: rect.midX, y: rect.midY), zoom: z.zoomLevel)
                let c = layout.contentNormalized(forScene: f)
                z.center = CGPoint(x: min(1, max(0, c.x)), y: min(1, max(0, c.y)))
                // Moving the frame means "look here": pin it.
                if moved { z.followsCursor = false; z.isAutomatic = false }
            }
        case .censor(let id)?:
            document.edit([.render]) { project in
                project.censors.first { $0.id == id }?.rect = VideoCensorSegment.clampedRect(contentRect(rect))
            }
        case .text(let id)?:
            document.edit([.render]) { project in
                project.texts.first { $0.id == id }?.rect = VideoTextSegment.clampedRect(contentRect(rect))
            }
        // Overlays are rotatable (see `currentItem()`/`rotatableDrag`) and
        // never reach this rect-only path.
        default:
            break
        }
    }

    // MARK: Inline text editing

    func beginTextEditing(id: UUID) {
        endTextEditing(commit: true)
        guard let segment = document.project.texts.first(where: { $0.id == id }),
              let item = currentItem(), let layout else { return }
        let frame = viewRect(normalized: item.rect)
        let displayedVideoHeight = canvasRect.height * (layout.videoRect.height / max(layout.crop.height, 0.01))
            / layout.canvasSize.height
        let fontSize = max(8, min(segment.fontSize * displayedVideoHeight / 1080, frame.height * 0.78))
        let font = VideoTextRasterizer.font(family: segment.fontFamily, size: fontSize, bold: segment.bold, italic: segment.italic)
        let paragraph = NSMutableParagraphStyle()
        switch segment.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        let color = NSColor(srgbRed: segment.textColor.r, green: segment.textColor.g, blue: segment.textColor.b,
                            alpha: segment.textColor.a)
        let scroll = NSScrollView(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.borderColor = VideoEditorStyle.text.cgColor
        scroll.layer?.borderWidth = 1.5
        scroll.layer?.cornerRadius = 4
        scroll.contentView.drawsBackground = false
        let textView = InlineVideoTextView(frame: NSRect(origin: .zero, size: frame.size))
        textView.isRichText = false
        textView.allowsUndo = true
        // Match the rendered box; without one, a translucent backing keeps
        // light text readable over any content while typing.
        textView.drawsBackground = true
        textView.backgroundColor = segment.bgStyle != .none
            ? NSColor(srgbRed: segment.bgColor.r, green: segment.bgColor.g, blue: segment.bgColor.b,
                      alpha: max(0.55, segment.bgColor.a))
            : NSColor(white: 0, alpha: 0.45)
        textView.font = font
        textView.textColor = color
        textView.alignment = paragraph.alignment
        textView.insertionPointColor = VideoEditorStyle.text
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        textView.string = segment.text
        textView.horizontalTextInset = max(2, fontSize * 0.18)
        textView.onCommit = { [weak self] in self?.endTextEditing(commit: true) }
        textView.onCancel = { [weak self] in self?.endTextEditing(commit: false) }
        textView.selectAll(nil)
        scroll.documentView = textView
        addSubview(scroll)
        textEditor = textView
        textEditorScroll = scroll
        editingTextID = id
        if var options = stageOptions {
            options.hiddenTextID = id
            setStageOptions(options)
        }
        window?.makeFirstResponder(textView)
    }

    private var stageOptions: VideoRenderPlanner.Options? { stagePlayback?.options }
    private var stagePlayback: VideoEditorPlayback? { (window?.windowController as? VideoEditorWindowController)?.playback }
    private func setStageOptions(_ options: VideoRenderPlanner.Options) { stagePlayback?.options = options }

    func endTextEditing(commit: Bool) {
        guard let id = editingTextID, let textView = textEditor else { return }
        let text = textView.string
        editingTextID = nil
        textView.discardUndoHistory()
        textEditorScroll?.removeFromSuperview()
        textEditor = nil
        textEditorScroll = nil
        if var options = stageOptions {
            options.hiddenTextID = nil
            setStageOptions(options)
        }
        if commit, document.project.texts.first(where: { $0.id == id })?.text != text {
            document.edit([.render, .segments]) { project in
                project.texts.first { $0.id == id }?.text = text
            }
        }
        window?.makeFirstResponder(window?.contentView)
    }
}

/// Inline editor for text overlays. Return commits (Shift-Return inserts a
/// newline), Escape cancels.
final class InlineVideoTextView: ScopedUndoTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var horizontalTextInset: CGFloat = 0 { didSet { centerTextVertically() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerTextVertically()
    }

    override func didChangeText() {
        super.didChangeText()
        centerTextVertically()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
            onCommit?()
            return
        }
        if selector == #selector(cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onCommit?() } }
        return result
    }

    func centerTextVertically() {
        guard let container = textContainer, let manager = layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        textContainerInset = NSSize(width: horizontalTextInset, height: max(0, floor((bounds.height - used) / 2)))
    }
}
