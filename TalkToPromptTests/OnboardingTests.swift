import AppKit
import SwiftUI
import XCTest
@testable import TalkToPrompt

final class OnboardingTests: XCTestCase {
    private let ready = OnboardingModel.Requirements(accessibility: true, inputMonitoring: true, microphone: true, apiKey: true)

    @MainActor
    func testStartsAtFirstMissingStepAndSkipsGrantedPermissions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = OnboardingModel(defaults: defaults)
        var requirements = ready
        requirements.accessibility = false
        requirements.inputMonitoring = false
        requirements.microphone = false
        requirements.apiKey = false
        model.begin(requirements: requirements)
        XCTAssertEqual(model.step, .accessibility)
        requirements.accessibility = true
        model.synchronize(requirements: requirements, awaitingRestart: true)
        XCTAssertEqual(model.step, .accessibility, "A restart prompt must hold the current slide")
        model.synchronize(requirements: requirements, awaitingRestart: false)
        XCTAssertEqual(model.step, .inputMonitoring)
        requirements.inputMonitoring = true
        model.synchronize(requirements: requirements, awaitingRestart: false)
        XCTAssertEqual(model.step, .microphone)
        requirements.microphone = true
        model.synchronize(requirements: requirements, awaitingRestart: false)
        XCTAssertEqual(model.step, .apiKey)
        requirements.apiKey = true
        model.synchronize(requirements: requirements, awaitingRestart: false)
        XCTAssertEqual(model.step, .test)
        XCTAssertFalse(model.hasCompleted, "Showing the test slide alone does not complete setup")
    }

    @MainActor
    func testCompletedSetupStaysHiddenOnlyWhenAllRequirementsRemainGranted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = OnboardingModel(defaults: defaults)
        var requirements = ready
        requirements.inputMonitoring = false
        first.begin(requirements: requirements)
        XCTAssertEqual(first.step, .inputMonitoring)
        first.dismiss()
        XCTAssertFalse(first.hasCompleted)
        let resumed = OnboardingModel(defaults: defaults)
        resumed.begin(requirements: ready)
        XCTAssertEqual(resumed.step, .test)
        resumed.complete(requirements: ready)
        XCTAssertTrue(resumed.hasCompleted)
        XCTAssertFalse(resumed.isPresented)
        let nextLaunch = OnboardingModel(defaults: defaults)
        nextLaunch.begin(requirements: ready)
        XCTAssertFalse(nextLaunch.isPresented)
        for missing in [OnboardingModel.Step.accessibility, .inputMonitoring, .microphone, .apiKey] {
            var requirements = ready
            switch missing {
            case .accessibility: requirements.accessibility = false
            case .inputMonitoring: requirements.inputMonitoring = false
            case .microphone: requirements.microphone = false
            case .apiKey: requirements.apiKey = false
            case .test: break
            }
            let launch = OnboardingModel(defaults: defaults)
            launch.begin(requirements: requirements)
            XCTAssertTrue(launch.isPresented)
            XCTAssertEqual(launch.step, missing)
        }
        nextLaunch.begin(requirements: ready, force: true)
        XCTAssertTrue(nextLaunch.isPresented)
        XCTAssertEqual(nextLaunch.step, .test)
    }

    @MainActor
    func testMissingRequirementCannotBeMarkedCompleteAndRevocationReturnsToItsSlide() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = OnboardingModel(defaults: defaults)
        model.begin(requirements: ready)
        var requirements = ready
        requirements.microphone = false
        model.complete(requirements: requirements)
        XCTAssertFalse(model.hasCompleted)
        XCTAssertTrue(model.isPresented)
        model.synchronize(requirements: requirements, awaitingRestart: false)
        XCTAssertEqual(model.step, .microphone)
    }

    @MainActor
    func testEverySlideFitsInLightAndDarkAppearance() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let microphone = MicrophoneRecordingSession(checkAuthorization: { .denied }, requestAccess: { XCTFail("Rendering must not request consent"); return false })
        let monitor = ShiftMonitor(defaults: defaults, checkPermission: { false }, requestAccess: { false },
                                   checkEventPostingPermission: { false }, requestEventPostingAccess: { false }, microphone: microphone)
        let key = APIKeyModel(validate: { _ in XCTFail("Rendering must not call OpenAI") })
        let model = OnboardingModel(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            for step in OnboardingModel.Step.allCases {
                var requirements = ready
                switch step {
                case .accessibility: requirements.accessibility = false
                case .inputMonitoring: requirements.inputMonitoring = false
                case .microphone: requirements.microphone = false
                case .apiKey: requirements.apiKey = false
                case .test: break
                }
                model.begin(requirements: requirements, force: true)
                let host = NSHostingView(rootView: OnboardingView(onboarding: model, monitor: monitor, apiKey: key, openSettings: { _ in }, complete: {}).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 580, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, 550, accuracy: 0.5)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "Onboarding-\(step)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
    }
}
