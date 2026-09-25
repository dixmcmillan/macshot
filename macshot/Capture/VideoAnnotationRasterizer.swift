import AppKit

/// Rasterizes one `VideoAnnotationSegment`'s screenshot-style drawing
/// (pencil, arrows, shapes, text, stamps, censors, …) for the animated video
/// renderer. Each user annotation becomes its own small, tightly-cropped
/// layer so it can pop/slide/draw-on independently and in the drawing's own
/// z-order; `pixelate`/`blur`/`highlight` (whose dimming needs the whole
/// frame — see `Annotation.drawHighlightDim`) are flattened into one
/// full-frame "base" layer instead, drawn first and always a plain fade.
///
/// Main-actor only: `Annotation.draw(in:)` is AppKit drawing (NSBezierPath,
/// NSGraphicsContext.current, NSImage), same constraint as
/// `VideoTextRasterizer.render`.
@MainActor
enum VideoAnnotationRasterizer {

    /// Snapshot of inputs that affect the rendered pixels. `annotationData`
    /// can carry baked pixelate/stamp/text images, so the cache key hashes
    /// it (count + hash) instead of holding/comparing a copy — like
    /// `VideoTextRasterizer.Spec`, two specs that compare equal are assumed
    /// to produce identical pixels.
    struct Spec: Hashable {
        let dataCount: Int
        let dataHash: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func spec(for segment: VideoAnnotationSegment, pixelSize: CGSize) -> Spec {
        Spec(dataCount: segment.annotationData.count, dataHash: segment.annotationData.hashValue,
             pixelWidth: max(1, Int(pixelSize.width.rounded())), pixelHeight: max(1, Int(pixelSize.height.rounded())))
    }

    /// One rendered layer: a small cropped image, where it sits in the
    /// segment's content rect, and (for tools that trace on) the reveal
    /// geometry in the image's own pixel space.
    struct Layer {
        let image: CGImage
        /// Content-normalized rect (top-left) this crop covers.
        let contentRect: CGRect
        let reveal: EffectsCompositionInstruction.AnnotationLayerSnapshot.Reveal?
    }

    struct RenderResult {
        /// Full-frame pixelate/blur/highlight composite; nil if none of
        /// those tools are present in the segment.
        let base: CGImage?
        /// Per-annotation layers, in drawing (z) order.
        let layers: [Layer]

        /// Center of the union of `layers`' tight content bounds — the
        /// pivot the stage rotates/scales the whole drawing about. `base`
        /// (full-frame) is deliberately excluded: its rect is always the
        /// whole canvas, which would make the union (and so the pivot)
        /// degenerate to the canvas center regardless of what was drawn.
        /// `nil` when there are no per-annotation layers (a bare censor).
        var pivot: CGPoint? { Self.unionContentRect(of: layers).map { CGPoint(x: $0.midX, y: $0.midY) } }

        /// Content-normalized union of `layers`' content rects. Exposed
        /// (rather than kept private) so the stage can compute the same
        /// pivot/bounding box without re-rasterizing.
        static func unionContentRect(of layers: [Layer]) -> CGRect? {
            layers.dropFirst().reduce(layers.first?.contentRect) { $0?.union($1.contentRect) }
        }
    }

    /// Rasterize every user-drawn annotation in `segment`, split into the
    /// full-frame base layer plus one small layer per remaining annotation.
    /// Returns nil for a degenerate size or a drawing with nothing left to
    /// render.
    ///
    /// Per-tool support (screenshot editor tools that can appear in a video
    /// annotation segment):
    /// - pencil, line, arrow, rectangle, filledRectangle, ellipse, marker,
    ///   number, measure, highlight: draw from stored geometry only — render
    ///   correctly with no external state.
    /// - text, stamp: draw a pre-rendered `NSImage` snapshot captured at
    ///   commit time (`textImage`/`stampImage`) — round-trips through
    ///   `AnnotationSerializer` and renders correctly.
    /// - pixelate, blur: draw the baked censor result (`bakedBlurNSImage`),
    ///   which the editor bakes from the source frame on commit and
    ///   persists — renders correctly as long as the segment was committed
    ///   (matches `bakePixelate()`'s contract).
    /// - loupe: `Annotation.toCodable()` intentionally drops
    ///   `bakedBlurNSImage` for this tool ("needs re-baking from the
    ///   editor's source image") and `sourceImage`/`sourceImageBounds` are
    ///   transient, never serialized. A decoded loupe annotation therefore
    ///   draws its ring/shadow chrome but an empty (transparent) lens — it
    ///   cannot show magnified content without a live source image. This is
    ///   a model limitation, not something fixable from the render side.
    static func render(_ segment: VideoAnnotationSegment, _ spec: Spec) -> RenderResult? {
        guard spec.pixelWidth > 0, spec.pixelHeight > 0 else { return nil }

        // `.select`/`.translateOverlay` mark non-drawable/interaction-only
        // content. The screenshot editor already excludes them the same way
        // before persisting annotation data — see
        // `DetachedEditorWindowController.currentAnnotationData`. Filtering
        // here too is a cheap defensive match to that convention.
        let annotations = segment.annotations.filter(\.isMovable)
        guard !annotations.isEmpty else { return nil }

        let baseTools = annotations.filter { $0.tool == .pixelate || $0.tool == .blur || $0.tool == .highlight }
        let layerTools = annotations.filter { !($0.tool == .pixelate || $0.tool == .blur || $0.tool == .highlight) }

        let sx = CGFloat(spec.pixelWidth) / max(segment.canvasSize.width, 1)
        let sy = CGFloat(spec.pixelHeight) / max(segment.canvasSize.height, 1)
        let bounds = NSRect(origin: .zero, size: segment.canvasSize)

        // One reusable full-frame scratch context for finding each
        // annotation's alpha bounds, instead of allocating N of them.
        guard let scratch = makeContext(width: spec.pixelWidth, height: spec.pixelHeight, sx: sx, sy: sy) else { return nil }

        var base: CGImage?
        if !baseTools.isEmpty {
            clear(scratch, width: spec.pixelWidth, height: spec.pixelHeight)
            withNSGraphicsContext(scratch) { nsCtx in
                // Same layering as the screenshot editor's own flattening
                // pass (`OverlayView.compositedImage`): pixelate censors
                // first, then one union highlight dim, then the highlight
                // borders / legacy blur pixels.
                for a in baseTools where a.tool == .pixelate { a.draw(in: nsCtx) }
                Annotation.drawHighlightDim(for: baseTools, in: bounds)
                for a in baseTools where a.tool != .pixelate { a.draw(in: nsCtx) }
            }
            base = scratch.makeImage()
        }

        var layers: [Layer] = []
        for annotation in layerTools {
            clear(scratch, width: spec.pixelWidth, height: spec.pixelHeight)
            withNSGraphicsContext(scratch) { annotation.draw(in: $0) }
            guard let box = alphaBounds(scratch, width: spec.pixelWidth, height: spec.pixelHeight) else { continue }

            let minCol = max(0, box.minCol - 2), maxCol = min(spec.pixelWidth - 1, box.maxCol + 2)
            let minRow = max(0, box.minRow - 2), maxRow = min(spec.pixelHeight - 1, box.maxRow + 2)
            let cropW = maxCol - minCol + 1, cropH = maxRow - minRow + 1
            guard cropW > 0, cropH > 0 else { continue }
            // Bottom of the crop in the same (unflipped) user-space pixels
            // the full-frame context draws in — see the class doc for the
            // row/user-space relationship this depends on.
            let cropOriginXPx = CGFloat(minCol)
            let cropOriginYPx = CGFloat(spec.pixelHeight - maxRow - 1)

            guard let cropCtx = makeContext(width: cropW, height: cropH, sx: sx, sy: sy,
                                            extraTranslate: CGPoint(x: -cropOriginXPx, y: -cropOriginYPx)) else { continue }
            withNSGraphicsContext(cropCtx) { annotation.draw(in: $0) }
            guard let cg = cropCtx.makeImage() else { continue }

            let contentRect = segment.contentRect(forCanvas: NSRect(
                x: cropOriginXPx / sx, y: cropOriginYPx / sy, width: CGFloat(cropW) / sx, height: CGFloat(cropH) / sy))
            let reveal = annotation.revealGeometry.map { geometry -> EffectsCompositionInstruction.AnnotationLayerSnapshot.Reveal in
                switch geometry {
                case let .path(points, width):
                    let pixelPoints = points.map { CGPoint(x: $0.x * sx - cropOriginXPx, y: $0.y * sy - cropOriginYPx) }
                    return .path(points: pixelPoints, width: width * sx)
                case let .sweep(center, rotation):
                    return .sweep(center: CGPoint(x: center.x * sx - cropOriginXPx, y: center.y * sy - cropOriginYPx),
                                 rotation: rotation)
                }
            }
            layers.append(Layer(image: cg, contentRect: contentRect, reveal: reveal))
        }

        guard base != nil || !layers.isEmpty else { return nil }
        return RenderResult(base: base, layers: layers)
    }

    // MARK: - Context helpers

    private static func makeContext(width: Int, height: Int, sx: CGFloat, sy: CGFloat,
                                    extraTranslate: CGPoint = .zero) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        clear(ctx, width: width, height: height)
        // Annotations are stored in `canvasSize` points, AppKit bottom-left
        // origin. Scale into pixel space, then shift so `extraTranslate`'s
        // canvas-pixel origin lands at this context's (0, 0) — used to
        // render a small crop of the full-frame drawing.
        let transform = CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: extraTranslate.x, y: extraTranslate.y))
        ctx.concatenate(transform)
        return ctx
    }

    /// Zeroes the backing pixel buffer directly (fully transparent), so
    /// reusing one context for many annotations doesn't need to fight the
    /// crop-translate CTM already concatenated into it.
    private static func clear(_ ctx: CGContext, width: Int, height: Int) {
        guard let data = ctx.data else { return }
        memset(data, 0, ctx.bytesPerRow * height)
    }

    /// Drives AppKit drawing into `ctx`, exactly like `VideoTextRasterizer`
    /// — `Annotation.draw(in:)` sets `NSGraphicsContext.current` itself, so
    /// save/restore around it.
    private static func withNSGraphicsContext(_ ctx: CGContext, _ body: (NSGraphicsContext) -> Void) {
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        body(nsCtx)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Tight pixel bounding box (buffer row/column space, row 0 = top) of
    /// every non-transparent pixel in `ctx`, or nil if it's entirely empty.
    private static func alphaBounds(_ ctx: CGContext, width: Int, height: Int) -> (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)? {
        guard let data = ctx.data else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minCol = Int.max, maxCol = -1, minRow = Int.max, maxRow = -1
        for row in 0..<height {
            let rowBase = row * bytesPerRow
            for col in 0..<width {
                // premultipliedFirst + byteOrder32Little stores bytes as
                // B, G, R, A — alpha is the 4th byte of each pixel.
                if bytes[rowBase + col * 4 + 3] != 0 {
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }
        guard maxCol >= 0 else { return nil }
        return (minCol, maxCol, minRow, maxRow)
    }
}
