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

## App Store screenshots

The 6.9" (1320x2868) marketing screenshots in `fastlane/screenshots/en-US` are built
from raw simulator captures by `tools/frame-screenshot.swift`, which applies the shared
purple frame, headline, and subhead measured off the original hand-made set:

```sh
swift tools/make-sample-photos.swift /tmp/samples     # synthetic stand-in "bad" photos
xcrun simctl addmedia <device> /tmp/samples/*.jpg
xcrun simctl io <device> screenshot /tmp/raw.png      # must be an iPhone 17 Pro Max
swift tools/frame-screenshot.swift /tmp/raw.png "Headline" "Subhead" \
  fastlane/screenshots/en-US/0N_name.png
```

Screenshots upload with `fastlane ios metadata`, which then runs
`screenshot_dedupe` automatically. That cleanup is not optional: when App Store Connect
is slow to index an upload, `deliver` decides the files it just sent are missing and
retries, and the retry leaves a second copy of every screenshot on the listing —
while still exiting successfully. `fastlane ios screenshot_audit` reports what is
actually live if you want to confirm.

Note `fastlane/README.md` is regenerated on every fastlane run, so it is not a place to
put notes like these.

## Mac support (validated, deferred to 1.1)

A Mac Catalyst build was spiked and **works with zero source changes** — everything
that looks iOS-only (`UIImage`, `UIApplication`, `Color(.systemGroupedBackground)`,
`.navigationBarTitleDisplayMode`) is fine because Catalyst *is* UIKit on macOS. The
analysis pipeline also compiles clean against the macOS SDK: PhotoKit, deletion via
`performChanges`, `VNCalculateImageAestheticsScoresRequest`, and the perceptual hash
all resolve.

To enable it, add to both target configs:

```
SUPPORTS_MACCATALYST = YES;
DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO;
```

then build with `-destination 'platform=macOS,variant=Mac Catalyst'`.

Two things the spike found that a compile alone would not have:

1. **Photos access is denied without an entitlement.** The Catalyst build ships only
   `com.apple.security.get-task-allow`, so `PHPhotoLibrary.authorizationStatus`
   reports denied/restricted and the app boots into the "needs access" dead end. It
   needs `com.apple.security.personal-information.photos-library`, plus App Sandbox
   for App Store distribution.
2. **The layout inflates.** At a 1024pt window the phone UI stretches — the footer
   button spans the full width with large empty gutters. The views need max-width
   constraints, and `FlaggedGrid` should use the extra width for more columns, which
   is the main reason to want a Mac build at all.

Note that iCloud Photos syncs deletions, so cleaning on iPhone already cleans the
Mac. Mac support is an ergonomics win (reviewing a large flagged grid on a big
display), not a coverage one.
