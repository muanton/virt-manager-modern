import SpiceShim

public enum Spice {
    /// The spice-gtk version this app is linked against.
    public static func version() -> String {
        String(cString: vmm_spice_version())
    }
}
