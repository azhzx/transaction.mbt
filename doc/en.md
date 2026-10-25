# azhzx/transaction — User and Design Manual (English)

Software Transactional Memory (STM) for [MoonBit](https://moonbitlang.com):
shared `TVar`s updated by atomic, composable transactions, with blocking that
composes (`retry` / `or_else`) instead of deadlocking.

- [Goals](#goals)
- [Installation](#installation)
- [Core concepts](#core-concepts)
- [API reference](#api-reference)
- [Semantics and rules](#semantics-and-rules)
- [Compositional blocking patterns](#compositional-blocking-patterns)
- [Design internals](#design-internals)
- [Concurrency model and backends](#concurrency-model-and-backends)
- [Testing and CI](#testing-and-ci)
- [Comparison with alternatives](#comparison-with-alternatives)
- [FAQ](#faq)
- [References and acknowledgements](#references-and-acknowledgements)

## Goals

1. Make shared mutable state between MoonBit tasks safe and **composable**:
   any two transactions combine into one atomic step without locks,
   lock ordering, or missed wake-ups.
2. Keep the core dependency-free so it builds on every backend (wasm,
   wasm-gc, native).
3. Offer blocking that composes: `retry` blocks *until something the
   transaction read changes*, and `or_else` merges two blocking operations
   into one.
4. Stay small and auditable: the core is a few hundred lines with a
   TL2-style design (global commit clock, per-variable versions, private
   write sets).

## Installation

```sh
moon add azhzx/transaction
```

Then import the packages you need in your `moon.pkg`:

```json
{
  "import": [
    "azhzx/transaction",
    "azhzx/transaction/runner"
  ]
}
```

TOML style (`moon.pkg`):

```toml
import {
  "azhzx/transaction" @transaction,
  "azhzx/transaction/runner" @runner, # only for async transactions
  "moonbitlang/async" @aio,           # only for the runner
}
```

The core package (`@transaction`) has no dependencies. The runner package
(`@runner`) adds `moonbitlang/async` for transactions whose body needs to
`await`.

## Core concepts

A quick tour; the README has runnable versions of these snippets.

**TVar** — a transactional variable. Create with `TVar::new(v)`, inspect the
last committed value outside transactions with `tv.peek()`.

**atomically** — runs a body as one transaction:

```moonbit
@transaction.atomically(txn => {
  let funds = txn.read(alice)
  txn.check(funds >= 30)
  txn.write(alice, funds - 30)
  txn.modify(bob, b => b + 30)
})
```

All reads go through the `Txn` handle; writes become visible to other
transactions only at commit.

**retry / check** — `txn.retry()` aborts the attempt because it cannot
proceed; `txn.check(cond)` retries unless `cond` holds. Under the async
runner the task *parks* until a variable the transaction read has been
committed by someone else, then the body runs again from the beginning.

**or_else** — merges alternatives: `txn.or_else(first, second)` runs
`first`; if it retries, its effects are discarded and `second` runs instead.
Under the runner, the combined operation wakes when *either* source changes.

**TMVar / TQueue** — ready-made structures: a one-slot empty-or-full cell
(`take` retries while empty, `put` while full) and a FIFO queue (`pop`
retries while empty).

**atomically_async** — the runner entry point for bodies that `await`:

```moonbit
@runner.atomically_async(txn => {
  let v = txn.read(cell)
  @aio.pause()               // suspend freely
  txn.write(cell, v + 1)     // validated against a fresh snapshot
})
```

## API reference

### Core package `azhzx/transaction`

| Item | Signature | Purpose |
|---|---|---|
| `TVar::new` | `(T) -> TVar[T]` | Create with an initial committed value |
| `TVar::peek` | `(TVar[T]) -> T` | Read the last committed value, no transaction |
| `Txn::read` | `(Txn, TVar[T]) -> T raise Conflict` | Transactional read (own writes visible) |
| `Txn::write` | `(Txn, TVar[T], T) -> Unit` | Buffered write, applied at commit |
| `Txn::modify` | `(Txn, TVar[T], (T) -> T raise) -> Unit raise` | Read-modify-write |
| `Txn::check` | `(Txn, Bool) -> Unit raise Retry` | Retry unless the condition holds |
| `Txn::retry` | `(Txn) -> T raise Retry` | Block the transaction |
| `Txn::or_else` | `(Txn, (Txn) -> T raise, (Txn) -> T raise) -> T raise` | Compositional choice |
| `atomically` | `((Txn) -> T raise) -> T raise` | Run one synchronous transaction |
| `is_retry` / `is_conflict` | `(Error) -> Bool` | Dispatch on the abstract `raise` |
| `commit_version` | `() -> Int` | The global commit clock (custom runners) |
| `on_commit` | `(() -> Unit) -> Unit` | Post-commit hook (custom runners) |
| `TMVar::*` | see `.mbti` | Empty-or-full one-slot cell |
| `TQueue::*` | see `.mbti` | Transactional FIFO queue |

`TVar` implements `Eq`/`Hash` by identity: two handles are equal exactly
when they refer to the same variable.

### Runner package `azhzx/transaction/runner`

| Item | Purpose |
|---|---|
| `atomically_async(f)` | Run an await-capable transaction; `Retry` parks the task until any commit, `Conflict` restarts after one yield |

Low-level primitives for custom runners: `Txn::begin`, `Txn::run`,
`Txn::run_async`, `commit_version`, `on_commit`.

## Semantics and rules

- **Atomicity.** Every `atomically` block applies all writes together or
  nothing.
- **Isolation.** A body sees one consistent snapshot; uncommitted writes of
  other transactions are never visible (`pending` write sets are keyed by
  transaction id).
- **Consistency via validation.** Every read records a version check; if a
  read variable is committed by another transaction, the body is rolled
  back and restarted — automatically under `atomically` /
  `atomically_async`.
- **Bodies may re-run.** Keep side effects (I/O, logging) out of the body
  or make them idempotent.
- **Values must be immutable.** Copy-on-write for containers (`copy()`,
  then mutate the copy, then `write`).
- **Transactions do not nest.** An inner `atomically` commits
  independently; if it invalidates the outer snapshot the outer restarts.
- **A blocked transaction has no effects.** When `retry` fires, *all*
  writes of that attempt are rolled back — see the barrier pattern below.
- **Errors propagate unchanged.** Body errors roll back and reach the
  caller; use `is_retry` to tell "blocked" from "failed".

## Compositional blocking patterns

**Producer/consumer** — `TQueue::pop` retries while empty; under the runner
the consumer parks, wakes on the next push:

```moonbit
@runner.atomically_async(txn => jobs.pop(txn))
```

**Choice** — serve whichever mailbox has mail:

```moonbit
@runner.atomically_async(txn =>
  txn.or_else(t => urgent.take(t), t => regular.take(t)))
```

**Barrier (the subtle one).** A blocked transaction rolls back its own
writes, so "increment the arrival counter, then wait" must be *two*
transactions — the arrival commits, the wait blocks:

```moonbit
@runner.atomically_async(txn => txn.modify(arrived, v => v + 1)) // commits
@runner.atomically_async(txn => txn.check(txn.read(arrived) == n)) // blocks
```

Writing both steps into one transaction deadlocks: every attempt rolls the
increment back and the counter never advances.

**Semaphore** — permits in a `TVar`; acquire with `check` and decrement in
one transaction, release in another.

**Bounded buffer** — `txn.check(queue.length(txn) < cap)` before `push`;
the producer parks when the buffer is full.

## Design internals

The layout follows the TL2 family of STM algorithms, adapted to a
cooperatively scheduled, single-threaded runtime:

- A **global commit clock** advances once per committed write transaction.
- Each `TVar` carries its **value**, a monotonically increasing
  **version**, and a **pending map** keyed by transaction id holding
  uncommitted writes (this is what lets an async body suspend with writes
  in flight without leaking them).
- Each `Txn` keeps three logs: **validators** (closures re-checking the
  version of every read), **commits** (write-back closures), and **undo**
  actions (pending-map cleanup, run in reverse on rollback).
- `Txn::read` revalidates the read set only when the global clock moved
  since the last validation, then returns the pending value of this
  transaction if present, else the committed value.
- Validation and commit run in one **synchronous section**; because
  coroutines only switch at suspension points, no interleaving can slip
  between check and commit — no locks needed.
- `or_else` marks the log lengths before the first branch and truncates
  back to the marks on retry, so the second branch starts from a clean
  slate.
- The runner parks on a condition variable; every write commit broadcasts
  (conservative — a parked transaction may wake, re-run, still observe its
  condition unmet, and park again; correctness is unaffected, and
  per-variable wakeups are a roadmap item).

Complexity: commit is O(read set + write set); a read is O(1) plus
revalidation, which is skipped unless the global clock changed.

## Concurrency model and backends

MoonBit tasks are cooperatively scheduled on a single-threaded event loop,
so any number of tasks can share `TVar`s with no data races — that is the
world this library is designed for. True parallel threads are not exposed
by the toolchain today; if a shared-memory backend arrives, the design
ports by wrapping the validation/commit section in a lock (the logs and
clock are already in place).

The core package builds on every backend (wasm, wasm-gc, native); the
runner needs `moonbitlang/async` and is tested on wasm and native.

## Testing and CI

- 120 tests across four layers: docstring/README doctests, unit tests
  (blackbox + whitebox), randomized stress with deterministic seeds
  (model equivalence, invariants, rollback completeness), and integration
  scenarios (`tests/`, realistic multi-task patterns).
  The stress suite includes a torn-state detector: an updater advances
  eight TVars atomically while observers suspend mid-read — a mixed
  old/new observation is impossible by construction and asserted to stay
  at zero.
- CI (GitHub Actions) runs `moon check`, `moon build`, `moon test` on wasm
  and native, the runnable example (`moon run cmd/main`), and coverage
  (`moon test --enable-coverage` + `moon coverage report`).

## Comparison with alternatives

| | Mutex/locks | Channels | This STM |
|---|---|---|---|
| Atomic multi-variable update | manual, deadlock-prone | n/a | one `atomically` block |
| Blocking composes | no (deadlock on nested acquire) | partially | `retry` + `or_else` |
| Missed wake-ups | possible (manual cond vars) | no | no (version-driven) |
| Body may re-run | no | no | yes (keep side effects out) |
| Works across backends | yes | yes | yes (core is dependency-free) |

## FAQ

**Can the body do I/O?** Only idempotent I/O — the body may re-run on
conflict or retry. Prefer doing I/O outside, then commit results in a short
transaction.

**Why does my counter never advance inside a blocking transaction?** See
the barrier pattern above: a retried attempt rolls back its writes. Commit
the effect and wait in separate transactions.

**How do I catch "it blocked" from sync `atomically`?** `catch { err => if
@transaction.is_retry(err) ... }` — the abstract `raise` cannot be pattern
matched with constructors.

**Is this a port of GHC's STM?** No. The semantics (retry/orElse, blocking
on the read set) follow the published STM literature; the implementation is
original MoonBit, structured after the TL2 algorithm family.

**Roadmap?** Per-variable wakeups (no thundering herd), a two-list queue
representation, TArray/TMap helper combinators.

## References and acknowledgements

Design and semantics draw on the published STM literature — no code was
ported:

- Tim Harris, Simon Marlow, Simon Peyton Jones, Maurice Herlihy,
  *Composable Memory Transactions* (PPoPP 2005) — `retry`/`orElse`
  semantics.
- Tim Harris, Keir Fraser, *Language Support for Lightweight Transactions*
  (OOPSLA 2003).
- Dave Dice, Ori Shalev, Nir Shavit, *Transactional Locking II* (DISC 2006)
  — the global-clock validation layout.

License: Apache-2.0. Design references are cited for credit; this
implementation is original and compatible with the referenced works'
licenses.
