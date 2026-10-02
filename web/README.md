# Puls Web

The self-hosted web viewer for the Puls health store, in the style of Apple
Health. Built with **Next.js (App Router) + TypeScript**, it reads directly
from the same **TimescaleDB** that Grafana uses and draws its own SVG charts:
activity rings, range-banded trend lines and bar series, with per-category
accent colors.

> **Local demo mode.** Outside production, an unset or unreachable `DATABASE_URL`
> serves generated demo data. Production never fabricates health data: database
> errors produce an explicit unavailable state and empty views.

## Quick start

```bash
cd web
npm install
cp .env.example .env        # optional — leave DATABASE_URL blank for local demo mode
npm run dev                 # http://localhost:3000
```

## Connecting to real data

Point `DATABASE_URL` at the Puls Postgres/TimescaleDB instance (the database is
`postgres`, same as Grafana — see `../server`). A read-only role is ideal.

```bash
# Local docker stack (../server): the database plus its schema
cd ../server && docker compose up -d migrate
# then in web/.env:
DATABASE_URL="postgres://postgres:YOUR_PASSWORD@localhost:5432/postgres?sslmode=disable"

# A remote stack whose Postgres port is bound to loopback: open an SSH tunnel
# and connect through it as the read-only `grafana` role.
ssh -N -L 15432:127.0.0.1:5432 <user>@<host>
DATABASE_URL="postgres://grafana:GRAFANA_DB_PASSWORD@127.0.0.1:15432/postgres?sslmode=disable"
```

Inside the compose stack the `web` service gets `DATABASE_URL` built from
`GRAFANA_DB_PASSWORD` automatically (see `../server/docker-compose.yml`).

`PULS_USER_ID` is the user shown until one is chosen (see "Choosing a user"
below); it defaults to the seeded app user. `PULS_TIME_ZONE` controls Today, greetings, chart buckets,
and day boundaries; it defaults to `UTC` and must match the server stack's
`PULS_TIME_ZONE` (the database exposes its own as `puls_time_zone()`; on a
mismatch the viewer logs a warning and stops using `metric_daily`). The status
dot shows **Live data** (green), **Demo data** (amber), or **Database unavailable**.

## Choosing a user

The database can hold more than one person's records — every phone that syncs
lands its rows under its own `user_id` — and the viewer shows one of them at a
time. Which one:

- **`PULS_USER_ID`** is the default: the user shown until one is chosen.
- **The sidebar's user switcher** appears when the database holds two or more
  users (a single-user install never sees it). Picking one posts to
  `/api/user`, which remembers the choice in a `puls-user` cookie for a year
  — a plain form, so it works without JavaScript — and sends you back to the
  page you were on. Users are listed by name, else e-mail, else the short form
  of their id; both fields stay empty until that phone's first profile sync.
- **`?user=<uuid>`** on any page picks a user the same way and then drops the
  parameter from the URL, so a bookmark or a link from Grafana can open one
  person directly. The id is the one Grafana's `user` variable shows (or
  `SELECT id, name FROM users`). Settings shows whose data is on screen.

**This is a preference, not access control.** Everyone behind the one
`WEB_AUTH_PASSWORD` can look at every user, and the cookie is nothing but the
chosen id (a forged value is at worst an id the database does not have, which
renders empty — with the switcher there to pick a real one). The viewer cannot
limit a person to their own records, so share the password only with people
who may see everything in the database.

## Access control

**`WEB_AUTH_PASSWORD` is a password prompt in front of the whole viewer.** Set
it and every route asks for HTTP Basic credentials; leave it empty and the
viewer has no login at all.

```bash
WEB_AUTH_PASSWORD="$(openssl rand -hex 12)"   # in server/.env
docker compose up -d web
```

`scripts/bootstrap.sh` generates one on a fresh install and prints it with the
pairing block (`make pairing` re-prints it). Details:

- **Any username is accepted** — there is one viewer and one secret, and a
  rejected username would only be a way to lock yourself out. Type anything.
- **`/api/healthz` stays open**, so container health checks and deploy probes
  keep working without credentials. Everything else, including static assets,
  `/api/user` and the `?user=` shortcut, goes through the check.
- The comparison is constant-time (both sides SHA-256'd, then compared
  branch-free), and nothing about a failed attempt is logged — the
  `Authorization` header holds the password, and a near-miss in a log file is
  still a password in a log file.
- The container says which mode it is in at startup:
  `docker compose logs web | grep puls-web`.
- **To turn it off**, empty the value in `.env` and `docker compose up -d web`.
- There is **no logout** (that is Basic auth); close the browser or use a
  private window.

The implementation is `proxy.ts` (Next.js 16's middleware convention) over the
pure helpers in `lib/auth.ts`, which `lib/auth.test.ts` covers.

**This is not a substitute for the bind address.** Basic auth sends the password
on every request, in the clear unless something terminates TLS in front. The
compose stack still binds the viewer to `WEB_BIND_ADDR` (default `127.0.0.1`);
to reach it from other machines, use a private overlay network (Tailscale, a
VPN), an SSH tunnel, or an HTTPS reverse proxy — never `0.0.0.0` on an
untrusted network, and never directly on the internet.

## What's here

| Route | View |
|---|---|
| `/` | **Today** — activity rings from today's local `HKActivitySummary`; falls back to today's quantity totals when today's summary is missing, plus headline metrics, recent workouts, and categories |
| `/category/[group]` | All metrics in an Apple-Health group (Activity, Heart, Sleep, …) as live cards |
| `/type/[id]` | **Metric detail** — interactive trend chart with D/7D/30D/90D/6M/Y/2Y/5Y/ALL ranges (see "The trend chart" below), min–max band for instantaneous metrics, bar series for cumulative ones, range stats; hover, tap or arrow keys read a bucket, wheel/pinch zoom and drag pan |
| `/data` | **Catalog** — quantity, category, and workout types with supported viewer routes, grouped with per-user sample counts and last-seen |
| `/workouts` | Latest 120 sessions with duration / energy / distance totals |
| `/workouts/[uuid]` | **Workout detail** — route map, heart rate and zones, splits, intra-workout streams, elevation, sub-activities |
| `/settings` | Whose data is on screen and its profile (age, sex, heart-rate figures behind the zones); display preferences, saved in this browser |

## Architecture

```
web/
├── app/                 # routes (server components query Postgres directly)
├── components/          # Sidebar, ActivityRings, TrendChart, Sparkline, MetricCard …
└── lib/
    ├── catalog.generated.ts  # GENERATED from ../docs/protocol/catalog.json (npm run gen:catalog)
    ├── catalog.ts       # the web catalog: generated core + web-only overlay, GROUPS, lookups
    ├── queries.ts       # the single data API (user id as first argument); local demo fallback
    ├── viewer.ts        # which user this request shows: puls-user cookie, else PULS_USER_ID
    ├── db.ts            # pg pool (server-only)
    ├── demo.ts          # deterministic synthetic data
    ├── metrics.ts       # cumulative-vs-instantaneous classification, time ranges
    ├── chart.ts         # SVG path / scale helpers
    ├── colors.ts        # per-group accent palette
    └── format.ts        # value / unit / time formatting
```

**How data is read.** Like Grafana, the viewer queries TimescaleDB directly
rather than going through the product API: `quantity_samples` /
`category_samples` / `workouts` joined to `sample_types`, bucketed with
`time_bucket()`. Every health-data read is scoped to the chosen user (the
`puls-user` cookie, else `PULS_USER_ID` — see "Choosing a user"), with calendar
boundaries in `PULS_TIME_ZONE`. Sleep and mindful sessions are durations, Stand
Hours count only stood records, and other categories are occurrence counts.
Cumulative raw samples total each source separately and choose the highest source
per bucket to avoid overlapping phone/Watch double counts; when the viewer's
`PULS_TIME_ZONE` equals the database's `puls_time_zone()`, daily canonical values
come from `metric_daily`; otherwise they come from raw local buckets. Today's
totals always use current raw local-day values, so the live headline does not
depend on aggregate refresh or bucket-settlement timing.
Instantaneous types average with a min–max band. Activity rings require the selected
user's summary for the actual current local date.

**The catalog is generated, not mirrored.** `lib/catalog.generated.ts` is
rendered by `npm run gen:catalog` (`scripts/gen-catalog.mjs`, no dependencies)
from the published type vocabulary `../docs/protocol/catalog.json`, which the
PulsHealthSync package tests render from the Swift `HealthTypeCatalog` — the
one place identifiers, kinds, canonical units, groups and display names are
defined (see `../docs/protocol/catalog.md`). `lib/catalog.ts` merges that core
with a web-only overlay (name overrides) and exposes `CATALOG`, `GROUPS`,
`GROUP_LABELS` and the lookups. To add a type, add it to the Swift catalog,
regenerate the JSON there, run `npm run gen:catalog` here and commit both
generated files; never edit them by hand. `npm run check:catalog` (run in CI)
fails when the generated file is stale, and `lib/catalog.test.ts` pins the
merged catalog to the JSON.

## The trend chart

**Ranges.** The selector (and `?range=`) offers D, 7D, 30D, 90D, 6M, Y, 2Y, 5Y
and ALL; `lib/metrics.ts` holds the table. The old `W` and `M` links still
open 7D and 30D. Each range fixes its bucket — hourly for D, daily through 90D,
weekly for 6M and Y, two-weekly for 2Y, calendar months for 5Y — and ALL starts
at the type's earliest sample (from the per-user stats the page loads anyway)
and sizes its bucket to that span, from days up to calendar quarters, so a
chart stays at roughly 30–90 points. Every bucket boundary is a local one in
`PULS_TIME_ZONE`, and day-or-coarser buckets of a covered type read
`metric_daily` (the hourly `quantity_rollups` underneath it) rather than raw
samples; the rest read `quantity_samples`, as before, so a 5Y or ALL chart of
a type without a daily aggregate is a scan of that type's whole history.

`components/TrendChart.tsx` is hand-drawn SVG driven by pointer events — no
chart library, in keeping with the viewer's dependency budget. On a metric page:

| Input | Effect |
|---|---|
| Hover (mouse, pen) | Crosshair and tooltip for the nearest bucket: its timestamp (hour, day, or the week it covers), value and unit, plus the min–max range when the bucket has one |
| Click / tap | Pins that bucket; the tooltip stays until another is picked, or Escape. Tapping again unpins |
| Wheel, trackpad pinch, two-finger pinch | Zooms the time window about the pointer, never narrower than five buckets or wider than the data |
| Horizontal drag, horizontal wheel | Pans the window while zoomed, stopping at the data's edges |
| **Reset** (shown while zoomed) | Back to the full selected range |
| Arrow keys, Home/End, PageUp/PageDown, `+`/`-`, Escape, `0` | Keyboard equivalents once the chart has focus (Tab reaches it): move the selection, zoom about it, clear the selection, then the zoom |

Changing the range always starts from the full new range with
nothing pinned — the zoom never changes which range button is selected. The
row above the chart is an `aria-live` readout of the active bucket (or the
visible window while zoomed), so the value is never hover-only. The SVG uses
`touch-action: pan-y`: one finger scrolls the page as usual, and only a
horizontal drag on a zoomed chart pans. The y axis follows the visible window.
The time arithmetic (clamp, zoom, pan, nearest bucket, wheel normalisation) is
`lib/chartDomain.ts`, pure and covered by `lib/chartDomain.test.ts`.

## Map tiles

The workout route map (`lib/mapStyles.ts`) draws its basemap from free public
tile endpoints that need no API key: Esri's Dark Gray and Light Gray Canvas
(`server.arcgisonline.com` — the dark and light styles, and so the `auto`
default), OpenStreetMap (`tile.openstreetmap.org`), Esri World Imagery, and
OpenTopoMap. The Canvas tiles stop at zoom 16; Leaflet scales those up for the
three levels past it. CARTO's basemaps used to supply the dark, light and
Voyager styles, but since September 2026 they answer every keyless request
with an "API KEY REQUIRED" tile, so they are gone: Voyager had no keyless
equivalent, and a browser that had picked it falls back to Auto. Each style
carries the attribution its operator requires, set in `mapStyles.ts` and
rendered by Leaflet's attribution control — that is a licence condition, not
decoration. These are other people's servers, though, offered under usage
policies written for modest, non-redistributed use (the
[OSMF tile usage policy](https://operations.osmfoundation.org/policies/tiles/),
Esri's ArcGIS Online terms). One person's viewer sits
well inside them; a public or heavily-trafficked deployment does not, and should
point at its own tile server or a paid provider rather than lean on the free
endpoints.

## Notes

- Read-only by design — this is a viewer; it never writes to the health store.
- Pages render dynamically. Data-source and catalog-stat checks use short in-process
  TTL caches to avoid repeated database work.
- Theme (dark/light) is set before paint and persisted to `localStorage`.
