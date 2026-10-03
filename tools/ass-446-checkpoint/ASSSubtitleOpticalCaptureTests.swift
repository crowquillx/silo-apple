#if os(iOS) || os(tvOS)
import AetherEngine
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor private final class OpticalState: ObservableObject {
    @Published var delay = 0.0
    @Published var width: CGFloat = 360
    @Published var stage = "onset"
}
private struct OpticalView: View {
    let controller: AetherPlaybackController
    @ObservedObject var state: OpticalState
    var body: some View {
        VStack(spacing: 12) {
            Text("446 \(controller.engine.videoRoute.rawValue) / \(state.stage)").foregroundStyle(.white)
            AetherPlayerSurface(engine: controller.engine)
                .overlay {
                    ASSSubtitleLayer(session: controller.assSubtitles,
                                     videoRect: CGRect(x: 0, y: 0, width: state.width, height: state.width * 9 / 16),
                                     delaySeconds: state.delay)
                }
                .frame(width: state.width, height: state.width * 9 / 16)
            HStack {
                Button("Pause / Resume") {
                    if controller.isPaused { controller.play() } else { controller.pause() }
                    print("OPTICAL UI pauseToggle source=\(controller.engine.clock.sourceTime) paused=\(controller.isPaused)")
                }
                Button("Seek +5") {
                    Task { let _ = await controller.seek(toSourceTime: controller.engine.clock.sourceTime + 5) }
                }
            }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).ignoresSafeArea()
    }
}
final class ASSSubtitleOpticalCaptureTests: XCTestCase {
    @MainActor func testExtendedAnimatedLoopback() async throws { try await capture(native: false, animated: true, loopback: true) }
    @MainActor func testTransportLoopback() async throws { try await capture(native: false, animated: true, transportOnly: true, loopback: true) }
    @MainActor func testSSASoftware() async throws { try await capture(native: false, short: true, legacySSA: true) }
    @MainActor func testSSANative() async throws { try await capture(native: true, short: true, legacySSA: true) }
    @MainActor func testTransportSoftware() async throws { try await capture(native: false, animated: true, transportOnly: true) }
    @MainActor func testTransportNative() async throws { try await capture(native: true, animated: true, transportOnly: true) }
    @MainActor func testShortSoftware() async throws { try await capture(native: false, short: true) }
    @MainActor func testShortNative() async throws { try await capture(native: true, short: true) }
    @MainActor func testExtendedSoftware() async throws { try await capture(native: false) }
    @MainActor func testExtendedNative() async throws { try await capture(native: true) }
    @MainActor func testExtendedAnimatedSoftware() async throws { try await capture(native: false, animated: true) }
    @MainActor func testExtendedAnimatedNative() async throws { try await capture(native: true, animated: true) }
    @MainActor func testAnimatedSoftware() async throws { try await capture(native: false, short: true, animated: true) }
    @MainActor func testAnimatedNative() async throws { try await capture(native: true, short: true, animated: true) }
    @MainActor private func capture(native: Bool, short: Bool = false, animated: Bool = false, transportOnly: Bool = false, legacySSA: Bool = false, loopback: Bool = false) async throws {
        AetherEngine.setForceSoftwarePathForTesting(!native && !loopback)
        defer { AetherEngine.setForceSoftwarePathForTesting(false) }
        let controller = try AetherPlaybackController()
        let state = OpticalState()
        #if os(tvOS)
        state.width = 1280
        #endif
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: animated ? "animated" : "sync", withExtension: "mkv"))
        let spec: AetherLoadSpec
        if native {
            var object = try PlaybackV3FixtureTestSupport.v2DecisionObject(bundleClass: Self.self)
            var plan = try XCTUnwrap(object["playback_plan"] as? [String: Any])
            plan["delivery"] = PlaybackProtocolV3.PlanDelivery.transcodeHLS
            var stream = try XCTUnwrap(plan["stream"] as? [String: Any])
            stream["url"] = "http://127.0.0.1:8446/hls/media.m3u8"
            stream["protocol"] = "hls"; stream["container"] = "mp4"
            stream["mime_type"] = "application/vnd.apple.mpegurl"; stream["headers"] = [String: String]()
            plan["stream"] = stream
            var timeline = try XCTUnwrap(plan["timeline"] as? [String: Any])
            timeline["source_start_seconds"] = 0.0; timeline["player_start_seconds"] = 0.0
            plan["timeline"] = timeline
            plan["selected_tracks"] = [String: Any]()
            plan["subtitle"] = ["mode": "off", "inventory": [[String: Any]]()]
            object["playback_plan"] = plan
            let response = try PlaybackV3FixtureTestSupport.v2Decision(object)
            guard case .playable(let validated, let sessionID) = response.validatedForApple() else {
                return XCTFail("Native controlled fixture plan rejected")
            }
            spec = try AetherLoadSpec(validating: validated, sessionID: sessionID,
                                      matchContentEnabled: false, panelIsInHDRMode: false)
            XCTAssertTrue(spec.options.nativeRemoteHLS)
        } else {
            spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false, panelIsInHDRMode: false)
        }
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        let primary: Int64
        if (native && !loopback) || legacySSA {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: animated ? "animated" : "sync", withExtension: legacySSA ? "ssa" : "ass"))
            primary = controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: "SYNC", language: "eng", formatHint: legacySSA ? "ssa" : "ass"), appTrackID: 1000)
        } else { primary = 2 }
        let alt = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "optical-alt", withExtension: "ass"))
        let secondary = controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: alt, name: "ALT", language: "eng", formatHint: "ass"), appTrackID: 1001)
        controller.selectSubtitleTrack(id: primary)
        for _ in 0..<100 {
            if !controller.engine.isLoadingSubtitles && !controller.engine.subtitleCues.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(controller.engine.subtitleCues.isEmpty)
        if loopback, controller.engine.videoRoute != .loopback {
            throw XCTSkip("Simulator routed to \(controller.engine.videoRoute.rawValue); native loopback hardware decode is unavailable")
        }
        XCTAssertEqual(controller.engine.videoRoute.rawValue, loopback ? "loopback" : native ? "remoteBypass" : "software")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: OpticalView(controller: controller, state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; controller.stop() }
        try await Task.sleep(for: .milliseconds(500))
        func mark(_ name: String) {
            state.stage = name
            print("OPTICAL CASE \(name) route=\(controller.engine.videoRoute.rawValue) source=\(controller.engine.clock.sourceTime) frame=\(controller.assSubtitles.frame != nil) delay=\(state.delay)")
        }
        func wait(_ seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
        }
        func change(_ name: String, operation: () -> Void) async throws {
            state.stage = "pending"
            let before = controller.engine.clock.sourceTime
            let started = Date()
            print("OPTICAL REQUEST \(name) source=\(before)")
            operation()
            for _ in 0..<250 {
                if controller.engine.state == .playing && controller.engine.clock.sourceTime > before + 0.01 {
                    print("OPTICAL APPLIED \(name) latency=\(Date().timeIntervalSince(started)) source=\(controller.engine.clock.sourceTime)")
                    mark(name)
                    return
                }
                try await wait(0.02)
            }
            XCTFail("Control did not resume within five seconds: \(name)")
        }
        mark("onset"); controller.play(); try await wait(12)
        if short { return }
        mark("paused"); controller.pause()
        try await wait(0.15)
        let paused = controller.engine.clock.sourceTime; try await wait(1.35)
        XCTAssertEqual(controller.engine.clock.sourceTime, paused, accuracy: 0.1)
        mark("resume"); controller.play(); try await wait(2)
        mark("seek-forward"); print("OPTICAL SEEK \(await controller.seek(toSourceTime: 16.25))"); try await wait(1.5)
        mark("seek-back"); print("OPTICAL SEEK \(await controller.seek(toSourceTime: 3.25))"); try await wait(1.5)
        mark("seek-repeated"); let _ = await controller.seek(toSourceTime: 10.25); let _ = await controller.seek(toSourceTime: 4.25); try await wait(2)
        if transportOnly { return }
        try await change("delay-positive") { state.delay = 0.5 }; try await wait(3)
        try await change("delay-negative") { state.delay = -0.5 }; try await wait(3)
        try await change("speed-1.5") { state.delay = 0; controller.setSpeed(1.5) }; try await wait(4)
        try await change("speed-0.5") { controller.setSpeed(0.5) }; try await wait(3)
        controller.setSpeed(1); controller.selectSubtitleTrack(id: nil); mark("off"); try await wait(1.5)
        try await change("on") { controller.selectSubtitleTrack(id: primary) }; try await wait(2)
        try await change("track-alt") { controller.selectSubtitleTrack(id: secondary) }; try await wait(2)
        try await change("track-sync") { controller.selectSubtitleTrack(id: primary) }; try await wait(2)
        state.width *= 0.8; mark("resize"); try await wait(2); state.width /= 0.8
        mark("drift-start"); try await wait(28)
        mark("drift-end"); try await wait(6)
        controller.prepareForReplacement(); mark("item-change")
        let replacement = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(replacement)
        if native {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: animated ? "animated" : "sync", withExtension: "ass"))
            let id = controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: "SYNC", language: "eng", formatHint: "ass"), appTrackID: 1000)
            controller.selectSubtitleTrack(id: id)
        } else { controller.selectSubtitleTrack(id: 2) }
        controller.play(); try await wait(5)
        mark("done")
    }
}
#endif

#if os(iOS) || os(tvOS)
import AetherEngine
import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Silo

final class ASSSubtitleLegacyCaptureTests: XCTestCase {
    @MainActor
    func testIssue446At24FPS() async throws {
        try await capture(fixture: "silo-issue446-24")
    }

    @MainActor
    func testIssue446At60FPS() async throws {
        try await capture(fixture: "silo-issue446-60")
    }

    @MainActor
    private func capture(fixture: String) async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.selectSubtitleTrack(id: 2)
        for _ in 0..<100 {
            if !controller.engine.isLoadingSubtitles && !controller.engine.subtitleCues.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(controller.engine.subtitleCues.isEmpty, "No fixture ASS cues arrived")

        #if os(tvOS)
        let size = CGSize(width: 1280, height: 720)
        #else
        let size = CGSize(width: 360, height: 202.5)
        #endif
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            ZStack {
                Color.black.ignoresSafeArea()
                AetherPlayerSurface(engine: controller.engine)
                    .overlay {
                        ASSSubtitleLayer(session: controller.assSubtitles,
                                         videoRect: CGRect(origin: .zero, size: size), delaySeconds: 0)
                    }
                    .frame(width: size.width, height: size.height)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
        }
        try await Task.sleep(for: .milliseconds(500))
        print("OPTICAL CASE onset fixture=\(fixture) route=\(controller.engine.videoRoute.rawValue) cues=\(controller.engine.subtitleCues.count)")
        controller.play()
        for _ in 0..<18 {
            try await Task.sleep(for: .seconds(1))
            print("OPTICAL SAMPLE fixture=\(fixture) route=\(controller.engine.videoRoute.rawValue) source=\(controller.engine.clock.sourceTime) frame=\(controller.assSubtitles.frame != nil)")
        }
        XCTAssertGreaterThan(controller.engine.clock.sourceTime, 15)
    }
}
#endif
