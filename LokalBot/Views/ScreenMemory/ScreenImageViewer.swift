import SwiftUI

/// Full-resolution pixels live only in this sheet's memory. Closing releases
/// the decoded image; no decrypted file is exported or written to disk.
struct ScreenImageViewer: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let screenshot: ActivityStore.Screenshot
    @State private var image: CGImage?
    @State private var zoom = 1.0
    @State private var fit = true
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(screenshot.windowTitle.isEmpty ? screenshot.app : screenshot.windowTitle).lineLimit(1)
                Spacer()
                Button("Fit") { fit = true }
                Button("Actual size") { fit = false; zoom = 1 }
                Slider(value: $zoom, in: 0.25...3) { Text("Image zoom") }.labelsHidden()
                    .frame(width: 120).onChange(of: zoom) { fit = false }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        let scale = fit ? min(geometry.size.width / Double(image.width), geometry.size.height / Double(image.height)) : zoom
                        Image(image, scale: 1, label: Text("Captured screen"))
                            .resizable()
                            .frame(width: Double(image.width) * scale, height: Double(image.height) * scale)
                    }
                } else if finished {
                    ContentUnavailableView("Image unavailable", systemImage: "rectangle.slash",
                                           description: Text("Pixels may have expired or could not be read. Retained text remains in the moment inspector."))
                } else { ProgressView("Opening image…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.frame(minWidth: 720, idealWidth: 960, minHeight: 500, idealHeight: 680)
        .task(id: screenshot.id) {
            let decoded = await app.screenshots.decryptedThumbnail(for: screenshot, maxPixelSize: 16_384)
            guard !Task.isCancelled else { return }
            image = decoded?.image
            finished = true
        }
        .onDisappear { image = nil }
    }
}
