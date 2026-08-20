# SnapSweep

A small iOS app that scans your photo library **on-device** for the blurry, too-dark,
and accidental "kid took 40 photos of the carpet" shots, then lets you review and
clean them up in one pass.

## How it works

- **Scan** — walks every photo in your library (videos are skipped) and scores each one:
  - *Sharpness*: variance of a Laplacian edge filter over a grayscale thumbnail.
    Out-of-focus photos have almost no edge response, so their score collapses toward zero.
  - *Brightness*: mean luminance, to catch pocket shots (near-black) and blown-out frames.
  - *Junk detection*: Apple's on-device Vision framework image-aesthetics model (iOS 18+),
    which is trained to spot accidental/low-quality captures.
- **Review** — flagged photos show in a grid sorted worst-first, each with badges
  explaining *why* it was flagged. A Strictness slider re-filters instantly.
  Tap a photo to toggle keep/remove; touch and hold to preview it full screen.
- **Act**
  - **Delete** — uses Apple's PhotoKit delete, so iOS shows its own confirmation
    dialog first, and everything lands in *Recently Deleted* for 30 days (recoverable).
  - **To Album** — the no-risk option: adds the selected photos to a
    "SnapSweep Flagged" album in Photos without deleting anything.

Nothing ever leaves the phone — no network calls, no analytics, no accounts.

## Running it on your iPhone

1. Open `SnapSweep.xcodeproj` in Xcode.
2. Select the **SnapSweep** target → *Signing & Capabilities* → set **Team** to your
   Apple ID (add it in Xcode ▸ Settings ▸ Accounts if it isn't there). Xcode will
   manage signing automatically. If the bundle id collides, change
   `com.bensiegel.SnapSweep` to anything unique.
3. Plug in your iPhone (or use Wi-Fi debugging), pick it as the run destination, press **Run**.
4. On the phone: Settings ▸ General ▸ VPN & Device Management → trust your developer
   certificate the first time.

Note: with a **free** Apple ID the install expires after 7 days (just press Run again
to refresh it). A paid Apple Developer account ($99/yr) extends that to a year and is
what you'd need for TestFlight/App Store distribution.

## Running it in the simulator

```sh
xcodebuild -project SnapSweep.xcodeproj -scheme SnapSweep \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install "iPhone 17 Pro" <path-to-built .app>
xcrun simctl launch "iPhone 17 Pro" com.bensiegel.SnapSweep
```

## Tuning

- The blur threshold maps from the Strictness slider in
  `ScanModel.recomputeFlagged()` (`15 + sensitivity * 235`). Raise the range to catch
  more borderline shots, lower it to only catch hopeless ones.
- Brightness cutoffs (`< 0.06` too dark, `> 0.97` blown out) and the Vision
  junk-score cutoff (`< -0.6`) live in the same function.
