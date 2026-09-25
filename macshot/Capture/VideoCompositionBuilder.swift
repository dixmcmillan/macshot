import AVFoundation

enum VideoCompositionBuilder {
    /// A video-kind overlay's own asset plus the model timing needed to place
    /// it: source `startTime` (pre-trim, same clock as `pieces`), the
    /// output-clock `duration` it plays, and `mediaStart` trimming its head.
    struct OverlayInput {
        let id: UUID
        let asset: AVAsset
        let startTime: Double
        let duration: Double
        let mediaStart: Double
    }

    /// Where a video overlay landed: its own composition track and the
    /// composition-clock instant it begins at.
    struct OverlayPlacement: Sendable {
        let trackID: CMPersistentTrackID
        let compStart: Double
    }

    struct Result {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let audioTracks: [AVMutableCompositionTrack]
        let timeMap: [EffectsCompositionInstruction.TimeMapEntry]
        let frameDuration: CMTime
        /// Separately recorded camera, aligned to the source clock.
        var cameraTrack: AVMutableCompositionTrack? = nil
        /// Video overlays that got their own composition track, keyed by
        /// segment id. An overlay missing here was skipped (cut out, past the
        /// trim, or its media couldn't be read) — never fails the whole build.
        var overlayPlacements: [UUID: OverlayPlacement] = [:]
        var duration: Double { composition.duration.seconds }
    }

    enum BuildError: LocalizedError {
        case invalidTimeline, missingVideo, unsupportedFreeze
        var errorDescription: String? {
            switch self {
            case .invalidTimeline: return "The edited recording contains an invalid time range."
            case .missingVideo: return "The source recording has no usable video track."
            case .unsupportedFreeze: return "The selected freeze frame could not be located in the source recording."
            }
        }
    }

    /// Constructs a privately owned composition. Every insert either succeeds
    /// or throws; a partial timeline must never be presented as a valid export.
    static func build(asset: AVAsset, pieces: [VideoSpeeds.Piece], includeAudio: Bool,
                      sourceFrameDuration: CMTime? = nil, camera: AVAsset? = nil,
                      overlays: [OverlayInput] = []) throws -> Result {
        guard let sourceVideo = asset.tracks(withMediaType: .video).first else { throw BuildError.missingVideo }
        guard !pieces.isEmpty else { throw BuildError.invalidTimeline }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BuildError.missingVideo }
        let sourceAudio = includeAudio ? asset.tracks(withMediaType: .audio) : []
        let frameDuration = sourceFrameDuration ?? VideoFrameCadence.declaredDuration(in: asset.metadata)
            ?? VideoFrameCadence.Inspection(track: sourceVideo).duration()
        let timeScale = editingTimeScale(tracks: [sourceVideo] + sourceAudio, frameDuration: frameDuration)
        video.naturalTimeScale = timeScale
        video.preferredTransform = sourceVideo.preferredTransform
        let audio = try sourceAudio.map { _ -> AVMutableCompositionTrack in
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BuildError.invalidTimeline }
            track.naturalTimeScale = timeScale
            return track
        }
        // Keep every edited endpoint on the same compatible clock. With a
        // fixed 1 GHz clock, subtracting a 1/600-second endpoint can overflow
        // CMTime's timescale and round a valid final range past the source.
        let sourceStart = CMTimeConvertScale(sourceVideo.timeRange.start, timescale: timeScale,
                                            method: .roundTowardPositiveInfinity)
        let sourceEnd = CMTimeConvertScale(sourceVideo.timeRange.end, timescale: timeScale,
                                          method: .roundTowardNegativeInfinity)
        // The camera file starts at the screen recording's first frame, so
        // both share the source clock. Missing camera time stays empty.
        let cameraSource = camera?.tracks(withMediaType: .video).first
        let cameraTrack = cameraSource == nil ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        cameraTrack?.naturalTimeScale = timeScale
        if let cameraSource { cameraTrack?.preferredTransform = cameraSource.preferredTransform }
        var cursor = CMTime.zero
        var map: [EffectsCompositionInstruction.TimeMapEntry] = []
        for piece in pieces {
            guard piece.srcStart.isFinite, piece.srcEnd.isFinite, piece.compositionDuration.isFinite,
                  piece.srcStart >= 0, piece.srcEnd >= piece.srcStart, piece.compositionDuration > 0,
                  piece.srcEnd <= sourceVideo.timeRange.end.seconds + 0.000000001,
                  piece.compositionDuration < 9_000_000_000 else {
                throw BuildError.invalidTimeline
            }
            var duration = CMTime(seconds: piece.compositionDuration, preferredTimescale: timeScale)
            guard duration.isNumeric, duration.value > 0 else { throw BuildError.invalidTimeline }
            let start = CMTime(seconds: piece.srcStart, preferredTimescale: timeScale)
            let sourceRange: CMTimeRange
            if piece.kind == .freeze {
                guard piece.srcStart == piece.srcEnd else { throw BuildError.invalidTimeline }
                sourceRange = try frameRange(at: start, in: sourceVideo, fallbackDuration: frameDuration)
            } else {
                let end = CMTime(seconds: piece.srcEnd, preferredTimescale: timeScale)
                // A seconds-to-ticks conversion may round a rational endpoint
                // outward by a fraction of a nanosecond. Preserve exact track
                // boundaries rather than rejecting a valid full-length trim.
                let exactStart = abs(start.seconds - sourceVideo.timeRange.start.seconds) <= 0.000000001
                    ? sourceStart : start
                let exactEnd = abs(end.seconds - sourceVideo.timeRange.end.seconds) <= 0.000000001
                    ? sourceEnd : end
                sourceRange = CMTimeRange(start: exactStart, end: exactEnd)
                if piece.kind == .normal {
                    guard abs(piece.compositionDuration - piece.sourceDuration) <= 0.000000001 else {
                        throw BuildError.invalidTimeline
                    }
                    duration = sourceRange.duration
                }
            }
            guard sourceRange.duration.isNumeric, sourceRange.duration.value > 0,
                  CMTimeRangeContainsTimeRange(sourceVideo.timeRange, otherRange: sourceRange) else {
                throw BuildError.invalidTimeline
            }
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if CMTimeCompare(sourceRange.duration, duration) != 0 {
                // Insertion rounds a rational source interval to the track's
                // clock. Scale the interval actually inserted: using the
                // original 1/30 duration here can leave a nanosecond gap at
                // the next segment, which a compositor may request.
                let insertedRange = CMTimeRange(start: cursor, end: video.timeRange.end)
                video.scaleTimeRange(insertedRange, toDuration: duration)
            }
            if let cameraSource, let cameraTrack {
                // A freeze holds the camera's own frame at that instant; the
                // screen frame's interval can span many camera frames.
                let cameraRange = piece.kind == .freeze
                    ? (try? frameRange(at: start, in: cameraSource, fallbackDuration: CMTime(value: 1, timescale: 30)))
                    : nil
                appendCamera(source: cameraSource, destination: cameraTrack, range: cameraRange ?? sourceRange,
                             at: cursor, scaledDuration: duration)
            }
            for (source, destination) in zip(sourceAudio, audio) {
                if piece.kind == .freeze {
                    destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
                } else {
                    try appendAudio(source: source, destination: destination, range: sourceRange,
                                    at: cursor, scaledDuration: duration)
                }
            }
            let end = CMTimeAdd(cursor, duration)
            guard end.isNumeric else { throw BuildError.invalidTimeline }
            map.append(.init(compStart: cursor.seconds, compEnd: end.seconds,
                             sourceStart: piece.srcStart,
                             factor: piece.kind == .freeze ? 0 : sourceRange.duration.seconds / duration.seconds))
            cursor = end
        }
        // A track holding only empty edits (e.g. a trim that starts after the
        // recorded audio ends) makes AVFoundation fail the whole export with
        // -11800, so drop tracks that carry no audio.
        let audible = audio.filter { track in
            if track.segments.contains(where: { !$0.isEmpty }) { return true }
            composition.removeTrack(track)
            return false
        }
        // Video overlays get their own track each, inserted once at the
        // composition instant their source `startTime` maps to — not through
        // the per-piece cut/speed/freeze loop above. Their audio is never
        // added, so it's muted by construction. A skipped overlay (cut out,
        // past the trim, unreadable media) simply has no entry in
        // `overlayPlacements`; it never fails the whole build.
        var overlayPlacements: [UUID: OverlayPlacement] = [:]
        for overlay in overlays {
            guard overlay.duration > 0, let compStart = compositionTime(forSource: overlay.startTime, timeMap: map),
                  let overlaySource = overlay.asset.tracks(withMediaType: .video).first else { continue }
            let head = max(0, overlay.mediaStart)
            let requested = CMTimeRange(start: CMTime(seconds: head, preferredTimescale: overlaySource.naturalTimeScale),
                                        end: CMTime(seconds: head + overlay.duration, preferredTimescale: overlaySource.naturalTimeScale))
            let clamped = CMTimeRangeGetIntersection(requested, otherRange: overlaySource.timeRange)
            guard clamped.duration.isNumeric, clamped.duration.seconds > 0,
                  let oTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            oTrack.naturalTimeScale = timeScale
            oTrack.preferredTransform = overlaySource.preferredTransform
            do {
                try oTrack.insertTimeRange(clamped, of: overlaySource, at: CMTime(seconds: compStart, preferredTimescale: timeScale))
                overlayPlacements[overlay.id] = OverlayPlacement(trackID: oTrack.trackID, compStart: compStart)
            } catch {
                composition.removeTrack(oTrack)
            }
        }
        return Result(composition: composition, videoTrack: video, audioTracks: audible,
                      timeMap: map, frameDuration: frameDuration, cameraTrack: cameraTrack,
                      overlayPlacements: overlayPlacements)
    }

    /// Composition-clock time at which `sourceTime` plays, or `nil` if it
    /// falls inside a cut or past the trimmed timeline. Unlike zoom/censor/
    /// text (evaluated against source time every frame so they track content
    /// through speed ramps and freezes), an overlay's *own* timing starts at
    /// this single composition instant and then runs on the output clock —
    /// this is the one place that instant is computed, from the same
    /// `timeMap` the compositor uses to go the other direction.
    static func compositionTime(forSource sourceTime: Double,
                                timeMap: [EffectsCompositionInstruction.TimeMapEntry]) -> Double? {
        for entry in timeMap {
            if entry.factor == 0 {
                // Freeze: a single held source instant spanning `compEnd - compStart`.
                if abs(sourceTime - entry.sourceStart) < 0.0001 { return entry.compStart }
                continue
            }
            let sourceEnd = entry.sourceStart + (entry.compEnd - entry.compStart) * entry.factor
            if sourceTime >= entry.sourceStart - 0.0001 && sourceTime < sourceEnd - 0.0001 {
                return entry.compStart + (sourceTime - entry.sourceStart) / entry.factor
            }
        }
        return nil
    }

    /// Camera time mirrors the screen: the same source range, scaled the same
    /// way. Parts the camera did not record are left empty (no bubble).
    private static func appendCamera(source: AVAssetTrack, destination: AVMutableCompositionTrack,
                                     range: CMTimeRange, at cursor: CMTime, scaledDuration: CMTime) {
        let start = destination.timeRange.duration.isNumeric ? CMTimeAdd(destination.timeRange.start, destination.timeRange.duration) : .zero
        if CMTimeCompare(start, cursor) < 0 {
            destination.insertEmptyTimeRange(CMTimeRange(start: start, end: cursor))
        }
        let overlap = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
        guard overlap.isValid, overlap.duration.isNumeric, overlap.duration.value > 0,
              range.duration.seconds > 0 else {
            destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: scaledDuration))
            return
        }
        let ratio = scaledDuration.seconds / range.duration.seconds
        let lead = CMTimeSubtract(overlap.start, range.start)
        let leadOut = CMTime(seconds: lead.seconds * ratio, preferredTimescale: scaledDuration.timescale)
        if leadOut.value > 0 { destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: leadOut)) }
        let at = CMTimeAdd(cursor, leadOut)
        do {
            try destination.insertTimeRange(overlap, of: source, at: at)
        } catch {
            destination.insertEmptyTimeRange(CMTimeRange(start: at, duration: overlap.duration))
        }
        let outDuration = CMTime(seconds: overlap.duration.seconds * ratio, preferredTimescale: scaledDuration.timescale)
        if CMTimeCompare(overlap.duration, outDuration) != 0, outDuration.value > 0 {
            destination.scaleTimeRange(CMTimeRange(start: at, duration: overlap.duration), toDuration: outDuration)
        }
        let end = CMTimeAdd(cursor, scaledDuration)
        let written = CMTimeAdd(destination.timeRange.start, destination.timeRange.duration)
        if CMTimeCompare(written, end) < 0 {
            destination.insertEmptyTimeRange(CMTimeRange(start: written, end: end))
        }
    }

    private static func editingTimeScale(tracks: [AVAssetTrack], frameDuration: CMTime) -> CMTimeScale {
        func gcd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            var a = lhs, b = rhs
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            return a
        }
        let limit: Int64 = 1_000_000_000
        // Prefer exact track boundaries, then include sample clocks wherever
        // a common timescale fits. Exotic incompatible clocks are rounded
        // inward at the source bounds by at most one high-resolution tick.
        let scales = tracks.flatMap { [$0.timeRange.start.timescale, $0.timeRange.duration.timescale] }
            + [frameDuration.timescale] + tracks.map(\.naturalTimeScale)
        var common: Int64 = 1
        for scale in scales where scale > 0 {
            let candidate = common / gcd(common, Int64(scale)) * Int64(scale)
            if candidate <= limit { common = candidate }
        }
        return CMTimeScale(common * (limit / common))
    }

    private static func appendAudio(source: AVAssetTrack, destination: AVMutableCompositionTrack,
                                    range: CMTimeRange, at cursor: CMTime, scaledDuration: CMTime) throws {
        let overlap = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
        if overlap.isValid, overlap.duration.isNumeric, overlap.duration.value > 0 {
            let before = CMTimeSubtract(overlap.start, range.start)
            if before.value > 0 { destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: before)) }
            try destination.insertTimeRange(overlap, of: source, at: CMTimeAdd(cursor, before))
            let after = CMTimeSubtract(range.end, overlap.end)
            if after.value > 0 {
                destination.insertEmptyTimeRange(CMTimeRange(start: CMTimeAdd(cursor,
                    CMTimeSubtract(overlap.end, range.start)), duration: after))
            }
        } else {
            destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
        }
        if CMTimeCompare(range.duration, scaledDuration) != 0 {
            destination.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDuration)
        }
    }

    /// Locate the whole presentation interval of one actual frame, including
    /// VFR and non-keyframes. Stretching a guessed 1/600-second slice could
    /// straddle the next frame or fail to contain a sample at all.
    private static func frameRange(at time: CMTime, in track: AVAssetTrack,
                                    fallbackDuration: CMTime) throws -> CMTimeRange {
        // Source seconds originate in UI/model Doubles. Snap a sub-nanosecond
        // conversion error at an exact frame boundary to that frame.
        let query = CMTimeAdd(time, CMTime(value: 1, timescale: 1_000_000_000))
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: query) else { throw BuildError.unsupportedFreeze }
        while CMTimeCompare(cursor.presentationTimeStamp, query) > 0 {
            guard cursor.stepInPresentationOrder(byCount: -1) != 0 else { break }
        }
        var end: CMTime
        while true {
            guard let next = cursor.copy() as? AVSampleCursor else { throw BuildError.unsupportedFreeze }
            if next.stepInPresentationOrder(byCount: 1) == 0 {
                let duration = cursor.currentSampleDuration
                end = CMTimeAdd(cursor.presentationTimeStamp,
                    duration.isNumeric && duration.value > 0 ? duration : fallbackDuration)
                break
            }
            end = next.presentationTimeStamp
            if CMTimeCompare(end, query) > 0 { break }
            guard cursor.stepInPresentationOrder(byCount: 1) != 0 else { break }
        }
        return CMTimeRangeGetIntersection(track.timeRange,
            otherRange: CMTimeRange(start: cursor.presentationTimeStamp, end: end))
    }
}
