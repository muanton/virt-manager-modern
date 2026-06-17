import os

public enum VMMLog {
    public static let libvirt = Logger(subsystem: "VirtManagerModern", category: "libvirt")
    public static let session = Logger(subsystem: "VirtManagerModern", category: "session")
    public static let console = Logger(subsystem: "VirtManagerModern", category: "console")
}