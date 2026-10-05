import AVFAudio
import Foundation
import UIKit

nonisolated struct PlaybackRuntimeDiagnostics: Sendable, Equatable {
    let description: String

    @MainActor
    init(state: PlayerState, settings: PlaybackDiagnosticSettings) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { output in
            switch output.portType {
            case .airPlay: "airPlay"
            case .bluetoothA2DP: "bluetoothA2DP"
            case .bluetoothHFP: "bluetoothHFP"
            case .bluetoothLE: "bluetoothLE"
            case .builtInSpeaker, .builtInReceiver: "builtIn"
            case .headphones: "headphones"
            case .usbAudio: "usb"
            case .HDMI: "hdmi"
            case .carAudio: "carAudio"
            default: "other"
            }
        }.sorted().joined(separator: "+")
        let application = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let category = session.category == .playback ? "playback" : "other"
        let mode = session.mode == .default ? "default" : "other"
        let policy = session.routeSharingPolicy == .longFormAudio ? "longFormAudio" : "other"
        description = [
            "runtime app=\(application) playback=\(PlaybackDiagnostics.PlaybackStatus(state.playbackState).rawValue) queue=\(state.queue.count) index=\(state.currentIndex) position=\(String(format: "%.2f", state.position)) duration=\(String(format: "%.2f", state.duration))",
            settings.description,
            "Audio session: category=\(category) mode=\(mode) policy=\(policy) outputs=\(outputs) sample-rate=\(session.sampleRate)Hz channels=\(session.outputNumberOfChannels) io-buffer=\(session.ioBufferDuration)s output-latency=\(session.outputLatency)s output-volume=\(session.outputVolume) other-audio=\(session.isOtherAudioPlaying)",
            "Device: low-power=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal-code=\(ProcessInfo.processInfo.thermalState.rawValue)"
        ].joined(separator: "\n    ")
    }
}
