import Foundation
import AVKit

protocol CropSettings {
	var dimensions: (width: Int, height: Int)? { get }
	var trackPreferredTransform: CGAffineTransform? { get }
	var crop: CropRect? { get }
}

extension GIFGenerator.Conversion: CropSettings {}

extension CropSettings {
	/**
	We don't use `croppedOutputDimensions` here because the `CGImage` source may have a different size. We use the size directly from the image.

	If the rect parameter defines an area that is not in the image, it returns nil: https://developer.apple.com/documentation/coregraphics/cgimage/1454683-cropping
	*/
	func croppedImage(image: CGImage) -> CGImage? {
		guard crop != nil else {
			return image
		}
		let transformedCrop = unnormalizedCropRect(sizeInPreferredTransformationSpace: .init(width: image.width, height: image.height))
		return image.cropping(to: transformedCrop)
	}

	func unnormalizedCropRect(sizeInPreferredTransformationSpace preferredSize: CGSize) -> CGRect {
		guard let trackPreferredTransform else {
			guard let cropRect = crop else {
				return .init(origin: .zero, size: preferredSize)
			}
			return cropRect.unnormalize(forDimensions: preferredSize)
		}

		let originalSize = CGRect(origin: .zero, size: preferredSize)
			.applying(trackPreferredTransform.inverted()).size
		guard let cropRect = crop else {
			return .init(origin: .zero, size: originalSize).applying(trackPreferredTransform)
		}
		let originalCropSize = cropRect.unnormalize(forDimensions: originalSize)
		return originalCropSize.applying(trackPreferredTransform)
	}

	var croppedOutputDimensions: (width: Int, height: Int)? {
		guard crop != nil else {
			return dimensions
		}

		guard let dimensions else {
			return nil
		}

		let outputDimensions = unnormalizedCropRect(sizeInPreferredTransformationSpace: .init(width: dimensions.width, height: dimensions.height))
		return (outputDimensions.width.toIntAndClampingIfNeeded,
				outputDimensions.height.toIntAndClampingIfNeeded)
	}
}
