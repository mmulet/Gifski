//
//  PreviewState.swift
//  Gifski
//
//  Created by Michael Mulet on 4/23/25.
//

import Foundation
import AVFoundation



enum FullPreviewStream {
	/**
	 Provides a stream of [FullPreviewGenerationEvents](FullPreviewGenerationEvent), as well as a function so that you can request new fullPreviews to be generated. Each event has an requestID that corresponds to each RequestNewFullPreview call.. Every request may not be granted (it may be skipped). Request id numbers increase monotonically

	 ## Example Usage:
	 ```swift
	 let (eventStream, RequestNewFullPreview) = createPreviewStream()
	 var fullPreviewState: FullPreviewGenerationEvent = .initial
	 var myRequestID = ...
	 Task {
		 for await event in eventStream {
			 var fullPreviewState: FullPreviewGenerationEvent = .initial
	 = event

			 guard event.requestID == myRequestID else {
				continue
			 }

			 if case let .generating(_, let progress, _): {
				print("almost there! we are at \(progress)%")
			 }
		 }
	 }
	 ...

	 //whenever your settings change and you need to generate a new fullPreview
	 requestNewFullPreview(SettingsForFullPreview(...)
	 ```
	 ## Internals
	 internally the fullPreviewStream works like this: It sets up its own AsyncStream that waits for calls to( RequestNewFullPreview)[RequestNewFullPreview], once there it cancels any existing requests for generation, then spawns a new task to generate the fullPreview.
	 */
	static func create() -> (AsyncStream<FullPreviewGenerationEvent>, RequestNewFullPreview, CancelGeneratingFullPreview) {
		// The output stream as this is a stream of FullPreviewGenerationEvents
		let ( stateStream, stateStreamContinuation ) = AsyncStream<FullPreviewGenerationEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))

		// The input stream, input new settings to make fullPreviews of
		let ( newSettingsStream, newSettingsContinuation ) = AsyncStream<(SettingsForFullPreview)>.makeStream(bufferingPolicy: .bufferingNewest(5))
		let fullPreviewState = FullPreviewState(stateStreamContinuation: stateStreamContinuation)


		let mainLoop = Task {
			for await settingsEvent in newSettingsStream {
				try Task.checkCancellation()

				let newSettings = settingsEvent
				let requestID = await fullPreviewState.newId()

				requestID.p("starting new settings")
				guard isNecessaryToCreateNewFullPreview(oldState: await fullPreviewState.state, newSettings: newSettings, requestID: requestID) else {
					// Not necessary to create a new fullPreview, no state change
					continue
				}
				requestID.p("Generating")
				await fullPreviewState.newGeneration(requestID: requestID, newSettings: newSettings) {
					do {
						await fullPreviewState.updatePreview(newPreviewState: .generating(settings: newSettings, progress: 0, requestID: requestID))

						let framesAndAsset = try await generateNewFullPreview(settings: newSettings, requestID: requestID) { progress in
							guard !Task.isCancelled else {
								return
							}
							await fullPreviewState.updatePreview(newPreviewState: .generating(settings: newSettings, progress: progress, requestID: requestID))
						}
						try Task.checkCancellation()
						requestID.p("success")
						let (preBaked, asset) = framesAndAsset
						await fullPreviewState.updatePreview(newPreviewState: .ready(settings: newSettings, asset: asset, preBaked: preBaked, requestID: requestID))
					} catch {
						if Task.isCancelled || error.isCancelled {
							requestID.p("I was cancelled")
							return
						}
						await fullPreviewState.updatePreview(newPreviewState: .empty(error: error.localizedDescription, requestID: requestID))
					}
				}
			}
		}

		stateStreamContinuation.onTermination = { _ in
			mainLoop.cancel()
			newSettingsContinuation.finish()
		}

		let debouncer = Debouncer(delay: .milliseconds(200))
		return (
			stateStream,
			{ (settings: SettingsForFullPreview)  in
				debouncer {
					newSettingsContinuation.yield((settings))
				}
			},
			{
				await fullPreviewState.cancelGeneration()
			}
		)
	}

	private actor FullPreviewState {
		private let stateStreamContinuation: AsyncStream<FullPreviewGenerationEvent>.Continuation
		var state: FullPreviewGenerationEvent = .empty(error: nil, requestID: -1)

		/**
		The current cancellable task that may be creating a new fullPreview
		 */
		private var generationTask: Task<(), Never>?

		private var automaticRequestID = 0

		init(stateStreamContinuation: AsyncStream<FullPreviewGenerationEvent>.Continuation) {
			self.stateStreamContinuation = stateStreamContinuation
		}

		deinit {
			generationTask?.cancel()
		}

		func newId() -> Int {
			automaticRequestID += 1
			return automaticRequestID
		}
		/**
		Cancels the last generationTask and creates a new one based on the provided operation. Please note that this async function returns when the task has *started* not when it has finished.
		 */
		func newGeneration(requestID: Int, newSettings: SettingsForFullPreview, operation: @escaping () async -> Void) async {
			if let generationTask,
			   !generationTask.isCancelled{
				requestID.p("canceling")
				generationTask.cancel()
				_ = await generationTask.result
				requestID.p("canceled old ")
			}

			generationTask = Task.detached(priority: .medium, operation: operation)
		}

		func updatePreview(newPreviewState: FullPreviewGenerationEvent){
			guard newPreviewState.requestID >= state.requestID else {
				return
			}
			state = newPreviewState
			stateStreamContinuation.yield(newPreviewState)
		}

		func cancelGeneration() {
			generationTask?.cancel()
			updatePreview(newPreviewState: .cancelled(requestID: newId()))
		}
	}

	fileprivate static func generateNewFullPreview(settings: SettingsForFullPreview, requestID: Int, onProgress: @escaping (Double) async -> Void) async throws -> (PreBakedFrames, TemporaryAVURLAsset) {
		let gifProgressWeight = 0.8
		let data = try await GIFGenerator.run(
			settings
				.conversion
		) { progress in
			Task {
				await onProgress(progress * gifProgressWeight)
			}
		}
		try Task.checkCancellation()
		guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
			throw CreateAVAssetError.failedToCreateImageData
		}

		async let preBaked = PreBakedFrames(imageSource, settings: settings)

		async let asset = createAVAssetFromGIF(imageSource: imageSource, settings: settings) { progress in
			await onProgress(gifProgressWeight + progress * (1 - gifProgressWeight))
		}

		return try await (preBaked, asset)
	}
	/**
	 See if we can skip generating a fullPreview based on the last state

	 - Returns: `true` if a new generation is required, `false` otherwise.
	 */
	fileprivate static func isNecessaryToCreateNewFullPreview(oldState: FullPreviewGenerationEvent, newSettings settings: SettingsForFullPreview, requestID: Int) -> Bool {
		switch oldState {
		case .empty, .cancelled:
			return true
		case .generating(let currentGenerationSettings, _, let oldRequestID),
				.ready(let currentGenerationSettings, _, _, let oldRequestID):
			if currentGenerationSettings == settings {
				requestID.p("Skipping - Same as \(oldRequestID)")
				return false
			}
			if case .ready = oldState,
			   currentGenerationSettings.areTheSameBesidesTimeRange(settings),
			   currentGenerationSettings.timeRangeContainsTimeRange(of: settings) {
				requestID.p("Skipping - Same as ready \(oldRequestID)")
				return false
			}
			requestID.p("Different than \(oldRequestID)")
			return true
		}
	}


	typealias RequestNewFullPreview = (SettingsForFullPreview) -> Void

	typealias CancelGeneratingFullPreview = () async -> Void
}




extension Int {
	/**
	 For debugging [createPreviewStream](createPreviewStream)
	 */
	func p(_ message: String) {
#if DEBUG
//				print("\n\n\(self): \(message)\n\n")
#endif
	}
}
