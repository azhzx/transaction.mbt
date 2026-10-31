# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org).

## [0.3.0] - 2026-10-31

### Fixed

- `Txn::retry` now carries the commit version of the snapshot the transaction
  last validated, instead of the clock observed at retry time. An
  asynchronous transaction that read a variable, suspended, missed a commit,
  and then retried could otherwise park forever; the runner now re-runs it
  immediately.
- `or_else` partial rollback restores pending writes made before the branch
  point instead of deleting them, which silently lost updates when a
  discarded branch wrote the same `TVar` again.
- `Txn::commit` clears its write log and only advances the commit clock when a
  write was actually applied. Reusing a committed handle no longer bumps the
  clock spuriously, wakes every parked task, or grows the log without bound.
- Added regression tests for retry across a suspension, `or_else` rollback,
  handle reuse, and cancellation mid-transaction.

### Changed

- Commit versions, transaction ids, variable versions and variable pending
  maps now use 64-bit counters. `commit_version()`, `Retry` and `Conflict`
  expose `Int64` instead of `Int32`; this is source-breaking for code that
  annotates those payloads explicitly.
- Documentation now reflects the 64-bit counters, the exact retry wake-up
  rule, current test counts, and the async cancellation semantics; the
  installation snippets use valid `moon.pkg` syntax.

## [0.2.0] - 2026-10-25

### Added

- Manual `Txn::commit` and `Txn::rollback` entry points for custom runners.
- Benchmark suite for the core transaction paths, plus heavier chaos stress
  suites for the core and the async runner.
- Runnable showcase (`examples/showcase`), bilingual user/design manual, and
  README examples verified as doctests.
- CI workflow covering check/build, wasm/js/native tests, coverage, and
  benchmarks; backend support matrix and module metadata/license filled in.

### Changed

- Test suite extended with integration scenarios and deterministic stress
  suites; CI refreshes the MoonBit registry index before each job.

## [0.1.0] - 2026-10-25

First release.

### Added

- Core package `azhzx/transaction` (dependency-free): `TVar`, `Txn`
  (`read` / `write` / `modify` / `check` / `retry` / `or_else` / `run` /
  `run_async` / manual `commit` / `rollback`), `atomically` with automatic
  conflict restarts, `TMVar`, `TQueue`, `is_retry` / `is_conflict`, and the
  `commit_version` / `on_commit` hooks for custom runners.
- Runner package `azhzx/transaction/runner`: `atomically_async` — await-capable
  transaction bodies that park on `Retry` until a commit and restart
  automatically on `Conflict`.
- Testing: 134 tests across four layers (doctests, unit, seeded stress/chaos
  with model-equivalence and invariant checks, integration scenarios), plus a
  14-case benchmark suite (`moon bench`).
- CI: type-check on all backends, build, tests on wasm/js/native, coverage,
  benchmarks, and the runnable example.
- Documentation: README with tested examples and bilingual manuals
  (`doc/en.md`, `doc/zh.md`).
