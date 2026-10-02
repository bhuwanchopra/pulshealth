# App Review notes

Two things live here: the text to paste into **App Store Connect → App Review
Information → Notes** (limit 4000 characters), and the background a maintainer
needs to answer follow-up questions without inventing anything.

## Before you submit

Fill in the four placeholders below with the values from the throwaway review
backend ([`review-backend.md`](review-backend.md)). Stand that up first: the
notes walk the reviewer through a sync. (The first run and the export path in
WITHOUT A DATABASE need no database.) The placeholder names say "server"; the
app and the notes say "database" — same thing.

| Placeholder | What it is |
|---|---|
| `<<<REVIEW_SERVER_URL>>>` | The HTTPS URL of the review instance, e.g. `https://review.example.net`. Must be HTTPS and reachable from anywhere. |
| `<<<REVIEW_TOKEN>>>` | Its `PULS_TOKEN`. Never reuse it after review: it ends up in Apple's notes. |
| `<<<REVIEW_USER_ID>>>` | The user UUID, `5ea4d000-0000-4000-8000-000000000001` unless you changed it. |
| `<<<REVIEW_EXPIRY>>>` | The date you intend to take the instance down. Keep it up until the app is approved. |

The field's limit is 4,000 characters. The block below is 3,797 with the
placeholders and about 3,860 filled in — about 3,920 if each of its 55 line
breaks counts as two, which is the reading to budget for. Any addition needs a
matching cut; measure the filled copy before pasting.

Do not paste a QR image into the notes — the reviewer cannot scan a picture on
the same screen they are reading. The typed path below is the one they will
use; the QR scanner is offered for completeness.

---

## Paste into the Review Notes field

```
WHAT THIS APP IS

PulsHealth copies the user's Apple Health data to a database that the USER runs. There is no developer-operated backend. The app uploads only to the address the user enters. No health data reaches the developer.

Syncing needs a database, so we stood up a throwaway one for this review. It holds no real person's data. The app also works with no database at all (WITHOUT A DATABASE, below).

REVIEW DATABASE

  Database URL: <<<REVIEW_SERVER_URL>>>
  Token:        <<<REVIEW_TOKEN>>>
  User ID:      <<<REVIEW_USER_ID>>>

Up until at least <<<REVIEW_EXPIRY>>>. If it is unreachable, please contact us before rejecting; we will bring it back the same day.

HOW TO EXERCISE THE APP (about 5 minutes)

1. Launch the app. A four-page introduction starts; swipe left to turn pages.
2. On page 2, tap "Continue" (a swipe left does the same). iOS shows its permission sheet: tap "Turn On All", then "Allow" (iOS 27: "Select All", "Continue", then "All Recorded Data and Future Data", "Allow"). The app requests READ access only. Page 3 follows.
3. Swipe to page 4 and tap "Start Exploring". The Explore tab appears.
4. Open the Sync tab and tap "Set Up". On the Database screen, type the Database URL and Token above into their fields. (Scanning needs a physical QR code.) iOS may offer to save the token; either answer is fine.
5. Tap "Test Connection". It should report success. Then "Save & Apply". The Sync tab shows the database and the upload begins.

WHAT YOU SHOULD SEE

- The Sync tab's "Samples sent" counter rises if the device has Health data. A new device may have none; that is expected.
- On an empty device: in Apple Health, search for Weight, open it, tap + (Add Data), enter a value and save. Back in PulsHealth, pull down on the Sync tab: the counter rises within seconds.
- Sync > Activity shows every upload.

WITHOUT A DATABASE

The Export tab writes the selected Health data to CSV or JSONL files on the device; "Share or Save to Files" opens the iOS share sheet. No network request is made. From a fresh install: do steps 1-3 above and open Export. The files are deleted once shared, and at every launch.

WHY WE DECLARE NSAllowsLocalNetworking

The user's database often runs on their own network, where a public TLS certificate is impractical. The exception permits plain HTTP to local-network hosts ONLY, and the app enforces the same rule itself: http:// is accepted only for localhost, *.local, an unqualified hostname or a private IP range. We do not set NSAllowsArbitraryLoads. The review database is HTTPS.

HEALTHKIT (Guideline 5.1.3)

- Read-only. The app never calls a HealthKit write API.
- Health data is not used for advertising, marketing or data mining, and is not shared with any third party. It leaves the app only as uploads to the user's database, or as export files the user sends through the share sheet.
- Never written to iCloud. The app keeps none, except an export the user asked for, in its temporary directory (never backed up) until shared.

CAMERA

Used only to read the pairing QR code. No frame is stored or sent. Declining is handled: the same screen offers "Type It Instead".

URL SCHEME (puls://)

One custom scheme, for pairing links (puls://pair?...) — the text a database's pairing QR code encodes, so the iOS Camera app can open it. Any page or app can fire such a URL, so a link configures nothing by itself: the app shows a confirmation naming the host, and accepting only fills in the fields on Sync > Database — the user still has to tap Save & Apply.

BACKGROUND MODES

"processing" plus HealthKit background delivery, so new samples upload without opening the app. There are no accounts, so no demo account.

Source (Apache-2.0): https://github.com/PulsHealth/pulshealth
Privacy policy: https://pulshealth.com/privacy
```

---

## Background for follow-up questions

### "Why does the app need an external database at all?"

It does not, for a one-off: the Export tab writes the selected Health
data to CSV or JSONL files on the device and hands them to the share sheet,
with no database and no network request, and the Explore tab shows what Apple
Health holds without either. The database is for the thing a file
cannot do — *continuous* sync into a database the user controls, so they can
query it with SQL, chart it in Grafana, or feed it to their own tools as new
data arrives. This is the same shape as other HealthKit exporters on the store;
the difference is that the destination is the user's own machine rather than a
vendor's cloud, which is the feature, not a limitation.

### "Is the app usable without a database?"

Yes, since 1.5 added the on-device export, and since 1.6 the first-run
flow does not ask for a database at all. Its four pages are "Unlock your
Health Data" (Explore, Export, Sync), Health access, one-time exports ("No
account and no database needed"), and syncing to your own database, which
says it can be set up any time from the Sync tab and links to
pulshealth.com/docs/server/ in Safari. The Sync tab of an install with no
database carries a setup card ("Keep a copy in your own database", with a Set
Up button that opens the Database screen) instead of looking broken. The App
Store description says the same.

What such an install does *not* do is anything in the background: exports run
only when the user taps Export, in the foreground.

### "Where do exported files go, and what is in them?"

Into the app's temporary directory (never backed up), then to the iOS share
sheet. The app deletes its copy when the share sheet reports completion, on
Delete Export, when another export starts, and at every launch. The files hold
the selected health data plus a manifest with the user ID, the app's random
device ID, the time zone and row counts — no token, no database URL, and none of
the name/e-mail/date-of-birth fields from Settings → User. The share sheet's
Copy action is excluded. `docs/privacy-policy.md` § Exports is the public
statement of all this.

### "The permission sheet asked how much data to share"

That is iOS 27's second page. *Past 30 Days and Future Data* works too: the app
then reads, syncs and exports only from 30 days back, says so on the Sync tab,
an analysis and an export result, never treats the older history as deleted
or empty in the database, and reads the rest by itself if access is widened
later under Settings → Privacy & Security → Health → PulsHealth. *Don't Allow*
on that page is taken as the user's answer: no error, nothing read. The notes
ask for All Recorded Data only so the reviewer sees a whole history arrive.

### "Does the app read the clipboard?"

Only when the user taps Paste Pairing Code, which is the system paste button
(`PasteButton`): iOS shows no paste prompt, and nothing is read otherwise.

### "Prove the local-network exception is narrow"

`PulsHealthSync/Sources/PulsHealthSync/Transport/ServerURLValidation.swift` is
the whole rule, and
`PulsHealthSync/Tests/PulsHealthSyncTests/` covers it, including the case where
a scanned pairing code carries plain HTTP to a public host — it is rejected
rather than saved. `Info.plist` sets only `NSAllowsLocalNetworking`;
`NSAllowsArbitraryLoads` is absent.

### "What about the health data you can read — ECG, State of Mind, medications?"

They are in the catalogue and are off unless the user turns them on, exactly
like every other type. Enabling one triggers the iOS permission sheet for it.
The app does not interpret any of them; it copies them.

### If review asks for a video

Record the five steps above on a device with a little Health data in it. Show
the Test Connection success row and the Sync tab's counter moving, then the
Export tab through to the share sheet. Do not use a
real person's health history.

### After approval

Take the review instance down ([`review-backend.md`](review-backend.md) § 6).
