import AetherEngine
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog
import QuartzCore

/// Load-scoped ASS presentation. Selection changes fence both font downloads
/// and rendered frames; no completed work from an outgoing track can reappear.
@MainActor
final class ASSSubtitleSession: ObservableObject {
    private(set) var frame: ASSSubtitleRenderer.Frame?
    let frames = PassthroughSubject<ASSSubtitleRenderer.Frame?, Never>()
    let invalidations = PassthroughSubject<Void, Never>()
    struct ReadyFrame {
        let prepared: PreparedFrame
        let replacesPendingFrames: Bool
    }
    let readyFrames = PassthroughSubject<ReadyFrame, Never>()
    var waitForDisplay: (() async -> Void)?
    var renderingTimingDidChange: (() -> Void)?
    var holdDisplay: ((ASSSubtitlePresentationClock.VideoSnapshot) -> Void)?
    var releaseDisplay: (() -> Void)?
    private let videoSnapshot: () -> ASSSubtitlePresentationClock.VideoSnapshot?
    private var holdGeneration: UInt64 = 0
    @Published private(set) var isLoadingFonts = false
    @Published private(set) var failureMessage: String?

    private let usesEngineClock: Bool
    private let engine: AetherEngine
    private let fontLoader: @Sendable (URLRequest, HTTPRequestAuthorization?) async throws -> [FontAttachment]
    private var renderer = ASSSubtitleRenderer()
    private var subscriptions: Set<AnyCancellable> = []
    private var events: [ASSSubtitleRenderer.Event] = []
    private let presentationClock: (CFTimeInterval) -> ASSSubtitlePresentationClock.Sample
    private let sampleClock: (CFTimeInterval) -> ASSSubtitlePresentationClock.Sample
    private let nextSourceFrame: (Double, CFTimeInterval) -> Double?
    private let invalidateSourceFrames: () -> Void
    private let resetFrameLookahead: () -> Void
    private var presentedFrame: PreparedFrame?
    private var fontTask: Task<Void, Never>?
    private struct FontRequest: Equatable {
        let request: URLRequest
        let authorization: HTTPRequestAuthorization?
    }
    private var fontRequests: [Int: FontRequest] = [:]
    private var fontCache: [URL: [FontAttachment]] = [:]
    private var selectedFonts: [FontAttachment] = []
    private var fontSelection: Int?
    private var generation: UInt64 = 0 { didSet { invalidations.send() } }
    private var fontGeneration: UInt64 = 0
    private var cueRevision: UInt64 = 0
    private var enabled = false
    private var didRecordFrame = false
    private var timelineOffset: Double = 0
    private var renderContext: (size: CGSize, scale: CGFloat, delay: Double)?
    private var seekFrame: PreparedFrame?
    private var selectedTrackID: Int?
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "ASSSubtitles")

    struct PreparedFrame {
        let frame: ASSSubtitleRenderer.Frame?
        let time: Double
        let hostTime: CFTimeInterval
        let sourcePresentationTime: Double
        let presentationTime: Double
        let beginsInterval: Bool
        let awaitsFrameTimestamp: Bool
        fileprivate var validity: Range<Double>
        fileprivate let generation: UInt64
        fileprivate let clockIdentity: UUID?
        fileprivate let sourceShift: Double?
        fileprivate let isAdvancing: Bool
        fileprivate let isTimeVarying: Bool
        fileprivate let activeEvents: Set<ASSSubtitleRenderer.Event>
        var isStatic: Bool { !isTimeVarying }
        var intervalStart: Double { validity.lowerBound }
        var intervalEnd: Double { validity.upperBound }
    }

    init(engine: AetherEngine,
         fontLoader: @escaping @Sendable (URLRequest, HTTPRequestAuthorization?) async throws -> [FontAttachment] = {
             try await ASSSubtitleSession.loadFonts($0, authorization: $1)
         },
         sampleClock: ((CFTimeInterval) -> ASSSubtitlePresentationClock.Sample)? = nil) {
        self.usesEngineClock = sampleClock == nil
        self.engine = engine
        self.fontLoader = fontLoader
        let clock = ASSSubtitlePresentationClock(engine: engine)
        self.videoSnapshot = { clock.videoSnapshot() }
        self.sampleClock = sampleClock ?? { clock.sample(atHostTime: $0) }
        self.presentationClock = sampleClock ?? { clock.presentationSample(atHostTime: $0) }
        self.nextSourceFrame = sampleClock == nil ? { clock.sourceFrameTime(onOrAfter: $0, atHostTime: $1) } : { time, _ in time }
        self.invalidateSourceFrames = sampleClock == nil ? { clock.invalidateVideoFrameTimes() } : {}
        self.resetFrameLookahead = sampleClock == nil ? { clock.resetLookahead() } : {}
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] trackID in
            self?.selectedTrackID = trackID
            self?.clearSelection()
        }.store(in: &subscriptions)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            cueRevision &+= 1
            let incoming = ASSSubtitleRenderer.Event.events(from: cues)
            if var presentedFrame {
                let time = presentedFrame.time
                let previous = Set(events.filter { Self.eventInterval($0)?.contains(time) == true })
                let next = Set(incoming.filter { Self.eventInterval($0)?.contains(time) == true })
                if previous != next {
                    generation &+= 1
                    setFrame(nil)
                } else {
                    presentedFrame.validity = Self.validityInterval(events: incoming, at: time)
                    self.presentedFrame = presentedFrame
                }
            }
            events = incoming
            if cues.isEmpty {
                renderer = ASSSubtitleRenderer()
                setFrame(nil)
            }
        }.store(in: &subscriptions)
        engine.$isSeeking.removeDuplicates().dropFirst().sink { [weak self] isSeeking in
            guard let self else { return }
            if isSeeking {
                invalidateSourceFrames()
                generation &+= 1
                setFrame(nil)
            }
            // A transport landing can precede decoded video admission. The
            // controller publishes only after that frame has been observed.
        }.store(in: &subscriptions)
    }

    deinit { fontTask?.cancel() }

    var renderingTimebase: CMTimebase? {
        guard usesEngineClock else { return nil }
        switch engine.videoRoute {
        case .software: return engine.softwarePresentationTimebase
        case .loopback, .remoteBypass: return engine.currentAVPlayer?.currentItem?.timebase
        case .none, .audio: return nil
        }
    }

    var handlesCurrentTrack: Bool {
        guard enabled else { return false }
        guard let track = engine.subtitleTracks.first(where: { $0.id == selectedTrackID }) else {
            return false
        }
        return ["ass", "ssa"].contains(track.codec.lowercased())
    }

    func beginLoad(timelineOffset: Double) {
        stop()
        self.timelineOffset = timelineOffset
    }

    func finishLoad() { enabled = true }

    func stop() {
        enabled = false
        fontRequests = [:]
        fontCache = [:]
        clearSelection()
    }

    func registerFontRequest(_ request: URLRequest, trackID: Int, authorization: HTTPRequestAuthorization? = nil) {
        let resource = FontRequest(request: request, authorization: authorization)
        guard fontRequests[trackID] != resource else { return }
        fontRequests[trackID] = resource
        if fontSelection == trackID { clearSelection() }
    }

    private func clearSelection() {
        seekFrame = nil
        generation &+= 1
        fontGeneration &+= 1
        fontTask?.cancel()
        fontTask = nil
        fontSelection = nil
        selectedFonts = []
        isLoadingFonts = false
        failureMessage = nil
        didRecordFrame = false
        setFrame(nil)
        renderer = ASSSubtitleRenderer()
    }

    /// Initial playback must not outrun an authored track's font download.
    /// A later Play intent still wins or loses through the controller's transport fence.
    func holdPresentation() {
        holdGeneration &+= 1
        if let image = videoSnapshot() { holdDisplay?(image) }
        resetFrameLookahead()
    }

    func prepareForPlayback() async {
        let held = holdGeneration
        defer { if held == holdGeneration { releaseDisplay?() } }
        while enabled, handlesCurrentTrack,
              let trackID = engine.activeSubtitleTrackIndex {
            if fontSelection != trackID { prepareFonts(trackID: trackID) }
            let epoch = fontGeneration
            await fontTask?.value
            guard !Task.isCancelled, enabled else { return }
            if engine.activeSubtitleTrackIndex != trackID || epoch != fontGeneration || isLoadingFonts { continue }
            guard failureMessage == nil else { return }
            if engine.isLoadingSubtitles {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            let size = renderContext?.size ?? CGSize(width: 1280, height: 720)
            let scale = renderContext?.scale ?? 1
            let delay = renderContext?.delay ?? 0
            let prepared = await prepareFrame(size: size, scale: scale,
                                              delaySeconds: delay, atHostTime: CACurrentMediaTime())
            guard !Task.isCancelled, enabled else { return }
            if epoch != fontGeneration || engine.activeSubtitleTrackIndex != trackID || isLoadingFonts { continue }
            guard let prepared else {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            if renderContext != nil {
                seekFrame = prepared
                guard publishSeekFrame() else {
                    try? await Task.sleep(for: .milliseconds(2))
                    continue
                }
                var previous = prepared
                for _ in 0..<4 where previous.isTimeVarying {
                    guard let source = nextDecodedFrame(after: previous, maximumLead: 0.25),
                          let next = await prepareFrame(size: size, scale: scale, delaySeconds: delay,
                                                        atHostTime: CACurrentMediaTime(), sourceTime: source) else { break }
                    guard !Task.isCancelled, epoch == fontGeneration, enabled,
                          engine.activeSubtitleTrackIndex == trackID else { break }
                    readyFrames.send(ReadyFrame(prepared: next, replacesPendingFrames: false))
                    previous = next
                }
                await waitForDisplay?()
                guard !Task.isCancelled, enabled else { return }
                if prepared.generation != generation || epoch != fontGeneration
                    || engine.activeSubtitleTrackIndex != trackID {
                    continue
                }
            }
            return
        }
    }

    func render(size: CGSize, scale: CGFloat, delaySeconds: Double) async {
        if let prepared = await prepareFrame(size: size, scale: scale, delaySeconds: delaySeconds,
                                             atHostTime: CACurrentMediaTime()) {
            present(prepared, atHostTime: CACurrentMediaTime(), delaySeconds: delaySeconds)
        }
    }

    func invalidatePendingFrames() {
        generation &+= 1
        setFrame(nil)
    }

    func configureRendering(size: CGSize, scale: CGFloat, delaySeconds: Double) {
        renderContext = (size, scale, delaySeconds)
        seekFrame = nil
    }

    func prepareForSeek(toSourceTime time: Double) async {
        guard let context = renderContext else { return }
        seekFrame = await prepareFrame(size: context.size, scale: context.scale,
                                       delaySeconds: context.delay, atHostTime: CACurrentMediaTime(),
                                       sourceTime: time)
    }

    func waitForSeekFrame(atOrAfter sourceTime: Double) async {
        guard engine.videoRoute == .software else { return }
        for _ in 0..<100 {
            guard enabled, !Task.isCancelled else { return }
            if let landed = nextSourceFrame(sourceTime, CACurrentMediaTime()),
               let timebase = engine.softwarePresentationTimebase,
               CMTimebaseGetTime(timebase).seconds >= landed - 0.000001 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @discardableResult
    private func publishSeekFrame() -> Bool {
        defer { seekFrame = nil }
        guard let prepared = seekFrame, prepared.generation == generation, let context = renderContext,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else { return false }
        let sample = presentationClock(CACurrentMediaTime())
        let time = Self.renderTime(engineTime: sample.sourceTime, timelineOffset: timelineOffset,
                                   isExternal: track.isExternal, delaySeconds: context.delay)
        guard let time = Self.rendererTime(time), prepared.validity.contains(time),
              prepared.activeEvents == Self.activeEvents(events, at: time),
              prepared.isStatic || prepared.time == time else { return false }
        guard prepared.isStatic || !engine.isSeeking else { return false }
        let ready = PreparedFrame(frame: prepared.frame, time: time, hostTime: CACurrentMediaTime(),
                                  sourcePresentationTime: prepared.sourcePresentationTime,
                                  presentationTime: prepared.presentationTime, beginsInterval: prepared.beginsInterval,
                                  awaitsFrameTimestamp: prepared.awaitsFrameTimestamp,
                                  validity: Self.validityInterval(events: events, at: time), generation: generation,
                                  clockIdentity: sample.identity, sourceShift: sample.sourceShift,
                                  isAdvancing: sample.isAdvancing, isTimeVarying: prepared.isTimeVarying,
                                  activeEvents: prepared.activeEvents)
        readyFrames.send(ReadyFrame(prepared: ready, replacesPendingFrames: true))
        return true
    }

    func nextDecodedFrame(after prepared: PreparedFrame, maximumLead: Double) -> Double? {
        let host = CACurrentMediaTime()
        guard !engine.isSeeking, isCurrent(prepared, atHostTime: host),
              let next = nextSourceFrame(prepared.sourcePresentationTime + (prepared.sourceShift ?? 0) + 0.00001, host),
              next - sampleClock(host).sourceTime <= maximumLead else { return nil }
        return next
    }

    func decodedFrameDuration(after prepared: PreparedFrame) -> CMTime {
        guard prepared.isTimeVarying,
              let next = nextDecodedFrame(after: prepared, maximumLead: 0.25) else { return .invalid }
        let interval = next - prepared.sourcePresentationTime - (prepared.sourceShift ?? 0)
        guard interval > 0, interval <= 1 else { return .invalid }
        return CMTime(seconds: interval, preferredTimescale: 1_000_000_000)
    }

    func currentPresentationTime(atHostTime host: CFTimeInterval, delaySeconds: Double) -> Double? {
        guard let track = engine.subtitleTracks.first(where: { $0.id == selectedTrackID }) else { return nil }
        return Self.rendererTime(Self.renderTime(engineTime: presentationClock(host).sourceTime,
            timelineOffset: timelineOffset, isExternal: track.isExternal, delaySeconds: delaySeconds))
    }

    func resolveFrameTimestamp(_ prepared: PreparedFrame) -> PreparedFrame? {
        guard prepared.awaitsFrameTimestamp else { return prepared }
        let source = prepared.sourcePresentationTime + (prepared.sourceShift ?? 0)
        guard let aligned = nextSourceFrame(source, prepared.hostTime) else { return nil }
        return PreparedFrame(frame: prepared.frame, time: prepared.time, hostTime: prepared.hostTime,
                             sourcePresentationTime: aligned - (prepared.sourceShift ?? 0),
                             presentationTime: prepared.presentationTime + aligned - source,
                             beginsInterval: prepared.beginsInterval, awaitsFrameTimestamp: false,
                             validity: prepared.validity, generation: prepared.generation,
                             clockIdentity: prepared.clockIdentity, sourceShift: prepared.sourceShift,
                             isAdvancing: prepared.isAdvancing, isTimeVarying: prepared.isTimeVarying,
                             activeEvents: prepared.activeEvents)
    }

    func prepareFrame(size: CGSize, scale: CGFloat, delaySeconds: Double,
                      atHostTime hostTime: CFTimeInterval, sourceTime: Double? = nil) async -> PreparedFrame? {
        guard sourceTime != nil || !engine.isSeeking else { return nil }
        guard enabled, handlesCurrentTrack,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            setFrame(nil)
            return nil
        }
        if fontSelection != track.id { prepareFonts(trackID: track.id) }
        guard !isLoadingFonts, failureMessage == nil else { return nil }
        let header = track.isExternal ? engine.sidecarASSHeader : track.assHeader
        guard let header, !header.isEmpty else {
            setFrame(nil)
            if !engine.isLoadingSubtitles {
                reportFailure("Subtitle data couldn’t be loaded. Turn subtitles off and on to retry.",
                              error: URLError(.cannotDecodeContentData))
            }
            return nil
        }
        let epoch = generation
        let worker = renderer
        let continuous = sampleClock(hostTime)
        var sample = continuous
        var requestedTime = Self.renderTime(engineTime: sourceTime ?? sample.sourceTime,
                                   timelineOffset: timelineOffset, isExternal: track.isExternal,
                                   delaySeconds: delaySeconds)
        if sourceTime == nil, Self.activeEvents(events, at: requestedTime).contains(where: { $0.isTimeVarying }) {
            sample = presentationClock(hostTime)
            requestedTime = Self.renderTime(engineTime: sample.sourceTime,
                                           timelineOffset: timelineOffset, isExternal: track.isExternal,
                                           delaySeconds: delaySeconds)
        }
        let offset = (track.isExternal ? timelineOffset : 0) - delaySeconds
        if Self.activeEvents(events, at: requestedTime).contains(where: { $0.isTimeVarying }),
           let videoTime = nextSourceFrame(requestedTime - offset, hostTime) {
            // The raster and its queued timestamp must describe the same frame,
            // including a seek target between two decoded video timestamps.
            requestedTime = videoTime + offset
        }
        guard let time = Self.rendererTime(requestedTime) else { return nil }
        let activeEvents = Self.activeEvents(events, at: time)
        let varying = activeEvents.contains { $0.isTimeVarying }
        let validity = Self.validityInterval(events: events, at: time)
        let boundary = varying || !validity.lowerBound.isFinite ? requestedTime : validity.lowerBound
        let alignedSource = nextSourceFrame(boundary - offset, hostTime)
        let presentationTime = alignedSource.map { $0 + offset } ?? boundary
        let intervalFirstFrame = nextSourceFrame(validity.lowerBound - offset, hostTime).map { $0 + offset }
        let beginsInterval = intervalFirstFrame.map { abs(presentationTime - $0) < 0.000001 }
            ?? (time <= validity.lowerBound + 0.001)
        do {
            let rendered = try await worker.render(header: header, fonts: selectedFonts,
                                                   events: events, revision: cueRevision, time: requestedTime, size: size, scale: scale)
            guard !Task.isCancelled, epoch == generation, enabled,
                  activeEvents == Self.activeEvents(events, at: time) else { return nil }
            if !didRecordFrame, rendered != nil, events.contains(where: { $0.start <= time && time < $0.end }) {
                didRecordFrame = true
                #if os(iOS) || os(tvOS)
                DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles",
                    message: "Local ASS frame ready: events=\(events.count) fonts=\(selectedFonts.count) source=\(track.isExternal ? "sidecar" : "embedded")")
                #endif
            }
            return PreparedFrame(frame: rendered, time: time, hostTime: hostTime, sourcePresentationTime: presentationTime - offset - (sample.sourceShift ?? 0), presentationTime: presentationTime, beginsInterval: beginsInterval, awaitsFrameTimestamp: alignedSource == nil && boundary.isFinite,
                                 validity: validity, generation: epoch,
                                 clockIdentity: sample.identity, sourceShift: sample.sourceShift,
                                 isAdvancing: sample.isAdvancing,
                                 isTimeVarying: varying,
                                 activeEvents: activeEvents)
        } catch {
            guard epoch == generation, !Task.isCancelled else { return nil }
            reportFailure("Subtitles couldn’t be rendered.", error: error)
            return nil
        }
    }

    @discardableResult
    func present(_ prepared: PreparedFrame, atHostTime hostTime: CFTimeInterval,
                 delaySeconds: Double, maximumAge: CFTimeInterval = .infinity) -> Bool {
        guard enabled, prepared.generation == generation,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            return false
        }
        let sample = presentationClock(hostTime)
        guard let time = Self.rendererTime(Self.renderTime(engineTime: sample.sourceTime,
                                   timelineOffset: timelineOffset, isExternal: track.isExternal,
                                   delaySeconds: delaySeconds)) else { return false }
        guard sample.identity == prepared.clockIdentity,
              sample.sourceShift == nil || prepared.sourceShift == nil || sample.sourceShift == prepared.sourceShift,
              prepared.validity.contains(time),
              prepared.activeEvents == Self.activeEvents(events, at: time) else { return false }
        if prepared.isTimeVarying {
            guard time == prepared.time else { return false }
        }
        presentedFrame = prepared
        setFrame(prepared.frame, keepPresentation: true)
        return true
    }

    func expireFrame(atHostTime hostTime: CFTimeInterval, delaySeconds: Double,
                     maximumAge: CFTimeInterval = .infinity) {
        guard let presentedFrame,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else { return }
        let sample = presentationClock(hostTime)
        guard let time = Self.rendererTime(Self.renderTime(engineTime: sample.sourceTime,
                                   timelineOffset: timelineOffset, isExternal: track.isExternal,
                                   delaySeconds: delaySeconds)) else {
            setFrame(nil)
            return
        }
        if sample.identity != presentedFrame.clockIdentity || !presentedFrame.validity.contains(time)
            || presentedFrame.activeEvents != Self.activeEvents(events, at: time)
            || (sample.sourceShift != nil && presentedFrame.sourceShift != nil && sample.sourceShift != presentedFrame.sourceShift)
            || (presentedFrame.isTimeVarying && !engine.isSeeking && time != presentedFrame.time) {
            setFrame(nil)
        }
    }

    func isCurrent(_ prepared: PreparedFrame, atHostTime hostTime: CFTimeInterval) -> Bool {
        let current = sampleClock(hostTime)
        return enabled && prepared.generation == generation
            && current.identity == prepared.clockIdentity
            && (current.sourceShift == nil || prepared.sourceShift == nil || current.sourceShift == prepared.sourceShift)
            && prepared.activeEvents == Self.activeEvents(events, at: prepared.time)
    }

    func animationClock(atHostTime hostTime: CFTimeInterval, delaySeconds: Double) -> (time: Double, rate: Double)? {
        guard enabled, let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else { return nil }
        let current = sampleClock(hostTime)
        guard current.identity != nil else { return nil }
        let future = sampleClock(hostTime + 1)
        let time = Self.renderTime(engineTime: current.sourceTime, timelineOffset: timelineOffset,
                                   isExternal: track.isExternal, delaySeconds: delaySeconds)
        return (time, current.isAdvancing ? max(0, future.sourceTime - current.sourceTime) : 0)
    }

    /// Prepare the next static event boundary before it reaches the screen.
    /// Sampling beyond a paused clock never invents a future playback position.
    func nextPreparationHostTime(after hostTime: CFTimeInterval,
                                 maximumLead: CFTimeInterval,
                                 delaySeconds: Double) -> CFTimeInterval? {
        guard maximumLead.isFinite, maximumLead > 0 else { return nil }
        guard let presentedFrame,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            return hostTime
        }
        let current = sampleClock(hostTime)
        let time = Self.renderTime(engineTime: current.sourceTime, timelineOffset: timelineOffset,
                                   isExternal: track.isExternal, delaySeconds: delaySeconds)
        let future = sampleClock(hostTime + maximumLead)
        let rate = (future.sourceTime - current.sourceTime) / maximumLead
        guard current.isAdvancing, rate.isFinite, rate > 0 else { return nil }
        let boundary: Double
        if presentedFrame.isTimeVarying {
            let offset = (track.isExternal ? timelineOffset : 0) - delaySeconds
            guard let next = nextSourceFrame(presentedFrame.presentationTime - offset + 0.00001, hostTime) else { return hostTime }
            boundary = next + offset
        } else {
            boundary = presentedFrame.validity.upperBound
        }
        let seconds = (boundary - time) / rate
        guard seconds.isFinite, seconds >= 0, seconds <= maximumLead else { return nil }
        // Stay inside the new millisecond interval after floating-point clock conversion.
        return hostTime + seconds + 0.001
    }

    private func setFrame(_ next: ASSSubtitleRenderer.Frame?, keepPresentation: Bool = false) {
        if !keepPresentation { presentedFrame = nil }
        guard frame?.image !== next?.image || frame?.rect != next?.rect else { return }
        frame = next
        frames.send(next)
    }

    private static func activeEvents(_ events: [ASSSubtitleRenderer.Event], at time: Double) -> Set<ASSSubtitleRenderer.Event> {
        Set(events.filter { eventInterval($0)?.contains(time) == true })
    }

    private static func validityInterval(events: [ASSSubtitleRenderer.Event], at time: Double) -> Range<Double> {
        var start = -Double.infinity
        var end = Double.infinity
        for event in events {
            guard let interval = eventInterval(event) else { continue }
            for boundary in [interval.lowerBound, interval.upperBound] {
                if boundary <= time { start = max(start, boundary) }
                else { end = min(end, boundary) }
            }
        }
        return start..<end
    }

    private static func eventInterval(_ event: ASSSubtitleRenderer.Event) -> Range<Double>? {
        let start = max(0, event.start)
        guard start.isFinite, event.end.isFinite, event.end > start,
              event.end < Double(Int64.max / 1_000) else { return nil }
        let startMilliseconds = Int64((start * 1_000).rounded())
        let endMilliseconds = Int64((event.end * 1_000).rounded())
        return (Double(startMilliseconds) / 1_000)..<(Double(endMilliseconds) / 1_000)
    }

    private static func rendererTime(_ time: Double) -> Double? {
        guard time.isFinite, abs(time) < Double(Int64.max / 1_000) else { return nil }
        return Double(Int64(time * 1_000)) / 1_000
    }

    nonisolated static func renderTime(engineTime: Double, timelineOffset: Double,
                           isExternal: Bool, delaySeconds: Double) -> Double {
        engineTime + (isExternal ? timelineOffset : 0) - delaySeconds
    }

    private func prepareFonts(trackID: Int) {
        fontSelection = trackID
        if !engine.fontAttachments.isEmpty {
            selectedFonts = engine.fontAttachments
            return
        }
        guard let resource = fontRequests[trackID], let url = resource.request.url else { return }
        if let cached = fontCache[url] {
            selectedFonts = cached
            return
        }
        isLoadingFonts = true
        let epoch = fontGeneration
        let loader = fontLoader
        fontTask = Task { [weak self] in
            do {
                let fonts = try await loader(resource.request, resource.authorization)
                guard let self, !Task.isCancelled, epoch == fontGeneration else { return }
                fontCache[url] = fonts
                selectedFonts = fonts
                isLoadingFonts = false
            } catch {
                guard let self, !Task.isCancelled, epoch == fontGeneration else { return }
                isLoadingFonts = false
                reportFailure("Subtitle fonts couldn’t be loaded. Turn subtitles off and on to retry.", error: error)
            }
        }
    }

    private func reportFailure(_ message: String, error: Error) {
        setFrame(nil)
        failureMessage = message
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles", message: message)
        #endif
        let underlying = error as NSError
        Self.logger.error("ASS subtitle failure domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public)")
    }

    nonisolated static func loadFonts(_ request: URLRequest, authorization: HTTPRequestAuthorization? = nil) async throws -> [FontAttachment] {
        var request = request
        request.timeoutInterval = 60
        let data: Data
        if let authorization {
            guard let url = request.url else { throw URLError(.badURL) }
            data = try await authorization.data(from: url, maximumBytes: 48 * 1_024 * 1_024, timeout: 60)
        } else if let url = request.url, url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            data = body
        }
        return try decodeFonts(data)
    }

    /// `GET /api/v2/stream/{session_id}/subtitles/{track}/fonts` answers with
    /// the shared collection envelope, `{"items": [{"name", "data"}]}`.
    nonisolated static func decodeFonts(_ data: Data) throws -> [FontAttachment] {
        struct Item: Decodable { let name: String; let data: Data }
        struct Bundle: Decodable { let items: [Item] }
        guard data.count <= 48 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        let items = try JSONDecoder().decode(Bundle.self, from: data).items
        guard items.count <= 64, items.allSatisfy({ !$0.name.isEmpty && !$0.data.isEmpty }),
              items.reduce(0, { $0 + $1.data.count }) <= 32 * 1_024 * 1_024 else {
            throw URLError(.cannotDecodeContentData)
        }
        return items.map { FontAttachment(filename: $0.name, mimeType: "", data: $0.data) }
    }
}
