import SwiftUI
import LibvirtKit

struct OverviewTab: View {
    let domain: DomainSummary

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Image(systemName: domain.state.symbol)
                            .foregroundStyle(domain.state.color)
                        Text(domain.state.label)
                    }
                }
                LabeledContent("Domain ID", value: domain.id >= 0 ? "\(domain.id)" : "—")
            }
            Section("Hardware") {
                LabeledContent("vCPUs", value: "\(domain.vcpus)")
                LabeledContent("Memory", value: Format.memory(kiB: domain.memoryKiB))
                LabeledContent("Max Memory", value: Format.memory(kiB: domain.maxMemoryKiB))
            }
            Section("Identity") {
                LabeledContent("Name", value: domain.name)
                LabeledContent("UUID", value: domain.uuid)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
