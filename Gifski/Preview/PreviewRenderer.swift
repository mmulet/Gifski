import CoreImage
import AppKit
import CoreGraphics

actor PreviewRenderer {
	static let shared = PreviewRenderer()

	struct PreviewCheckerboardParameters: Equatable {
		let isDarkMode: Bool
		let videoBounds: CGRect
	}

	static func renderOriginal(
		from videoFrame: CVPixelBuffer,
		to outputFrame: CVPixelBuffer,
	) async throws {
		try await shared.renderOriginal(from: videoFrame, to: outputFrame)
	}

	static func renderPreview(
		previewFrame: CVPixelBuffer,
		outputFrame: CVPixelBuffer,
		previewCheckerboardParams: PreviewCheckerboardParameters
	) async throws {
		try await shared.renderPreview(previewFrame: previewFrame, outputFrame: outputFrame, previewCheckerboardParams: previewCheckerboardParams)
	}

	static func renderPreview(
		previewFrame: CGImage,
		outputFrame: CVPixelBuffer,
		previewCheckerboardParams: PreviewCheckerboardParameters
	) async throws {
		try await shared.renderPreview(previewFrame: previewFrame, outputFrame: outputFrame, previewCheckerboardParams: previewCheckerboardParams)
	}


	private func renderPreview(
		previewFrame: CVPixelBuffer,
		outputFrame: CVPixelBuffer,
		previewCheckerboardParams: PreviewCheckerboardParameters
	) async throws {
		let previewImage = CIImage(
			cvPixelBuffer: previewFrame,
			options: outputFrame.colorSpace.map { space -> [CIImageOption: Any] in
				[
					.colorSpace: space
				]
			}
		)
		try await renderPreview(previewImage: previewImage, outputFrame: outputFrame, previewCheckerboardParams: previewCheckerboardParams)
	}

	private func renderPreview(
		previewFrame: CGImage,
		outputFrame: CVPixelBuffer,
		previewCheckerboardParams: PreviewCheckerboardParameters
	) async throws {
		try await renderPreview(previewImage: CIImage(cgImage: previewFrame), outputFrame: outputFrame, previewCheckerboardParams: previewCheckerboardParams)
	}

	private func renderOriginal(
		from videoFrame: CVPixelBuffer,
		to outputFrame: CVPixelBuffer,
	) throws {
		try videoFrame.copy(to: outputFrame)
	}

	private func renderPreview(
		previewImage: CIImage,
		outputFrame: CVPixelBuffer,
		previewCheckerboardParams: PreviewCheckerboardParameters
	) async throws {
		let context = CIContext()
		let outputWidth = Double(outputFrame.width)
		let outputHeight = Double(outputFrame.height)
		let outputSize = CGSize(width: outputWidth, height: outputHeight)
		let outputRect = CGRect(origin: .zero, size: outputSize)

		let checkerboard = createCheckerboard(
			outputRect: outputRect,
			uniforms: previewCheckerboardParams
		)

		let previewBounds = previewImage.extent

		let translationX = (outputWidth - previewBounds.width) / 2 - previewBounds.minX
		let translationY = (outputHeight - previewBounds.height) / 2 - previewBounds.minY

		let transform = CGAffineTransform.identity
			.translatedBy(x: translationX, y: translationY)

		let translatedPreview = previewImage.transformed(by: transform)
		let result = translatedPreview.composited(over: checkerboard)

		context.render(
			result.cropped(to: outputRect),
			to: outputFrame,
			bounds: outputRect,
			colorSpace: outputFrame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
		)
	}

	private func createCheckerboard(
		outputRect: CGRect,
		uniforms: PreviewCheckerboardParameters
	) -> CIImage {
		guard let filter = CIFilter(name: "CICheckerboardGenerator") else {
			return CIImage.empty()
		}
		let scaleX = outputRect.width / uniforms.videoBounds.width
		let scaleY = outputRect.height / uniforms.videoBounds.height

		filter.setValue(Double(CheckerboardViewConstants.gridSize) * scaleX, forKey: "inputWidth")

		filter.setValue((uniforms.isDarkMode ? CheckerboardViewConstants.firstColorDark : CheckerboardViewConstants.firstColorLight).ciColor ?? .black, forKey: "inputColor0")
		filter.setValue((uniforms.isDarkMode ? CheckerboardViewConstants.secondColorDark : CheckerboardViewConstants.secondColorLight).ciColor ?? .white, forKey: "inputColor1")

		filter.setValue(
			CIVector(
				x: outputRect.midX + uniforms.videoBounds.midX * scaleX,
				y: outputRect.midY + uniforms.videoBounds.midY * scaleY
			),
			forKey: "inputCenter"
		)
		guard let output = filter.outputImage else {
			return CIImage.empty()
		}
		return output
	}
}
