import SwiftUI
import AVFoundation
import MediaPlayer

/// Reads system volume through KVO and writes only user input through MPVolumeView.
/// Observation updates must never write back to the system volume.
struct SystemVolumeView: View {
    var contentColor: Color = .white

    @State private var observer = SystemVolumeObserver()

    var body: some View {
        ProgressSlider(
            value: Binding(
                get: { TimeInterval(observer.displayVolume) },
                set: { newValue in
                    let v = Float(max(0, min(1, newValue)))
                    observer.displayVolume = v
                    observer.userTarget = v
                }
            ),
            total: 1.0,
            onEditingChanged: { editing in observer.isEditing = editing },
            trackColor: contentColor.opacity(0.2),
            fillColor: contentColor.opacity(0.95)
        )
        .background {
            HiddenVolumeWriter(observer: observer)
                .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityLabel("Volume")
        .accessibilityValue(Double(observer.displayVolume).formatted(.percent.precision(.fractionLength(0))))
        .task {
            observer.refreshFromSystem()
        }
    }
}

/// Separates displayed volume from pending user input to prevent KVO feedback loops.
@Observable
@MainActor
private final class SystemVolumeObserver {
    var displayVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// Pending user input; nil means no system-volume write is needed.
    var userTarget: Float?
    var isEditing = false
    private var observation: NSKeyValueObservation?

    init() {
        displayVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.new]
        ) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isEditing else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    self.displayVolume = newVolume
                }
            }
        }
    }

    /// Refreshes display only; outputVolume may have been stale before audio-session setup.
    func refreshFromSystem() {
        displayVolume = AVAudioSession.sharedInstance().outputVolume
    }

}

private struct HiddenVolumeWriter: UIViewRepresentable {
    let observer: SystemVolumeObserver

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        guard let target = observer.userTarget,
              let slider = uiView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        if abs(slider.value - target) > 0.001 {
            slider.setValue(target, animated: false)
        }
        // Consume once — deferred so we don't mutate observable state during the view update; cleared only if no
        // newer value arrived, so a fast drag never drops its last value and a stale target is never re-written.
        Task { @MainActor [observer] in
            if observer.userTarget == target { observer.userTarget = nil }
        }
    }
}
