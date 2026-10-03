import AetherEngine
import AVFoundation
import CoreMedia
import CoreImage
import Foundation

@MainActor
final class ASSSubtitlePresentationClock {
    struct Sample {
        let sourceTime: Double
        let identity: UUID?
        let isAdvancing: Bool
        let sourceShift: Double?

        init(sourceTime: Double, identity: UUID?, isAdvancing: Bool, sourceShift: Double? = nil) {
            self.sourceTime = sourceTime
            self.identity = identity
            self.isAdvancing = isAdvancing
            self.sourceShift = sourceShift
        }
    }

    private struct ClockKey: Equatable {
        let route: VideoRoute
        let item: ObjectIdentifier?
        let timebase: ObjectIdentifier
    }

    /// The software decoder reports scheduled frame PTS on its own thread.
    final class SoftwareFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var minimumGeneration: UInt64 = 0
        private var times: [Double] = []

        func append(_ frame: SoftwareVideoFrameTime) {
            let time = frame.presentation.seconds
            guard time.isFinite else { return }
            lock.lock()
            defer { lock.unlock() }
            guard frame.generation >= generation, frame.generation >= minimumGeneration else { return }
            if frame.generation != generation {
                generation = frame.generation
                times.removeAll(keepingCapacity: true)
            }
            if times.last.map({ $0 < time }) ?? true { times.append(time) }
            else if !times.contains(time) { times.append(time); times.sort() }
            if times.count > 4_096 { times.removeFirst(times.count - 4_096) }
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            minimumGeneration = generation &+ 1
            times.removeAll(keepingCapacity: true)
        }

        func accepts(_ frame: SoftwareVideoFrameTime) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return frame.generation == generation && frame.generation >= minimumGeneration
        }

        func time(at position: Double) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = times.lastIndex(where: { $0 <= position + 0.000001 }) else { return nil }
            return times[index]
        }

        func time(onOrAfter position: Double) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            return times.first(where: { $0 >= position - 0.000001 })
        }
    }

    private let engine: AetherEngine
    private let softwareFrames = SoftwareFrames()
    private weak var outputItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var nativeFrameTimes: [Double] = []
    private var nativePixels: [Double: CVPixelBuffer] = [:]
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var clockKey: ClockKey?
    private var clockIdentity = UUID()

    init(engine: AetherEngine) {
        self.engine = engine
        let frames = softwareFrames
        engine.setSoftwareVideoFrameTimeObserver { frames.append($0) }
    }

    func invalidateVideoFrameTimes() {
        softwareFrames.invalidate()
        nativeFrameTimes.removeAll(keepingCapacity: true)
        nativePixels.removeAll(keepingCapacity: true)
    }

    /// Render the cue at the timestamp of the video frame, rather than between frames.
    /// Preparation uses the continuous clock so future static boundaries can be warmed.
    func presentationSample(atHostTime hostTime: CFTimeInterval) -> Sample {
        let sample = sample(atHostTime: hostTime)
        guard sample.identity != nil, !engine.isSeeking else { return sample }
        let sourceTime: Double?
        switch engine.videoRoute {
        case .software:
            if !sample.isAdvancing, let displayed = engine.softwareDisplayedVideoFrameTime,
               softwareFrames.accepts(displayed) {
                return Sample(sourceTime: displayed.presentation.seconds, identity: sample.identity,
                              isAdvancing: false, sourceShift: sample.sourceShift)
            }
            sourceTime = softwareFrames.time(at: sample.sourceTime)
                ?? softwareFrames.time(onOrAfter: sample.sourceTime)
        case .loopback, .remoteBypass:
            guard let item = engine.currentAVPlayer?.currentItem else { return sample }
            if outputItem !== item {
                if let outputItem, let videoOutput { outputItem.remove(videoOutput) }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                item.add(output)
                outputItem = item
                videoOutput = output
                nativeFrameTimes = []
                nativePixels = [:]
            }
            if let videoOutput {
                let time = CMTime(seconds: sample.sourceTime - (sample.sourceShift ?? 0), preferredTimescale: 1_000_000_000)
                var displayed = CMTime.invalid
                if videoOutput.hasNewPixelBuffer(forItemTime: time),
                   let pixel = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
                   displayed.isNumeric, displayed.seconds.isFinite {
                    recordNativeFrame(displayed.seconds, pixel: pixel)
                }
            }
            let shift = sample.sourceShift ?? 0
            let first = nativeFrameTimes.first.flatMap {
                $0 + shift - sample.sourceTime <= 0.25 ? $0 : nil
            }
            let displayedTime = nativeFrameTimes.last(where: { $0 <= sample.sourceTime - shift + 0.000001 })
                ?? first
            sourceTime = displayedTime.map { $0 + shift }
        case .none, .audio:
            sourceTime = nil
        }
        return Sample(sourceTime: sourceTime ?? sample.sourceTime, identity: sample.identity,
                      isAdvancing: sample.isAdvancing, sourceShift: sample.sourceShift)
    }

    /// Static cuts and animated rasters start on a video frame, including sidecars
    /// whose authored boundary falls between two decoded frame timestamps.
    func sourceFrameTime(onOrAfter sourceTime: Double, atHostTime hostTime: CFTimeInterval) -> Double? {
        guard sourceTime.isFinite else { return nil }
        switch engine.videoRoute {
        case .software:
            return softwareFrames.time(onOrAfter: sourceTime)
        case .loopback, .remoteBypass:
            guard !engine.isSeeking else { return nil }
            let sample = presentationSample(atHostTime: hostTime)
            let shift = sample.sourceShift ?? 0
            if nativeFrameTimes.first(where: { $0 + shift >= sourceTime - 0.000001 }) == nil,
               let videoOutput {
                // Ask for decoded future frames, without assuming a constant frame rate.
                for lead in [0.0, 0.004, 0.008, 0.016, 0.032, 0.064, 0.128] {
                    let requested = CMTime(seconds: sourceTime - shift + lead, preferredTimescale: 1_000_000_000)
                    var displayed = CMTime.invalid
                    if videoOutput.hasNewPixelBuffer(forItemTime: requested),
                       let pixel = videoOutput.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed),
                       displayed.isNumeric, displayed.seconds.isFinite {
                        recordNativeFrame(displayed.seconds, pixel: pixel)
                        if displayed.seconds + shift >= sourceTime - 0.000001 { break }
                    }
                }
            }
            return nativeFrameTimes.first(where: { $0 + shift >= sourceTime - 0.000001 }).map { $0 + shift }
        case .none, .audio:
            return nil
        }
    }

    /// Retain the outgoing picture while a parked seek or track change prepares
    /// its matching subtitle. Reading the display does not move the A/V clock.
    struct VideoSnapshot {
        let image: CGImage
        let itemTime: Double
    }

    func videoSnapshot() -> VideoSnapshot? {
        let pixel: CVPixelBuffer?
        let itemTime: Double
        switch engine.videoRoute {
        case .software:
            pixel = engine.softwarePiPSource?.layer.sampleBufferRenderer.displayedPixelBuffer()
            guard let pixel, let metadata = CVBufferCopyAttachment(pixel, "AetherSoftwareFrameTime" as CFString, nil)
                as? [String: NSNumber], let pts = metadata["pts"] else { return nil }
            itemTime = pts.doubleValue
        case .loopback, .remoteBypass:
            let sample = presentationSample(atHostTime: CACurrentMediaTime())
            let time = CMTime(seconds: sample.sourceTime - (sample.sourceShift ?? 0), preferredTimescale: 1_000_000_000)
            var displayed = CMTime.invalid
            if let value = videoOutput?.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
               displayed.isNumeric, displayed.seconds.isFinite {
                pixel = value
                itemTime = displayed.seconds
            } else if let cached = nativePixels.keys.filter({ $0 <= time.seconds + 0.000001 }).max() {
                pixel = nativePixels[cached]
                itemTime = cached
            } else { return nil }
        case .none, .audio:
            return nil
        }
        guard let pixel else { return nil }
        let image = CIImage(cvPixelBuffer: pixel)
        guard itemTime.isFinite, let rendered = imageContext.createCGImage(image, from: image.extent) else { return nil }
        return VideoSnapshot(image: rendered, itemTime: itemTime)
    }

    private func recordNativeFrame(_ time: Double, pixel: CVPixelBuffer) {
        nativePixels[time] = pixel
        while nativePixels.count > 6, let first = nativePixels.keys.min() { nativePixels.removeValue(forKey: first) }
        if !nativeFrameTimes.contains(time) {
            nativeFrameTimes.append(time)
            nativeFrameTimes.sort()
            if nativeFrameTimes.count > 512 { nativeFrameTimes.removeFirst(nativeFrameTimes.count - 512) }
        }
    }

    func sample(atHostTime hostTime: CFTimeInterval) -> Sample {
        let parkedTime = engine.clock.sourceTime.isFinite ? engine.clock.sourceTime : 0
        guard hostTime.isFinite else {
            return unavailableSample(sourceTime: parkedTime)
        }

        switch engine.videoRoute {
        case .loopback, .remoteBypass:
            guard let player = engine.currentAVPlayer,
                  let item = player.currentItem,
                  let timebase = item.timebase else {
                return unavailableSample(sourceTime: parkedTime)
            }

            let identity = identity(for: ClockKey(route: engine.videoRoute,
                                                  item: ObjectIdentifier(item),
                                                  timebase: ObjectIdentifier(timebase)))
            let rate = CMTimebaseGetEffectiveRate(timebase)
            let isAdvancing = rate.isFinite && rate > 0
            guard !engine.isSeeking,
                  let itemTime = mediaTime(atHostTime: hostTime, on: timebase) else {
                return Sample(sourceTime: parkedTime, identity: identity, isAdvancing: false)
            }

            let sourceTime: Double
            let sourceShift: Double
            if engine.videoRoute == .loopback {
                guard let shift = engine.presentationAxisMap.shiftSeconds(atItemSeconds: itemTime),
                      shift.isFinite, (itemTime + shift).isFinite else {
                    return Sample(sourceTime: parkedTime, identity: identity, isAdvancing: false)
                }
                sourceTime = itemTime + shift
                sourceShift = shift
            } else {
                sourceTime = itemTime
                sourceShift = 0
            }
            return Sample(sourceTime: sourceTime, identity: identity,
                          isAdvancing: isAdvancing, sourceShift: sourceShift)

        case .software:
            guard let timebase = engine.softwarePresentationTimebase else {
                return unavailableSample(sourceTime: parkedTime)
            }
            let identity = identity(for: ClockKey(route: .software,
                                                  item: nil,
                                                  timebase: ObjectIdentifier(timebase)))
            let rate = CMTimebaseGetEffectiveRate(timebase)
            let isAdvancing = engine.state == .playing && rate.isFinite && rate > 0
            let isLandedPause = engine.state == .paused && rate == 0
            let isStoppedAfterFirstFrame = engine.state == .playing && rate == 0
                && engine.hasFirstFrameReadyForDisplay
            guard !engine.isSeeking, !engine.isBuffering,
                  isAdvancing || isLandedPause || isStoppedAfterFirstFrame,
                  let sourceTime = mediaTime(atHostTime: hostTime, on: timebase) else {
                return Sample(sourceTime: parkedTime, identity: identity, isAdvancing: false)
            }
            return Sample(sourceTime: sourceTime, identity: identity, isAdvancing: isAdvancing)

        case .none, .audio:
            return unavailableSample(sourceTime: parkedTime)
        }
    }

    private func unavailableSample(sourceTime: Double) -> Sample {
        clockKey = nil
        return Sample(sourceTime: sourceTime, identity: nil, isAdvancing: false)
    }

    private func identity(for key: ClockKey) -> UUID {
        if clockKey != key {
            clockKey = key
            clockIdentity = UUID()
        }
        return clockIdentity
    }

    private func mediaTime(atHostTime hostTime: CFTimeInterval, on timebase: CMTimebase) -> Double? {
        let hostTime = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        guard hostTime.isNumeric else { return nil }
        let time = CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: timebase)
        guard time.isNumeric, time.seconds.isFinite else { return nil }
        return time.seconds
    }
}
