# Bulk export

`GET /v1/export` on the product API returns a whole range of one dataset as a
**file** — CSV for a spreadsheet, JSONL for a notebook or a chat attachment —
instead of the JSON document the other endpoints return. It streams: the rows
go out as they are read, so an export of a busy type is bounded by the disk it
lands on rather than by the server's memory.

`tools/puls-export` is a small client for it. Everything below works equally
with `curl`.

```bash
# a year of sleep, as a spreadsheet
puls-export --dataset sleep --start 2026-01-01 --end 2027-01-01 -o sleep.csv

# a week of raw heart rate, one JSON object per line
puls-export --dataset samples --type HKQuantityTypeIdentifierHeartRate \
  --format jsonl --start 2026-01-01 --end 2026-01-08 > heart-rate.jsonl

# the same thing with curl; -OJ takes the filename from the response
curl -fL -H "Authorization: Bearer $PULS_API_TOKEN" -OJ \
  "$PULS_API_URL/v1/export?format=csv&dataset=sleep&start=1767225600000&end=1798761600000"
```

## Parameters

| Parameter | Required | Meaning |
|---|---|---|
| `format` | yes | `csv` or `jsonl` |
| `dataset` | yes | one of the six below |
| `start`, `end` | yes | epoch milliseconds, `[start, end)` |
| `types` | `daily_metrics` only | comma-separated HealthKit identifiers |
| `type` | `samples` only | exactly one HealthKit identifier |
| `activityType` | `workouts` only | keep one activity type |
| `user` | no | the user to export, a UUID (see *Whose data* below) |

`limit` and `offset` do not apply: an export is bounded by its range, not by a
page size, and `workouts` returns the whole range rather than one page.

**Whose data.** Every export is one user's. Without `user` it is the server's
default (`PULS_USER_ID`), as every other endpoint. `user=<uuid>` asks for
someone else — `GET /v1/users` lists who exists — and the server allows that
only with `PULS_MULTI_USER=true`; otherwise it answers `403
{"error": "multi-user reads are disabled"}` rather than quietly exporting the
default user's data under another name. A value that is not a UUID is a
`400`. Neither refusal counts against the failed-authentication limit.

**Range caps.** `samples` keeps the **31 days** `/v1/samples` enforces — a
busy type runs to hundreds of thousands of rows a month. Every other dataset
is capped at **366 days**, like `/v1/sleep/daily` and `/v1/state-of-mind`.
That is stricter than `/v1/metrics/daily` and `/v1/workouts`, which page
instead (and `/v1/activity/summary`, one small row per day): a file is
bounded only by its range, so it needs a cap. The cap measures the instant span; the day-grained datasets also
reject a range that touches more than 366 local calendar days, with their own
message. Either way it is a `400` naming the limit, before the first byte of
the file, in the JSON endpoints' shape:
`{"error": "range must not exceed 31 days"}`.

**At most two exports run at once.** Each holds a database connection for the
length of the download, and the pool is small, so a third request is refused
immediately with a `503` and a `Retry-After` header rather than queued behind
them — waiting would tie up the connection the limit exists to protect.

## Datasets and their columns

The CSV header row and the JSONL object keys are the same list, in the same
order, so the two formats can never describe different rows. Field names are
the JSON endpoints' names; where an endpoint nests, the export flattens — the
identifying fields repeat on every row, and a nested field is named by its
path.

| `dataset` | From | Columns |
|---|---|---|
| `daily_metrics` | `/v1/metrics/daily` | `identifier`, `unit`, `date`, `value` |
| `samples` | `/v1/samples` | `type`, `unit`, `uuid`, `start`, `end`, `value`, `label`, `source` |
| `workouts` | `/v1/workouts` | `uuid`, `activityType`, `start`, `end`, `durationS`, `distanceM`, `energyKcal`, `hasRoute`, `availableMetrics` |
| `sleep` | `/v1/sleep/daily` | `date`, `start`, `end`, `inBedMinutes`, `asleepMinutes`, `stages.core`, `stages.deep`, `stages.rem`, `stages.unspecified`, `stages.awake`, `sources` |
| `activity` | `/v1/activity/summary` | `date`, `moveKcal`, `moveGoalKcal`, `exerciseMin`, `exerciseGoalMin`, `standHours`, `standGoalHours`, `moveMode`, `moveTimeMin`, `moveTimeGoalMin` |
| `state_of_mind` | `/v1/state-of-mind` | `uuid`, `date`, `timestamp`, `kind`, `valence`, `valenceClassification`, `labels`, `associations` |

Values follow the same rules as the JSON endpoints — epoch milliseconds for
instants, `YYYY-MM-DD` local calendar days (in the server's `PULS_TIME_ZONE`)
for days, canonical units — with two format-specific conventions:

- **A null is an empty CSV cell** and an explicit `null` in JSONL, never a
  zero and never a missing key. Every line of a dataset has the same shape.
- **A list** (`availableMetrics`, `labels`, `associations`) is comma-joined
  inside its quoted CSV cell and stays a JSON array in JSONL.

`samples` is *not* deduplicated across devices, exactly like `/v1/samples`: if
an iPhone and an Apple Watch recorded the same minutes, both rows are there.
Use `daily_metrics` for totals.

One thing to know before double-clicking a CSV: cells are written verbatim, so
a value that begins with `=`, `+`, `-` or `@` is a formula to a spreadsheet.
Every column here is a number, a date, a UUID or a HealthKit identifier except
`source`, which is the display name of whatever app wrote the sample. Import
the file as text — or use JSONL — if you do not trust every app that has ever
written to your Health store.

## How it streams

The response carries no `Content-Length`, so it is framed
`Transfer-Encoding: chunked` and the file starts arriving before the query has
finished. The first push happens before any row is read — it carries the CSV
header row, or for JSONL just the response head — and rows follow in flush
windows. Nothing is buffered to the length of the export, on either side:
`puls-export` copies the body straight through to the file.

A failure once the body is on the wire **aborts the connection** rather than
closing a short file cleanly, so a truncated export is always a visibly failed
download (`curl: (18) transfer closed`, `puls-export: the download stopped
early`) and never a file that quietly stops halfway. Everything that can be
rejected — an unknown `dataset` or `format`, a missing filter, an identifier
that has never been synced, a range over the cap — is checked *before* the
first byte, and comes back as the usual JSON `400`.

The response is an attachment named
`puls-<dataset>-<start>-<end>.<csv|jsonl>`.

## The `puls-export` CLI

```bash
go install github.com/PulsHealth/pulshealth/tools/puls-export@latest
# or, from a checkout — it is its own Go module, so build it from its own
# directory; there is no module at the repository root
cd tools/puls-export && go build -o puls-export .
```

It is a thin client: it builds the query, sends the bearer token, and copies
the response through. Everything the server can reject is left to the server
and its message is printed verbatim, so the binary cannot drift out of step
with the endpoint.

| Flag | Default | |
|---|---|---|
| `--url` | `$PULS_API_URL`, else `http://127.0.0.1:8081` | product API base URL |
| `--token` | `$PULS_API_TOKEN` | bearer token, from `server/.env` |
| `--dataset` | — | required |
| `--format` | `csv` | `csv` or `jsonl` |
| `--start`, `--end` | — | `YYYY-MM-DD` or epoch milliseconds; the range is half-open |
| `--types`, `--type`, `--activity-type` | — | the per-dataset filters above |
| `--time-zone` | `$PULS_TIME_ZONE`, else UTC | the zone a `YYYY-MM-DD` bound is read in |
| `--user` | `$PULS_USER_ID`, else none | the user to export; none leaves it to the server's default |
| `-o` | standard output | write to this file |
| `--version` | | print the version and exit |

`--start 2026-01-01 --end 2026-02-01` is the whole of January. Exit status is
`0` on success, `2` for a mistake in the command line, `1` for a failed
download; the output file named by `-o` is created only once the server has
answered `200`, so a rejected request never truncates the previous export.
A `403` is explained the way a `401` is: the server only exports its
`PULS_USER_ID` unless it runs with `PULS_MULTI_USER=true`.

## On-device export (no server)

Everything above needs a server the phone has synced to. The app can also
write files **straight from HealthKit**, with no server involved:
`HealthExporter` in the `PulsHealthSync` package
([`PulsHealthSync/README.md`](../PulsHealthSync/README.md), "On-device export")
runs the ordinary sync sweep — the same queries, the same canonical-unit
conversion, the same aggregate math — against a throwaway engine whose
transport appends to files instead of POSTing. The files are staged in the
app's temporary directory for the share sheet.

**In the app it is the Export tab**, a builder. Pick the data types, add any
aggregate series (hourly, daily, weekly or monthly values for a quantity
type), a time range (last 30 days, 90 days, a year, all time, or your own
start and end date), CSV or JSONL, and whether to zip it. The draft starts
from the selection applied under Sync → Synced Data — the same types,
aggregate series and workout route/stream switches. What you change in it is
this export's alone, never the sync's, and the sync start date in Settings
plays no part.

An end date is exclusive: samples that start before it, activity-ring days
before its local day, and routes and streams of workouts that started before
it. An aggregate bucket that straddles the end date is left out rather than
written as a partial value, so a daily series ends on the last whole day
before it.

When it finishes, **Share or Save to Files** opens the iOS share sheet with
every file of the export, manifest included. With **Zip into one file** on,
it shares one `puls-export-<yyyyMMdd-HHmmss>.zip` holding a folder of that
name with the same files, unchanged. iOS's own archiver (`NSFileCoordinator`)
builds the zip after the files are written, so the manifest's byte counts are
the uncompressed sizes. The app deletes its staged copy once the share sheet
reports the files were handed over, when you tap Delete Export, when you
start another export, and at every launch — so save the files somewhere
before moving on.

Keep the app open and the phone unlocked while it runs: HealthKit cannot be
read on a locked phone, and an export that runs into a lock finishes
**incomplete** and says which types it could not read. For scale: 340,000
samples came to 41 MB as CSV and 212 MB as JSONL (the wire format carries
each sample's time-zone context and source), written in 5–7 seconds on a
simulator. A phone is slower, and years of Apple Watch heart rate run to
millions of samples.

It offers the same two formats, and they are not symmetrical:

**JSONL is the complete one, and it is replayable.** The file
(`puls-export-<yyyyMMdd-HHmmss>.jsonl`) is a concatenation of
[Puls Sync Protocol](protocol/README.md) batches exactly as they would have
gone over the wire, uncompressed: each batch's header line, then its sample,
deletion, route, series, aggregate and activity-summary lines. Nothing about it
is export-specific — it is the format `docs/protocol/schema/` specifies and the
fixture corpus tests — so every field of every kind is there, and a file can be
fed to a server later: split it before each header line (the only lines whose
top-level object has a `batchID`), gzip each piece if you like, and `POST` it to
`/v1/batches` with the bearer token and `X-User-ID`. Ingest is idempotent, so
replaying into a server that already holds some of it is safe. Three things to
know:

- The user is an HTTP header on the wire, not part of the body, so the JSONL
  does not say whose data it is. The manifest (below) does.
- There is no `{"profile":…}` line. The name, e-mail, date of birth and sex on
  that line are the app's settings rather than HealthKit data, and an export
  leaves them out of a file that is about to be shared.
- Deletion lines are kept. HealthKit can return the tombstones it still holds
  even to a first query, and a replay should apply them.

[`tools/protocol-check`](../tools/protocol-check) validates one batch per file,
so split an export the same way before checking it.

**CSV is a flattened view**, one file per dataset that has rows
(`puls-export-<yyyyMMdd-HHmmss>-<dataset>.csv`; a dataset with no rows gets no
file). Where a dataset also exists on the server the file is the same file:
same header row, same order, epoch-millisecond instants, `YYYY-MM-DD` local
days, canonical units, a null as an empty cell, a list comma-joined inside its
quoted cell, lowercase UUIDs, floats without an exponent — and the same
spreadsheet-formula caveat, because cells are written verbatim here too.

| `dataset` | On the server too? | Columns |
|---|---|---|
| `samples` | yes | `type`, `unit`, `uuid`, `start`, `end`, `value`, `label`, `source` |
| `workouts` | yes | `uuid`, `activityType`, `start`, `end`, `durationS`, `distanceM`, `energyKcal`, `hasRoute`, `availableMetrics` |
| `activity` | yes | `date`, `moveKcal`, `moveGoalKcal`, `exerciseMin`, `exerciseGoalMin`, `standHours`, `standGoalHours`, `moveMode`, `moveTimeMin`, `moveTimeGoalMin` |
| `state_of_mind` | yes | `uuid`, `date`, `timestamp`, `kind`, `valence`, `valenceClassification`, `labels`, `associations` |
| `aggregates` | no — device only | `type`, `func`, `intervalValue`, `intervalUnit`, `deviceFilter`, `bucketStart`, `bucketEnd`, `value`, `unit` |
| `workout_routes` | no — device only | `workoutUUID`, `t`, `lat`, `lon`, `alt`, `hAcc`, `vAcc`, `speed`, `course` |
| `workout_series` | no — device only | `workoutUUID`, `type`, `unit`, `t`, `value` |
| `medication_doses` | no — device only | `uuid`, `start`, `end`, `medication`, `status`, `scheduledAt`, `doseQuantity`, `doseUnit`, `source` |

The device-only files use the wire format's own keys, in wire order, one row
per bucket, GPS fix, stream datapoint or dose. How the two sides differ:

- **`samples` holds every selected quantity and category type in one file**,
  where the server exports one type per request. `label` — the server's name
  for a category value, joined from its `category_labels` table — is always
  empty: the app has no such table, and the column is kept so the header
  matches. A category sample's `value` is HealthKit's raw integer on both sides.
- **`daily_metrics` and `sleep` do not exist on the device.** Both are views the
  server computes over what it has stored (per-day totals deduplicated across
  devices; nights assembled from sleep-stage samples). The device's counterpart
  to `daily_metrics` is `aggregates`, the statistics HealthKit itself computes
  for whatever aggregate series are configured; sleep stages are rows of
  `samples`.
- **Local days are the phone's.** `activity.date` and `state_of_mind.date` are
  computed in the phone's time zone, which is what the server's
  `PULS_TIME_ZONE` is required to match anyway.
- **What CSV leaves out.** Metadata, device, source bundle and version, the
  per-sample time-zone context, and a workout's statistics, events and
  sub-activities have no column. ECG voltage traces, beat-to-beat heartbeat
  series and deletion tombstones have no file at all; the result the package
  returns counts them so the app can say so and suggest JSONL.

Both formats come with `puls-export-<yyyyMMdd-HHmmss>-manifest.json`: the user
ID, the device ID, the requested range (`startDate`, `null` = all time;
`endDate`, `null` = now), the format, the protocol `schemaVersion` and the app
version, the time zone local days were computed in, the exported `types` and
`aggregates` (each series as `type|func|intervalValue|intervalUnit|deviceFilter`),
and per-file and per-dataset row counts. Its main job is `"complete": false`
with a `failures` list whenever a selected type could not be read to the end
(access never granted for it, the phone locked part-way through) or a sample
could not be converted to its canonical unit. A file that stops short looks
exactly like the file of someone with less data; the manifest tells them
apart.

On iOS 27, Health access can be limited to recent history (the permission
sheet's "Past 30 Days and Future Data", or Limited Access under Settings →
Privacy & Security → Health). HealthKit then reads a type only from an
earliest date on, and `limitedHistory` maps each type whose date falls after
the export's start to that date (epoch milliseconds). The files hold nothing
of those types before it, so that export is incomplete too; choose Full
Access and export again to get the rest.

One caveat for replaying **aggregate** lines. Bucket boundaries are counted
from the start of the series, so an export aligns each series to the grid the
app's own sync uses, and a replay overwrites the server's buckets rather than
adding a second, offset set. That alignment is exact for day, week and month
buckets and for hour or minute intervals that divide a day evenly. It can be
off for intervals that do not (5 hours, 7 minutes) and for a month series that
starts on the 29th–31st; replay those with the aggregate lines filtered out and
let the phone's next sync recompute them.

## See also

- The endpoint reference on the running server: `GET /docs`, and the
  machine-readable [`/openapi.json`](../server/api/docs.go).
- [`docs/database-guide.md`](database-guide.md) — what the columns mean and
  which trap each dataset avoids.
- [`docs/ai.md`](ai.md) — the same data through an MCP client or a ChatGPT
  Action.
