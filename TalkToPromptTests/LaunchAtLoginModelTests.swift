import ServiceManagement
import XCTest
@testable import TalkToPrompt

@MainActor
private final class LoginItemFixture {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var settingsOpened = 0
    var failure = false
    var approvalRequired = false
    lazy var model = LaunchAtLoginModel(
        checkStatus: { [unowned self] in status },
        register: { [unowned self] in
            registrations += 1
            if failure { throw NSError(domain: "LoginItemTest", code: 1) }
            status = approvalRequired ? .requiresApproval : .enabled
        },
        unregister: { [unowned self] in
            removals += 1
            if failure { throw NSError(domain: "LoginItemTest", code: 1) }
            status = .notRegistered
        },
        openSettings: { [unowned self] in settingsOpened += 1 }
    )
}

final class LaunchAtLoginModelTests: XCTestCase {
    @MainActor
    func testReadingStatusDoesNotEnableLoginItem() {
        let f = LoginItemFixture()
        XCTAssertEqual(f.model.statusText, "Disabled")
        f.model.refresh()
        XCTAssertEqual(f.registrations, 0)
        XCTAssertEqual(f.removals, 0)
    }

    @MainActor
    func testEnableAndDisableUseSystemStatus() {
        let f = LoginItemFixture()
        f.model.setEnabled(true)
        XCTAssertTrue(f.model.isEnabled)
        XCTAssertEqual(f.registrations, 1)
        f.model.setEnabled(true)
        XCTAssertEqual(f.registrations, 1)
        f.model.setEnabled(false)
        XCTAssertFalse(f.model.isRequested)
        XCTAssertEqual(f.removals, 1)
    }

    @MainActor
    func testApprovalRequiredIsNotReportedAsEnabledAndCanBeCancelled() {
        let f = LoginItemFixture()
        f.approvalRequired = true
        f.model.setEnabled(true)
        XCTAssertFalse(f.model.isEnabled)
        XCTAssertTrue(f.model.needsApproval)
        XCTAssertTrue(f.model.isRequested)
        XCTAssertEqual(f.model.statusText, "Needs approval")
        f.model.openLoginItemsSettings()
        XCTAssertEqual(f.settingsOpened, 1)
        f.model.setEnabled(false)
        XCTAssertFalse(f.model.isRequested)
        XCTAssertEqual(f.removals, 1)
    }

    @MainActor
    func testRefreshReflectsExternalChangesWithoutReregistering() {
        let f = LoginItemFixture()
        f.model.setEnabled(true)
        f.status = .requiresApproval
        f.model.refresh()
        XCTAssertTrue(f.model.needsApproval)
        XCTAssertEqual(f.registrations, 1)
        f.status = .enabled
        f.model.refresh()
        XCTAssertTrue(f.model.isEnabled)
    }

    @MainActor
    func testFailedChangesPreserveActualStateAndReportError() {
        let f = LoginItemFixture()
        f.failure = true
        f.model.setEnabled(true)
        XCTAssertFalse(f.model.isRequested)
        XCTAssertNotNil(f.model.errorMessage)
        f.failure = false
        f.model.setEnabled(true)
        XCTAssertNil(f.model.errorMessage)
        f.failure = true
        f.model.setEnabled(false)
        XCTAssertTrue(f.model.isEnabled)
        XCTAssertNotNil(f.model.errorMessage)
    }
}
