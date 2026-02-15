import AVFoundation
import GoogleInteractiveMediaAds
import TruexAdRenderer
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
    private var isPresentingInfillionAd = false
    private var truexAdRenderer: TruexAdRenderer?
    private var didReceiveInfillionCredit = false
    private var lastInfillionAdEndTime: Double?

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
                self?.requestStream()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        truexAdRenderer?.stop()
        truexAdRenderer = nil
        isPresentingInfillionAd = false
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
                    if let cuepoints = self.streamManager?.cuepoints as? [IMACuepoint] {
                        for (i, cp) in cuepoints.enumerated() {
                            print("[SSAIGAMRef] Cuepoint \(i): start=\(cp.startTime) end=\(cp.endTime) played=\(cp.isPlayed)")
                        }
                    }
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

        // Snap back to the first unplayed cue point before the target
        if let cuePoint = (streamManager.cuepoints as? [IMACuepoint])?
            .filter({ !$0.isPlayed && $0.startTime <= targetStreamSeconds })
            .min(by: { $0.startTime < $1.startTime }) {
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

    private func handleAdStarted(_ event: IMAAdEvent) {
        guard !isPresentingInfillionAd else { return }
        guard let ad = event.ad else { return }
        let adSystem = ad.adSystem.lowercased()

        let isTruex = adSystem == "truex"
        let isIDVx = adSystem == "idvx"
        guard isTruex || isIDVx else { return }

        let configKey = isIDVx ? "idvx" : "truex"
        let vastData = vastConfigs?[configKey]
        guard let vastData else {
            print("[SSAIGAMRef] Missing prefetched VAST for \(configKey)")
            return
        }

        // Calculate end time for the placeholder ad so we can seek past it
        // when the Infillion experience completes without credit.
        let currentStreamSeconds = CMTimeGetSeconds(player.currentTime())
        let duration = ad.duration
        if duration > 0 {
            lastInfillionAdEndTime = currentStreamSeconds + duration
        } else {
            lastInfillionAdEndTime = nil
        }

        // Note: In a typical GAM flow, you would call getTraffickingParameters on the
        // IMA ad object. Here we explicitly extract AdParameters from the prefetched VAST
        // because we cannot modify the GAM ad source configuration (limited account access).
        let params = extractAdParameters(from: vastData)
        guard params != nil else {
            print("[SSAIGAMRef] Missing AdParameters in prefetched VAST for \(configKey)")
            return
        }

        startInfillionAd(params: params)
    }

    private func startInfillionAd(params: [String: Any]?) {
        guard truexAdRenderer == nil else { return }
        guard let params else { return }

        isPresentingInfillionAd = true
        didReceiveInfillionCredit = false

        player.pause()
        hideControls()

        truexAdRenderer = TruexAdRenderer(adParameters: params, slotType: "midroll", delegate: self)

        truexAdRenderer?.start(view)
    }

    private func finishInfillionAd(earnedCredit: Bool) {
        truexAdRenderer?.stop()
        truexAdRenderer = nil
        isPresentingInfillionAd = false

        player.play()

        if earnedCredit {
            skipCurrentAdBreak()
            isPlayingAd = false
            showControls()
        } else if let lastInfillionAdEndTime {
            // Seek to the end of the placeholder ad so fallback ads can play.
            let lastInfillionAdEndSecond = floor(lastInfillionAdEndTime)
            let target = CMTime(seconds: max(0, lastInfillionAdEndSecond - 0.1), preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        lastInfillionAdEndTime = nil
    }

    private func skipCurrentAdBreak() {
        guard let cuepoints = streamManager?.cuepoints as? [IMACuepoint] else { return }
        let streamSeconds = CMTimeGetSeconds(player.currentTime())
        guard let cuepoint = cuepoints.first(where: { $0.startTime <= streamSeconds && streamSeconds < $0.endTime }) else {
            return
        }
        let target = CMTime(seconds: cuepoint.endTime + 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self,
                  let streamManager = self.streamManager,
                  !self.isPlayingAd,
                  !self.progressSlider.isTracking,
                  let duration = self.player.currentItem?.duration,
                  duration.isNumeric else { return }
            let streamSeconds = CMTimeGetSeconds(time)

            // If playback hits an already-played ad break during normal playback, skip it.
            if let cuepoint = (streamManager.cuepoints as? [IMACuepoint])?
                .first(where: { $0.isPlayed && $0.startTime <= streamSeconds && streamSeconds < $0.endTime }) {
                let target = CMTime(seconds: cuepoint.endTime + 0.1, preferredTimescale: 600)
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }

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
            let pos = CMTimeGetSeconds(player.currentTime())
            print("[SSAIGAMRef] AD_BREAK_STARTED at stream time \(pos)")
            isPlayingAd = true
            hideControls()
        case .AD_BREAK_ENDED:
            let pos = CMTimeGetSeconds(player.currentTime())
            print("[SSAIGAMRef] AD_BREAK_ENDED at stream time \(pos)")
            isPlayingAd = false
        case .STARTED:
            let pos = CMTimeGetSeconds(player.currentTime())
            print("[SSAIGAMRef] STARTED at stream time \(pos)")
            handleAdStarted(event)
        default:
            break
        }
    }

    func streamManager(_ streamManager: IMAStreamManager, didReceive error: IMAAdError) {
        print("[SSAIGAMRef] Ad error: \(error.message ?? "unknown error")")
    }
}

// MARK: - TruexAdRendererDelegate

extension SSAIGAMRefController: TruexAdRendererDelegate {
    func onAdCompleted(_ timeSpent: Int) {
        print("[SSAIGAMRef] TrueX completed: \(timeSpent)")
        finishInfillionAd(earnedCredit: didReceiveInfillionCredit)
    }

    func onAdError(_ errorMessage: String) {
        print("[SSAIGAMRef] TrueX error: \(errorMessage)")
        finishInfillionAd(earnedCredit: didReceiveInfillionCredit)
    }

    func onNoAdsAvailable() {
        print("[SSAIGAMRef] TrueX no ads available")
        finishInfillionAd(earnedCredit: didReceiveInfillionCredit)
    }

    func onAdFreePod() {
        print("[SSAIGAMRef] TrueX credit earned (ad-free pod)")
        didReceiveInfillionCredit = true
    }

    func onPopupWebsite(_ url: String!) {
        print("[SSAIGAMRef] TrueX popup: \(url ?? "<unknown>")")
    }
}
