import Foundation
import AVKit

extension CVPixelBuffer {
	enum ConvertToGIFError: Error {
		case failedToCreateCGContext
	}

	func convertToGIF(
		settings: SettingsForFullPreview
	) async throws -> Data {
		//  Not the fastest way to convert `CVPixelBuffer` to image, but the runtime of `GIFGenerator.convertOneFrame` is so much larger that optimizing this would be a waste
		var ciImage = CIImage(cvPixelBuffer: self)
		if let trackPrefferedTransform = settings.conversion.trackPreferredTransform {
			// Convert AVFoundation (top-left origin) transform to Core Image (bottom-left origin)
			let imageHeight = ciImage.extent.height
			let flip = CGAffineTransform(translationX: 0, y: imageHeight).scaledBy(x: 1, y: -1)
			let ciTransform = flip.concatenating(trackPrefferedTransform).concatenating(flip)
			ciImage = ciImage.transformed(by: ciTransform)
		}
		let ciContext = CIContext()

		guard
			let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
		else {
			throw ConvertToGIFError.failedToCreateCGContext
		}

		guard
			let croppedImage = settings.conversion.croppedImage(image: cgImage)
		else {
			throw GIFGenerator.Error.cropNotInBounds
		}

		return try await GIFGenerator.convertOneFrame(
			frame: croppedImage,
			dimensions: settings.conversion.croppedOutputDimensions,
			quality: max(0.1, settings.conversion.settings.quality),
			fast: true
		)
	}
}
