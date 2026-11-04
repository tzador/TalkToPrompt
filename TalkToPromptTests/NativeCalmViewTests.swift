import AppKit
import SwiftUI
import XCTest
@testable import TalkToPrompt

final class NativeCalmViewTests: XCTestCase {
    @MainActor
    private var ready: NativeCalmState {
        .init(inputMonitoring: .granted, accessibility: .granted, microphone: .granted,
              apiKeyStatus: "Provided sk-...7Q2A", hasAPIKey: true,
              loginStatus: "Enabled", loginRequested: true, loginNeedsApproval: false)
    }

    @MainActor
    private func host(_ state: NativeCalmState, scheme: ColorScheme) -> (NSWindow, NSHostingView<some View>) {
        let view = NativeCalmView(state: state, actions: .init(
            inputMonitoring: {}, accessibility: {}, microphone: {}, apiKey: {},
            setLogin: { _ in }, loginSettings: {}
        )).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @MainActor
    func testContentFitsWithoutExtraHeightAcrossSetupAndAppearanceStates() {
        var missing = ready
        missing.inputMonitoring = .missing
        missing.accessibility = .missing
        missing.microphone = .missing
        missing.apiKeyStatus = "Not provided"
        missing.hasAPIKey = false
        var approval = ready
        approval.loginStatus = "Needs approval"
        approval.loginNeedsApproval = true
        var checking = ready
        checking.inputMonitoring = .checking
        checking.accessibility = .checking
        var restart = ready
        restart.inputMonitoring = .restartRequired
        var unavailable = ready
        unavailable.apiKeyUnavailable = true
        unavailable.loginUnavailable = true
        unavailable.loginStatus = "Unavailable"
        var sizes: [NSSize] = []
        for scheme in [ColorScheme.light, .dark] {
            for state in [ready, missing, approval, checking, restart, unavailable] {
                let (window, host) = host(state, scheme: scheme)
                defer { window.close() }
                let size = host.fittingSize
                XCTAssertEqual(size.width, 720, accuracy: 0.5)
                XCTAssertLessThan(size.height, 800)
                XCTAssertGreaterThan(size.height, 600)
                XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.5)
                sizes.append(size)
            }
        }
        for size in sizes {
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 1, "Changing status should not resize the settings rows or window")
        }
    }

    @MainActor
    func testActualLightAndDarkRenderingAndCapturePreviews() throws {
        var backgrounds: [CGFloat] = []
        for scheme in [ColorScheme.light, .dark] {
            for isReady in [true, false] {
                var state = ready
                if !isReady {
                    state.microphone = .missing
                    state.hasAPIKey = false
                    state.apiKeyStatus = "Not provided"
                    state.loginNeedsApproval = true
                    state.loginStatus = "Needs approval"
                }
                let (window, host) = host(state, scheme: scheme)
                defer { window.close() }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "NativeCalm-\(isReady ? "ready" : "setup")-\(scheme == .dark ? "dark" : "light")"
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                if isReady {
                    let color = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4))
                    backgrounds.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                }
            }
        }
        XCTAssertGreaterThan(backgrounds[0], 0.8)
        XCTAssertLessThan(backgrounds[1], 0.3)
    }
}
