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

    func testStoragePoolEventRegistration() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let deregister = try await conn.registerStoragePoolEvents(onLifecycle: { _, _ in },
                                                                  onRefresh: { _ in })
        deregister()
    }

    func testHostSummary() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let summary = try await conn.hostSummary()
        XCTAssertFalse(summary.libvirtVersion.isEmpty)
        XCTAssertGreaterThan(summary.node.cpus, 0)
        XCTAssertGreaterThan(summary.domainCount, 0)
    }

    func testNodeMemoryStats() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        // The built-in test driver does not implement virNodeGetMemoryStats.
        guard let stats = try? await conn.nodeMemoryStats() else { return }
        XCTAssertNotNil(stats.totalKiB ?? stats.freeKiB ?? stats.availableKiB)
    }

    func testHasManagedSave() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let domains = try await conn.listDomains()
        guard let domain = domains.first else {
            XCTFail("No domains in test driver")
            return
        }
        _ = try await conn.hasManagedSave(uuid: domain.uuid)
    }

    func testListNetworks() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        _ = try await conn.listNetworks()
    }

    func testGuestInfoInactiveDomain() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let domains = try await conn.listDomains()
        guard let inactive = domains.first(where: { !$0.isActive }) else { return }
        let info = try await conn.guestInfo(uuid: inactive.uuid)
        XCTAssertTrue(info.isEmpty)
    }

    func testScreenshotOnRunningDomain() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let domains = try await conn.listDomains()
        guard let active = domains.first(where: \.isActive) else { return }
        _ = try? await conn.screenshot(uuid: active.uuid)
    }

    func testDomainPersistentXML() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let domains = try await conn.listDomains()
        guard let domain = domains.first else { return }
        _ = try await conn.domainPersistentXML(uuid: domain.uuid)
        _ = try await conn.domainIsUpdated(uuid: domain.uuid)
    }

    func testAllDomainStatsIncludesBlockCounters() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let stats = try await conn.allDomainStats()
        for (_, s) in stats {
            // Counters exist even when zero; fields must be readable.
            _ = s.blockReadBytes
            _ = s.blockWriteBytes
            _ = s.netRxBytes
            _ = s.netTxBytes
        }
    }

    func testStoragePoolRefresh() async throws {
        let conn = try await LibvirtConnection.open(uri: uri)
        defer { conn.close() }
        let pools = try await conn.listStoragePools()
        guard let pool = pools.first else {
            XCTFail("No storage pools in test driver")
            return
        }
        if pool.active {
            _ = try await conn.listVolumes()
        }
    }
}