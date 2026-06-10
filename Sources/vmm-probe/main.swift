import Foundation
import LibvirtKit
import SpiceKit

print("libvirt library version: \(Libvirt.libraryVersion())")
print("spice client version: \(Spice.version())")

// Smoke-test the full connection + listing path against libvirt's built-in
// fake driver, which needs no real server.
let uri = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test:///default"

do {
    let conn = try await LibvirtConnection.open(uri: uri)
    print("connected to \(uri)")
    if let host = await conn.hostname() { print("host: \(host)") }

    let domains = try await conn.listDomains()
    print("\(domains.count) domain(s):")
    for d in domains {
        print("  - \(d.name)  [\(d.state.label)]  vcpus=\(d.vcpus)  mem=\(d.memoryKiB)KiB  id=\(d.id)")
    }

    // Exercise a lifecycle round-trip on the fake driver.
    if let first = domains.first {
        if first.isActive {
            print("pausing \(first.name)…")
            try await conn.perform(.pause, uuid: first.uuid)
            try await conn.perform(.resume, uuid: first.uuid)
            print("paused + resumed OK")
        }
    }
    conn.close()
} catch {
    print("ERROR: \(error)")
    exit(1)
}
