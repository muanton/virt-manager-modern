import SwiftUI

enum MemoryUnit: String, CaseIterable, Identifiable {
    case gib = "GiB"
    case mib = "MiB"
    var id: String { rawValue }
    var mibFactor: Double { self == .gib ? 1024 : 1 }
}

/// Numeric amount + unit menu editing a value stored in MiB.
/// GiB is the default unit everywhere; the stored value stays MiB so the
/// libvirt XML (KiB) conversion is untouched.
struct MemoryAmountField: View {
    @Binding var mib: Double
    @Binding var unit: MemoryUnit
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(
                get: { mib / unit.mibFactor },
                set: { mib = ($0 * unit.mibFactor).rounded() }
            ), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onSubmit(onCommit)
            Picker("", selection: $unit) {
                ForEach(MemoryUnit.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// "2 GiB" / "1.5 GiB" / "512 MiB" — for summaries.
func memoryLabel(mib: Double) -> String {
    if mib >= 1024 {
        let g = mib / 1024
        return g == g.rounded() ? "\(Int(g)) GiB"
                                : String(format: "%.2f GiB", g)
    }
    return "\(Int(mib)) MiB"
}
