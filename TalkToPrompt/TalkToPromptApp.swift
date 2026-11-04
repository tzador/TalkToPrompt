import AppKit
import SwiftUI

@main
struct TalkToPromptApp: App {
    var body: some Scene {
        Window("TalkToPrompt", id: "main") {
            ContentView()
                .background(WindowButtonConfiguration())
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}

private struct WindowButtonConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView {
        WindowView()
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        private weak var positionedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false

            guard positionedWindow !== window else { return }
            positionedWindow = window
            // Wait for SwiftUI to establish the content-fitted window size.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      let screen = NSScreen.screens.first else { return }
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            }
        }
    }
}
