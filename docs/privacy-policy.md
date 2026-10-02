# PulsHealth privacy policy

**Last updated: 2026-10-02**

PulsHealth is an iOS app that copies the health data on your iPhone to a
database **you** run, or — if you have no database — writes it to files you
then save or send yourself. This policy describes what the app does with your data.
It is short because the app does very little: it reads Apple Health, it uploads
to the one address you type in, it exports a file when you ask for one, and
that is the whole of it.

## The short version

- **The developer of PulsHealth receives no data from you** — unless they have
  invited you to use their own database, which is then the one you enter in
  the app (see [If the developer invited you](#if-the-developer-invited-you)).
  There is no account to sign up for, no telemetry endpoint, and no
  developer server built into the app: it talks to the database address you
  enter and to nothing else.
- **Your health data leaves the phone in two ways, and both are yours.** The
  app uploads only to the database URL you enter in it — typed, or taken from
  your database's pairing code (scanned, pasted, or opened as a link you
  confirm) — and it has no other network destination compiled into it. And when
  you ask for an export, it writes files and hands them to the iOS share sheet;
  where they go from there is the choice you make in that sheet. An export
  involves no network request by the app at all.
- **No analytics, no advertising, no tracking, no third-party SDKs.** The app
  and its `PulsHealthSync` library have zero third-party dependencies. Nothing
  profiles you, and no identifier is shared with anyone.
- **HealthKit access is read-only.** PulsHealth asks Apple Health for read
  permission and never writes, edits, or deletes anything in Apple Health.
- **You choose what is read.** Nothing is read until you pick the data types
  and iOS grants permission, and you can change or revoke that at any time.

## What the app reads

Only the Apple Health data types you enable in the app, and only for the date
range you set. Depending on your selection this can include quantities (steps,
heart rate, energy, weight, blood oxygen, …), categories (sleep, mindfulness,
symptoms, …), workouts together with their GPS routes and per-second sensor
series, and daily activity-ring summaries. Some of the types you may enable are
particularly sensitive — ECG, State of Mind, medication dose events, and
workout GPS routes among them. None of these is read unless you turn it on and
iOS grants permission for it. The full catalogue is visible in the app's Data
Types screen and in [`docs/protocol/catalog.json`](protocol/catalog.json).

If you fill them in, the app also sends the identity fields you typed into it —
name, email address, date of birth, biological sex — to your own database, so
your data is stored under a person rather than an anonymous row and so
heart-rate zones can be computed. Every one of those fields starts unset. You
type them into Settings → User; the app never reads them from Apple Health or
anywhere else, and leaving them blank is fully supported.

Each upload also carries a `deviceID` so your database can tell one phone from
another. It is a random UUID the app generates for itself on first run — not
the advertising identifier, not `identifierForVendor`, not tied to you or to
the hardware — and it goes only to your database, and into the files of an
export you make yourself.

## Where it goes

To the database URL you configure — the address of the PulsHealth backend you
run, or of a receiver you built from the protocol — over HTTPS, authenticated
with a bearer token you also configure. That is the only network destination. (An export is not a
network destination: see [Exports](#exports) below.)

Plain `http://` is permitted **only** for hosts on your local network
(`localhost`, `*.local`, and the private IP ranges `10.x`, `172.16–31.x`,
`192.168.x`), because a self-hosted database commonly lives on a home network
where a public TLS certificate is awkward. Every other address must be `https://`;
the app refuses to save or use a plain-HTTP address for any host outside those
ranges. This is enforced both by the app's own validation and by iOS App
Transport Security (`NSAllowsLocalNetworking`).

## What stays on the device

- **The bearer token** is stored in the iOS **Keychain**
  (`kSecClassGenericPassword`, accessibility
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable after the first
  unlock following a restart so background syncs can run, and bound to this
  device so it is never restored onto another one from a backup). It is
  scrubbed out of logged error messages and anything the app exports.
  **One exception, and only when the Keychain refuses a write:** rather than
  lose the token — which would stall every sync until you typed it in again —
  the app keeps it in its own state file until the Keychain accepts it, then
  removes it. That file carries the same protection as the rest of the app's
  data: unreadable until the first unlock after a restart, and excluded from
  device and iCloud backups, so a parked token is never carried off the phone.
- **Sync state** — one file, `sync-state.json`, in the app's private container,
  holding your configuration (database URL, chosen types, start date, and the
  identity fields if you filled them in), the opaque HealthKit query anchors,
  per-type counters, and progress watermarks. It is written atomically with
  iOS file protection and is excluded from device backups. It holds **no health
  samples** — a sync streams those to your database and keeps none of them in
  the app. The one time health samples rest in the app's storage is an export you
  asked for, briefly, as described under [Exports](#exports); the analysis
  summaries below are derived numbers, not samples.
- **Analysis summaries** — when you analyze a data type on the Explore tab,
  the app reads the past year of that type from Apple Health and keeps a
  *summary* of it, one
  small file per type (`profiles/<type>.json` in the app's private container),
  so the next visit does not repeat a read that can take minutes: how many
  samples there are, the first and last dates, how many fall on each day, the
  spread of values (minimum, maximum, average, a few percentiles and a
  histogram of at most a few dozen bins), the typical time between samples,
  and how many came from each source app or device, by name. It never holds
  an individual sample, a timestamp paired with a value, a sample identifier
  or any metadata. These files carry the same protection as the sync state
  (unreadable until the first unlock after a restart, excluded from backups),
  are rewritten when the type's data changes, and Settings → Privacy & Data →
  Delete Analysis removes all of them at once.
- **Logs and background-activity telemetry** — an in-app event log and a record
  of each background wake (when it ran, how long, how many samples moved). They
  stay on the device unless *you* share them from the Background Activity
  screen, which writes them to the app's temporary directory for the share
  sheet. They hold counts and timings, not health values.
- **App preferences** — four `UserDefaults` flags (whether Health access has
  been requested, whether medication access has been requested, whether the
  first-run flow has been completed, and the background-task schedule status).
  No personal data.

Deleting the app deletes all of this from the phone, a staged export included.
It does not delete anything already uploaded to your database, or any exported
file you saved or sent somewhere else — those are yours to manage.

## Exports

The Export tab writes the data types and series you choose for it, for the
time range you pick, to files on the phone: CSV, or JSONL (the same format the app
uploads), zipped into one file if you ask for that. It works with no database
configured and makes no network request. It
runs only when you tap Export; nothing exports on a schedule or in the
background.

- **Where the files are.** In the app's temporary directory, which iOS never
  includes in a device or iCloud backup. They carry iOS file protection
  (unreadable until the first unlock after a restart) and no other encryption.
- **How long they stay.** Until you have shared them: the app deletes its copy
  when the share sheet reports that the files were handed over. It also deletes
  it when you tap Delete Export, when you start another export, and every time
  the app launches — so an export you never shared, or one interrupted by a
  crash, does not outlive the next launch. A cancelled or failed export keeps
  nothing.
- **What is in them.** The health data you selected, as Apple Health holds it —
  which includes the name of the app or device that recorded each sample (for
  example the name you gave your Apple Watch). A manifest file beside the data
  records your user ID, the app's random `deviceID`, the phone's time zone, the
  app version, the time range and the row counts — and, when Health access is
  limited to recent history (iOS 27), the date each limited type could be read
  from; a JSONL export repeats the
  `deviceID` and app version at the head of each batch, as an upload does. The files do **not** contain the bearer token,
  the database URL, or the name, email address, date of birth or sex from
  Settings → User.
- **Where they go.** Wherever you send them from the share sheet — Files,
  AirDrop, another app. The app's Copy action is turned off for exports, so the
  files are not placed on the clipboard. Once a file has left the app it is an
  ordinary, unencrypted file: it is only as private as the place you put it,
  the app can no longer delete it, and the developer never sees it.

## Camera

The app can read a pairing QR code printed by your database's backend so you do
not have to type a URL, a token and a UUID by hand. That is the **only** use of the camera.
The camera runs only while the scanning screen is open, no photo or video frame
is recorded, stored, or transmitted, and nothing but the text of the scanned
code leaves the scanner. Declining camera access is fully supported: the same
screen offers to let you type the details instead, and the app works exactly the
same way. The same code also works without the camera: pasted with the system
Paste button (the app reads the clipboard only on that tap), or opened as a
`puls://` link, which the app asks you to confirm — naming the address it points
to — before it fills anything in.

## Health data and Apple's rules

PulsHealth does not use HealthKit data for advertising, marketing, or
data-mining purposes, and does not disclose HealthKit data to any third party.
It is not shared with, or sold to, anyone — there is nobody to share it with:
the only recipient of an upload is your own database, and an exported file goes
only where you send it.

## Children

PulsHealth is not directed at children. It collects nothing centrally, so there
is no children's data for the developer to hold.

## What you are responsible for as a self-hoster

Because you run the database, the parts of the system that would normally be a
provider's responsibility are yours:

- **Where your database runs and who can reach it.** Exposing the ingest endpoint
  to the internet, putting it behind a VPN, or keeping it on your LAN is your
  decision. The project's documentation binds every service to loopback by
  default.
- **TLS.** The app requires HTTPS for anything that is not a local-network
  host, but the certificate and the reverse proxy in front of the ingest
  endpoint are yours to provide.
- **The bearer token.** It is a single shared secret. Anyone who has it can
  upload and delete data in your database. Rotate it if it leaks.
- **Data at rest, backups, and deletion.** Your database holds identifiable
  health data. Encryption at rest, retention, and honouring your own deletion
  requests are yours to arrange. The project ships a backup service, but it is
  opt-in and off until you turn it on — until then the Postgres volume is the
  only copy.
- **Anyone else you let use your database.** If you host other people's data, you
  are the data controller for it, and any obligations that come with that are
  yours.
- **Anything you connect to the database.** Grafana, the web viewer, the MCP
  server for AI assistants, notebooks, and your own queries all read the same
  database. What you point at it, and what those tools do with the data, is
  outside the app's control.

## If the developer invited you

The developer runs one PulsHealth database of their own, with the web viewer
at `app.pulshealth.com`, for family and friends they invite. There is no
sign-up: an account exists only because the developer created an invite for
you. If you use it:

- **The app still works exactly as described above.** It uploads only to the
  database address you entered — in this case the developer's — and to
  nowhere else.
- **The developer holds your data.** Everything the app uploads (the health
  data you chose to sync, and the identity fields if you filled them in) is
  stored in the developer's database under your own user ID. The developer,
  as the person who runs that database, can access it. It is used for one
  thing: showing it back to you. It is not sold, shared or analysed, and no
  one else who uses the viewer can see it — the database itself limits each
  signed-in person to their own records.
- **Your viewer account.** Signing in to the viewer stores your email
  address, a one-way hash of your password (never the password), and, for
  each browser you sign in from, when it signed in and was last used, its
  browser and system name, and its IP address. The viewer sets one cookie,
  which keeps you signed in; it holds a random value and nothing else.
- **Cloudflare carries the viewer's traffic.** `app.pulshealth.com` is
  reached through Cloudflare, which terminates its TLS connection and so
  handles the pages you open, health data on them included, under
  [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/).
  If the developer has put Cloudflare Access in front of it, signing in there
  sends your email address to Cloudflare for a one-time code.
- **Maps.** A workout's route map is drawn by your browser fetching map tiles
  directly from the provider named on the map (Esri, OpenStreetMap or
  OpenTopoMap). Those requests carry no health data, but they do reveal to
  that provider which area the map shows, and the viewer's address.
- **Leaving.** Ask the developer, and they delete your viewer account and
  every row stored under your user ID; delete the app's database address (or
  the app) to stop uploading.

## The website

Everything above is about the app and, in the section just before this one,
the developer's own viewer. This section is about pulshealth.com,
which is a separate thing.

The site is a set of static files. It loads no analytics, sets no cookies,
and includes no tracking scripts or third-party embeds. No health data ever
passes through it: the app does not talk to it, and there is nothing to sign
in to on it. Its "Sign in" link leads to the developer's invite-only viewer
at `app.pulshealth.com`, a separate site described in the section above.

Two forms on the site — "Sign up for updates" and the consulting contact
form — send exactly what you type into them (a name, an email address, and
for the consulting form an optional organisation and a message) to a form
endpoint the maintainer runs on Amazon Web Services, tagged with which form it
came from. That is the only thing the site sends anywhere, and it happens only
when you press the button. The updates list is used for the occasional
project announcement and nothing else.

## Changes to this policy

This document is versioned in the project's public repository. Changes arrive
as commits, so the full history is visible at
<https://github.com/PulsHealth/pulshealth/commits/main/docs/privacy-policy.md>.

## Contact

- **Questions and general contact:** open an issue at
  <https://github.com/PulsHealth/pulshealth/issues>.
- **Security problems:** please use GitHub's private vulnerability reporting at
  <https://github.com/PulsHealth/pulshealth/security/advisories/new>, as
  described in [`SECURITY.md`](../SECURITY.md). Do not file a public issue for a
  security problem.
