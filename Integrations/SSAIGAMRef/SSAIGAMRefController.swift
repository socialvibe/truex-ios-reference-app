import AVFoundation
import GoogleInteractiveMediaAds
import UIKit

class SSAIGAMRefController: UIViewController {

    private static let contentSourceID = "2496857"
    private static let videoID = "truex-content22-4k"

    private let player = AVPlayer()
    private var playerLayer: AVPlayerLayer!

    private var adsLoader: IMAAdsLoader!
    private var streamManager: IMAStreamManager?
    private var videoDisplay: IMAAVPlayerVideoDisplay?
    private var streamRequested = false
    private var playerObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var isPlayingAd = false
    private var userSeekTime: CMTime?

    @IBOutlet private var spinner: UIActivityIndicatorView!
    @IBOutlet private var progressSlider: UISlider!
    @IBOutlet private var playPauseButton: UIButton!

    private var controlsTimer: Timer?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ""
        view.backgroundColor = .black

        setUpPlayer()
        setUpAdsLoader()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !streamRequested {
            streamRequested = true
            // Workaround: fetch VAST configs to patch GAM ad data that we are unable
            // to modify at the source due to limited GAM account access (see +VASTWorkaround)
            loadVASTConfigs { [weak self] in
                if let configs = self?.vastConfigs {
                    for (key, data) in configs {
                        print("[SSAIGAMRef] VAST config (\(key)):\n\(String(data: data, encoding: .utf8) ?? "<binary>")")
                    }
                }
                self?.requestStream()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controlsTimer?.invalidate()
        controlsTimer = nil
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        streamManager?.destroy()
        streamManager = nil
        videoDisplay = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    deinit {
        streamManager?.destroy()
    }

    // MARK: - Setup

    private func setUpPlayer() {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.insertSublayer(playerLayer, at: 0)

        progressSlider.addTarget(self, action: #selector(progressSliderChanged(_:event:)),
                                 for: .valueChanged)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped),
                                  for: .touchUpInside)
        playPauseButton.backgroundColor = UIColor(white: 0, alpha: 0.5)
        playPauseButton.layer.cornerRadius = 40
        playPauseButton.tintColor = .white
        playPauseButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 40), forImageIn: .normal)

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        view.addGestureRecognizer(tap)

        playerObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                self?.spinner.stopAnimating()
                self?.playerObservation = nil
                if let self, !self.isPlayingAd {
                    self.showControls()
                }
            }
        }
    }

    @objc private func progressSliderChanged(_ slider: UISlider, event: UIEvent) {
        guard let streamManager,
              let duration = player.currentItem?.duration,
              duration.isNumeric else { return }
        let contentDuration = streamManager.contentTime(forStreamTime: CMTimeGetSeconds(duration))
        let targetContentSeconds = Double(slider.value) * contentDuration
        let targetStreamSeconds = streamManager.streamTime(forContentTime: targetContentSeconds)

        // Snap back to unplayed cue points the user tries to seek past
        if let cuePoint = streamManager.previousCuepoint(forStreamTime: targetStreamSeconds),
           !cuePoint.isPlayed {
            userSeekTime = CMTime(seconds: targetStreamSeconds, preferredTimescale: 600)
            let snapTime = CMTime(seconds: cuePoint.startTime, preferredTimescale: 600)
            player.seek(to: snapTime, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        let targetTime = CMTime(seconds: targetStreamSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func viewTapped() {
        guard !isPlayingAd, !spinner.isAnimating else { return }
        if playPauseButton.isHidden {
            showControls()
        } else {
            hideControls()
        }
    }

    @objc private func playPauseTapped() {
        if player.timeControlStatus == .playing {
            player.pause()
            setPlayPauseImage("play.fill")
        } else {
            player.play()
            setPlayPauseImage("pause.fill")
        }
        resetControlsTimer()
    }

    private func showControls() {
        progressSlider.isHidden = false
        playPauseButton.isHidden = false
        let name = player.timeControlStatus == .playing ? "pause.fill" : "play.fill"
        setPlayPauseImage(name)
        resetControlsTimer()
    }

    private func hideControls() {
        progressSlider.isHidden = true
        playPauseButton.isHidden = true
        controlsTimer?.invalidate()
        controlsTimer = nil
    }

    private func setPlayPauseImage(_ systemName: String) {
        playPauseButton.setImage(UIImage(systemName: systemName), for: .normal)
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    private func setUpAdsLoader() {
        let settings = IMASettings()
        adsLoader = IMAAdsLoader(settings: settings)
        adsLoader.delegate = self
    }

    private func requestStream() {
        videoDisplay = IMAAVPlayerVideoDisplay(avPlayer: player)
        let request = IMAVODStreamRequest(
            contentSourceID: Self.contentSourceID,
            videoID: Self.videoID,
            adDisplayContainer: IMAAdDisplayContainer(
                adContainer: view, viewController: self),
            videoDisplay: videoDisplay!,
            userContext: nil
        )
        adsLoader.requestStream(with: request)
    }
}

// MARK: - IMAAdsLoaderDelegate

extension SSAIGAMRefController: IMAAdsLoaderDelegate {
    func adsLoader(_ loader: IMAAdsLoader, adsLoadedWith adsLoadedData: IMAAdsLoadedData) {
        streamManager = adsLoadedData.streamManager
        streamManager?.delegate = self
        streamManager?.initialize(with: nil)
        print("[SSAIGAMRef] Stream loaded successfully")

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval,
                                                           queue: .main) { [weak self] time in
            guard let self,
                  let streamManager = self.streamManager,
                  !self.isPlayingAd,
                  !self.progressSlider.isTracking,
                  let duration = self.player.currentItem?.duration,
                  duration.isNumeric else { return }
            let streamSeconds = CMTimeGetSeconds(time)
            let contentSeconds = streamManager.contentTime(forStreamTime: streamSeconds)
            let contentDuration = streamManager.contentTime(forStreamTime: CMTimeGetSeconds(duration))
            guard contentDuration > 0 else { return }
            self.progressSlider.value = Float(contentSeconds / contentDuration)
        }
    }

    func adsLoader(_ loader: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
        print("[SSAIGAMRef] Stream failed to load: \(adErrorData.adError.message ?? "unknown error")")
    }
}

// MARK: - IMAStreamManagerDelegate

extension SSAIGAMRefController: IMAStreamManagerDelegate {
    func streamManager(_ streamManager: IMAStreamManager, didReceive event: IMAAdEvent) {
        switch event.type {
        case .AD_BREAK_STARTED:
            isPlayingAd = true
            hideControls()
        case .AD_BREAK_ENDED:
            isPlayingAd = false
            if let seekTime = userSeekTime {
                userSeekTime = nil
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        default:
            break
        }
    }

    func streamManager(_ streamManager: IMAStreamManager, didReceive error: IMAAdError) {
        print("[SSAIGAMRef] Ad error: \(error.message ?? "unknown error")")
    }
}
