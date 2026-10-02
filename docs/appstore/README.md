# App Store submission

Everything needed to put the iOS app on the App Store, written so a submission
can be assembled from this directory without inventing facts about the app.

The app is **live on the App Store**:
[PulsHealth](https://apps.apple.com/us/app/pulshealth/id6757657354) (free,
Health & Fitness, 4+, bundle ID `com.pulsHealth.PulsHealth`). What shipped,
and when, is the [Release record](#release-record) at the bottom.

| Document | What it is |
|---|---|
| [`listing.md`](listing.md) | The App Store Connect record: name, subtitle, promotional text, description, keywords, URLs, category, age-rating answers, the App Privacy "Data Not Collected" answer and its reasoning, and what to do about screenshots. |
| [`review-notes.md`](review-notes.md) | The App Review Information → Notes text, ready to paste once four placeholders are filled in, plus prepared answers for the questions this app invites. |
| [`review-backend.md`](review-backend.md) | How to stand up the throwaway public server a reviewer needs, and how to tear it down afterwards. |
| [`../privacy-policy.md`](../privacy-policy.md) | The privacy policy, served at `https://pulshealth.com/privacy` by `site/`. |

They cover **STORE-1**, **STORE-2**, **STORE-3** and **STORE-5** from
[`docs/open-source-plan.md`](../open-source-plan.md).

## The one-sentence version

PulsHealth sends the user's health data to a server the *user* runs — or, on
request, writes it to files the user saves or sends themselves; the developer
receives nothing, operates nothing, and has nothing to collect. Every
document here is an application of that single fact, and every claim in them is
checkable against the source in this repository.

## Submission checklist

Work top to bottom. Items marked **maintainer only** need the Apple Developer
account, the signing team, a real device or personal contact details.

### Build and upload

- [ ] Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
      `PulsHealth/project.yml`. The store holds 1.6 (19), so the next upload
      needs a version above 1.6 and build 20 or higher: App Store Connect
      refuses a build number it has already accepted.
- [ ] `cd PulsHealth && xcodegen` — the Xcode project is generated and
      untracked — with `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`.
- [ ] **maintainer only** — Archive and upload with the signed-in Xcode:
      ```bash
      xcodebuild archive -project PulsHealth.xcodeproj -scheme PulsHealth \
        -destination 'generic/platform=iOS' \
        -archivePath "$SCRATCH/PulsHealth.xcarchive" -allowProvisioningUpdates
      xcodebuild -exportArchive -archivePath "$SCRATCH/PulsHealth.xcarchive" \
        -exportOptionsPlist "$SCRATCH/ExportOptions.plist" -allowProvisioningUpdates
      ```
      `ExportOptions.plist` sets method `app-store-connect`, destination
      `upload`, signing style `automatic` and the `teamID`; it holds the Team
      ID, so it never goes in the repository. `ITSAppUsesNonExemptEncryption`
      is `false` in `Info.plist`, so there is no export-compliance
      questionnaire.
- [ ] Check the processed build's privacy report: the app and the
      `PulsHealthSync` package each ship a `PrivacyInfo.xcprivacy` declaring no
      tracking, no collected data, and `UserDefaults` / `CA92.1`.
- [ ] **maintainer only** — Run the TestFlight build on a real device,
      installed over the store version, for a few days. Background delivery,
      continued processing and an upgrade's first sync only show up there.
- [ ] Add the build to the [Release record](#release-record).

### Listing and privacy policy

- [ ] Re-read [`../privacy-policy.md`](../privacy-policy.md) against the
      build. It is a factual claim about the binary: any change to where data
      goes, what is stored or what is read lands there too, and the site is
      deployed (`scripts/deploy-site.sh`) before submitting, because App Review
      reads the live `/privacy`.
- [ ] Update [`listing.md`](listing.md) for what changed — description,
      promotional text, keywords, What's New — check the bracketed counts, and
      paste.
- [ ] Age rating and App Privacy are answered as tabulated in `listing.md`
      (4+, Data Not Collected). Revisit them only if something they ask about
      changed.

### Screenshots

- [ ] Retake the set if the screens changed, in the order
      [`listing.md`](listing.md) § Screenshots gives. Never ship simulator
      shots of Explore, a Type page, Sync or background activity **without the
      demo fixtures**: with no Health data behind them every count is zero,
      which misrepresents the app.
- [ ] Keep the four images in the root `README.md` (`docs/images/app/`,
      600 px wide) in step with the store set.

### Review backend

- [ ] Stand up the throwaway instance following
      [`review-backend.md`](review-backend.md), and verify it from off-network
      (`/healthz` and `/v1/capabilities`).
- [ ] Walk the whole of [`review-notes.md`](review-notes.md) on a spare device
      (or an erased simulator), exactly as written.
- [ ] Fill the four placeholders and paste the notes block. Keep the filled-in
      copy out of the repository — it holds a live token.
- [ ] **maintainer only** — App Review contact details (name, phone, e-mail)
      are personal and deliberately absent from this repository.

### Submit

- [ ] Attach the build, choose the release option and submit. Expect
      questions about the external database and `NSAllowsLocalNetworking`;
      the notes answer both.

### After approval

- [ ] Tear the review instance down, volume and DNS record included
      ([`review-backend.md`](review-backend.md) § 6).
- [ ] Add the release to the [Release record](#release-record), and update
      `CLAUDE.md`'s "shipped software" bullet and `docs/roadmap.md`.

## Keeping these documents true

They make specific factual claims about the binary. When any of the following
changes, revisit them in the same pull request:

| If this changes | Revisit |
|---|---|
| Where data is sent, or any new outbound request | `privacy-policy.md`, `listing.md` (App Privacy), `review-notes.md` |
| A new dependency of any kind | `privacy-policy.md`, `listing.md` — "zero third-party dependencies" stops being true |
| A new permission or usage string | `privacy-policy.md`, `review-notes.md`, `PrivacyInfo.xcprivacy` |
| A URL scheme, or any other way another app or a web page can hand the app input (today: `puls://pair`, confirmed before it fills anything) | `privacy-policy.md` (how the server URL gets into the app), `review-notes.md` (URL SCHEME), `listing.md` (the "Unrestricted web access" row) |
| What is stored on the device, or where (today: sync state, logs, four preferences, a staged export, and per-type analysis summaries) | `privacy-policy.md` § What stays on the device, `SECURITY.md`, the site's `/privacy` glance card |
| The on-device export: where files are staged, when the app deletes them (launch, new export, Delete Export, a completed share), what identity they carry, which share activities are offered | `privacy-policy.md` § Exports, `SECURITY.md`, the site's `/privacy` glance card, `review-notes.md` (WITHOUT A SERVER, HEALTHKIT), `listing.md` (description, App Privacy point 2) |
| The first-run flow's steps | `review-notes.md` — the reviewer walkthrough is step-by-step |
| `ServerURLValidation`'s rules | `review-notes.md` — the ATS justification quotes them |
| Anything about HealthKit write access | everything; read-only is the load-bearing claim |
| The maintainer's invite-only viewer instance: who may join (today invitation only), what it stores, who carries its traffic (Cloudflare) | `privacy-policy.md` § If the developer invited you, the site's `/privacy` glance card, `listing.md` (App Privacy point 1). Opening it to sign-ups changes the App Privacy answer — decide that first |
| What ships to the store | [Release record](#release-record) — these documents describe the shipped binary, not whatever `main` happens to be |

## Release record

What is actually on the store, so the next submission starts from a record
rather than from memory. Add a row per release; builds that went to TestFlight
only are noted under the release that superseded them.

| | |
|---|---|
| Listing | [apps.apple.com/us/app/pulshealth/id6757657354](https://apps.apple.com/us/app/pulshealth/id6757657354) |
| Bundle ID | `com.pulsHealth.PulsHealth` |
| Category / rating / price | Health & Fitness (secondary: Utilities) · 4+ · Free |
| First released | 2026-01-21 |

| Version | Released | Notes |
|---|---|---|
| 1.6 (19) | 2026-10-01 | Current version on the store. Explore, Export, Sync and Settings tabs; Explore analyses of a type's past year, with summaries kept on the device; an Export builder that needs no database (CSV or JSONL, optionally zipped); iOS 27 limited Health history handled without overwriting what the app cannot read; a four-page first run whose Health page cannot be skipped, calling the sync destination "your database". Also carries 1.5's pairing from a link, the Camera app or the clipboard, and recent-data-first background sync. Built with Xcode 27.0 (iOS 27.0 SDK). Submitted 2026-09-30, approved and released automatically 2026-10-01. Screenshots from the simulator with the demo fixtures (`listing.md` § Screenshots). The review instance received no uploads. 1.5 (16) and 1.6 (17, 18) went to TestFlight only. |
| 1.4 (15) | 2026-09-19 | Self-hosted sync: first-run onboarding with QR pairing, Keychain token, per-server sync state, capabilities-gated UI, published type vocabulary. Build 14 was rejected under 5.2.5 ("Apple" in the subtitle) and 5.1.1(iv) (a skippable pre-permission screen); build 15 fixed both. Reviewed on an iPad Air 11-inch (M3). |
| 1.3 | 2026-01-24 | CSV/JSON export app with QR data requests. |
