import AVFoundation
import CoreImage
import ImageIO

/// Turns a project into AVFoundation compositions. Preview and every export
/// use the same planner, so what plays is what saves.
@MainActor
final class VideoRenderPlanner {
    struct Options {
        /// Output scale relative to the native canvas (preview uses < 1).
        var scale: CGFloat = 1
        /// Show the whole canvas with no camera motion (editing spatial items).
        var suspendCamera = false
        /// Crop editing: show the full uncropped recording without a frame.
        var showUncropped = false
        /// Text segment currently being typed inline, hidden from the render.
        var hiddenTextID: UUID?
        /// Annotation segment currently open for editing, hidden from the
        /// render (mirrors `hiddenTextID`; unused until an editing UI needs it).
        var hiddenAnnotationID: UUID?
        /// Exports wait for the exact pointer track instead of showing the
        /// previous one while a long take recomputes.
        var exactPointer = false
    }

    private let document: VideoEditorDocument
    private let art = VideoSceneArtCache()
    private lazy var assets = VideoSceneBuilder.makeAssets(recording: document.recording)
    private var textCache: [UUID: (spec: VideoTextRasterizer.Spec, image: CIImage)] = [:]

    /// One cached per-annotation layer: its image plus the metadata needed
    /// to rebuild an `AnnotationLayerSnapshot` for the segment's current
    /// timing every frame without re-rasterizing.
    private struct AnnotationLayerCache {
        let image: CIImage
        let rect: CGRect
        let reveal: EffectsCompositionInstruction.AnnotationLayerSnapshot.Reveal?
    }
    private struct AnnotationCacheEntry {
        let spec: VideoAnnotationRasterizer.Spec
        let base: CIImage?
        let layers: [AnnotationLayerCache]
        /// Center of the union of `layers`' content rects — the drawing's
        /// pivot for the segment's stage transform. `nil` (falls back to the
        /// canvas center) when there are no per-annotation layers.
        let pivot: CGPoint
    }
    private var annotationCache: [UUID: AnnotationCacheEntry] = [:]
    private var cameraAsset: AVAsset?
    /// Loaded video-overlay assets, keyed by segment id so an in-place file
    /// swap (same id, new `fileName`) reloads rather than reusing a stale asset.
    private var overlayAssets: [UUID: (fileName: String, asset: AVAsset)] = [:]
    /// Decoded still-image overlays, cached by file name (loaded once).
    private var overlayImageCache: [String: CIImage] = [:]

    init(document: VideoEditorDocument) {
        self.document = document
        if let url = document.cameraURL { cameraAsset = AVURLAsset(url: url) }
    }

    var hasCamera: Bool { cameraAsset != nil }

    /// Scene layout of `project` at an output scale.
    func layout(for project: VideoProject, scale: CGFloat = 1, showUncropped: Bool = false) -> VideoSceneLayout? {
        var frame = project.look.frame
        var crop = project.crop
        if showUncropped {
            frame = VideoFrameStyle()
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return VideoSceneGeometry.layout(contentSize: document.contentSize, crop: crop, frame: frame, scale: scale)
    }

    /// Kept source ranges → timeline pieces for a trim range.
    static func pieces(project: VideoProject, from start: Double, to end: Double) -> [VideoSpeeds.Piece] {
        let kept = VideoCuts.keptRanges(trimStart: start, trimEnd: end, cuts: project.cuts)
        return VideoSpeeds.pieces(keptRanges: kept, speeds: project.speeds, freezes: project.freezes)
    }

    func processed(project: VideoProject, from start: Double, to end: Double,
                   includeAudio: Bool) throws -> VideoCompositionBuilder.Result {
        try VideoCompositionBuilder.build(asset: document.asset, pieces: Self.pieces(project: project, from: start, to: end),
                                          includeAudio: includeAudio, sourceFrameDuration: document.frameDuration,
                                          camera: cameraAsset, overlays: videoOverlayInputs(project: project))
    }

    /// Loads (and caches) each video-kind overlay's own media as an asset,
    /// the way `cameraAsset` is loaded once from `document.cameraURL`. Image
    /// overlays don't need a composition track, so they're excluded here.
    private func videoOverlayInputs(project: VideoProject) -> [VideoCompositionBuilder.OverlayInput] {
        var live = Set<UUID>()
        var inputs: [VideoCompositionBuilder.OverlayInput] = []
        for segment in project.overlays where segment.kind == .video {
            guard let url = document.overlayURL(for: segment) else { continue }
            live.insert(segment.id)
            let asset: AVAsset
            if let cached = overlayAssets[segment.id], cached.fileName == segment.fileName {
                asset = cached.asset
            } else {
                asset = AVURLAsset(url: url)
                overlayAssets[segment.id] = (segment.fileName, asset)
            }
            inputs.append(.init(id: segment.id, asset: asset, startTime: segment.startTime,
                                duration: segment.duration, mediaStart: segment.mediaStart))
        }
        for key in Array(overlayAssets.keys) where !live.contains(key) { overlayAssets.removeValue(forKey: key) }
        return inputs
    }

    /// Complete video composition for a processed timeline.
    func videoComposition(project: VideoProject, processed: VideoCompositionBuilder.Result,
                          options: Options, frameDuration: CMTime? = nil,
                          onTrackReady: @escaping () -> Void = {}) throws -> AVMutableVideoComposition {
        guard let layout = layout(for: project, scale: options.scale, showUncropped: options.showUncropped) else {
            throw VideoCompositionRendering.RenderError.invalidGeometry
        }
        let scene = snapshot(project: project, layout: layout, options: options,
                             webcamTrackID: processed.cameraTrack?.trackID, timeMap: processed.timeMap,
                             overlayPlacements: processed.overlayPlacements, onTrackReady: onTrackReady)
        let censors = project.censors.filter { $0.endTime > $0.startTime }.sorted { $0.startTime < $1.startTime }
            .map(VideoCensorSnapshot.init)
        let texts = textSnapshots(project: project, layout: layout, hidden: options.hiddenTextID)
        let annotations = annotationLayers(project: project, layout: layout, hidden: options.hiddenAnnotationID)
        return try VideoCompositionRendering.sceneComposition(asset: processed.composition, track: processed.videoTrack,
            frameDuration: frameDuration ?? document.frameDuration, timeMap: processed.timeMap, scene: scene,
            censorSegments: censors, textSnapshots: texts, annotationLayers: annotations)
    }

    /// Composition over the untouched source asset (no timeline edits). Still
    /// image overlays can render here (their timing is computed straight from
    /// `timeMap`); video overlays need their own composition track and can't
    /// — none will be in `project.overlays` when this path is chosen, since
    /// their presence forces the processed-composition path instead.
    func sourceComposition(project: VideoProject, track: AVAssetTrack,
                           timeMap: [EffectsCompositionInstruction.TimeMapEntry], options: Options,
                           onTrackReady: @escaping () -> Void = {}) throws -> AVMutableVideoComposition {
        guard let layout = layout(for: project, scale: options.scale, showUncropped: options.showUncropped) else {
            throw VideoCompositionRendering.RenderError.invalidGeometry
        }
        let scene = snapshot(project: project, layout: layout, options: options, webcamTrackID: nil,
                             timeMap: timeMap, onTrackReady: onTrackReady)
        let censors = project.censors.filter { $0.endTime > $0.startTime }.sorted { $0.startTime < $1.startTime }
            .map(VideoCensorSnapshot.init)
        let texts = textSnapshots(project: project, layout: layout, hidden: options.hiddenTextID)
        let annotations = annotationLayers(project: project, layout: layout, hidden: options.hiddenAnnotationID)
        return try VideoCompositionRendering.sceneComposition(asset: document.asset, track: track,
            frameDuration: document.frameDuration, timeMap: timeMap, scene: scene,
            censorSegments: censors, textSnapshots: texts, annotationLayers: annotations)
    }

    func snapshot(project: VideoProject, layout: VideoSceneLayout, options: Options,
                  webcamTrackID: CMPersistentTrackID?,
                  timeMap: [EffectsCompositionInstruction.TimeMapEntry] = [],
                  overlayPlacements: [UUID: VideoCompositionBuilder.OverlayPlacement] = [:],
                  onTrackReady: @escaping () -> Void = {}) -> VideoSceneSnapshot {
        let track = options.exactPointer ? document.cursorTrackForExport() : document.cursorTrack(onReady: onTrackReady)
        var webcam: VideoWebcamLayer?
        if let id = webcamTrackID, let cameraTrack = cameraAsset?.tracks(withMediaType: .video).first,
           let upright = VideoRenderGeometry.layout(sourceSize: cameraTrack.naturalSize,
                                                     preferredTransform: cameraTrack.preferredTransform) {
            webcam = VideoWebcamLayer(trackID: id, style: project.look.camera,
                                      uprightTransform: upright.coreImageTransform, uprightSize: upright.uprightSize)
        }
        let overlays = overlayLayers(project: project, timeMap: timeMap, overlayPlacements: overlayPlacements)
        return VideoSceneBuilder.snapshot(project: project, layout: layout, recording: document.recording, track: track,
                                          assets: assets, art: art, directory: document.projectDirectory,
                                          drawsCursor: document.cursorIsEditable && !options.showUncropped,
                                          rendersOverlays: document.overlaysAreEditable,
                                          suspendCamera: options.suspendCamera || options.showUncropped,
                                          webcam: webcam, overlays: overlays)
    }

    /// Media overlays placed and timed like text boxes, but on the
    /// composition clock (see `VideoOverlayLayer`). A video overlay needs a
    /// placement from `VideoCompositionBuilder` (absent when it was cut out,
    /// past the trim, its media was unreadable, or this is the source-only
    /// preview path); a still image only needs `compStart`, found here from
    /// the same `timeMap` the compositor uses the other direction. Either
    /// kind missing its mapping is simply left out — never fails the scene.
    private func overlayLayers(project: VideoProject, timeMap: [EffectsCompositionInstruction.TimeMapEntry],
                               overlayPlacements: [UUID: VideoCompositionBuilder.OverlayPlacement]) -> [VideoOverlayLayer] {
        var liveImages = Set<String>()
        var result: [VideoOverlayLayer] = []
        for segment in project.overlays {
            switch segment.kind {
            case .video:
                guard let placement = overlayPlacements[segment.id],
                      let track = overlayAssets[segment.id]?.asset.tracks(withMediaType: .video).first,
                      let upright = VideoRenderGeometry.layout(sourceSize: track.naturalSize,
                                                               preferredTransform: track.preferredTransform)
                else { continue }
                result.append(VideoOverlayLayer(id: segment.id, trackID: placement.trackID, stillImage: nil,
                    uprightTransform: upright.coreImageTransform, rect: segment.rect, compStart: placement.compStart,
                    duration: segment.duration, opacity: segment.opacity, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut,
                    rotation: segment.rotation))
            case .image:
                guard let compStart = VideoCompositionBuilder.compositionTime(forSource: segment.startTime, timeMap: timeMap),
                      let url = document.overlayURL(for: segment) else { continue }
                liveImages.insert(segment.fileName)
                let image: CIImage
                if let cached = overlayImageCache[segment.fileName] {
                    image = cached
                } else {
                    guard let loaded = Self.loadStillImage(url: url) else { continue }
                    overlayImageCache[segment.fileName] = loaded
                    image = loaded
                }
                result.append(VideoOverlayLayer(id: segment.id, trackID: nil, stillImage: image,
                    uprightTransform: .identity, rect: segment.rect, compStart: compStart, duration: segment.duration,
                    opacity: segment.opacity, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut, rotation: segment.rotation))
            }
        }
        for key in Array(overlayImageCache.keys) where !liveImages.contains(key) { overlayImageCache.removeValue(forKey: key) }
        return result
    }

    /// Decodes a still-image overlay once; loaded on the main actor like the
    /// project's background image (`VideoSceneArtCache`).
    private static func loadStillImage(url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Whether the project has at least one video-kind overlay — these need
    /// their own composition track, so their presence forces the
    /// processed-composition path even with no cuts/speed/freezes/camera.
    static func hasVideoOverlays(project: VideoProject) -> Bool {
        project.overlays.contains { $0.kind == .video }
    }

    /// Text boxes rasterized at their output pixel size (cached per spec).
    func textSnapshots(project: VideoProject, layout: VideoSceneLayout,
                       hidden: UUID?) -> [EffectsCompositionInstruction.TextSnapshot] {
        var result: [EffectsCompositionInstruction.TextSnapshot] = []
        var live = Set<UUID>()
        let referenceHeight = Int((layout.videoRect.height / max(layout.crop.height, 0.01)).rounded())
        for segment in project.texts where segment.endTime > segment.startTime && segment.id != hidden {
            let rect = layout.canvasRect(forContent: segment.rect)
            let spec = VideoTextRasterizer.spec(for: segment, pixelWidth: max(2, Int(rect.width.rounded())),
                                                pixelHeight: max(2, Int(rect.height.rounded())),
                                                renderHeight: max(2, referenceHeight))
            live.insert(segment.id)
            let image: CIImage
            if let cached = textCache[segment.id], cached.spec == spec {
                image = cached.image
            } else {
                guard let cg = VideoTextRasterizer.render(spec) else { continue }
                image = CIImage(cgImage: cg)
                textCache[segment.id] = (spec, image)
            }
            result.append(.init(id: segment.id, startTime: segment.startTime, endTime: segment.endTime,
                                rect: segment.rect, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut, image: image))
        }
        for key in Array(textCache.keys) where !live.contains(key) { textCache.removeValue(forKey: key) }
        return result
    }

    /// Timed screenshot-style annotation overlays (`VideoAnnotationSegment`),
    /// rasterized once per segment and cached like text boxes, then expanded
    /// into one `AnnotationLayerSnapshot` per animated layer: the full-frame
    /// pixelate/blur/highlight base (if present, plain fade, rect = full
    /// content — the `highlight` tool needs to dim the whole frame) first,
    /// then each cropped per-annotation layer in drawing order so entrance
    /// stagger and z-order match what was drawn.
    func annotationLayers(project: VideoProject, layout: VideoSceneLayout,
                         hidden: UUID?) -> [EffectsCompositionInstruction.AnnotationLayerSnapshot] {
        var result: [EffectsCompositionInstruction.AnnotationLayerSnapshot] = []
        var live = Set<UUID>()
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let pixelRect = layout.canvasRect(forContent: full)
        // Guard against pathological sizes: a very tight crop (down to
        // VideoProjectLimits' 5% minimum) blows the *full, uncropped*
        // content rect up far past the canvas. Cap each side at the render
        // ceiling used everywhere else in the pipeline
        // (`VideoSceneGeometry.maxDimension`) instead of attempting a
        // multi-gigabyte CGContext; only that extreme-crop edge case loses
        // sharpness.
        let cap = VideoSceneGeometry.maxDimension
        let pixelSize = CGSize(width: min(cap, max(2, pixelRect.width.rounded())),
                               height: min(cap, max(2, pixelRect.height.rounded())))
        for segment in project.annotations
            where segment.endTime > segment.startTime && segment.id != hidden && !segment.annotationData.isEmpty {
            live.insert(segment.id)
            let spec = VideoAnnotationRasterizer.spec(for: segment, pixelSize: pixelSize)
            let entry: AnnotationCacheEntry
            if let cached = annotationCache[segment.id], cached.spec == spec {
                entry = cached
            } else {
                guard let rendered = VideoAnnotationRasterizer.render(segment, spec) else {
                    annotationCache.removeValue(forKey: segment.id)
                    continue
                }
                let base = rendered.base.map { CIImage(cgImage: $0) }
                let layers = rendered.layers.map {
                    AnnotationLayerCache(image: CIImage(cgImage: $0.image), rect: $0.contentRect, reveal: $0.reveal)
                }
                let pivot = rendered.pivot ?? CGPoint(x: 0.5, y: 0.5)
                entry = AnnotationCacheEntry(spec: spec, base: base, layers: layers, pivot: pivot)
                annotationCache[segment.id] = entry
            }
            if let base = entry.base {
                result.append(.init(segmentID: segment.id, startTime: segment.startTime, endTime: segment.endTime,
                                    rect: full, image: base, layerIndex: 0, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut,
                                    entrance: .fade, exit: .fade, stagger: 0, reveal: nil,
                                    pivot: entry.pivot, offset: segment.offset, scale: segment.scale, rotation: segment.rotation))
            }
            for (index, layer) in entry.layers.enumerated() {
                result.append(.init(segmentID: segment.id, startTime: segment.startTime, endTime: segment.endTime,
                                    rect: layer.rect, image: layer.image, layerIndex: index,
                                    fadeIn: segment.fadeIn, fadeOut: segment.fadeOut,
                                    entrance: segment.entrance, exit: segment.exit, stagger: segment.stagger,
                                    reveal: layer.reveal,
                                    pivot: entry.pivot, offset: segment.offset, scale: segment.scale, rotation: segment.rotation))
            }
        }
        for key in Array(annotationCache.keys) where !live.contains(key) { annotationCache.removeValue(forKey: key) }
        return result
    }

    /// The drawing's pivot (center of the union of its layers' tight content
    /// bounds) and that same union rect, both content-normalized — what the
    /// stage needs to draw/hit-test the annotation's transform handles
    /// without re-rasterizing. Reads the cache `annotationLayers(project:layout:hidden:)`
    /// already populated for this frame; `nil` before the segment has ever
    /// rendered (in practice, always populated once selected — selecting an
    /// annotation seeks to a frame where it's visible).
    func annotationBounds(segmentID: UUID) -> (pivot: CGPoint, contentRect: CGRect)? {
        guard let entry = annotationCache[segmentID] else { return nil }
        let rects = entry.layers.map(\.rect)
        guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return nil }
        return (entry.pivot, union)
    }

    /// Timeline duration after cuts, speed and freezes within the trim.
    static func outputDuration(project: VideoProject) -> Double {
        VideoSpeeds.totalCompositionDuration(pieces(project: project, from: project.trimStart, to: project.trimEnd))
    }
}
