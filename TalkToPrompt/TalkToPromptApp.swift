import AppKit
import SwiftUI

@main
struct TalkToPromptApp: App {
    var body: some Scene {
        Window("TalkToPrompt", id: "main") {
            ContentView()
                .background(WindowButtonConfiguration())
        }
        .defaultSize(width: 480, height: 320)
    }
}

private struct WindowButtonConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView {
        WindowView()
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
