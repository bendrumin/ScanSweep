fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios check

```sh
[bundle exec] fastlane ios check
```

Scan the metadata for common App Store rejection reasons.

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload metadata and screenshots to App Store Connect. No binary.

Options: force:true skips the HTML preview; skip_screenshots:true for text only.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).

----

## Screenshots

The 6.9" (1320x2868) marketing screenshots in `fastlane/screenshots/en-US` are
built from raw simulator captures by `tools/frame-screenshot.swift`, which
applies the shared purple frame, headline, and subhead:

```sh
swift tools/make-sample-photos.swift /tmp/samples      # optional stand-in photos
xcrun simctl addmedia <device> /tmp/samples/*.jpg
xcrun simctl io <device> screenshot /tmp/raw.png       # iPhone 17 Pro Max
swift tools/frame-screenshot.swift /tmp/raw.png "Headline" "Subhead" \
  fastlane/screenshots/en-US/0N_name.png
```
