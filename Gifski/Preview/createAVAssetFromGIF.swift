//
//  createAVAssetFromGIF.swift
//  Gifski
//
//  Created by Michael Mulet on 4/22/25.
//

import Foundation
import AVKit

/**
 Convert a GIF to an AVAAsset
 */
func createAVAssetFromGIF(imageSource: CGImageSource, settings: SettingsForFullPreview, onProgress: @escaping (Double) -> Void) async throws -> TemporaryAVURLAsset {
	let numberOfImages = CGImageSourceGetCount(imageSource)
	guard numberOfImages > 0,
		  let firstCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
	else {
		throw CreateAVAssetError.noImages
	}

	let tempPath = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).mov")
	guard let assetWriter = try? AVAssetWriter(outputURL: tempPath, fileType: .mov) else {
		throw CreateAVAssetError.failedToCreateAssetWriter
	}

	let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
		AVVideoCodecKey: AVVideoCodecType.h264,
		AVVideoWidthKey: firstCGImage.width,
		AVVideoHeightKey: firstCGImage.height
	])
	writerInput.expectsMediaDataInRealTime = false
	let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
		assetWriterInput: writerInput,
		sourcePixelBufferAttributes: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
			kCVPixelBufferWidthKey as String: firstCGImage.width,
			kCVPixelBufferHeightKey as String: firstCGImage.height
		]
	)
	guard assetWriter.canAdd(writerInput) else {
		throw CreateAVAssetError.cannotAddWriterInput
	}
	assetWriter.add(writerInput)

	guard assetWriter.startWriting() else {
		throw CreateAVAssetError.failedToStartWriting
	}
	assetWriter.startSession(atSourceTime: .zero)

	var frameIndex = 0

	let frameRate: CMTimeScale = await {
		if let settingFrameRate = settings.conversion.frameRate {
			return CMTimeScale(settingFrameRate)
		}
		if let inputFrameRate = try? await settings.conversion.asset.frameRate {
			return CMTimeScale(inputFrameRate)
		}
		return CMTimeScale(30.0)
	}()


	let dispatchQueue = DispatchQueue(label: "com.gifski.assetWriterQueue")
	let sendableImageSource = SendableWrapper(imageSource)
	let sendableWriterInput = SendableWrapper(writerInput)
	let sendablePixelBufferAdaptor = SendableWrapper(pixelBufferAdaptor)

	try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
		writerInput.requestMediaDataWhenReady(on: dispatchQueue) {
			do {
				var progressThreshold = 0.05
				while sendableWriterInput.value.isReadyForMoreMediaData && frameIndex < numberOfImages {
					try Task.checkCancellation()
					let progress = Double(frameIndex) / Double(numberOfImages)
					if progress > progressThreshold {
						onProgress(progress)
						progressThreshold = progress + 0.05
					}
					defer {
						frameIndex += 1
					}
					guard let cgImage = CGImageSourceCreateImageAtIndex(sendableImageSource.value, frameIndex, nil) else {
						throw CreateAVAssetError.failedToCreateImage
					}
					guard let pixelBufferPool = sendablePixelBufferAdaptor.value.pixelBufferPool,
						  let pixelBuffer = createPixelBuffer(from: cgImage, using: pixelBufferPool)
					else {
						throw CreateAVAssetError.failedToCreatePixelBuffer
					}

					let presentationTime = CMTime(
						value: CMTimeValue(frameIndex),
						timescale: frameRate
					)
					guard sendablePixelBufferAdaptor.value.append(pixelBuffer, withPresentationTime: presentationTime) else {
						throw CreateAVAssetError.cannotAppendNewImage
					}
				}
				if frameIndex >= numberOfImages {
					sendableWriterInput.value.markAsFinished()
					continuation.resume()
				}
			} catch {
				sendableWriterInput.value.markAsFinished()
				continuation.resume(throwing: error)
			}
		}
	}
	writerInput.markAsFinished()
	await assetWriter.finishWriting()
	guard assetWriter.status != .failed else {
		throw CreateAVAssetError.failedToWrite
	}
	return TemporaryAVURLAsset(url: tempPath)
}

private func createPixelBuffer(from cgImage: CGImage, using pool: CVPixelBufferPool) -> CVPixelBuffer? {
	var pixelBuffer: CVPixelBuffer?
	guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
		  let pixelBuffer else {
		return nil
	}

	return pixelBuffer.withLockedPlanes { planes in
		guard planes.count == 1,
			  let plane = planes.first else {
			return nil
		}
		guard let context = CGContext(
			data: plane.base,
			width: cgImage.width,
			height: cgImage.height,
			bitsPerComponent: 8,
			bytesPerRow: plane.bytesPerRow,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
		) else {
			return nil
		}
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
		return pixelBuffer
	}
}


enum CreateAVAssetError: Error {
	case failedToStartWriting
	case failedToCreateImageData
	case failedToCreateImage
	case failedToCreatePixelBuffer
	case failedToCreateAssetWriter
	case failedToWrite
	case cannotAddWriterInput
	case cannotAppendNewImage
	case noImages
}
final class TemporaryAVURLAsset: AVURLAsset, @unchecked Sendable {
	deinit {
		try? FileManager.default.removeItem(at: self.url)
	}
}
