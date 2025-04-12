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
	var previewImage: NSImage?

	private var previewImageCommand: PreviewCommand?

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
				self.imageBeingGeneratedNow = true

				defer {
					self.imageBeingGeneratedNow = false
				}
				self.previewImage = await generatePreviewImage(
					previewCommand: item.command
				)
				self.previewImageCommand = previewImageCommand
			}
		}
	}


	func generatePreview(command: PreviewCommand)  {
		self.commandStream.add(command)
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
	) async -> NSImage? {
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
			return NSImage(data: data)
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
			guard let data,
				  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
				  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
				return nil
			}
			return NSImage(cgImage: cgImage, size: .zero)
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
}
