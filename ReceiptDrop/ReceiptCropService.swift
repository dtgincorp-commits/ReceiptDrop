import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Detects a receipt's edges in a captured photo and perspective-corrects
/// (deskews) it into a clean, cropped rectangle — used both for the original-
/// photo viewer's "Cropped" mode and for what gets attached when sharing, so
/// a friend/spouse sees just the receipt, not the table/hand/background
/// around it.
///
/// Confidence-gated: returns nil (never guesses) if detection is weak or the
/// detected edges sit too close to the frame border. The edge check matters
/// most for a long, curled thermal receipt whose total sits near the bottom
/// of the frame — a "confident-looking" crop there could clip off exactly
/// the number someone needs to see. Callers should always fall back to the
/// original photo when this returns nil.
enum ReceiptCropService {
    static func crop(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let orientation = cgOrientation(from: image.imageOrientation)

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let quad = request.results?.first as? VNRectangleObservation else {
            return nil
        }

        // Same area threshold as the live auto-capture detector — a long
        // receipt legitimately fills more of the frame vertically, so
        // requiring a large margin from the edges rejected valid crops more
        // often than intended.
        guard quadArea(quad) > 0.15, !cornersNearEdge(quad) else { return nil }

        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = ciImage.extent
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + p.x * extent.width, y: extent.origin.y + p.y * extent.height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomLeft = point(quad.bottomLeft)
        filter.bottomRight = point(quad.bottomRight)
        guard let output = filter.outputImage else { return nil }

        let context = CIContext()
        guard let outputCG = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }

    private static func cornersNearEdge(_ quad: VNRectangleObservation) -> Bool {
        let margin: CGFloat = 0.005
        let points = [quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight]
        return points.contains { $0.x < margin || $0.x > 1 - margin || $0.y < margin || $0.y > 1 - margin }
    }

    private static func quadArea(_ quad: VNRectangleObservation) -> CGFloat {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var area: CGFloat = 0
        for i in 0..<points.count {
            let j = (i + 1) % points.count
            area += points[i].x * points[j].y
            area -= points[j].x * points[i].y
        }
        return abs(area) / 2
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
