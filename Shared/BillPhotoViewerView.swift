import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Full-screen viewer for the original captured receipt photo, reached by
/// tapping the thumbnail on the Bill Breakdown screen — lets the user check
/// the AI-read breakdown against the actual paper, pinch-zoomed for a closer
/// look, with two optional renderings one tap away: a contrast-boosted
/// "Enhanced" mode for faded thermal-paper text, and a "Cropped" mode that
/// deskews the receipt and removes the background (table, hand, etc.).
/// Neither is automatic — enhancement doesn't reliably help on every photo
/// (glare, very dark shots), and cropping only appears at all when detection
/// is confident (see `ReceiptCropService`) — so "Original" is always the
/// reliable fallback, one tap away.
struct BillPhotoViewerView: View {
    let photoData: Data
    let onDone: () -> Void

    private enum ViewMode: String, CaseIterable, Identifiable {
        case original = "Original"
        case enhanced = "Enhanced"
        case cropped = "Cropped"
        var id: String { rawValue }
    }

    @State private var viewMode: ViewMode = .original
    @State private var originalImage: UIImage?
    @State private var enhancedImage: UIImage?
    @State private var croppedImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = currentImage {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea()
                } else {
                    // No adjacent text — this is the whole screen's content
                    // for the brief moment before the photo decodes.
                    ProgressView().tint(.white).accessibilityLabel("Loading photo")
                }
                VStack {
                    Spacer()
                    if availableModes.count > 1 {
                        Picker("View", selection: $viewMode) {
                            ForEach(availableModes) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(8)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Original Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard let image = UIImage(data: photoData) else { return }
            originalImage = image
            Task.detached(priority: .userInitiated) {
                let enhanced = Self.enhance(image)
                let cropped = ReceiptCropService.crop(image)
                await MainActor.run {
                    enhancedImage = enhanced
                    croppedImage = cropped
                }
            }
        }
    }

    private var availableModes: [ViewMode] {
        var modes: [ViewMode] = [.original]
        if enhancedImage != nil { modes.append(.enhanced) }
        if croppedImage != nil { modes.append(.cropped) }
        return modes
    }

    private var currentImage: UIImage? {
        switch viewMode {
        case .original: return originalImage
        case .enhanced: return enhancedImage ?? originalImage
        case .cropped: return croppedImage ?? originalImage
        }
    }

    /// Boosts contrast and desaturates toward a crisper black-on-white
    /// "scanned document" look — helps faded thermal-paper text pop on many
    /// photos, though not a guaranteed improvement on every one.
    private static func enhance(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        // `CIImage(image:)` doesn't reliably apply the source UIImage's
        // orientation, so a photo taken in portrait can come back rotated
        // after the round-trip through Core Image — explicitly bake in the
        // correct orientation ourselves before filtering.
        let ciImage = CIImage(cgImage: cgImage).oriented(cgOrientation(from: image.imageOrientation))
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.contrast = 1.4
        filter.brightness = 0.05
        filter.saturation = 0.0
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let outputCG = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }

    private static func cgOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// A `UIScrollView`-backed image view for reliable pinch-to-zoom and pan —
/// SwiftUI's native gesture modifiers are fussier to get right for this than
/// the well-worn UIKit pattern (same approach Photos-style viewers use).
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
