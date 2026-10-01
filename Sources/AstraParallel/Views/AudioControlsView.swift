import SwiftUI

struct AudioControlsView: View {
    @ObservedObject var session: VirtualMachineSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("VM Audio").font(.headline)
                Spacer()
                Text("\(Int(session.playbackVolume * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $session.playbackVolume, in: 0...1)
                    .accessibilityLabel("VM volume")
                    .accessibilityValue("\(Int(session.playbackVolume * 100)) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            Toggle("Mute VM audio", isOn: $session.playbackMuted)
            Divider()
            Toggle("Mute when Astra is in the background", isOn: $session.muteAudioInBackground)
            if session.muteAudioInBackground && !session.applicationActive {
                Text("Audio is muted while Astra is in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 310)
    }
}
