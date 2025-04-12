import AVKit
import SwiftUI

struct TrimmingAVPlayer: NSViewControllerRepresentable {
	typealias NSViewControllerType = TrimmingAVPlayerViewController

	let asset: AVAsset
	var controlsStyle = AVPlayerViewControlsStyle.inline
	var loopPlayback = false
	var bouncePlayback = false
	var speed = 1.0

	var showPreview = false
	var currentTimeDidChange: ((Double) -> Void)?
	var previewImage: NSImage?
	var previewAnimation: NSImage?
	var animationBeingGeneratedNow = false

	var timeRangeDidChange: ((ClosedRange<Double>) -> Void)?

	func makeNSViewController(context: Context) -> NSViewControllerType {
		.init(
			playerItem: .init(asset: asset),
			controlsStyle: controlsStyle,
			currentTimeDidChange: currentTimeDidChange,
			timeRangeDidChange: timeRangeDidChange
		)
	}

	func updateNSViewController(_ nsViewController: NSViewControllerType, context: Context) {
		if asset != nsViewController.currentItem.asset {
			nsViewController.currentItem = .init(asset: asset)
		}

		nsViewController.loopPlayback = loopPlayback
		nsViewController.bouncePlayback = bouncePlayback
		nsViewController.player.defaultRate = Float(speed)
		nsViewController.showPreview = showPreview
		nsViewController.animationBeingGeneratedNow = animationBeingGeneratedNow
		nsViewController.previewAnimation = previewAnimation
		nsViewController.previewImage = previewImage

		if nsViewController.player.rate != 0 {
			nsViewController.player.rate = nsViewController.player.rate > 0 ? Float(speed) : -Float(speed)
		}
	}
}

// TODO: Move more of the logic here over to the SwiftUI view.
/**
A view controller containing AVPlayerView and also extending possibilities for trimming (view) customization.
*/
final class TrimmingAVPlayerViewController: NSViewController {
	private(set) var timeRange: ClosedRange<Double>?
	private let playerItem: AVPlayerItem
	fileprivate let player: LoopingPlayer
	private let controlsStyle: AVPlayerViewControlsStyle
	private let timeRangeDidChange: ((ClosedRange<Double>) -> Void)?
	private var cancellables = Set<AnyCancellable>()
	private var previewView: NSHostingView<PreviewView>!

	// TrimmingAVPlayerViewController+PreviewGenerator
	private let currentTimeDidChange: ((Double) -> Void)?
	private var periodicTimeObserver: Any?
	private var rateObserver: AnyCancellable?
	@MainActor
	var previewViewState = PreviewViewState(previewImage: nil)

	fileprivate var previewAnimation: NSImage? {
		didSet {
			/**
			Only update the previewImage if we are
			playing
			 */
			guard player.rate != 0 else {
				return
			}
			Task{
				@MainActor in
				self.previewViewState.previewImage = self.previewAnimation
			}
		}
	}

	fileprivate var previewImage: NSImage? {
		didSet {
			/**
			 Only assign to the image if we are paused
			 */
			guard player.rate == 0 else {
				return
			}
			Task {
				@MainActor in
				self.previewViewState.previewImage = self.previewImage
			}
		}
	}


	/**
	 On Showing or hiding the preview we
	 also have to hide the trim buttons
	 because we hide the play button if
	 the animation preview is not
	 available
	 */
	fileprivate var showPreview = false {
		didSet {
			playerView.showPreview = self.showPreview
			guard oldValue != self.showPreview else {
				return
			}
			if self.showPreview {
				playerView.contentOverlayView?.addSubview(previewView)
				playerView.hideTrimButtons()
			   previewView.constrainEdgesToSuperview()
			} else {
				playerView.hideTrimButtons()
				previewView.removeFromSuperview()
			}
		}
	}


	/**
	 Have to update the player views' AnimationBeingGeneratedNow
	 because it will have to hide the play button if the animation
	 is unavailable
	 */
	fileprivate var animationBeingGeneratedNow = false {
		didSet {
			playerView.animationBeingGeneratedNow = self.animationBeingGeneratedNow
			guard oldValue != self.animationBeingGeneratedNow else {
				return
			}
			playerView.hideTrimButtons()
		}
	}



	var playerView: TrimmingAVPlayerView { view as! TrimmingAVPlayerView }

	/**
	The minimum duration the trimmer can be set to.
	*/
	var minimumTrimDuration = 0.1 {
		didSet {
			playerView.minimumTrimDuration = minimumTrimDuration
		}
	}

	var loopPlayback: Bool {
		get { player.loopPlayback }
		set {
			player.loopPlayback = newValue
		}
	}

	var bouncePlayback: Bool {
		get { player.bouncePlayback }
		set {
			player.bouncePlayback = newValue
		}
	}

	/**
	Get or set the current player item.

	When setting an item, it preserves the current playback rate (which means pause state too), playback position, and trim range.
	*/
	var currentItem: AVPlayerItem {
		get { player.currentItem! }
		set {
			let rate = player.rate
			let playbackPercentage = player.currentItem?.playbackProgress ?? 0
			let playbackRangePercentage = player.currentItem?.playbackRangePercentage

			player.replaceCurrentItem(with: newValue)

			DispatchQueue.main.async { [self] in
				player.rate = rate
				player.currentItem?.seek(toPercentage: playbackPercentage)
				player.currentItem?.playbackRangePercentage = playbackRangePercentage
			}
		}
	}

	init(
		playerItem: AVPlayerItem,
		controlsStyle: AVPlayerViewControlsStyle = .inline,
		currentTimeDidChange: ((Double) -> Void)? = nil,
		timeRangeDidChange: ((ClosedRange<Double>) -> Void)? = nil
	) {
		self.playerItem = playerItem
		self.player = LoopingPlayer(playerItem: playerItem)
		self.controlsStyle = controlsStyle
		self.timeRangeDidChange = timeRangeDidChange
		self.currentTimeDidChange = currentTimeDidChange

		super.init(nibName: nil, bundle: nil)

		var previousRate: Float = 0.0
		rateObserver = player
			.publisher(for: \.rate)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] newRate in
				guard let self else {
					return
				}
				defer {
					previousRate = newRate
				}

				guard self.showPreview else {
					return
				}
				// If animation is being generated, show the preview image
				if self.animationBeingGeneratedNow {
					// Avoid infinite loop: stop the player if rate is already 0
					guard newRate != 0 else {
						return
					}
					self.player.rate = 0
					self.previewViewState.previewImage = self.previewImage
					return
				}

				let shouldShowAnimation = newRate != 0

				if shouldShowAnimation {
					self.previewViewState.previewImage = self.previewAnimation
					if newRate > 0 && previousRate == 0 {
						self.player.seekToStart()
					}
				} else {
					self.previewViewState.previewImage = self.previewImage
				}
			}
		Task {
			for await time in  self.player.timeStream() {
				self.currentTimeDidChange?(time.toTimeInterval)
			}
		}
	}

	deinit {
		print("TrimmingAVPlayerViewController - DEINIT")
		if let periodicTimeObserver {
			player.removeTimeObserver(periodicTimeObserver)
		}
		rateObserver?.cancel()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		previewView = NSHostingView(rootView: PreviewView(previewViewState: self.previewViewState))
		let playerView = TrimmingAVPlayerView()
		playerView.allowsVideoFrameAnalysis = false
		playerView.controlsStyle = controlsStyle
		playerView.player = player
		view = playerView
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		// Support replacing the item.
		player.publisher(for: \.currentItem)
			.compactMap(\.self)
			.flatMap { currentItem in
				// TODO: Make a `AVPlayerItem#waitForReady` async property when using Swift 6.
				currentItem.publisher(for: \.status)
					.first { $0 == .readyToPlay }
					.map { _ in currentItem }
			}
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in
				guard let self else {
					return
				}

				playerView.setupTrimmingObserver()

				if let durationRange = $0.durationRange {
					timeRangeDidChange?(durationRange)
				}

				// This is here as it needs to be refreshed when the current item changes.
				playerView.observeTrimmedTimeRange { [weak self] timeRange in
					self?.timeRange = timeRange
					self?.timeRangeDidChange?(timeRange)
				}
			}
			.store(in: &cancellables)
	}
}



final class TrimmingAVPlayerView: AVPlayerView {
	private var timeRangeCancellable: AnyCancellable?
	private var trimmingCancellable: AnyCancellable?


	/**
	 TrimmingAVPlayerView + PreviewGenerator
	 These are needed to hide the play button
	 when an animation is not yet available
	 this is done in hideTrimButtons
	 */
	fileprivate var showPreview = false
	fileprivate var animationBeingGeneratedNow = false

	/**
	The minimum duration the trimmer can be set to.
	*/
	var minimumTrimDuration = 0.1

	deinit {
		print("TrimmingAVPlayerView - DEINIT")
	}

	// TODO: This should be an AsyncSequence.
	fileprivate func observeTrimmedTimeRange(_ updateClosure: @escaping (ClosedRange<Double>) -> Void) {
		var skipNextUpdate = false

		timeRangeCancellable = player?.currentItem?.publisher(for: \.duration, options: .new)
			.sink { [weak self] _ in
				guard
					let self,
					let item = player?.currentItem,
					let fullRange = item.durationRange,
					let playbackRange = item.playbackRange
				else {
					return
				}

				// Prevent infinite recursion.
				guard !skipNextUpdate else {
					skipNextUpdate = false
					updateClosure(playbackRange.minimumRangeLength(of: minimumTrimDuration, in: fullRange))
					return
				}

				guard playbackRange.length > minimumTrimDuration else {
					skipNextUpdate = true
					item.playbackRange = playbackRange.minimumRangeLength(of: minimumTrimDuration, in: fullRange)
					return
				}

				updateClosure(playbackRange)
			}
	}

	fileprivate func setupTrimmingObserver() {
		trimmingCancellable = Task {
			do {
				try await activateTrimming()
				addCheckerboardView()
				hideTrimButtons()
				window?.makeFirstResponder(self)
			} catch {}
		}
		.toCancellable
	}

	fileprivate func hideTrimButtons() {
		// This method is a collection of hacks, so it might be acting funky on different OS versions.
		guard
			let avTrimView = firstSubview(deep: true, where: { $0.simpleClassName == "AVTrimView" }),
			let superview = avTrimView.superview
		else {
			return
		}

		// First find the constraints for `avTrimView` that pins to the left edge of the button.
		// Then replace the left edge of a button with the right edge - this will stretch the trim view.
		if let constraint = superview.constraints.first(where: {
			($0.firstItem as? NSView) == avTrimView && $0.firstAttribute == .right
		}) {
			superview.removeConstraint(constraint)
			constraint.changing(secondAttribute: .right).isActive = true
		}

		if let constraint = superview.constraints.first(where: {
			($0.secondItem as? NSView) == avTrimView && $0.secondAttribute == .right
		}) {
			superview.removeConstraint(constraint)
			constraint.changing(firstAttribute: .right).isActive = true
		}

		// Now find buttons that are not images (images are playing controls) and hide them.
		superview.subviews
			.first { $0 != avTrimView }?
			.subviews
			.filter { ($0 as? NSButton)?.image == nil }
			.forEach {
				$0.isHidden = true
			}

		if self.showPreview && animationBeingGeneratedNow {
			/**
			 Hide the play button when the animation is being generated
			 Only show it when you can play the animation
			 */
			superview.subviews
				.first { $0 != avTrimView }?
				.subviews
				.forEach {
					guard let button = ($0 as? NSButton) else {
						return
					}
					button.isEnabled = false
				}
		} else {
			/**
			 Need to potentially unhide the play button
			 */
			superview.subviews
				.first { $0 != avTrimView }?
				.subviews
				.forEach {
					guard let button = ($0 as? NSButton) else {
						return
					}
					button.isEnabled = true
				}
			superview.subviews
				.first { $0 != avTrimView }?
				.subviews
				.filter { ($0 as? NSButton)?.image == nil }
				.forEach {
					$0.isHidden = true
				}
		}
	}

	fileprivate func addCheckerboardView() {
		let overlayView = NSHostingView(rootView: CheckerboardView(clearRect: videoBounds))
		contentOverlayView?.addSubview(overlayView)
		overlayView.constrainEdgesToSuperview()
	}

	/**
	Prevent user from dismissing trimming view.
	*/
	override func cancelOperation(_ sender: Any?) {}
}
