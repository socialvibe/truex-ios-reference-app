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
    private var streamRequested = false
    private var playerObservation: NSKeyValueObservation?

    @IBOutlet private var spinner: UIActivityIndicatorView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        streamManager?.destroy()
        streamManager = nil
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
        view.layer.addSublayer(playerLayer)

        playerObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                self?.spinner.stopAnimating()
                self?.playerObservation = nil
            }
        }
    }

    private func setUpAdsLoader() {
        let settings = IMASettings()
        adsLoader = IMAAdsLoader(settings: settings)
        adsLoader.delegate = self
    }

    private func requestStream() {
        let videoDisplay = IMAAVPlayerVideoDisplay(avPlayer: player)
        let request = IMAVODStreamRequest(
            contentSourceID: Self.contentSourceID,
            videoID: Self.videoID,
            adDisplayContainer: IMAAdDisplayContainer(
                adContainer: view, viewController: self),
            videoDisplay: videoDisplay,
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
    }

    func adsLoader(_ loader: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
        print("[SSAIGAMRef] Stream failed to load: \(adErrorData.adError.message ?? "unknown error")")
    }
}

// MARK: - IMAStreamManagerDelegate

extension SSAIGAMRefController: IMAStreamManagerDelegate {
    func streamManager(_ streamManager: IMAStreamManager, didReceive event: IMAAdEvent) {
        print("[SSAIGAMRef] Ad event: \(event.typeString ?? "unknown")")
        if let url = (player.currentItem?.asset as? AVURLAsset)?.url {
            print("[SSAIGAMRef] Stream URL: \(url.absoluteString)")
        }
    }

    func streamManager(_ streamManager: IMAStreamManager, didReceive error: IMAAdError) {
        print("[SSAIGAMRef] Ad error: \(error.message ?? "unknown error")")
    }
}
