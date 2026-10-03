import AVFoundation
import Combine
import IOSurface
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ASSSubtitleLayer: View {
    @ObservedObject var session: ASSSubtitleSession
    let videoRect: CGRect
    let delaySeconds: Double
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            ASSSubtitleCanvas(session: session, videoRect: videoRect,
                              scale: displayScale, delaySeconds: delaySeconds)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = session.failureMessage {
                status(message)
            } else if session.isLoadingFonts {
                status("Loading subtitle fonts…")
            }
        }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .position(x: videoRect.midX, y: videoRect.maxY - videoRect.height * 0.1)
    }
}

#if os(macOS)
@MainActor
private struct ASSSubtitleCanvas: NSViewRepresentable {
    let session: ASSSubtitleSession
    let videoRect: CGRect
    let scale: CGFloat
    let delaySeconds: Double

    func makeCoordinator() -> ASSSubtitleDisplayDriver { ASSSubtitleDisplayDriver() }

    func makeNSView(context: Context) -> ASSSubtitleCanvasView {
        let view = ASSSubtitleCanvasView()
        let driver = context.coordinator
        driver.attach(view)
        view.onWindowChange = { [weak driver] visible in driver?.setVisible(visible) }
        return view
    }

    func updateNSView(_ view: ASSSubtitleCanvasView, context: Context) {
        context.coordinator.configure(session: session, videoRect: videoRect,
                                      scale: scale, delaySeconds: delaySeconds)
        context.coordinator.setVisible(view.window != nil)
    }

    static func dismantleNSView(_ view: ASSSubtitleCanvasView, coordinator: ASSSubtitleDisplayDriver) {
        view.onWindowChange = nil
        coordinator.detach()
    }
}

private final class ASSSubtitleCanvasView: NSView {
    var onWindowChange: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        displayLink(target: target, selector: selector)
    }

    var subtitleLayer: CALayer { layer! }
}
#else
@MainActor
private struct ASSSubtitleCanvas: UIViewRepresentable {
    let session: ASSSubtitleSession
    let videoRect: CGRect
    let scale: CGFloat
    let delaySeconds: Double

    func makeCoordinator() -> ASSSubtitleDisplayDriver { ASSSubtitleDisplayDriver() }

    func makeUIView(context: Context) -> ASSSubtitleCanvasView {
        let view = ASSSubtitleCanvasView()
        let driver = context.coordinator
        driver.attach(view)
        view.onWindowChange = { [weak driver] visible in driver?.setVisible(visible) }
        return view
    }

    func updateUIView(_ view: ASSSubtitleCanvasView, context: Context) {
        context.coordinator.configure(session: session, videoRect: videoRect,
                                      scale: scale, delaySeconds: delaySeconds)
        context.coordinator.setVisible(view.window != nil)
    }

    static func dismantleUIView(_ view: ASSSubtitleCanvasView, coordinator: ASSSubtitleDisplayDriver) {
        view.onWindowChange = nil
        coordinator.detach()
    }
}

private final class ASSSubtitleCanvasView: UIView {
    var onWindowChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }

    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        CADisplayLink(target: target, selector: selector)
    }

    var subtitleLayer: CALayer { layer }
}
#endif

@MainActor
private final class ASSSubtitleDisplayDriver: NSObject {
    private struct StagedFrame {
        let prepared: ASSSubtitleSession.PreparedFrame
        let targetTime: CFTimeInterval
        var isEnqueued = false
    }

    private weak var view: ASSSubtitleCanvasView?
    private weak var session: ASSSubtitleSession?
    private let imageLayer = CALayer()
    private let sampleLayer = AVSampleBufferDisplayLayer()
    private let heldLayer = CALayer()
    private struct ScheduledRaster {
        let prepared: ASSSubtitleSession.PreparedFrame
        let canvasSize: CGSize
    }
    private var scheduledRasters: [ScheduledRaster] = []
    private var sampleLayerPrimed = false
    private var frameSubscription: AnyCancellable?
    private var invalidationSubscription: AnyCancellable?
    private var seekSubscription: AnyCancellable?
    private var displayLink: CADisplayLink?
    private var renderTask: Task<Void, Never>?
    private var renderInFlight = false
    private var stagedFrame: StagedFrame?
    private var queuedFrames: [ASSSubtitleSession.PreparedFrame] = []
    private var lastEnqueuedBuffer: CVPixelBuffer?
    private var readyDisplayBuffer: CVPixelBuffer?
    private var version: UInt64 = 0
    private var videoRect = CGRect.zero
    private var scale: CGFloat = 1
    private var delaySeconds = 0.0
    private var estimatedRenderDuration = 0.0
    private var displayedPreparedHostTime: CFTimeInterval?
    private var displayedMaximumAge = 0.0
    private let scheduledKey = "ASSNextFrame"

    func attach(_ view: ASSSubtitleCanvasView) {
        self.view = view
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        view.subtitleLayer.addSublayer(imageLayer)
        sampleLayer.isOpaque = false
        sampleLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        sampleLayer.videoGravity = .resize
        view.subtitleLayer.addSublayer(sampleLayer)
        heldLayer.contentsGravity = .resize
        heldLayer.opacity = 0
        view.subtitleLayer.addSublayer(heldLayer)
    }

    func configure(session: ASSSubtitleSession, videoRect: CGRect,
                   scale: CGFloat, delaySeconds: Double) {
        let changed = self.session !== session || self.videoRect != videoRect
            || self.scale != scale || self.delaySeconds != delaySeconds
        guard changed else { return }

        let sessionChanged = self.session !== session
        let timingChanged = self.delaySeconds != delaySeconds
        let preservesQueuedFrames = !sessionChanged && !timingChanged && session.renderingTimebase != nil
        self.session = session
        self.videoRect = videoRect
        self.scale = scale
        self.delaySeconds = delaySeconds
        session.configureRendering(size: videoRect.size, scale: scale, delaySeconds: delaySeconds)
        if preservesQueuedFrames {
            // Full-canvas buffers retain their timing when the video rectangle
            // changes. Scale the visible and queued buffers while warming the
            // next frames at the new resolution.
            version &+= 1
            renderTask?.cancel()
            renderTask = nil
            renderInFlight = false
            if stagedFrame?.isEnqueued != true { stagedFrame = nil }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.frame = videoRect
            heldLayer.frame = videoRect
            CATransaction.commit()
            return
        }
        invalidatePendingWork()
        session.invalidatePendingFrames()
        show(nil)

        if sessionChanged {
            session.waitForDisplay = { [weak self] in await self?.waitForReadyDisplay() }
            session.holdDisplay = { [weak self] image in self?.holdDisplay(image) }
            session.releaseDisplay = { [weak self] in self?.releaseHeldDisplay() }
            frameSubscription = session.frames.sink { [weak self] frame in
                self?.show(frame)
            }
            invalidationSubscription = session.invalidations.sink { [weak self] in
                self?.invalidatePendingWork()
                self?.show(nil)
            }
            seekSubscription = session.readyFrames.sink { [weak self, weak session] update in
                guard let self, let session else { return }
                let prepared = update.prepared
                if update.replacesPendingFrames {
                    self.invalidatePendingWork()
                    self.scheduledRasters.removeAll(keepingCapacity: true)
                }
                let queued = !prepared.awaitsFrameTimestamp && self.schedule(prepared)
                if update.replacesPendingFrames, queued { self.readyDisplayBuffer = self.lastEnqueuedBuffer }
                if queued, !prepared.isStatic, session.renderingTimebase != nil {
                    self.queuedFrames.append(prepared)
                    session.present(prepared, atHostTime: CACurrentMediaTime(), delaySeconds: self.delaySeconds)
                } else {
                    self.stagedFrame = StagedFrame(prepared: prepared, targetTime: prepared.hostTime, isEnqueued: queued)
                }
            }
        }
        if !sessionChanged, timingChanged { session.renderingTimingDidChange?() }
    }

    func setVisible(_ visible: Bool) {
        guard let view else { return }
        if visible {
            guard displayLink == nil else { return }
            let link = view.makeDisplayLink(target: self, selector: #selector(displayTick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            guard displayLink != nil else { return }
            displayLink?.invalidate()
            displayLink = nil
            invalidatePendingWork()
            session?.invalidatePendingFrames()
            show(nil)
        }
    }

    func detach() {
        setVisible(false)
        frameSubscription = nil
        invalidationSubscription = nil
        seekSubscription = nil
        session?.waitForDisplay = nil
        session?.holdDisplay = nil
        session?.releaseDisplay = nil
        session = nil
        imageLayer.removeFromSuperlayer()
        sampleLayer.removeFromSuperlayer()
        heldLayer.removeFromSuperlayer()
        view = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard let session else { return }
        let nextDisplay = link.targetTimestamp
        guard nextDisplay.isFinite else { return }
        let nominal = link.duration.isFinite && link.duration > 0 ? link.duration : 1.0 / 60
        let observed = nextDisplay - link.timestamp
        let interval = observed.isFinite && observed > 0
            ? min(max(1.0 / 240, observed), max(1.0 / 24, nominal))
            : nominal
        let maximumAge = interval * 2
        if queuedFrames.contains(where: { !session.isCurrent($0, atHostTime: link.timestamp) }) {
            invalidatePendingWork()
        }
        if let time = session.currentPresentationTime(atHostTime: link.timestamp, delaySeconds: delaySeconds) {
            while let first = queuedFrames.first, first.time <= time {
                session.present(first, atHostTime: link.timestamp, delaySeconds: delaySeconds)
                queuedFrames.removeFirst()
            }
        }
        if let timing = session.animationClock(atHostTime: link.timestamp, delaySeconds: delaySeconds) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.speed = Float(timing.rate)
            imageLayer.beginTime = imageLayer.superlayer?.convertTime(link.timestamp, from: nil) ?? link.timestamp
            imageLayer.timeOffset = timing.time
            CATransaction.commit()
        }

        if let stagedFrame, !session.isCurrent(stagedFrame.prepared, atHostTime: link.timestamp) {
            self.stagedFrame = nil
            imageLayer.removeAnimation(forKey: scheduledKey)
            // Discard an outgoing cue's queued cut without blanking the frame
            // that is still visible while playback or selection is changing.
            sampleLayer.sampleBufferRenderer.flush()
        }
        if let stagedFrame, stagedFrame.prepared.awaitsFrameTimestamp,
           let resolved = session.resolveFrameTimestamp(stagedFrame.prepared) {
            self.stagedFrame = StagedFrame(prepared: resolved, targetTime: stagedFrame.targetTime)
        }
        if let stagedFrame, !stagedFrame.prepared.awaitsFrameTimestamp, !stagedFrame.isEnqueued {
            self.stagedFrame?.isEnqueued = schedule(stagedFrame.prepared)
        }
        if let stagedFrame, stagedFrame.isEnqueued, !stagedFrame.prepared.isStatic,
           session.renderingTimebase != nil {
            queuedFrames.append(stagedFrame.prepared)
            self.stagedFrame = nil
        }
        if let stagedFrame {
            if stagedFrame.isEnqueued,
               session.present(stagedFrame.prepared, atHostTime: link.timestamp,
                               delaySeconds: delaySeconds, maximumAge: maximumAge) {
                self.stagedFrame = nil
                if stagedFrame.prepared.frame != nil {
                    displayedPreparedHostTime = stagedFrame.prepared.hostTime
                    displayedMaximumAge = maximumAge
                } else {
                    displayedPreparedHostTime = nil
                    displayedMaximumAge = 0
                }
            } else if (!stagedFrame.prepared.isStatic && stagedFrame.targetTime < nextDisplay - maximumAge)
                || (session.animationClock(atHostTime: link.timestamp, delaySeconds: delaySeconds)?.time ?? -.infinity) >= stagedFrame.prepared.intervalEnd {
                self.stagedFrame = nil
                imageLayer.removeAnimation(forKey: scheduledKey)
            }
        }
        session.expireFrame(atHostTime: link.timestamp, delaySeconds: delaySeconds,
                            maximumAge: max(maximumAge, displayedMaximumAge))

        guard stagedFrame == nil, queuedFrames.count < 5, !renderInFlight, !session.isLoadingFonts,
              session.failureMessage == nil, videoRect.width > 0,
              videoRect.height > 0, scale > 0 else { return }
        let lead = estimatedRenderDuration.isFinite ? estimatedRenderDuration : 0
        let framesAhead = Int(min(4.0, max(1.0, ceil(lead / interval))))
        let followingSource = queuedFrames.last.flatMap { session.nextDecodedFrame(after: $0, maximumLead: 0.25) }
        if !queuedFrames.isEmpty, followingSource == nil { return }
        guard let preparationTime = followingSource != nil ? nextDisplay : session.nextPreparationHostTime(
            after: nextDisplay, maximumLead: 1, delaySeconds: delaySeconds
        ) else { return }
        let renderTarget = preparationTime > nextDisplay
            ? preparationTime
            : nextDisplay + Double(framesAhead) * interval
        if let displayedPreparedHostTime {
            displayedMaximumAge = max(maximumAge,
                                      min(interval * 5, renderTarget - displayedPreparedHostTime))
        }
        let requestVersion = version
        let started = CACurrentMediaTime()
        let size = videoRect.size
        let renderScale = scale
        let delay = delaySeconds
        renderInFlight = true
        renderTask = Task { [weak self] in
            let prepared = await session.prepareFrame(size: size, scale: renderScale,
                                                      delaySeconds: delay, atHostTime: renderTarget,
                                                      sourceTime: followingSource)
            guard let self, requestVersion == self.version else { return }
            self.renderInFlight = false
            self.renderTask = nil
            guard let prepared else { return }
            let duration = CACurrentMediaTime() - started
            self.estimatedRenderDuration = self.estimatedRenderDuration * 0.7 + duration * 0.3
            self.stagedFrame = StagedFrame(prepared: prepared, targetTime: renderTarget)
            if prepared.presentationTime.isFinite, !prepared.awaitsFrameTimestamp {
                self.stagedFrame?.isEnqueued = self.schedule(prepared)
            }
            if self.stagedFrame?.isEnqueued == true, !prepared.isStatic, session.renderingTimebase != nil {
                self.queuedFrames.append(prepared)
                self.stagedFrame = nil
                await self.warmFollowingFrames(after: prepared, requestVersion: requestVersion)
            }
        }
    }

    private func warmFollowingFrames(after first: ASSSubtitleSession.PreparedFrame, requestVersion: UInt64) async {
        guard let session else { return }
        var previous = first
        renderInFlight = true
        defer { if requestVersion == version { renderInFlight = false; renderTask = nil } }
        while requestVersion == version, queuedFrames.count < 5, !Task.isCancelled,
              let source = session.nextDecodedFrame(after: previous, maximumLead: 0.25),
              let next = await session.prepareFrame(size: videoRect.size, scale: scale, delaySeconds: delaySeconds,
                                                   atHostTime: CACurrentMediaTime(), sourceTime: source) {
            guard requestVersion == version, !Task.isCancelled else { return }
            let queued = !next.awaitsFrameTimestamp && schedule(next)
            if queued, !next.isStatic {
                queuedFrames.append(next)
                previous = next
            } else {
                stagedFrame = StagedFrame(prepared: next, targetTime: next.hostTime, isEnqueued: queued)
                return
            }
        }
    }

    private func invalidatePendingWork() {
        version &+= 1
        renderTask?.cancel()
        renderTask = nil
        renderInFlight = false
        stagedFrame = nil
        queuedFrames.removeAll(keepingCapacity: true)
        readyDisplayBuffer = nil
        imageLayer.removeAllAnimations()
        // A seek keeps the outgoing video visible until its replacement lands.
        // Keep its subtitle too; the warmed replacement is queued at landing.
        sampleLayer.sampleBufferRenderer.flush()
    }

    /// Queue warmed rasters on the same timebase and PTS as the video frames.
    @discardableResult
    private func schedule(_ prepared: ASSSubtitleSession.PreparedFrame) -> Bool {
        guard prepared.sourcePresentationTime.isFinite else { return false }
        if let timebase = session?.renderingTimebase {
            guard sampleLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return false }
            imageLayer.opacity = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if sampleLayer.controlTimebase !== timebase { sampleLayer.controlTimebase = timebase }
            sampleLayer.frame = videoRect
            CATransaction.commit()
            if !sampleLayerPrimed {
                // A display layer presents its first buffer immediately. Prime it
                // with transparent pixels so a warmed future cue stays scheduled.
                let now = min(CMTimebaseGetTime(timebase).seconds, prepared.sourcePresentationTime) - 0.000001
                if let empty = sampleBuffer(prepared, empty: true, time: now) {
                    sampleLayer.sampleBufferRenderer.enqueue(empty)
                    sampleLayerPrimed = true
                }
            }
            guard let buffer = sampleBuffer(prepared) else { return false }
            sampleLayer.sampleBufferRenderer.enqueue(buffer)
            lastEnqueuedBuffer = CMSampleBufferGetImageBuffer(buffer)
            scheduledRasters.removeAll { abs($0.prepared.sourcePresentationTime - prepared.sourcePresentationTime) < 0.000001 }
            scheduledRasters.append(ScheduledRaster(prepared: prepared, canvasSize: videoRect.size))
            if scheduledRasters.count > 12 { scheduledRasters.removeFirst(scheduledRasters.count - 12) }
            return true
        }
        sampleLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        sampleLayerPrimed = false
        let frame = prepared.frame
        let rect = frame.map {
            CGRect(x: videoRect.minX + $0.rect.minX, y: videoRect.minY + $0.rect.minY,
                   width: $0.rect.width, height: $0.rect.height)
        } ?? imageLayer.frame
        let contents = CAKeyframeAnimation(keyPath: "contents")
        contents.values = [frame?.image as Any? ?? NSNull()]
        contents.calculationMode = .discrete
        let bounds = CAKeyframeAnimation(keyPath: "bounds")
        #if os(macOS)
        bounds.values = [NSValue(rect: CGRect(origin: .zero, size: rect.size))]
        #else
        bounds.values = [NSValue(cgRect: CGRect(origin: .zero, size: rect.size))]
        #endif
        bounds.calculationMode = .discrete
        let position = CAKeyframeAnimation(keyPath: "position")
        #if os(macOS)
        position.values = [NSValue(point: CGPoint(x: rect.midX, y: rect.midY))]
        #else
        position.values = [NSValue(cgPoint: CGPoint(x: rect.midX, y: rect.midY))]
        #endif
        position.calculationMode = .discrete
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [frame == nil ? 0 : 1]
        opacity.calculationMode = .discrete
        let group = CAAnimationGroup()
        group.animations = [contents, bounds, position, opacity]
        let refresh = displayLink?.duration ?? 1.0 / 60
        group.beginTime = prepared.presentationTime - (prepared.isStatic || prepared.beginsInterval ? 0 : refresh * Double(imageLayer.speed) / 2)
        group.duration = 1
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        imageLayer.isHidden = false
        imageLayer.add(group, forKey: scheduledKey)
        return true
    }

    private func holdDisplay(_ video: ASSSubtitlePresentationClock.VideoSnapshot) {
        guard heldLayer.opacity == 0 else { return }
        let width = Int((videoRect.width * scale).rounded())
        let height = Int((videoRect.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(video.image, in: rect)
        // Reading two live display layers in succession can straddle a refresh.
        // Use the queued raster belonging to this exact retained video frame.
        if let raster = scheduledRasters.filter({ $0.prepared.sourcePresentationTime <= video.itemTime + 0.000001 })
            .max(by: { $0.prepared.sourcePresentationTime < $1.prepared.sourcePresentationTime }),
           let frame = raster.prepared.frame, raster.canvasSize.width > 0, raster.canvasSize.height > 0 {
            let sx = CGFloat(width) / raster.canvasSize.width
            let sy = CGFloat(height) / raster.canvasSize.height
            context.draw(frame.image, in: CGRect(x: frame.rect.minX * sx,
                y: CGFloat(height) - frame.rect.maxY * sy,
                width: frame.rect.width * sx, height: frame.rect.height * sy))
        }
        guard let image = context.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldLayer.frame = videoRect
        heldLayer.contents = image
        heldLayer.opacity = 1
        CATransaction.commit()
    }

    private func releaseHeldDisplay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldLayer.opacity = 0
        heldLayer.contents = nil
        CATransaction.commit()
    }

    private func waitForReadyDisplay() async {
        guard let expected = readyDisplayBuffer, let timebase = session?.renderingTimebase,
              CMTimebaseGetEffectiveRate(timebase) == 0 else { return }
        let expectedSurface = CVPixelBufferGetIOSurface(expected)?.takeUnretainedValue()
        for _ in 0..<100 {
            guard !Task.isCancelled, readyDisplayBuffer === expected,
                  CMTimebaseGetEffectiveRate(timebase) == 0 else { return }
            if let displayed = sampleLayer.sampleBufferRenderer.displayedPixelBuffer() {
                if displayed === expected { return }
                if let expectedSurface, let displayedSurface = CVPixelBufferGetIOSurface(displayed)?.takeUnretainedValue(),
                   IOSurfaceGetID(expectedSurface) == IOSurfaceGetID(displayedSurface) { return }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func sampleBuffer(_ prepared: ASSSubtitleSession.PreparedFrame, empty: Bool = false, time: Double? = nil) -> CMSampleBuffer? {
        let width = Int((videoRect.width * scale).rounded())
        let height = Int((videoRect.height * scale).rounded())
        var pixel: CVPixelBuffer?
        guard width > 0, height > 0,
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel) == kCVReturnSuccess,
            let pixel else { return nil }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if !empty, let frame = prepared.frame {
            let rect = CGRect(x: frame.rect.minX * scale,
                              y: CGFloat(height) - frame.rect.maxY * scale,
                              width: frame.rect.width * scale, height: frame.rect.height * scale)
            context.draw(frame.image, in: rect)
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                  imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: time ?? prepared.sourcePresentationTime, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                  formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func show(_ frame: ASSSubtitleRenderer.Frame?) {
        if session?.handlesCurrentTrack != true {
            releaseHeldDisplay()
            scheduledRasters.removeAll(keepingCapacity: true)
            sampleLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
            sampleLayerPrimed = false
        }
        if session?.renderingTimebase != nil {
            imageLayer.opacity = 0
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAnimation(forKey: scheduledKey)
        if let frame {
            imageLayer.opacity = 1
            imageLayer.contents = frame.image
            imageLayer.frame = CGRect(x: videoRect.minX + frame.rect.minX,
                                      y: videoRect.minY + frame.rect.minY,
                                      width: frame.rect.width, height: frame.rect.height)
            imageLayer.contentsScale = scale
            imageLayer.isHidden = false
        } else {
            imageLayer.opacity = 0
            imageLayer.isHidden = false
            imageLayer.contents = nil
            displayedPreparedHostTime = nil
            displayedMaximumAge = 0
        }
        CATransaction.commit()
    }
}
