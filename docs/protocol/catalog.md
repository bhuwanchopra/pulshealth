# The type vocabulary: `catalog.json`

[`catalog.json`](catalog.json) is the published vocabulary of the Puls Sync
Protocol: every HealthKit type the PulsHealth app can sync, with the facts a
receiver, a viewer or an analyst needs about it — the identifier that appears
in `type` on the wire, its kind, its canonical unit, its aggregation
behaviour, and the first iOS release that carries it. It exists so those facts
are written down **once**. The Swift catalog
([`HealthTypeCatalog.swift`](../../PulsHealthSync/Sources/PulsHealthSync/Models/HealthTypeCatalog.swift))
stays the authoritative definition, because HealthKit's constraints (which
identifiers exist, which units parse, which statistics a type allows) can only
be checked from Swift; this file is **rendered from it**, and everything else
is rendered from this file.

```
HealthTypeCatalog.swift  ──(package test, write mode)──▶  docs/protocol/catalog.json
                                                                  │
                                              web/scripts/gen-catalog.mjs
                                                                  ▼
                                                     web/lib/catalog.generated.ts
                                                                  │
                                              merged by web/lib/catalog.ts (overlay)
```

Two checks keep the chain honest, and both run in CI:

- `CatalogVocabularyTests.publishedVocabularyMatchesTheCatalog` in the
  PulsHealthSync package renders the vocabulary from the live catalog and
  compares it **byte for byte** with the committed file. It fails with the
  first differing line and the regeneration recipe.
- `npm run check:catalog` in `web/` renders `catalog.generated.ts` from the
  JSON to a temporary file and diffs it against the committed one.

## Regenerating

Change the Swift catalog, then let the test rewrite the file (the
`TEST_RUNNER_` prefix is xcodebuild's way of passing an environment variable
to the test runner), then re-render the web core:

```bash
cd PulsHealthSync && TEST_RUNNER_PULS_WRITE_CATALOG=1 xcodebuild test \
  -scheme PulsHealthSync -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PulsHealthSyncTests/CatalogVocabularyTests
cd ../web && npm run gen:catalog
```

Commit `docs/protocol/catalog.json`, `web/lib/catalog.generated.ts` and the
Swift change together. Never edit the JSON or the generated TypeScript by
hand: the tests will fail, and `gen-catalog.mjs` refuses a JSON file that is
not in the canonical layout.

The rendering runtime matters in one way. `aggregationStyle` and
`allowedAggregateFunctions` are read from HealthKit at render time (the app
derives the legal function set from `HKQuantityType.aggregationStyle` — see the
gotchas in `CLAUDE.md`), so a **quantity** type gated above the simulator that
renders the file cannot be published until the test runs on that iOS. Today
that is HRV RMSSD (iOS 27): regenerate on an iOS 27 simulator. On an older
runtime the three rendering tests are skipped (CI's Xcode 27 job runs them),
and a `PULS_WRITE_CATALOG=1` run fails naming the runtime it needs. Every
other fact, including `minimumIOS`, is declared in the catalog and renders
identically on any runtime.

## Layout

The file is canonical `JSON.stringify(document, null, 2)` output with a
trailing newline: 2-space indentation, `"key": value`, empty arrays as `[]`,
no escaping beyond what JSON requires (`/` and non-ASCII such as `VO₂` stay
literal), and a fixed key order. Type entries are sorted by identifier (byte
order), so adding a type is a contiguous insertion in the diff.

```json
{
  "protocol": 1,
  "source": "PulsHealthSync/Sources/PulsHealthSync/Models/HealthTypeCatalog.swift",
  "groups": [ { "key": "activity", "label": "Activity" }, … ],
  "types": [
    {
      "identifier": "HKQuantityTypeIdentifierStepCount",
      "kind": "quantity",
      "unit": "count",
      "aggregationStyle": "cumulative",
      "allowedAggregateFunctions": ["sum", "mostRecent", "duration"],
      "minimumIOS": "17.0",
      "displayName": "Steps",
      "group": "activity",
      "estimatedSamplesPerDay": 250
    },
    …
  ]
}
```

| Field | Meaning |
|---|---|
| `protocol` | The protocol major version this vocabulary belongs to (`schemaVersion` in the batch header). The vocabulary grows without bumping it: new identifiers are additive, and a receiver MUST accept identifiers it has never seen ([spec §5](README.md#5-type-vocabulary-and-canonical-units)). |
| `source` | The Swift file the vocabulary is rendered from. |
| `groups` | The Apple-Health-style display groups in the app's order: `key` is the stable machine name used by `types[].group`, `label` the display text. |
| `types[].identifier` | The string in `type` on the wire and in `sample_types.identifier` in the reference schema: the HealthKit identifier for quantity and category types; the fixed strings `HKWorkoutTypeIdentifier`, `HKDataTypeIdentifierHeartbeatSeries`, `HKDataTypeIdentifierElectrocardiogram`, `HKDataTypeIdentifierStateOfMind`, `HKMedicationDoseEventTypeIdentifierMedicationDoseEvent` and `HKActivitySummaryTypeIdentifier` for the rest. |
| `types[].kind` | The app's `SampleKind`: `quantity`, `category`, `workout`, `heartbeatSeries`, `ecg`, `stateOfMind`, `medicationDose` or `activitySummary`. `activitySummary` is the activity rings, which travel on their own `activitySummary` line and are never a sample ([spec §4.6](README.md#46-activity-summary)); the identifier appears only in `/v1/stats` bookkeeping. |
| `types[].unit` | The canonical unit every value of a quantity type is converted to on the phone, as an `HKUnit` string; `null` for every other kind. `%` is a **fraction** (blood oxygen 0.97, not 97), `count/min` is per minute. `duration` aggregates carry `s` instead, which is not a catalog unit. |
| `types[].aggregationStyle` | HealthKit's `HKQuantityAggregationStyle` case name for quantity types (`cumulative`, `discreteArithmetic`, `discreteTemporallyWeighted`, `discreteEquivalentContinuousLevel`); `null` otherwise. Cumulative types add up over a period (steps, energy); discrete ones are readings (heart rate, weight). |
| `types[].allowedAggregateFunctions` | The `func` values an `aggregate` line ([spec §4.5](README.md#45-aggregate)) can carry for this type — the functions HealthKit accepts for its aggregation style: cumulative types allow `sum`, `mostRecent`, `duration`; discrete types `average`, `min`, `max`, `mostRecent`, `duration`. Empty for non-quantity kinds. |
| `types[].minimumIOS` | The first iOS release the app exports the type on, `"major.minor"`. `"17.0"` (the app's deployment target) for anything older; `"18.0"` for State of Mind and sleep-apnea events; `"26.0"` for medication doses. A receiver may see any listed type from any phone at or above that release, and never one from below it. |
| `types[].displayName` | The app's display name (what the web viewer shows unless its overlay overrides it). |
| `types[].group` | One of `groups[].key`. |
| `types[].estimatedSamplesPerDay` | The app's rough samples-per-active-day hint, used for backfill ETAs; a sizing aid, not a promise. |

## Consuming it

Anything that needs the vocabulary should read this file rather than restate
it. The web viewer's `gen-catalog.mjs` is the model: read, validate the shape
(it checks key order, sorting, uniqueness, unit/style consistency and group
membership), render whatever your language wants. A receiver does not need it
at all to be conformant — the wire format carries `unit` with every quantity
sample — but it is the list to compare against when deciding what to store,
chart or alert on, and `aggregationStyle` is the right basis for "sum or
average this?" decisions.
