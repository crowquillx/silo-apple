import AetherEngine
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Silo

final class ASSSubtitlePresentationTests: XCTestCase {
    private let size = CGSize(width: 320, height: 180)

    func testDiscardedVideoTimestampsCannotAlignABackwardsSeek() {
        let frames = ASSSubtitlePresentationClock.SoftwareFrames()
        func frame(_ time: Double, _ generation: UInt64) -> SoftwareVideoFrameTime {
            SoftwareVideoFrameTime(presentation: CMTime(seconds: time, preferredTimescale: 1_000),
                                   generation: generation)
        }
        frames.append(frame(16.271, 7))
        frames.invalidate()
        frames.append(frame(16.313, 7))
        XCTAssertNil(frames.time(onOrAfter: 3.25), "Discarded outgoing frames must not date the new subtitle")
        frames.append(frame(3.271, 13))
        frames.append(frame(17.021, 10))
        XCTAssertEqual(frames.time(onOrAfter: 3.25), 3.271)
        XCTAssertNil(frames.time(onOrAfter: 4))
    }

    private final class TestClock {
        var sourceTime = 1.0
        var isAdvancing = true
        private var identity = UUID()

        func replaceIdentity() { identity = UUID() }

        func sample(atHostTime _: CFTimeInterval) -> ASSSubtitlePresentationClock.Sample {
            ASSSubtitlePresentationClock.Sample(
                sourceTime: sourceTime,
                identity: identity,
                isAdvancing: isAdvancing
            )
        }
    }

    private actor FontGate {
        var waiting: [String: CheckedContinuation<[FontAttachment], Never>] = [:]

        func load(_ request: URLRequest) async -> [FontAttachment] {
            await withCheckedContinuation { waiting[request.url!.lastPathComponent] = $0 }
        }

        func hasRequest(_ name: String) -> Bool { waiting[name] != nil }
        func finish(_ name: String) { waiting.removeValue(forKey: name)?.resume(returning: []) }
    }

    @MainActor
    func testRestoringSpeedKeepsInitialPlaybackParked() async throws {
        let clock = TestClock()
        let (controller, _) = try await loadedSession(clock: clock)
        defer { controller.stop() }
        let timebase = try XCTUnwrap(controller.engine.softwarePresentationTimebase)
        controller.setRate(1.5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(CMTimebaseGetEffectiveRate(timebase), 0)
        XCTAssertEqual(controller.engine.clock.sourceTime, 0, accuracy: 0.01)
    }

    @MainActor
    func testPausedSeekWarmsTheFirstAdmittedVideoFrame() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authored", withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.selectSubtitleTrack(id: 2)
        try await waitForCues(controller)
        controller.assSubtitles.configureRendering(size: size, scale: 1, delaySeconds: 0)
        let result = await controller.seek(toSourceTime: 0.755)
        guard case .completed = result else { return XCTFail("Paused seek did not complete") }
        let timebase = try XCTUnwrap(controller.engine.softwarePresentationTimebase)
        // Seeking between frames must park on the first admitted video PTS.
        // Aether rebases this fixture's 21 ms container origin; frame 19 is 0.792.
        XCTAssertEqual(CMTimebaseGetTime(timebase).seconds, 0.792, accuracy: 0.001)
        XCTAssertEqual(CMTimebaseGetEffectiveRate(timebase), 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(CMTimebaseGetTime(timebase).seconds, 0.792, accuracy: 0.001)
    }

    @MainActor
    func testStartupWaitSurvivesReplacementOfTheSameTracksFontRequest() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authored-no-fonts", withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        XCTAssertTrue(controller.engine.fontAttachments.isEmpty)
        controller.selectSubtitleTrack(id: 2)
        try await waitForCues(controller)
        let gate = FontGate()
        let session = ASSSubtitleSession(engine: controller.engine, fontLoader: { request, _ in
            await gate.load(request)
        })
        session.finishLoad()
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.invalid/old")!), trackID: 2)
        var completed = false
        let startup = Task { await session.prepareForPlayback(); completed = true }
        defer { startup.cancel() }
        for _ in 0..<100 {
            if await gate.hasRequest("old") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let oldStarted = await gate.hasRequest("old")
        XCTAssertTrue(oldStarted)
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.invalid/new")!), trackID: 2)
        await gate.finish("old")
        for _ in 0..<100 {
            if await gate.hasRequest("new") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let newStarted = await gate.hasRequest("new")
        XCTAssertTrue(newStarted)
        XCTAssertFalse(completed, "A cancelled old font request must not release initial playback")
        await gate.finish("new")
        await startup.value
        XCTAssertTrue(completed)
        XCTAssertFalse(session.isLoadingFonts)
    }

    @MainActor
    func testStartupRepreparesAfterCueInvalidationDuringDisplayWait() async throws {
        let clock = TestClock()
        clock.isAdvancing = false
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }
        session.configureRendering(size: size, scale: 1, delaySeconds: 0)
        var waits = 0
        session.waitForDisplay = {
            waits += 1
            if waits == 1 { session.invalidatePendingFrames() }
        }
        await session.prepareForPlayback()
        XCTAssertEqual(waits, 2, "Playback must wait for a replacement raster after its first one was invalidated")
    }

    @MainActor
    private func loadedSession(clock: TestClock) async throws -> (AetherPlaybackController, ASSSubtitleSession) {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authored", withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.selectSubtitleTrack(id: 2)
        try await waitForCues(controller)
        let session = ASSSubtitleSession(engine: controller.engine, sampleClock: clock.sample)
        session.finishLoad()
        return (controller, session)
    }

    @MainActor
    private func waitForCues(_ controller: AetherPlaybackController) async throws {
        for _ in 0..<100 {
            if !controller.engine.isLoadingSubtitles, !controller.engine.subtitleCues.isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Aether did not publish ASS cues")
    }

    @MainActor
    private func preparedFrame(_ session: ASSSubtitleSession, atHostTime hostTime: CFTimeInterval) async throws -> ASSSubtitleSession.PreparedFrame {
        let prepared = await session.prepareFrame(size: size, scale: 1, delaySeconds: 0,
                                                  atHostTime: hostTime)
        return try XCTUnwrap(prepared)
    }

    @MainActor
    private func layer(containing image: CGImage, in root: CALayer) -> CALayer? {
        if (root.contents as AnyObject?) === (image as AnyObject) { return root }
        for child in root.sublayers ?? [] {
            if let match = layer(containing: image, in: child) { return match }
        }
        return nil
    }

    @MainActor
    func testVisibleCanvasDrivesLayerAndClearsItAtCueEnd() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        let videoRect = CGRect(x: 25, y: 30, width: size.width, height: size.height)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 260)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(frame: bounds)
        window.windowScene = scene
        window.rootViewController = UIHostingController(rootView:
            ASSSubtitleLayer(session: session, videoRect: videoRect, delaySeconds: 0)
                .frame(width: bounds.width, height: bounds.height)
                .ignoresSafeArea()
        )
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
        }

        var paintedFrame: ASSSubtitleRenderer.Frame?
        var paintedLayer: CALayer?
        for _ in 0..<150 {
            window.layoutIfNeeded()
            if let frame = session.frame,
               let imageLayer = layer(containing: frame.image, in: window.layer),
               !imageLayer.isHidden {
                paintedFrame = frame
                paintedLayer = imageLayer
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try XCTUnwrap(paintedFrame, "The display link never published an ASS frame")
        let imageLayer = try XCTUnwrap(paintedLayer, "The rendered image never reached the canvas layer")
        XCTAssertEqual(imageLayer.frame.minX, videoRect.minX + frame.rect.minX, accuracy: 0.5)
        XCTAssertEqual(imageLayer.frame.minY, videoRect.minY + frame.rect.minY, accuracy: 0.5)
        XCTAssertEqual(imageLayer.frame.width, frame.rect.width, accuracy: 0.5)
        XCTAssertEqual(imageLayer.frame.height, frame.rect.height, accuracy: 0.5)

        clock.sourceTime = 6
        for _ in 0..<100 {
            if session.frame == nil, imageLayer.contents == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(session.frame)
        XCTAssertNil(imageLayer.contents)
        XCTAssertTrue(imageLayer.isHidden || imageLayer.opacity == 0)
    }

    @MainActor
    func testPreparedStaticFrameCanBeUsedEarlierInsideTheSameCue() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        clock.sourceTime = 2
        let future = try await preparedFrame(session, atHostTime: 10)
        XCTAssertNotNil(future.frame)
        clock.sourceTime = 1
        XCTAssertTrue(session.present(future, atHostTime: 11, delaySeconds: 0))
        XCTAssertTrue(session.frame?.image === future.frame?.image)

        clock.sourceTime = 2
        XCTAssertTrue(session.present(future, atHostTime: 12, delaySeconds: 0))
        XCTAssertTrue(session.frame?.image === future.frame?.image)
    }

    @MainActor
    func testEventBoundaryRejectsLateResultAndClearsDisplayedPixels() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        clock.sourceTime = 5.9
        let closing = try await preparedFrame(session, atHostTime: 10)
        XCTAssertNotNil(closing.frame)
        clock.sourceTime = 6
        XCTAssertFalse(session.present(closing, atHostTime: 11, delaySeconds: 0))
        XCTAssertNil(session.frame)

        clock.sourceTime = 5.9
        let displayed = try await preparedFrame(session, atHostTime: 12)
        XCTAssertTrue(session.present(displayed, atHostTime: 12, delaySeconds: 0))
        XCTAssertNotNil(session.frame)
        clock.sourceTime = 6
        session.expireFrame(atHostTime: 13, delaySeconds: 0)
        XCTAssertNil(session.frame, "An expired image must clear even before the next render finishes")
    }

    @MainActor
    func testStaticRasterDoesNotDisappearWhileItsCueIsStillActive() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        let prepared = try await preparedFrame(session, atHostTime: 10)
        XCTAssertNotNil(prepared.frame)
        clock.sourceTime = 1.04
        XCTAssertTrue(session.present(prepared, atHostTime: 10.04, delaySeconds: 0,
                                       maximumAge: 2.0 / 60.0),
                       "Static pixels remain correct throughout the active cue")
        XCTAssertNotNil(session.frame)

        let current = try await preparedFrame(session, atHostTime: 11)
        clock.sourceTime = 1.06
        XCTAssertTrue(session.present(current, atHostTime: 11.02, delaySeconds: 0,
                                      maximumAge: 2.0 / 60.0))
        XCTAssertNotNil(session.frame)
        clock.sourceTime = 1.1
        session.expireFrame(atHostTime: 11.04, delaySeconds: 0, maximumAge: 2.0 / 60.0)
        XCTAssertNotNil(session.frame, "Render scheduling must not make a static cue flicker")
        clock.sourceTime = 6
        session.expireFrame(atHostTime: 12, delaySeconds: 0, maximumAge: 2.0 / 60.0)
        XCTAssertNil(session.frame)
    }

    @MainActor
    func testInvalidationClearsAnAlreadyDisplayedFrameImmediately() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        let prepared = try await preparedFrame(session, atHostTime: 10)
        XCTAssertTrue(session.present(prepared, atHostTime: 10, delaySeconds: 0))
        XCTAssertNotNil(session.frame)
        session.invalidatePendingFrames()
        XCTAssertNil(session.frame)
        XCTAssertFalse(session.present(prepared, atHostTime: 10, delaySeconds: 0))
    }

    @MainActor
    func testPausedPresentationUsesTheMillisecondRenderedByLibass() async throws {
        let clock = TestClock()
        clock.isAdvancing = false
        clock.sourceTime = -0.0009
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        let prepared = try await preparedFrame(session, atHostTime: 10)
        XCTAssertEqual(prepared.time, 0)
        XCTAssertNotNil(prepared.frame)

        clock.sourceTime = 0.0001
        XCTAssertTrue(session.present(prepared, atHostTime: 11, delaySeconds: 0),
                      "Both requested times render at libass millisecond zero")
        XCTAssertNotNil(session.frame)
        session.expireFrame(atHostTime: 12, delaySeconds: 0)
        XCTAssertNotNil(session.frame)
    }

    @MainActor
    func testTrackSeekLoadAndClockReplacementFencePreparedFrames() async throws {
        let clock = TestClock()
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        let outgoing = try await preparedFrame(session, atHostTime: 10)
        controller.selectSubtitleTrack(id: 3)
        XCTAssertFalse(session.present(outgoing, atHostTime: 11, delaySeconds: 0))
        XCTAssertNil(session.frame)

        try await waitForCues(controller)
        let seekFrame = try await preparedFrame(session, atHostTime: 12)
        session.invalidatePendingFrames()
        XCTAssertFalse(session.present(seekFrame, atHostTime: 13, delaySeconds: 0))

        let previousClock = try await preparedFrame(session, atHostTime: 14)
        clock.replaceIdentity()
        XCTAssertFalse(session.present(previousClock, atHostTime: 15, delaySeconds: 0))

        let previousLoad = try await preparedFrame(session, atHostTime: 16)
        session.beginLoad(timelineOffset: 0)
        XCTAssertFalse(session.present(previousLoad, atHostTime: 17, delaySeconds: 0))
    }

    @MainActor
    func testPausedAnimatedFrameRequiresTheSameClockTime() async throws {
        let clock = TestClock()
        clock.isAdvancing = false
        let (controller, session) = try await loadedSession(clock: clock)
        defer { controller.stop() }

        let script = #"""
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,40,&H000000FF,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\move(20,30,220,30)\p1}m 0 0 l 20 0 20 20 0 20
        """#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ass")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let sidecarID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 20)
        controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url), appTrackID: sidecarID)
        controller.selectSubtitleTrack(id: sidecarID)
        try await waitForCues(controller)
        XCTAssertNotNil(controller.engine.sidecarASSHeader)

        clock.sourceTime = 1
        let early = try await preparedFrame(session, atHostTime: 10)
        XCTAssertNotNil(early.frame)
        clock.sourceTime = 2
        XCTAssertFalse(session.present(early, atHostTime: 11, delaySeconds: 0),
                       "The cue is still active, but its animated pixels belong to another time")
        XCTAssertNil(session.frame)

        let current = try await preparedFrame(session, atHostTime: 12)
        XCTAssertNotNil(current.frame)
        XCTAssertFalse(current.frame?.image === early.frame?.image)
        XCTAssertTrue(session.present(current, atHostTime: 12, delaySeconds: 0))
    }
}

import CoreImage
import CoreVideo

@MainActor
final class ASSSubtitleFrameCompositionTests: XCTestCase {
    private let size = CGSize(width: 64, height: 64)
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: linear])

    private func video(format: OSType, hdr: Bool = false) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        let transfer = hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2
        let primaries = hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
        let matrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let color = try XCTUnwrap(CGColor(colorSpace: linear, components: hdr ? [4, 2, 1, 1] : [0.1, 0.2, 0.6, 1]))
        context.render(CIImage(color: CIColor(cgColor: color)), to: buffer,
            bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_709))
        return buffer
    }

    private func subtitle() throws -> ASSSubtitleRenderer.Frame {
        let image = try XCTUnwrap(context.createCGImage(CIImage(color: .white), from: CGRect(x: 0, y: 0, width: 8, height: 8)))
        return ASSSubtitleRenderer.Frame(image: image, rect: CGRect(x: 8, y: 8, width: 16, height: 12))
    }

    private func rgba(_ pixel: CVPixelBuffer) -> [Float] {
        var values = [Float](repeating: 0, count: 64 * 64 * 4)
        values.withUnsafeMutableBytes {
            context.render(CIImage(cvPixelBuffer: pixel), toBitmap: $0.baseAddress!, rowBytes: 64 * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(origin: .zero, size: size), format: .RGBAf, colorSpace: linear)
        }
        return values
    }

    func testEmptyCueKeepsDecodedVideoBuffer() throws {
        let input = try video(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertTrue(ASSSubtitleFrameCompositor().composite(input, frame: nil, canvasSize: size) === input)
    }

    func testSDRCompositionPreservesPictureAndPlacesSubtitle() throws {
        let input = try video(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let output = try XCTUnwrap(ASSSubtitleFrameCompositor().composite(input, frame: subtitle(), canvasSize: size))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), CVPixelBufferGetPixelFormatType(input))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 64)
        let original = rgba(input), actual = rgba(output)
        for channel in 0..<3 { XCTAssertEqual(actual[(32 * 64 + 32) * 4 + channel], original[(32 * 64 + 32) * 4 + channel], accuracy: 0.02) }
        for channel in 0..<3 { XCTAssertGreaterThan(actual[(12 * 64 + 12) * 4 + channel], 0.9) }
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }

    func testHDRCompositionKeepsTenBitPQMetadataAndHighlightValues() throws {
        let input = try video(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, hdr: true)
        let output = try XCTUnwrap(ASSSubtitleFrameCompositor().composite(input, frame: subtitle(), canvasSize: size))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        let original = rgba(input), actual = rgba(output)
        let offset = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(original[offset], 1)
        for channel in 0..<3 { XCTAssertEqual(actual[offset + channel], original[offset + channel], accuracy: 0.08) }
    }
}


@MainActor
final class ASSSubtitleFailureDisplayTests: XCTestCase {
    func testFontFailureRemovesPairedPictureAndPlaybackContinues() async throws {
        AetherEngine.setForceSoftwarePathForTesting(true)
        defer { AetherEngine.setForceSoftwarePathForTesting(false) }
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authored-no-fonts", withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false, panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.selectSubtitleTrack(id: 2)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            AetherPlayerSurface(engine: controller.engine)
                .overlay { ASSSubtitleLayer(session: controller.assSubtitles,
                    videoRect: CGRect(x: 0, y: 0, width: 320, height: 180), delaySeconds: 0) }
                .frame(width: 320, height: 180))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; controller.stop() }
        controller.play()
        func layers(_ layer: CALayer) -> [AVSampleBufferDisplayLayer] {
            (layer as? AVSampleBufferDisplayLayer).map { [$0] } ?? layer.sublayers?.flatMap(layers) ?? []
        }
        var paired: AVSampleBufferDisplayLayer?
        for _ in 0..<150 {
            paired = layers(window.layer).first { $0.name == "ASSSubtitlePairedVideo" }
            if let pixel = paired?.sampleBufferRenderer.displayedPixelBuffer(), CVPixelBufferGetWidth(pixel) > 2,
               controller.engine.clock.sourceTime > 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let display = try XCTUnwrap(paired)
        let visiblePixel = try XCTUnwrap(display.sampleBufferRenderer.displayedPixelBuffer())
        XCTAssertGreaterThan(CVPixelBufferGetWidth(visiblePixel), 2, "The paired picture must be visible before failing its font request")
        XCTAssertFalse(display.isHidden)
        controller.assSubtitles.registerFontRequest(URLRequest(url: URL(fileURLWithPath: "/silo-test/missing-font-bundle.zip")), trackID: 2)
        for _ in 0..<150 {
            if controller.assSubtitles.failureMessage != nil, display.isHidden { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.assSubtitles.failureMessage)
        XCTAssertTrue(display.isHidden, "A failed subtitle must uncover the engine's moving video")
        let before = controller.engine.clock.sourceTime
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(controller.engine.clock.sourceTime, before + 0.25)
    }
}
