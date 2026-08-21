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

### ios screenshot_audit

```sh
[bundle exec] fastlane ios screenshot_audit
```

List the screenshots actually live on App Store Connect, per locale and

device size. deliver's upload retry can leave duplicates behind, so this

is the check after any screenshot push.

### ios testflight_link

```sh
[bundle exec] fastlane ios testflight_link
```

Report the TestFlight beta groups and any public (open) join link.

### ios beta_review_status

```sh
[bundle exec] fastlane ios beta_review_status
```

Show what Beta App Review still needs before an external build can ship:

reviewer contact details, the app-level description, and What to Test.

### ios beta_test_info

```sh
[bundle exec] fastlane ios beta_test_info
```

Fill in the tester-facing TestFlight text: the app-level beta description

and the newest build's What to Test.

e.g. fastlane ios beta_test_info feedback_email:you@example.com

### ios beta_submit

```sh
[bundle exec] fastlane ios beta_submit
```

Set the Beta App Review contact details and submit the newest build for

review. Apple requires all four: first_name, last_name, phone, email.

e.g. fastlane ios beta_submit first_name:Ben last_name:Siegel phone:+15551234567 email:you@example.com

### ios testflight_public_link

```sh
[bundle exec] fastlane ios testflight_public_link
```

Create (or reuse) an external TestFlight group with an open public join

link, attach the newest build, and print the URL for the website.

### ios screenshot_dedupe

```sh
[bundle exec] fastlane ios screenshot_dedupe
```

Delete duplicate screenshots left behind by a deliver upload retry,

keeping one complete copy of each filename and restoring filename order.

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
