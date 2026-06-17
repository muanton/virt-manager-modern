import AppKit
import SwiftUI

struct ScreenshotPreview: View {
    let data: Data

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        } else {
            Text("Could not decode screenshot").foregroundStyle(.secondary).font(.caption)
        }
    }
}