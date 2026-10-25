# azhzx/transaction

[![CI](https://github.com/azhzx/transaction.mbt/actions/workflows/ci.yml/badge.svg)](https://github.com/azhzx/transaction.mbt/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

Software Transactional Memory (STM) for [MoonBit](https://moonbitlang.com):
shared `TVar`s updated by atomic, composable transactions, with blocking that
composes (`retry` / `or_else`) instead of deadlocking.

**Documentation:** [English manual](doc/en.md) · [中文手册](doc/zh.md)

```mbt check
///|
test "atomic transfer between accounts" {
  let alice = @transaction.TVar::new(100)
  let bob = @transaction.TVar::new(20)
  @transaction.atomically(txn => {
    let funds = txn.read(alice)
    txn.check(funds >= 30) // block (retry) while funds are short
    txn.write(alice, funds - 30)
    txn.modify(bob, balance => balance + 30)
  })
  inspect(alice.peek(), content="70")
  inspect(bob.peek(), content="50")
}
```

## Why STM

Locks do not compose: acquiring two locks in different orders deadlocks, and
combining guarded operations into one atomic step requires exposing locks.
STM composes instead:

- **Atomicity** — every `atomically` block applies all of its `TVar` writes
  together or not at all.
- **Isolation** — a transaction body sees one consistent snapshot; uncommitted
  writes of other transactions are never visible.
- **Compositional blocking** — `txn.retry()` blocks the current task *until
  something it read changes*, and `txn.or_else(first, second)` combines two
  blocking operations into one that wakes when either can proceed. No
  condition variables, no deadlocks, no missed wake-ups.
- **Automatic restart** — if a read variable is committed by another
  transaction mid-body, the body is rolled back and re-run on a fresh
  snapshot. You write straight-line code; the runtime handles interference.

The classic trade-off applies: a transaction body may run more than once, so
keep side effects (I/O, logging) out of it or make them idempotent.

## Packages

| Package | Purpose | Depends on |
|---|---|---|
| `azhzx/transaction` | Core: `TVar`, `Txn`, `atomically`, `TMVar`, `TQueue` | nothing beyond core |
| `azhzx/transaction/runner` | `atomically_async`: transactions whose body may `await` | `moonbitlang/async` |

Backend support:

| Package | wasm | wasm-gc | js | native |
|---|---|---|---|---|
| core | ✓ | ✓ | ✓ | ✓ |
| runner | ✓ | — | ✓ | ✓ |

The core package stays dependency-free and checks on every backend. The
runner needs `moonbitlang/async`, whose current release has no wasm-gc entry
point; the affected packages declare `supported_targets` accordingly.

## Quick start

Install the module:

```sh
moon add azhzx/transaction
```

Then import the packages you need in `moon.pkg`:

```moonbit nocheck
///|
import {
  "azhzx/transaction",
  "azhzx/transaction/runner",
} // only if you need async transactions
```

Inside a transaction, `read` and `write` go through the `Txn` handle, never
the `TVar` directly. Outside, `peek` reads the last committed value without
starting a transaction:

```mbt check
///|
test "read, write, and peek" {
  let counter = @transaction.TVar::new(0)
  let doubled = @transaction.atomically(txn => {
    txn.modify(counter, x => x + 1)
    txn.read(counter) * 2
  })
  inspect(doubled, content="2")
  inspect(counter.peek(), content="1")
}
```

## Blocking and choice

`txn.check(cond)` retries until `cond` holds, and `txn.retry()` retries
unconditionally. Under the async runner the task *parks* (it does not spin)
and is woken by the next commit to a variable the transaction read:

```mbt check
///|
test "retry blocks the transaction, not the program" {
  let balance : @transaction.TVar[Int] = @transaction.TVar::new(0)
  try
    @transaction.atomically(txn => {
      txn.check(txn.read(balance) >= 10)
      txn.modify(balance, x => x - 10)
    })
  catch {
    err => assert_true(@transaction.is_retry(err))
  } noraise {
    _ => fail("expected the transaction to block")
  }
  inspect(balance.peek(), content="0")
}
```

`or_else` composes alternatives: take from either mailbox, in one atomic
step, without polling:

```mbt check
///|
test "or_else tries the first branch, then the second" {
  let urgent : @transaction.TMVar[String] = @transaction.TMVar::new()
  let regular = @transaction.TMVar::full("regular-mail")
  let message = @transaction.atomically(txn => {
    txn.or_else(t => urgent.take(t), t => regular.take(t))
  })
  inspect(message, content="regular-mail")
}
```

Synchronous `atomically` propagates `Retry` to the caller (it cannot park —
see `is_retry` above). To block the current task instead, use the async
runner:

```mbt nocheck
///|
async test "consumer parks until a producer commits" {
  let jobs : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let received = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      received.val = @runner.atomically_async(txn => jobs.pop(txn))
    })
    @runner.atomically_async(txn => jobs.push(txn, 42))
  })
  inspect(received.val, content="42")
}
```

The body may also `await` freely: uncommitted writes stay private to the
transaction, and the snapshot is re-validated after every suspension.

## Ready-made structures

Built from `TVar` and the same four primitives, usable from any transaction:

- **`TMVar[T]`** — empty-or-full one-slot cell. `take` retries while empty,
  `put` retries while full: a transactional meeting point.
- **`TQueue[T]`** — transactional FIFO queue. `pop` retries while empty;
  `push`, `try_pop`, `peek`, `length`, `is_empty` round it out.

```mbt check
///|
test "queue hands work to a consumer in FIFO order" {
  let jobs = @transaction.TQueue::new()
  @transaction.atomically(txn => {
    jobs.push(txn, "first")
    jobs.push(txn, "second")
  })
  inspect(@transaction.atomically(t => jobs.pop(t)), content="first")
  inspect(
    @transaction.atomically(t => jobs.try_pop(t)) is Some("second"),
    content="true",
  )
}
```

## Semantics

- **Values must be immutable.** For `Array`/`Map` values, build a fresh copy
  (`items.copy()` then mutate the copy) and write it back; never mutate a
  value obtained from `txn.read`.
- **A body may re-run.** `Retry`, `Conflict`, and validation failures restart
  the body with a fresh transaction. Side effects are not rolled back.
- **Errors propagate.** Any error raised by the body rolls back the writes
  and reaches the caller unchanged; `is_retry` distinguishes blocking from
  failure.
- **Transactions do not nest.** An `atomically` call inside a transaction
  body runs and commits independently; if it invalidates the outer
  snapshot, the outer transaction restarts automatically.
- **Commit ordering.** A global commit clock plus per-`TVar` versions detect
  stale snapshots in O(read set). Validation and commit happen in one
  synchronous section, so no interleaving can slip between them.

## Concurrency model

MoonBit tasks are cooperatively scheduled on a single-threaded event loop, so
any number of tasks can share `TVar`s with no data races — this library is
designed for that world. True parallel threads are not exposed by the
toolchain today; if a shared-memory backend arrives, the design (global
version clock, read-set validation, private write sets — a TL2-style layout)
ports by wrapping the validation/commit section in a lock.

## Development

```sh
moon test                            # wasm (default) — includes README and docstring tests
moon test --target native            # native backend
moon bench --target native --release # benchmark suite (see doc/en.md)
moon run examples/showcase           # runnable example (see below)
moon info && moon fmt                # refresh .mbti interfaces and format
```

Tests live in four layers: docstring/README doctests, unit tests (`*_test.mbt`,
`*_wbtest.mbt` next to each package), randomized stress suites with
deterministic seeds (`stress_test.mbt`, `chaos_stress_test.mbt`, and their
runner counterparts), and integration scenarios (`tests/`). A benchmark
suite (`transaction_bench_test.mbt`) measures the core transaction paths.
CI runs check, build, both test targets, the example program, coverage, and
benchmarks on every push and pull request.

### Runnable example

`examples/showcase` is a self-contained showcase (atomic transfer + a
blocking producer/consumer pipeline):

```sh
moon run examples/showcase               # wasm
moon run examples/showcase --target native
```

Output:

```text
after transfer: alice=70, bob=50
consumer received: [10, 20, 30]
```

## License

Apache-2.0. The STM semantics (retry/orElse, blocking on the read set) follow
the published research literature (see the
[manual](doc/en.md#references-and-acknowledgements)); the implementation is
original MoonBit code — nothing is ported from other projects.
