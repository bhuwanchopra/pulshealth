# PulsHealth: a guide for AI assistants

This server gives read-only access to Apple Health data — usually one
person's. The PulsHealth iOS app reads HealthKit on their iPhone and syncs
every sample to a database they run themselves; this server answers from
that database through a read-only API. Nothing here can change any data.

## Start here

1. If several people might share this server — a household, a family —
   call `list_users` first. It names everyone with data, says which one is
   the *default* (whom every other tool answers for when its `user` argument
   is omitted), and whether `multi_user` is on: when it is `false`, asking
   for anyone but the default is refused by the server, and when the answer
   carries `pinned_user_id` this instance serves that one person only. Every
   data tool takes an optional `user`; pass a `user_id` from `list_users` to
   read that person's data, and say whose data you are reporting.
2. For a broad "how have I been doing lately" question, `get_summary` is the
   cheapest first call: one short markdown page over the last 7, 14, 30 or
   90 days — activity, heart, sleep, workouts, body and a coverage line —
   with units in the text and every figure already deduplicated. It carries
   averages and totals only; anything about a particular day, workout or
   reading needs the tools below.
3. Call `list_available_types` next. It tells you which HealthKit types
   have data, in which unit, how far back the history goes, how current it is
   (`latest`), and — importantly — `today` and `time_zone`, because you do not
   otherwise know what day it is for this person.
4. Pick the tool by the question (recipes below). Prefer the daily tools for
   "how much / how many / on average" questions and `get_latest_metrics` for
   "what is my current ..." questions.
5. Quote units. Say which days have no data rather than treating them as
   zero. Do not sum raw samples yourself: the daily tools already give the
   deduplicated value.

## Tools

| Tool | Answers |
|---|---|
| `list_users` | Who has data on this server, which of them is the default, whether another can be asked for (`multi_user`). |
| `get_summary(range?)` | The last 7d (default), 14d, 30d or 90d as one short markdown page: activity, heart, sleep, workouts, body, coverage. Averages and totals only. |
| `list_available_types` | What data exists, its units, its time bounds, today's date and the time zone. |
| `get_profile` | Name, email, date of birth, age, biological sex. |
| `get_latest_metrics(types)` | The newest single reading per quantity type (weight, resting heart rate, HRV, VO2 max, blood oxygen, ...). |
| `get_daily_metrics(types, start_date, end_date)` | One value per calendar day: sums for cumulative types, averages for discrete ones. Up to 10 types and 366 days per call. |
| `get_activity_rings(start_date, end_date)` | Apple Watch Move / Exercise / Stand values and goals per day. |
| `list_workouts(start_date?, end_date?, activity_type?, limit?, offset?)` | Workout summaries, newest first. |
| `get_workout(uuid)` | One workout's per-type statistics, events and multi-sport parts. |
| `get_workout_series(uuid, types?, max_points?)` | The second-by-second streams inside one workout (heart rate, power, speed, ...). |
| `get_sleep(start_date, end_date)` | One row per night: time asleep, time in bed, the stage breakdown, how many devices recorded it. |
| `get_samples(type, start_date, end_date, limit?, offset?)` | The individual records of one type — raw, undeduplicated. Up to 31 days per call. |
| `get_state_of_mind(start_date, end_date)` | Logged moods and emotions: valence, labels, associations. |

Every tool except `list_users` also takes an optional `user`. Every tool but
`get_summary` (which returns the page as markdown text) returns one compact
JSON object; the per-user ones carry `user_id` when a
user was named or the instance is pinned, and omit it when the answer is the
default person's. Errors come back as tool errors with the reason (a date in
the wrong format, an unknown workout, a user this instance cannot read, the
product API rejecting the token, the API being unreachable). Values are
rounded to four decimals.

## The data model in brief

- **Types are HealthKit identifiers.** Quantity types look like
  `HKQuantityTypeIdentifierStepCount`; category types like
  `HKCategoryTypeIdentifierSleepAnalysis`; workouts are
  `HKWorkoutTypeIdentifier`; rings are `HKActivitySummaryTypeIdentifier`.
  Always pass the full identifier.
- **Raw samples** are the individual HealthKit records: a heart-rate reading
  every few seconds during a workout, one weight entry per weigh-in, one
  step-count interval per minute. `get_latest_metrics` returns the newest raw
  sample of a type.
- **Daily metrics** are one number per local calendar day per type. They come
  from the daily aggregates HealthKit computes on the phone when the app
  synced them (`aggregate_rows > 0` in the catalog), otherwise from a
  single-source rollup on the server. This is the surface for totals,
  averages and trends.
- **Activity rings** are the Apple Watch's own daily summaries (Move in kcal,
  Exercise in minutes, Stand in hours, each with a goal). They are what the
  person sees in the Fitness app; do not reconstruct them from samples.
- **Workouts** have a summary (activity, start, end, duration, distance,
  energy), a detail (per-type min/avg/max/sum statistics, events such as
  pauses and laps, and sub-activities for multi-sport sessions) and the
  streams behind those statistics (`get_workout_series`).
- **Sleep** is stored as one raw sample per stage, but `get_sleep` returns it
  the way a person thinks about it: one row per night. See below.
- **State of Mind** entries are typed in by hand in the Health or Mindfulness
  app. They are sparse and self-reported; most days have none.

## Units

Every value of a type is in that type's canonical unit, given by
`list_available_types` and repeated as `unit` in every answer. The common
ones:

| Types | Unit |
|---|---|
| StepCount, FlightsClimbed, SwimmingStrokeCount | `count` |
| HeartRate, RestingHeartRate, WalkingHeartRateAverage, RespiratoryRate, CyclingCadence | `count/min` (beats or breaths per minute) |
| DistanceWalkingRunning, DistanceCycling, DistanceSwimming, Height | `m` |
| WalkingSpeed, RunningSpeed | `m/s` |
| ActiveEnergyBurned, BasalEnergyBurned, DietaryEnergyConsumed | `kcal` |
| AppleExerciseTime, AppleStandTime, AppleMoveTime, TimeInDaylight | `min` |
| BodyMass, LeanBodyMass | `kg` |
| HeartRateVariabilitySDNN, HeartRateVariabilityRMSSD, RunningGroundContactTime | `ms` |
| OxygenSaturation, BodyFatPercentage, WalkingAsymmetryPercentage | `%` — **a fraction**: 0.97 means 97 % |
| VO2Max | `ml/kg*min` |
| BodyTemperature, AppleSleepingWristTemperature | `degC` |
| BloodPressureSystolic / Diastolic | `mmHg` |
| BloodGlucose | `mg/dL` |
| RunningPower, CyclingPower | `W` |
| Dietary macronutrients | `g` (sodium and caffeine `mg`, water `mL`) |

Workout fields carry their unit in the name: `duration_s` (seconds of active
time, pauses excluded), `distance_m` (metres), `energy_kcal`. Convert for the
reader when helpful (1 km = 1000 m; 1 mi = 1609.344 m; pace = duration /
distance).

## Cumulative versus discrete metrics

- **Cumulative** types accumulate over time: steps, distance, active and
  basal energy, exercise and stand minutes, flights climbed, dietary intake.
  Their daily value is a **sum**. Their latest raw sample is one small
  increment (a minute of walking), never a total — for "how many steps
  today" use `get_daily_metrics`, not `get_latest_metrics`.
- **Discrete** types are measurements: heart rate, resting heart rate, HRV,
  weight, blood oxygen, VO2 max, respiratory rate, temperature. Their daily
  value is an **average** of that day's readings; their latest raw sample is
  the current reading.
- Only types the phone aggregates daily appear in `get_daily_metrics`. A
  type with raw rows but no aggregate rows has latest readings only.

## The double-counting rule

An iPhone and an Apple Watch both record steps, distance and energy for the
same minutes. Adding raw samples across both devices roughly doubles daily
step counts — the most common way to misread this data. The daily tools
avoid it: HealthKit's own daily aggregate already merges the devices, and the
server's fallback takes a single source per day. `get_sleep` applies the same
idea per night. Trust `get_daily_metrics`, `get_activity_rings` and
`get_sleep`; never total raw readings yourself.

`get_samples` is the deliberate exception: it hands back the individual
records exactly as synced, **not** deduplicated, because that is the point of
asking for them. Use it to look at particular readings — every blood-pressure
entry, when the heart rate spiked, each logged symptom — never to compute a
total or an average.

## Sleep

`get_sleep` returns one row per sleep session. Two rules shape it:

- **A night belongs to the day you wake up.** Apple Health does this too, so
  a night from 22:40 on the 20th to 06:30 on the 21st is dated the 21st. "How
  did I sleep last night?" on the 21st means the row dated the 21st.
- **A gap of more than three hours starts a new session**, so a daytime nap is
  its own row on the same date. Check `start` and `end` before calling a row
  "last night".

Durations are minutes: `asleep_min` (core + deep + REM + unspecified),
`in_bed_min`, and a `stages` breakdown. `awake_min` is time awake during the
night and is *not* part of `asleep_min`; `unspecified_min` is sleep recorded
without stage detail, typical of an iPhone or a third-party app. `sources`
counts the devices that recorded the night — when several did, nothing is
summed across them: `in_bed_min` is the largest single source's total, and
`asleep_min` with its stages come together from the source that recorded the
most sleep.

## The time-zone rule

Every date in this server is a calendar day in the server's configured time
zone (`time_zone` in `list_available_types` and `get_profile`), which is set
to match the phone's zone. Inclusive `start_date`/`end_date` ranges return
exactly those days. Instants (`timestamp`, `start`, `end`, `latest`) are ISO
8601 with the zone's UTC offset. If the person travelled, days are still cut
in the configured zone.

## What is not available yet

- GPS routes, medication doses, ECGs and heartbeat series. The database
  holds them; no tool serves them.
- Any kind of writing: this server is read-only, so it cannot log, correct or
  delete a single record.

## Recipes: question → tool

| Question | Do this |
|---|---|
| "What data do you have about me?" | `list_available_types`; summarise kinds, units, date range, freshness. |
| "How have I been doing lately?" / "Give me an overview of my month" | `get_summary(range="30d")`; relay the page's figures with their units, then offer to go deeper with the tools below. |
| "How many steps did I take last week?" | `get_daily_metrics(types=[HKQuantityTypeIdentifierStepCount], start_date, end_date)`; sum the days, name any missing day. |
| "What's my resting heart rate trend?" | `get_daily_metrics` with RestingHeartRate (and HeartRateVariabilitySDNN) over 30–90 days; compare first and last weeks. |
| "What do I weigh now?" / "Has my weight changed?" | `get_latest_metrics([HKQuantityTypeIdentifierBodyMass])` for now; `get_daily_metrics` over months for the trend. |
| "Did I close my rings yesterday?" | `get_activity_rings(yesterday, yesterday)`; a ring is closed when value ≥ goal. |
| "How active was I this month?" | `get_activity_rings` for the month + `get_daily_metrics` for StepCount and AppleExerciseTime. |
| "Compare my runs this month to last month" | `list_workouts(activity_type="running")` twice (one range per month); totals, averages, pace; `get_workout` on a few for heart rate. |
| "What was my longest ride?" | `list_workouts(activity_type="cycling", limit=200)`, page with `offset` if `next_offset` appears; pick the max `distance_m`. |
| "How hard was Tuesday's workout?" | `list_workouts` for that day, then `get_workout(uuid)`; report heart-rate avg/max, energy, duration. |
| "How did my heart rate move during that run?" | `get_workout_series(uuid, types=[HKQuantityTypeIdentifierHeartRate])`; describe the shape, not every point. |
| "How did I sleep last week?" | `get_sleep(start_date, end_date)`; average `asleep_min` (report in hours), name the best and worst night, mention the stage mix and any night with no data. |
| "Did I sleep better on the nights I ran?" | `get_sleep` for the range and `list_workouts` for the same range; line the workout days up with the *following* night's row (a night is dated by its wake-up day). |
| "When exactly did my heart rate spike yesterday?" | `get_samples(type=HKQuantityTypeIdentifierHeartRate, start_date, end_date)`; read the individual samples, never total them. |
| "How have I been feeling lately?" | `get_state_of_mind(start_date, end_date)`; report the entries and their labels plainly, and say most days have none if so. |
| "How old am I?" / "Who is this data for?" | `get_profile`. |
| "Is my partner's data here too?" / "How did Alex sleep?" | `list_users`; if `multi_user` is true, pass their `user_id` as `user` to `get_sleep` (or any tool) and say whose data it is. If it is false, only the default person can be read — say so. |

When a range is longer than 366 days, split it into several calls. When the
person asks about "this week" or "last month", compute the dates from
`today` and the zone's calendar (weeks start on Monday unless they say
otherwise).
