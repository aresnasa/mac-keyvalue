import XCTest

@testable import MacKeyValue

final class MacKeyValueTests: XCTestCase {
    func testBuildIdentityRequiresMigrationForMissingOrDifferentMarker() {
        let current = AppBuildIdentity(version: "0.1.2", build: "42")

        XCTAssertTrue(AppBuildIdentity.requiresMigration(from: nil, to: current))
        XCTAssertTrue(AppBuildIdentity.requiresMigration(from: "0.1.1 (41)", to: current))
        XCTAssertFalse(AppBuildIdentity.requiresMigration(from: "0.1.2 (42)", to: current))
    }

    func testBuildIdentityComparesNumericVersionsAndBuilds() {
        XCTAssertTrue(
            AppBuildIdentity(version: "0.1.9", build: "100")
                .isOlder(than: AppBuildIdentity(version: "0.1.10", build: "1"))
        )
        XCTAssertTrue(
            AppBuildIdentity(version: "0.1.10", build: "7")
                .isOlder(than: AppBuildIdentity(version: "0.1.10", build: "8"))
        )
        XCTAssertFalse(
            AppBuildIdentity(version: "0.2.0", build: "1")
                .isOlder(than: AppBuildIdentity(version: "0.1.10", build: "99"))
        )
    }
}
