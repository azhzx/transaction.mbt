# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org).

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
