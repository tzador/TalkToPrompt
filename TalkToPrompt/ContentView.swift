import SwiftUI

struct ContentView: View {
    @State private var beepPlayer = BeepPlayer()
    @State private var playbackError: String?

    var body: some View {
        Button("Play Beep") {
            do {
                try beepPlayer.play()
            } catch {
                playbackError = error.localizedDescription
            }
        }
        .controlSize(.large)
        .accessibilityHint("Plays a one-second pure tone")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 280, minHeight: 180)
        .alert("Unable to Play Beep", isPresented: Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "Audio playback failed.")
        }
    }
}

#Preview {
    ContentView()
}
