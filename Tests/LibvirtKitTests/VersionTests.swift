import XCTest
@testable import LibvirtKit

final class VersionTests: XCTestCase {
    func testLibraryVersionIsResolved() {
        let v = Libvirt.libraryVersion()
        XCTAssertNotEqual(v, "unknown")
        XCTAssertTrue(v.contains("."), "expected dotted version, got \(v)")
    }
}
