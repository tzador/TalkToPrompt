import AppKit
import SwiftUI

@main
struct TalkToPromptApp: App {
    var body: some Scene {
        Window("TalkToPrompt", id: "main") {
            ContentView()
                .background(WindowButtonConfiguration())
        }
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentSize)
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
            window?.styleMask.remove(.resizable)
            window?.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
