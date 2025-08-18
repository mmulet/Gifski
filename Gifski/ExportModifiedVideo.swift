import Foundation
import AVKit
import SwiftUI

struct ExportModifiedVideoView: View {
	@Environment(AppState.self) private var appState
	@Binding var state: ExportModifiedVideoState
	let sourceURL: URL

	@Binding var isAudioWarningPresented: Bool

	var body: some View {
		ZStack{}
			.sheet(isPresented: isProgressSheetPresented) {
				ProgressView()
			}
			.fileExporter(
				isPresented: isFileExporterPresented,
				item: exportableMP4,
				defaultFilename: defaultExportModifiedFileName
			) {
				do {
					let url = try $0.get()
					try? url.setAppAsItemCreator()
				} catch {
					appState.error = error
				}
			}
			.fileDialogCustomizationID("export")
			.fileDialogMessage("Choose where to save the video")
			.fileDialogConfirmationLabel("Save")
			.alert2(
				"Export Video Limitation",
				message: "Exporting a video with audio is not supported. The audio track will be ignored.",
				isPresented: $isAudioWarningPresented
			)
	}

	private var exportableMP4: ExportableMP4? {
		guard case let .finished(url) = state else {
			return nil
		}
		return ExportableMP4(url: url)
	}

	private var defaultExportModifiedFileName: String {
		"\(sourceURL.filenameWithoutExtension) modified.mp4"
	}

	private var isProgressSheetPresented: Binding<Bool> {
		.init(
			get: {
				guard !isAudioWarningPresented,
					  case let .exporting(_, videoIsOverTwentySeconds) = state else {
					return false
				}
				return videoIsOverTwentySeconds
			},
			set: {
				guard !$0,
					  case let .exporting(task, _) = state else {
					return
				}
				task.cancel()
				state = .idle
			}
		)
	}

	private var isFileExporterPresented: Binding<Bool> {
		.init(
			get: { state.isFinished && !isAudioWarningPresented },
			set: {
				guard !$0,
				   case let .finished(url) = state else {
					return
				}
				try? FileManager.default.removeItem(at: url)
				state = .idle
			}
		)
	}


	enum Error: Swift.Error {
		case unableToExportAsset
		case unableToCreateExportSession
		case unableToAddCompositionTrack

		var errorDescription: String? {
			switch self {
			case .unableToExportAsset:
				"Unable to export the asset because it is not compatible with the current device."
			case .unableToCreateExportSession:
				"Unable to create an export session for the video."
			case .unableToAddCompositionTrack:
				"Failed to add a composition track to the video."
			}
		}
	}
}


enum ExportModifiedVideoState: Equatable {
	case idle
	case exporting(Task<Void, Never>, videoIsOverTwentySeconds: Bool)
	case finished(URL)

	var shouldShowProgress: Bool {
		switch self {
		case .idle, .finished:
			false
		case .exporting(_, videoIsOverTwentySeconds: let videoIsOverTwentySeconds):
			videoIsOverTwentySeconds
		}
	}
	var shouldShowFileExporter: Bool {
		switch self {
		case .idle, .exporting:
			false
		case .finished:
			true
		}
	}

	var isExporting: Bool {
		switch self {
		case .exporting:
			true
		default:
			false
		}
	}

	var isFinished: Bool {
		switch self {
		case .finished:
			true
		default:
			false
		}
	}
}


/**
Convert a source video to an `.mp4` using the same scale, speed, and crop as the exported `.gif`.
- Returns: Temporary URL of the exported video.
*/
func exportModifiedVideo(conversion: GIFGenerator.Conversion) async throws -> URL {
	let (composition, compositionVideoTrack) = try await createComposition(
		conversion: conversion
	)
	let videoComposition = try await createVideoComposition(
		compositionVideoTrack: compositionVideoTrack,
		conversion: conversion
	)
	let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent( "\(UUID().uuidString).mp4")

	let presets = AVAssetExportSession.allExportPresets()
	guard presets.contains(AVAssetExportPresetHighestQuality) else {
		throw ExportModifiedVideoView.Error.unableToCreateExportSession
	}
	guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHighestQuality, with: composition, outputFileType: .mp4) else {
		throw ExportModifiedVideoView.Error.unableToCreateExportSession
	}

	guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
		throw ExportModifiedVideoView.Error.unableToCreateExportSession
	}
	exportSession.videoComposition = videoComposition
	try await exportSession.export(to: outputURL, as: .mp4)
	return outputURL
}

/**
Creates the mutable composition along with the video track inserted.
*/
private func createComposition(
	conversion: GIFGenerator.Conversion,
) async throws -> (AVMutableComposition, AVMutableCompositionTrack) {
	let composition = AVMutableComposition()

	guard let compositionTrack = composition.addMutableTrack(
		withMediaType: .video,
		preferredTrackID: kCMPersistentTrackID_Invalid
	) else {
		throw ExportModifiedVideoView.Error.unableToAddCompositionTrack
	}
	let videoTrack = try await conversion.firstVideoTrack
	try compositionTrack.insertTimeRange(
		try await conversion.exportModifiedVideoTimeRange,
		of: videoTrack,
		at: .zero
	)
	compositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
	return (composition, compositionTrack)
}

/**
Create an `AVMutableVideoComposition` that will scale, translate, and crop the `compositionVideoTrack`.
*/
private func createVideoComposition(
	compositionVideoTrack: AVMutableCompositionTrack,
	conversion: GIFGenerator.Conversion
) async throws -> AVMutableVideoComposition {
	let preferredTransform = try await compositionVideoTrack.load(.preferredTransform)

	let videoComposition = AVMutableVideoComposition()

	let cropRectInPixels = try await conversion.cropRectInPixels
	videoComposition.renderSize = cropRectInPixels.size
	videoComposition.frameDuration = try await compositionVideoTrack.load(.minFrameDuration)

	let instruction = AVMutableVideoCompositionInstruction()
	// The instruction time range must be greater than or equal to the video and there is no penalty for making it longer, so add 1.0 second to the duration just to be safe
	instruction.timeRange = CMTimeRange(start: .zero, duration: .init(seconds: try await conversion.videoWithoutBounceDuration.toTimeInterval + 1.0, preferredTimescale: .video))

	let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
	let scale = try await conversion.scale
	var transform = preferredTransform
	transform = transform.scaledBy(x: scale.width, y: scale.height)
	transform = transform.translated(by:
		-cropRectInPixels.origin / scale,
    )

	layerInstruction.setTransform(transform, at: .zero)
	// layerInstruction.setTransform(.init(scaledBy: scale).translated(by: -cropRectInPixels.origin / scale), at: .zero)
	instruction.layerInstructions = [layerInstruction]

	videoComposition.instructions = [instruction]
	return videoComposition
}

private struct ExportableMP4: Transferable {
	let url: URL
	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(exportedContentType: .mpeg4Movie) { .init($0.url) }
			.suggestedFileName { $0.url.filename }
	}
}
