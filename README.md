# Infillion iOS Reference App

## Overview

This project demonstrates how to integrate the Infillion ad renderer with various ad insertion mechanisms on iOS. Each integration is presented as a standalone screen accessible from the app's home menu.

## Prerequisites

- Xcode 15+
- iOS 16+
- Familiarity with AVPlayer and the relevant ad SDK for the integration you're looking at

## Dependencies

Managed via Swift Package Manager:

- [GoogleInteractiveMediaAds](https://developers.google.com/interactive-media-ads/docs/sdks/ios/) (v3.28.10) — IMA SDK for stream and ad management
- [TruexAdRenderer-iOS](https://github.com/socialvibe/TruexAdRenderer-iOS-Swift-Package) (v4.1.0) — Infillion interactive ad renderer

## Infillion Ad Types

- **true[X]** — An interactive opt-in ad that always appears at position 1 of the ad pod. It presents a choice card to the viewer. If they engage and complete the interaction, they earn true[ATTENTION] credit and the rest of the ad break is skipped. If they decline, fallback ads play instead.
- **IDVx** — A non-interactive ad that plays automatically without viewer input. It can appear at any position in the ad pod and integrates seamlessly alongside third-party ads.

Both are delivered through the `TruexAdRenderer` and identified at runtime by the ad's `adSystem` field (`truex` or `idvx`).

## Integrations

### SSAI + GAM

Server-side ad insertion via Google Ad Manager. The implementation lives in `Integrations/SSAIGAMRef/`.

**Files:**
- `SSAIGAMRefController.swift` — stream setup, ad break handling, TrueX renderer lifecycle
- `SSAIGAMRefController+VASTWorkaround.swift` — prefetches VAST configs (workaround for limited GAM account access; not part of a standard integration)

**Flow:**

1. **Request the SSAI stream** — An `IMAVODStreamRequest` is created with the content source and video IDs. IMA stitches ads into the stream.

2. **Detect Infillion ads** — When `IMAStreamManagerDelegate` fires a `.STARTED` event, the ad's `adSystem` field is checked for `truex` or `idvx`.

3. **Start the engagement** — Playback is paused, `TruexAdRenderer` is initialized with the ad parameters, and `start` is called to present the interactive experience.

4. **Handle credit** — If the viewer earns true[ATTENTION], the `onAdFreePod` delegate callback fires. The app records this so it can skip the remaining ad break when the renderer finishes.

5. **Handle completion** — On `onAdCompleted`, `onAdError`, or `onNoAdsAvailable`, the renderer is torn down and playback resumes. If credit was earned, the entire ad break is skipped; otherwise, fallback ads play normally.

**Playback controls:**
- Tap to show/hide play-pause and progress slider (auto-hides after 3 seconds)
- Seeking snaps back to the first unplayed ad cue point before the target position
- Already-played ad breaks are automatically skipped during normal playback

## Setup

1. Clone the repository
2. Open `Integrations.xcodeproj` in Xcode
3. Xcode will resolve Swift Package Manager dependencies automatically
4. Build and run on a simulator or device
