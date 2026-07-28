import XCTest
@testable import PullerApp

final class ServiceMenuModelTests: XCTestCase {
    func testIncompleteInstallationOffersOnlyInstall() {
        let model = ServiceMenuModel(
            installationStatus: .notInstalled,
            isOperationInProgress: false
        )

        XCTAssertEqual(model.title, "安装服务")
        XCTAssertEqual(model.operation, .install)
        XCTAssertTrue(model.isEnabled)
    }

    func testCompleteInstallationOffersOnlyUninstall() {
        let model = ServiceMenuModel(
            installationStatus: .installed,
            isOperationInProgress: false
        )

        XCTAssertEqual(model.title, "卸载服务")
        XCTAssertEqual(model.operation, .uninstall)
        XCTAssertTrue(model.isEnabled)
    }

    func testApplicableActionIsDisabledDuringOperation() {
        for status in [ServiceInstallationStatus.notInstalled, .installed] {
            let model = ServiceMenuModel(
                installationStatus: status,
                isOperationInProgress: true
            )

            XCTAssertFalse(model.isEnabled)
        }
    }
}
