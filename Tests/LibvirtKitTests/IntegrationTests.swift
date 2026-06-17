import XCTest
@testable import LibvirtKit

/// Smoke tests against libvirt's built-in test:///default driver (no SSH host).
final class IntegrationTests: XCTestCase {
    private let uri = "test:///default"

    func testConnectAndListDomains() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        _ = await conn.hostname()
        let domains = try await conn.listDomains()
        // The test driver always has at least one predefined domain.
        XCTAssertFalse(domains.isEmpty)
    }

    func testDefineAndUndefineDomain() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }

        let xml = """
        <domain type='qemu'>
          <name>vmm-integration-test</name>
          <memory unit='KiB'>524288</memory>
          <vcpu>1</vcpu>
          <os><type arch='x86_64'>hvm</type></os>
        </domain>
        """
        let defined = try await conn.defineXML(xml)
        XCTAssertEqual(defined.name, "vmm-integration-test")

        let listed = try await conn.listDomains()
        XCTAssertTrue(listed.contains { $0.uuid == defined.uuid })

        try await conn.undefineBasic(uuid: defined.uuid)
        let after = try await conn.listDomains()
        XCTAssertFalse(after.contains { $0.uuid == defined.uuid })
    }

    func testListStoragePools() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let pools = try await conn.listStoragePools()
        XCTAssertFalse(pools.isEmpty)
    }

    func testDomainEventRegistration() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let deregister = try await conn.registerDomainEvents { _, _ in }
        deregister()
    }
}