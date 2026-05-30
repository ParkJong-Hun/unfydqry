# spec/ — shared cross-platform test specification

The data-driven portion of the Swift / Kotlin / Rust test suites lives here as
JSON, so all three runners (`swift test`, `gradle :unifiedquery:test`,
`cargo test`) execute the *same* cases against the *same* expected outputs.
Any drift in the Rust normalization / search logic surfaces in all three CIs
at once instead of leaking through silent test divergence.

Background and rationale: see [`../docs/cross-platform-search-engine-design.md`](../docs/cross-platform-search-engine-design.md) §E.4.

## Files

| File | What it drives |
|---|---|
| `normalize.json` | `normalize(input, profile)` pure `(input → expected)` cases incl. the design-doc §2.2 trace table. |
| `search.json` | `SearchEngine` scenarios (a sequence of `ops` followed by `assertions`) and `seeded_matrices` (shared seed reused across many queries). |
| `reindex.json` | In-place index regeneration: index under one profile, reopen under another via `withConfigRebuilding`, and assert the search results before and after the rebuild. |

## Optional behaviour selectors

Both files support **optional** fields that pick which normalize profile / search
strategy a case runs under. They are backward compatible: a record that omits
them falls back to the original behaviour, so existing cases and any loader that
ignores the fields keep working without a `version` bump.

- `normalize.json` cases may set `"profile"`: one of `"loose"` (default) or
  `"nfkc_case_fold"`. Loaders map it and call `normalizeWithProfile(input, profile)`.
- `search.json` scenarios and `seeded_matrices` may set `"config"`:
  `{"normalize": <profile>, "strategy": <strategy>}`. Either key is optional;
  `normalize` defaults to `"loose"` and `strategy` to `"trigram_bm25"`. Other
  strategies: `"substring"`, `"prefix"`. When present, loaders open the engine
  via `SearchEngine.withConfig(dbPath, config)` instead of the default constructor.

## Common conventions

Every file has a top-level `version` integer (currently **3** for all files).
Loaders should refuse to run if this doesn't match the version they were written
for — that way a future breaking schema change can't silently make tests pass by
loading nothing.

Every individual record carries an `id` (or `query` for matrix entries) and a
**`description`**:

- `id` is a short snake-case string, unique within its array. It appears in
  test failure messages and in CI logs, so it should read like a stable
  identifier.
- `description` is a 1–2 sentence English explanation of why the case exists
  and what behaviour it pins down. Loaders include this in every failure
  message so a CI log alone is enough to understand what broke.
- An optional `source` field on `normalize.json` cases cites the design doc
  (e.g. `"source": "design-doc §2.2"`).

## Schemas

### `normalize.json`

```jsonc
{
  "version": 3,
  "cases": [
    {
      "id": "...",
      "description": "...",
      "input": "<string>",
      "expected": "<string>",
      "profile": "<optional profile key>",
      "options": { "fold_choonpu": true, ... },  // optional; see below
      "source": "<optional citation>"
    }
  ],
  "inequalities": [
    {
      "id": "...",
      "description": "...",
      "a": "<string>",
      "b": "<string>",
      "profile": "<optional profile key>",
      "options": { ... }                          // optional; see below
    }
  ]
}
```

A record may select normalization in one of two ways:
- `profile` — a named preset (`loose` (default) or `nfkc_case_fold`).
- `options` — a composable [`NormalizeOptions`](../README.md#configuring-behaviour) set
  (any of the boolean keys `lowercase`, `kana_fold`, `fold_diacritics`,
  `fold_choonpu`, `expand_iteration_marks`, `normalize_hyphens`,
  `strip_digit_grouping`, `collapse_whitespace`; absent keys default to false).
  NFKC is always applied as the foundation. When `options` is present it takes
  precedence and the loader calls `normalizeWithOptions`.

Loader pseudocode:

- For each `cases` entry: normalize `input` (via `normalizeWithOptions(options)` if
  present, else `normalizeWithProfile(profile ?? loose)`) and assert it equals
  `expected`; additionally assert **idempotency** — normalizing `expected` again
  yields `expected`. (Normalization is a fixed point.)
- For each `inequalities` entry: assert the two inputs normalize to *different*
  keys under the same profile/options — pins distinctions that must *not* fold
  together (e.g. dakuten が vs. unvoiced か).

### `search.json`

```jsonc
{
  "version": 3,
  "scenarios": [
    {
      "id": "...",
      "description": "...",
      // optional; `options` (composable NormalizeOptions) takes precedence over `normalize`:
      "config": {"normalize": <profile>, "options": {<step>: true, ...}, "strategy": <strategy>},
      "ops": [
        {"op": "index",  "id": <i64>, "text": "<string>"},
        {"op": "remove", "id": <i64>}
      ],
      "assertions": [
        {
          "search": {"query": "<string>", "limit": <u32>},
          "expected_ids": [<i64>, ...],     // optional: hit-id set (order-insensitive)
          "expected_count": <usize>,        // optional: number of hits
          "score": "zero" | "nonzero_finite", // optional: predicate on every hit's score
          "scores_non_decreasing": true,    // optional: returned scores are sorted ascending
          "expect_no_error": true           // optional: assert search() returns without error
        }
      ]
    }
  ],
  "seeded_matrices": [
    {
      "id": "...",
      "description": "...",
      "limit": <u32>,
      "seed": [
        {"op": "index", "id": <i64>, "text": "<string>"}
      ],
      "queries": [
        {
          "query": "<string>",
          "description": "...",
          "expected_ids": [<i64>, ...]
        }
      ]
    }
  ]
}
```

Loader pseudocode:

- For each scenario: open a fresh in-memory `SearchEngine` (via `withConfig` when
  `config` is present, else the default constructor), replay `ops` in order, then
  for each assertion run `search(query, limit)` and apply **every present
  predicate** (skip absent ones):
  - `expected_ids` → the hit-id *set* equals this (order-insensitive).
  - `expected_count` → the number of hits equals this (used when *which* ids come
    back isn't spec-stable, e.g. under a `limit`).
  - `score` → every hit's score is `0.0` (`"zero"`, the unranked LIKE/substring
    paths) or non-zero and finite (`"nonzero_finite"`, the bm25/fuzzy paths).
    Exact score values are not spec-stable, only their sign/finiteness.
  - `scores_non_decreasing` → the returned scores are sorted ascending (ranking order).
  - `expect_no_error` → `search()` completes without throwing (no further check);
    used for queries whose result set isn't meaningful (whitespace, FTS5 reserved
    syntax) but which must not crash.
- For each seeded_matrix: open a fresh engine, replay the entire `seed`, then
  for each query in `queries` compare hit-ids against `expected_ids` (same
  semantics; `limit` is inherited from the matrix).

`ops` is a tagged union — `"op": "index"` requires `id` + `text`, `"op": "remove"`
requires `id` only.

### `reindex.json`

```jsonc
{
  "version": 3,
  "cases": [
    {
      "id": "...",
      "description": "...",
      "config_before": {"normalize": <profile>, "strategy": <strategy>},
      "config_after":  {"normalize": <profile>, "strategy": <strategy>},
      "ops": [ {"op": "index", "id": <i64>, "text": "<string>"} ],
      "before": [ {"search": {"query": "<string>", "limit": <u32>}, "expected_ids": [<i64>, ...]} ],
      "after":  [ {"search": {"query": "<string>", "limit": <u32>}, "expected_ids": [<i64>, ...]} ]
    }
  ]
}
```

Loader pseudocode: open a **persistent** (temp-file, not in-memory) engine with
`withConfig(config_before)`, replay `ops`, assert every `before` check, then
close it and reopen the same path with `withConfigRebuilding(config_after)` and
assert every `after` check. A profile change makes `withConfigRebuilding`
re-normalize the retained raw text under the new profile, so `before` pins the
pre-rebuild behaviour and `after` pins the regenerated behaviour. `config_before`
/ `config_after` reuse the same optional shape as `search.json`'s `config`, and
each `before` / `after` entry reuses the full `assertions` shape (the same
predicate fields documented for `search.json`).

## What's deliberately *not* here

Almost all behaviour now reduces to a spec record: normalization equality,
inequality, and idempotency; and search by every strategy/profile including
score sign/finiteness, ranking order, hit count, and non-throwing safety. Only
the handful of assertions that depend on language-specific runtime primitives
(not on the engine's input→output contract) stay in native test source:

- **Concurrency** (`withTaskGroup` / `ExecutorService`) — asserts thread-safety
  using each language's threading primitives.
- **Filesystem lifecycle** (file creation on disk, persistence across reopen,
  invalid-path throws the platform's error type) — coupled to each language's
  I/O and error-type APIs.

When in doubt, prefer adding a case to the spec; only fall back to native code
when the assertion genuinely can't be expressed as a comparison over the
engine's inputs and outputs.
