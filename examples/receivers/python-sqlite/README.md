# Python + SQLite reference receiver

The smallest useful backend for the PulsHealth app: one file, the Python
standard library, a SQLite database. It exists to prove that
[`docs/protocol/`](../../../docs/protocol/README.md) is implementable in an
afternoon and to be something you can copy and grow. It stores everything
the app sends; it has no dashboards, no TLS, and no read endpoints beyond
`/v1/capabilities`.

## Run it

Python 3.11 or newer, nothing to install.

```bash
cd examples/receivers/python-sqlite
PULS_TOKEN="$(openssl rand -hex 32)" python3 receiver.py
# puls-sqlite-receiver listening on 127.0.0.1:8080
```

| Variable | Default | Meaning |
|---|---|---|
| `PULS_TOKEN` | (required) | The bearer token the app must send. |
| `PULS_DB` | `puls.sqlite` | SQLite file; created with its schema on first start. |
| `PULS_BIND` | `127.0.0.1` | Listen address. Loopback by default, like the reference stack's `INGEST_BIND_ADDR`. Set `0.0.0.0` deliberately to accept a phone on your LAN — there is no TLS here and no throttling of failed authentications. |
| `PULS_PORT` | `8080` | Listen port. |

Check it is up:

```bash
curl -s localhost:8080/healthz
curl -s -H "Authorization: Bearer $PULS_TOKEN" localhost:8080/v1/capabilities
# {"protocolVersions": [1], "features": ["batches", "profile"], "server": "puls-sqlite-receiver", "version": "1"}
```

## Point the app at it

The receiver speaks plain HTTP, which the app allows for hosts on the local
network (private addresses and `.local` names); anything reachable only over
the internet needs HTTPS in front of it. On a phone on the same Wi-Fi:

1. Start the receiver with `PULS_BIND=0.0.0.0` and find the machine's LAN
   address (`ipconfig getifaddr en0` on macOS, `hostname -I` on Linux).
2. In PulsHealth, **Sync → Set Up** (later, **Sync → Database**): Database
   URL `http://192.168.1.23:8080` (your address), Token the `PULS_TOKEN`
   value. Tap **Test Connection**; it calls `/v1/capabilities` and should
   report a receiver speaking protocol 1. Then **Save & Apply**.
3. **Sync → Synced Data**: pick what to sync, tap Apply. Batches start
   arriving within seconds; the receiver logs one line per request.

Because the receiver advertises only `batches` and `profile`, the app hides
a type's database row counts and its **Reconcile with Database** action (they
need `stats`, `digest` and `uuids`). Aggregate buckets, activity summaries,
routes and series are stored anyway; the feature list says what a receiver
*guarantees*, and this one keeps the claim modest.

## What it stores

| Table | Key | Content |
|---|---|---|
| `samples` | `uuid` | one row per HealthKit sample: type, kind, start/end, value, unit, category, source, device, and the complete JSON line in `line` for anything not broken out |
| `deletions` | `uuid` | tombstones applied |
| `route_points` | `(workout_uuid, t_ms)` | GPS fixes |
| `series_points` | `(workout_uuid, type, t_ms)` | intra-workout curves |
| `aggregates` | `(user, type, func, interval, unit, device_filter, bucket_start_ms)` | statistics buckets, upserted; `value` NULL when the bucket is empty |
| `activity_summaries` | `(user, date)` | one row per local day, upserted |
| `users` | `id` | profile snapshot per `X-User-ID` |
| `batches` | `batch_id` | one row per accepted batch; a replayed batch ID is a no-op |

Every row carries `user_id`. Timestamps are stored as epoch milliseconds, as
they arrive. A query to get started:

```sql
SELECT date(start_ms / 1000, 'unixepoch') AS day, round(avg(value), 1) AS bpm
FROM samples WHERE type = 'HKQuantityTypeIdentifierHeartRate'
GROUP BY day ORDER BY day DESC LIMIT 14;
```

## Behaviour the spec requires

- Any 2xx is an acknowledgement; the receiver commits the whole batch in one
  transaction before answering `200` with the reference count body.
- Samples are insert-if-absent on UUID; deletions are no-ops for unknown
  UUIDs and take a workout's points along; aggregates and activity
  summaries upsert with explicit nulls clearing values; the profile line
  replaces the snapshot.
- Malformed input is a `400` with `{"error": "..."}` and is never retried by
  the app; a wrong token is `401`; an unsupported `X-Puls-Protocol` or
  `schemaVersion` gets the fixed
  `{"error":"unsupported protocol version","supportedVersions":[1]}` body.
- Storage failures are `500`, which the app retries with backoff.

Concurrency is a lock around the single SQLite connection; uploads from one
phone serialise, which is fine for a personal server.

## Smoke test

`smoke_test.py` posts every fixture from `docs/protocol/fixtures` in order,
checks the returned counts against the `.expected.json` files, replays each
batch (must be a 2xx no-op), and checks the negative cases (wrong token,
unsupported version, garbage, count mismatch, unknown line type, bad user
ID, bad gzip). With no arguments it starts `receiver.py` itself on a free
loopback port with a throwaway database:

```bash
python3 smoke_test.py
```

Against any other receiver (an empty store, since the expected counts depend
on order):

```bash
python3 smoke_test.py --url https://health.example.net --token "$PULS_TOKEN"
```

A receiver that returns no count body passes the status checks with a note;
one that returns counts must match the reference server's numbers.
