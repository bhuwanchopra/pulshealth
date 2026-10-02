# Puls Sync Protocol v1 fixture corpus

Known-good batches, one scenario per file, as plain-text NDJSON so they can
be read and diffed. Each `NN-name.ndjson` has a sibling `NN-name.expected.json`
with the HTTP status and the count body a conformant reference server returns.

| Fixture | Exercises |
|---|---|
| `01-quantity-category` | Quantity samples (explicit nulls, metadata, temporal contexts) and a category sample in one batch |
| `02-workout-route-series` | A workout with per-type statistics, events and a sub-activity; a route chunk; a series chunk |
| `03-aggregates-activity-profile` | Two aggregate buckets (one explicit-null), two activity summaries (one legacy without `localDate`), a profile line that clears name and email |
| `04-legacy-header` | A pre-versioning header (no `schemaVersion`, no optional counts) re-sending a known UUID: the duplicate is a no-op |
| `05-deletions` | A tombstone for a stored sample and one for an unknown UUID |
| `06-empty-probe` | The header-only connection probe |
| `07-special-kinds` | Heartbeat series, ECG, State of Mind, medication dose |

The expected counts assume the fixtures are applied **in file-name order to
an empty store**: `04` re-sends a UUID that `01` stored, and `05` deletes it.
Where the order matters, the `notes` field of the `expected.json` gives the
standalone counts. Replaying any
fixture immediately after itself must return 2xx with `accepted` 0.

The lines come from the Go parser's own test fixtures
(`server/ingest/parse_test.go`) and its README example, so they are what the
reference server is tested against. `tools/protocol-check` validates every
fixture against the schemas in CI, and
`examples/receivers/python-sqlite/smoke_test.py` posts them to a live
receiver and compares the counts:

```bash
# validate the corpus (and any batch you capture) against the schemas
cd tools/protocol-check && go test ./... && go run . ../../docs/protocol/fixtures/*.ndjson

# post the corpus to a receiver
python3 examples/receivers/python-sqlite/smoke_test.py --url http://localhost:8080 --token "$PULS_TOKEN"
```

To send one fixture by hand:

```bash
gzip -c docs/protocol/fixtures/01-quantity-category.ndjson | curl -sS -X POST http://localhost:8080/v1/batches \
  -H "Authorization: Bearer $PULS_TOKEN" -H "Content-Type: application/x-ndjson" \
  -H "Content-Encoding: gzip" -H "X-Puls-Protocol: 1" \
  -H "X-User-ID: 5ea4d000-0000-4000-8000-000000000001" --data-binary @-
```

Adding a scenario: write the batch, run `protocol-check` on it, add the
`expected.json`, and extend the coverage test in `tools/protocol-check` if it
introduces a new line type or kind.
