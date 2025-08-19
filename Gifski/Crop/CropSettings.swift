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
		let transformedCrop = unormalziedCropFor(sizeInPreferredTransformationSpace: .init(width: image.width, height: image.height))
		return image.cropping(to: transformedCrop)
	}

	func unormalziedCropFor(sizeInPreferredTransformationSpace prefferedSize: CGSize) -> CGRect {
		let cropRect = crop ?? .initialCropRect
		guard let trackPreferredTransform else {
			return cropRect.unnormalize(forDimensions: prefferedSize)
		}
		let origninalSize = CGRect(origin: .zero, size: prefferedSize)
			.applying(trackPreferredTransform.inverted()).size
		let originalCropSize = cropRect.unnormalize(forDimensions: origninalSize)
		return originalCropSize.applying(trackPreferredTransform)
	}

	var croppedOutputDimensions: (width: Int, height: Int)? {
		guard crop != nil else {
			return dimensions
		}

		guard let dimensions else {
			return nil
		}

		let outputDimensions = unormalziedCropFor(sizeInPreferredTransformationSpace: .init(width: dimensions.width, height: dimensions.height))
		return (outputDimensions.width.toIntAndClampingIfNeeded,
				outputDimensions.height.toIntAndClampingIfNeeded)
	}
}
