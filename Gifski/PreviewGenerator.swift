//
//  PreviewGenerator.swift
//  Gifski
//
//  Created by Michael Mulet on 3/22/25.

import Foundation
import SwiftUI
import AVFoundation

@Observable
final class PreviewGenerator {
	@MainActor
	var previewImage: NSImage?

	private var previewImageCommand: PreviewCommand?
	@MainActor
	var imageBeingGeneratedNow = false

	private var commandStream = LatestCommandAsyncStream()

	init() {
		Task(priority: .utility) {
			for await item in commandStream {
				guard commandStream.commandIsLatest(command: item) else {
					continue
				}
				if previewImageCommand == item.command {
					/**
					 Don't regenerate if it's the same
					 */
					continue
				}
				Task {
					@MainActor in
					self.imageBeingGeneratedNow = true
				}
				defer {
					Task {
						@MainActor in

						self.imageBeingGeneratedNow = false
					}
				}
				let data = await generatePreviewImage(
					previewCommand: item.command
				)
				Task {
					@MainActor in
					self.previewImage = data?.toPreviewImage()
				}

				self.previewImageCommand = previewImageCommand
			}
		}
	}


	func generatePreview(command: PreviewCommand)  {
		self.commandStream.add(command)
	}

	/**
	 NSImages are not Sendable so we will
	 just send the Data to the main thread
	 and create the image there
	 */
	private struct PreviewImageData: Sendable {
		private var imageData: Data
		private var type: ImageDataType

		init(imageData: Data, type: ImageDataType){
			self.imageData = imageData
			self.type = type
		}

		fileprivate enum ImageDataType {
			case stillImage
			case animatedGIF
		}

		func toPreviewImage() -> NSImage?{
			let image: NSImage
			switch type {
			case .animatedGIF:
				image = NSImage(data: imageData) ?? NSImage()
			case .stillImage:
				guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
					  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
					return nil
				}
				image = NSImage(cgImage: cgImage, size: .zero)
			}
			return image
		}
	}




	struct PreviewCommand: Sendable, Equatable {
		let whatToGenerate: PreviewGeneration
		let settingsAtGenerateTime: GIFGenerator.Conversion

		enum PreviewGeneration: Equatable {
			case oneFrame(atTime: Double)
			case entireAnimation
		}
	}



	/**
	 This will use GiFGenerate To generate a new preview image at a particular
	 time or of the entire animation
	 */
	private func generatePreviewImage(
		previewCommand: PreviewCommand
	) async -> PreviewImageData? {
		switch previewCommand.whatToGenerate {
		case .entireAnimation:
			let data = try? await GIFGenerator.run(previewCommand.settingsAtGenerateTime) { _ in
				/**
				 no-op
				 */
			}
			guard let data
				   else {
				return nil
			}
			let asset = await createAVAssetFromGif(data: data, previewCommand: previewCommand)



			print("didn't crash")
			return .init(imageData: data, type: .animatedGIF)
		case .oneFrame(let previewTimeToGenerate):
			guard let frameRange = previewCommand.settingsAtGenerateTime.timeRange else {
				/**
				 Don't have a frame range at all
				 don't produce a preview GIF
				 */
				return nil
			}
			guard let frameRate = previewCommand.settingsAtGenerateTime.frameRate else {
				return nil
			}
			/**
			 We want to generate 1 frame
			 we have currentFrameSettings.frameRate frames/second
			 or 1/currentFrameSettings.frameRate seconds/frame
			 then multiply by 1 frame to the duration of one frame
			 */

			let duration_of_one_frame: Double = 1 / (frameRate.toDouble)

			/**
			 Line up the current time to a frame that will
			 be generated the generator
			 */
			let frame_number = ((previewTimeToGenerate - frameRange.lowerBound) / duration_of_one_frame).rounded(.down)

			let start = frame_number * duration_of_one_frame + frameRange.lowerBound

			var currentFrameSettings = previewCommand.settingsAtGenerateTime

			/**
			 Set the frame rate artificially high
			 because the GifGenerator may fail
			 to run if near the end and less than
			 one frame is pushed through
			 */
			currentFrameSettings.frameRate = 18

			/**
			 Generate an average of 2.5 frames
			 GIFGenerator fails if generating only 1
			 frame. So le'ts make sure at least 2 frames
			 generate
			 */
			currentFrameSettings.timeRange = start...(start + 2.5 / 18.0)
			let data = try? await GIFGenerator.run(currentFrameSettings) { _ in
				/**
				 no-op
				 */
			}
			guard let data else {
				return nil
			}
			return .init(imageData: data, type: .stillImage)
		}
	}

	/**
	 An async Stream that will yield when a new item is added,
	 but keeps an up to date sequence of items so you can
	 know if you are processing the latest item inserted into
	 the stream.
	 */
	private struct LatestCommandAsyncStream: AsyncSequence {
		fileprivate struct SequencedPreviewCommand {
			let command: PreviewCommand
			let sequenceNumber: Int
		}
		func commandIsLatest(command: SequencedPreviewCommand) -> Bool {
			command.sequenceNumber == latestItemSequenceNumber
		}
		private var latestItemSequenceNumber = -1
		private var stream: AsyncStream<SequencedPreviewCommand>!
		private var continuation: AsyncStream<SequencedPreviewCommand>.Continuation!

		init() {
			self.stream = AsyncStream { continuation in
				self.continuation = continuation
			}
		}
		mutating func add(_ command: PreviewCommand) {
			latestItemSequenceNumber += 1
			continuation.yield(
				.init(command: command, sequenceNumber: latestItemSequenceNumber)
			)
		}
		func makeAsyncIterator() -> AsyncStream<SequencedPreviewCommand>.Iterator {
			stream.makeAsyncIterator()
		}
	}

	private func createAVAssetFromGif(data: Data, previewCommand: PreviewCommand) async -> AVAsset? {
		guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
			return nil
		}
		let numberOfImagesCount = CGImageSourceGetCount(imageSource)
		guard numberOfImagesCount > 0 else {
			return nil
		}
		guard let firstCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
			return nil
		}
		let tempPath = FileManager.default.temporaryDirectory.appending(component: "output.move")
		guard let assetWriter = try? AVAssetWriter(outputURL: tempPath, fileType: .mov) else {
			return nil
		}

		let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.proRes4444,
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
			return nil
		}
		assetWriter.add(writerInput)

		assetWriter.startWriting()
		assetWriter.startSession(atSourceTime: .zero)

		let dispatchQueue = DispatchQueue(label: "com.gifski.assetWriterQueue")
		var frameIndex = 0

		let frameRate: CMTimeScale
		if let settingFrameRate = previewCommand.settingsAtGenerateTime.frameRate {
			frameRate = CMTimeScale(settingFrameRate)
		} else if let inputFrameRaate = try? await previewCommand.settingsAtGenerateTime.asset.frameRate {
			frameRate = CMTimeScale(inputFrameRaate)
		} else {
			frameRate = CMTimeScale(30.0)
		}


		let dataReadyStream = AsyncStream { continuation in
			writerInput.requestMediaDataWhenReady(on: dispatchQueue) {
				continuation.yield()
			}
		}
		for await _ in dataReadyStream {
			while writerInput.isReadyForMoreMediaData && frameIndex < numberOfImagesCount {
				defer {
					frameIndex += 1
				}
				guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else {
					continue
				}
				guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
					continue
				}
				var pixelBuffer: CVPixelBuffer?
				guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
					  let pixelBuffer else {
					continue
				}
				CVPixelBufferLockBaseAddress(pixelBuffer, [])
				defer {
					CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
				}
				guard let context = CGContext(
					data: CVPixelBufferGetBaseAddress(pixelBuffer),
					width: cgImage.width,
					height: cgImage.height,
					bitsPerComponent: 8,
					bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
					space: CGColorSpaceCreateDeviceRGB(),
					bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
				) else {
					continue
				}
				context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
				let presentationTime = CMTime(
					value: CMTimeValue(frameIndex),
					timescale: frameRate
				)
				pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
			}
			if frameIndex >= numberOfImagesCount {
				break
			}
		}

		writerInput.markAsFinished()
		await withCheckedContinuation { continuation in
			assetWriter.finishWriting {
				continuation.resume()
			}
		}
		return AVURLAsset(url: tempPath)
	}
}
