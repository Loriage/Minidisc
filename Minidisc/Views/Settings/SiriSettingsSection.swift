import Intents
import SwiftUI

struct SiriSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorization = INPreferences.siriAuthorizationStatus()

    var body: some View {
        Section {
            Button(action: configure) {
                switch authorization {
                case .authorized:
                    Label("Manage Siri Access", systemImage: "gearshape")
                case .denied, .restricted:
                    Label("Open Settings", systemImage: "gearshape")
                default:
                    Label("Enable Siri", systemImage: "waveform")
                }
            }
            .accessibilityIdentifier("siri-authorization")
        } header: {
            Text("Siri")
        } footer: {
            Text("Allow Siri to search your Minidisc library and control music playback.")
            Text("You can revoke Siri access in iOS Settings.")
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        authorization = INPreferences.siriAuthorizationStatus()
    }

    private func configure() {
        if authorization != .notDetermined {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } else {
            INPreferences.requestSiriAuthorization { _ in
                Task { @MainActor in refresh() }
            }
        }
    }
}
