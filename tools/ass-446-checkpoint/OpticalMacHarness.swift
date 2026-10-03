#if os(macOS)
import AetherEngine
import SwiftUI

@MainActor final class OpticalMacState: ObservableObject {
    let controller: AetherPlaybackController
    @Published var stage = "ready"
    @Published var delay = 0.0
    @Published var route = "none"

    init() { controller = try! AetherPlaybackController() }

    func load(native: Bool, loopback: Bool = false) async {
        do {
            controller.stop()
            AetherEngine.setForceSoftwarePathForTesting(!native)
            let directory = URL(fileURLWithPath: "/Users/m1/silo-446-build/validation-20261003-032038/fixtures")
            let spec: AetherLoadSpec
            if native && !loopback {
                let data = try Data(contentsOf: URL(fileURLWithPath: "/Users/m1/silo-446-optical/iosApp/Tests/Fixtures/APIv2/playback_start_opaque_ids.json"))
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["server_features"] = (object["server_features"] as? [String] ?? []) + [PlaybackProtocolV3.headerAuthenticatedMediaFeature]
                var plan = object["playback_plan"] as! [String: Any]
                plan["delivery"] = PlaybackProtocolV3.PlanDelivery.transcodeHLS
                var stream = plan["stream"] as! [String: Any]
                stream["url"] = "http://127.0.0.1:8446/hls/media.m3u8"
                stream["protocol"] = "hls"; stream["container"] = "mp4"
                stream["mime_type"] = "application/vnd.apple.mpegurl"; stream["headers"] = [String: String]()
                plan["stream"] = stream
                var timeline = plan["timeline"] as! [String: Any]
                timeline["source_start_seconds"] = 0.0; timeline["player_start_seconds"] = 0.0
                plan["timeline"] = timeline
                plan["selected_tracks"] = [String: Any]()
                plan["subtitle"] = ["mode": "off", "inventory": [[String: Any]]()]
                object["playback_plan"] = plan
                let response = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self,
                    from: JSONSerialization.data(withJSONObject: object)).legacy()
                guard case .playable(let validated, let sessionID) = response.validatedForApple() else { stage = "plan rejected"; return }
                spec = try AetherLoadSpec(validating: validated, sessionID: sessionID,
                    matchContentEnabled: false, panelIsInHDRMode: false)
            } else {
                spec = try AetherLoadSpec(offlineURL: directory.appendingPathComponent("sync.mkv"),
                    startPosition: 0, audioOnly: false, panelIsInHDRMode: false)
            }
            let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
            try await controller.finishLoad(epoch)
            if native && !loopback {
                let id = controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: directory.appendingPathComponent("sync.ass"),
                    name: "SYNC", language: "eng", formatHint: "ass"), appTrackID: 1000)
                controller.selectSubtitleTrack(id: id)
            } else { controller.selectSubtitleTrack(id: 2) }
            for _ in 0..<100 {
                if !controller.engine.isLoadingSubtitles && !controller.engine.subtitleCues.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            route = controller.engine.videoRoute.rawValue
            stage = "parked"
            print("OPTICAL MAC route=\(route) cues=\(controller.engine.subtitleCues.count)")
        } catch { stage = error.localizedDescription }
    }
}

struct OpticalMacHarness: View {
    @StateObject private var state = OpticalMacState()
    var body: some View {
        VStack {
            Text("446 macOS \(state.route) / \(state.stage)").foregroundStyle(.white)
            AetherPlayerSurface(engine: state.controller.engine)
                .overlay { ASSSubtitleLayer(session: state.controller.assSubtitles,
                    videoRect: CGRect(x: 0, y: 0, width: 640, height: 360), delaySeconds: state.delay) }
                .frame(width: 640, height: 360)
            HStack {
                Button("Software") { Task { await state.load(native: false) } }
                Button("Native AVPlayer") { Task { await state.load(native: true) } }
                Button("Native loopback") { Task { await state.load(native: true, loopback: true) } }
                Button("Play / Pause") {
                    if state.controller.isPaused { state.stage = "playing"; state.controller.play() }
                    else { state.stage = "paused"; state.controller.pause() }
                }
                Button("Seek 3.25") { Task { state.stage = "seek"; let _ = await state.controller.seek(toSourceTime: 3.25); state.stage = "landed" } }
            }
            HStack {
                Button("Delay +0.5") { state.delay = 0.5; state.stage = "delay-positive" }
                Button("Delay -0.5") { state.delay = -0.5; state.stage = "delay-negative" }
                Button("1.5x") { state.controller.setSpeed(1.5); state.stage = "speed-1.5" }
                Button("1x / reset delay") { state.controller.setSpeed(1); state.delay = 0; state.stage = "reset" }
            }
        }.padding().frame(minWidth: 680, minHeight: 475).background(.black)
    }
}
#endif
