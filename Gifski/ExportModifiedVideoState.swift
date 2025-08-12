import Foundation

enum ExportModifiedVideoState {
	case idle
	case audioWarning
	case exporting(Task<Void, Never>, videoIsOverTwentySeconds: Bool)
	case finished(URL)

	var isWarning: Bool {
		switch self {
		case .audioWarning:
			true
		default:
			false
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
