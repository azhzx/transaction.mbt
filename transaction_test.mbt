// Blackbox tests for the public API of `azhzx/transaction`.
// They only use the package as an external user would, via `@transaction`.

///|
test "atomically commits all writes together" {
  let a = @transaction.TVar::new(1)
  let b = @transaction.TVar::new(2)
  @transaction.atomically(txn => {
    txn.write(a, 10)
    txn.write(b, 20)
  })
  inspect(a.peek(), content="10")
  inspect(b.peek(), content="20")
}

///|
test "atomically discards writes when the body raises" {
  let cell = @transaction.TVar::new(1)
  try
    @transaction.atomically(txn => {
      txn.write(cell, 99)
      (fail("boom") : Int32)
    })
  catch {
    err => {
      assert_true(!@transaction.is_retry(err))
      assert_true(!@transaction.is_conflict(err))
    }
  } noraise {
    _ => fail("expected the body error to propagate")
  }
  inspect(cell.peek(), content="1")
}

///|
test "atomically sees its own writes" {
  let cell = @transaction.TVar::new(0)
  let seen = @transaction.atomically(txn => {
    txn.write(cell, 7)
    txn.read(cell)
  })
  inspect(seen, content="7")
}

///|
test "writing the same tvar twice keeps only the last value" {
  let cell = @transaction.TVar::new(0)
  @transaction.atomically(txn => {
    txn.write(cell, 1)
    txn.write(cell, 2)
  })
  inspect(cell.peek(), content="2")
}

///|
test "atomically restarts the body automatically on conflict" {
  let cell = @transaction.TVar::new(0)
  let attempts = Ref(0)
  let result = @transaction.atomically(txn => {
    attempts.val = attempts.val + 1
    let current = txn.read(cell)
    if current == 0 {
      // Committing a nested transaction invalidates the outer snapshot.
      @transaction.atomically(t => t.write(cell, 10))
    }
    txn.read(cell)
  })
  inspect(result, content="10")
  inspect(attempts.val, content="2")
}

///|
test "retry propagates out of atomically without applying writes" {
  let cell = @transaction.TVar::new(5)
  try
    @transaction.atomically(txn => {
      txn.write(cell, 6)
      txn.check(false)
    })
  catch {
    err => assert_true(@transaction.is_retry(err))
  } noraise {
    _ => fail("expected Retry to propagate")
  }
  inspect(cell.peek(), content="5")
}

///|
test "read-only transactions keep the commit version" {
  let cell = @transaction.TVar::new(1)
  let before = @transaction.commit_version()
  @transaction.atomically(txn => ignore(txn.read(cell)))
  inspect(@transaction.commit_version() - before, content="0")
}

///|
test "write transactions advance the commit version once" {
  let cell = @transaction.TVar::new(1)
  let before = @transaction.commit_version()
  @transaction.atomically(txn => txn.write(cell, 2))
  inspect(@transaction.commit_version() - before, content="1")
}

///|
test "on_commit listeners run after each write commit" {
  let cell = @transaction.TVar::new(0)
  let fired = Ref(0)
  @transaction.on_commit(() => fired.val = fired.val + 1)
  @transaction.atomically(txn => txn.write(cell, 1))
  inspect(fired.val, content="1")
  @transaction.atomically(txn => txn.write(cell, 2))
  inspect(fired.val, content="2")
}

///|
test "uncommitted writes stay invisible to other transactions" {
  let cell = @transaction.TVar::new(0)
  let txn = @transaction.Txn::begin()
  txn.write(cell, 42)
  let seen = @transaction.atomically(t => t.read(cell))
  inspect(seen, content="0")
  txn.run(_ => ())
  inspect(cell.peek(), content="42")
}

///|
test "modify reads, applies, and writes back" {
  let cell = @transaction.TVar::new(20)
  @transaction.atomically(txn => txn.modify(cell, x => x * 2 + 1))
  inspect(cell.peek(), content="41")
}

///|
test "or_else runs the second branch when the first retries" {
  let empty = @transaction.TMVar::new()
  let picked = @transaction.atomically(txn => {
    txn.or_else(t => empty.take(t), _ => "fallback")
  })
  inspect(picked, content="fallback")
}

///|
test "or_else keeps the first branch result when it succeeds" {
  let full = @transaction.TMVar::full("first")
  let second_ran = Ref(false)
  let picked = @transaction.atomically(txn => {
    txn.or_else(t => full.take(t), _ => {
      second_ran.val = true
      "second"
    })
  })
  inspect(picked, content="first")
  inspect(second_ran.val, content="false")
}

///|
test "or_else discards the first branch writes before running second" {
  let cell = @transaction.TVar::new(0)
  let result = @transaction.atomically(txn => {
    txn.or_else(
      t => {
        t.write(cell, 1)
        t.retry()
      },
      t => {
        let committed = t.read(cell)
        t.write(cell, committed + 5)
        committed
      },
    )
  })
  inspect(result, content="0")
  inspect(cell.peek(), content="5")
}

///|
test "or_else propagates errors other than retry" {
  let cell = @transaction.TVar::new(0)
  let second_ran = Ref(false)
  try
    @transaction.atomically(txn => {
      txn.or_else(_ => fail("first failed"), _ => {
        second_ran.val = true
        "second"
      })
    })
  catch {
    err => assert_true(!@transaction.is_retry(err))
  } noraise {
    _ => fail("expected the first branch error to propagate")
  }
  inspect(second_ran.val, content="false")
  inspect(cell.peek(), content="0")
}

///|
test "tvar equality and hashing follow identity" {
  let a = @transaction.TVar::new(1)
  let b = @transaction.TVar::new(1)
  assert_true(a == a)
  assert_true(a != b)
  let by_key : Map[@transaction.TVar[Int32], String] = Map([])
  by_key[a] = "a"
  by_key[b] = "b"
  inspect(by_key[a], content="a")
  inspect(by_key.length(), content="2")
}

///|
test "tmvar put and take round-trip" {
  let box = @transaction.TMVar::new()
  @transaction.atomically(txn => box.put(txn, "payload"))
  let taken = @transaction.atomically(txn => box.take(txn))
  inspect(taken, content="payload")
  assert_true(box.peek() is None)
}

///|
test "tmvar take retries while empty" {
  let box : @transaction.TMVar[Int32] = @transaction.TMVar::new()
  try @transaction.atomically(txn => box.take(txn)) catch {
    err => assert_true(@transaction.is_retry(err))
  } noraise {
    _ => fail("expected Retry to propagate")
  }
  assert_true(box.peek() is None)
}

///|
test "tmvar put retries while full" {
  let box = @transaction.TMVar::full("one")
  try @transaction.atomically(txn => box.put(txn, "two")) catch {
    err => assert_true(@transaction.is_retry(err))
  } noraise {
    _ => fail("expected Retry to propagate")
  }
  assert_true(box.peek() is Some("one"))
}

///|
test "tmvar non-blocking variants" {
  let box = @transaction.TMVar::new()
  let txn = @transaction.Txn::begin()
  assert_true(txn.run(_ => box.try_put(txn, 1)) is true)
  assert_true(txn.run(_ => box.try_put(txn, 2)) is false)
  assert_true(txn.run(_ => box.try_take(txn)) is Some(1))
  assert_true(txn.run(_ => box.try_take(txn)) is None)
  inspect(txn.run(_ => box.is_empty(txn)), content="true")
}

///|
test "tqueue preserves FIFO order" {
  let queue = @transaction.TQueue::new()
  @transaction.atomically(txn => {
    queue.push(txn, "a")
    queue.push(txn, "b")
    queue.push(txn, "c")
  })
  let a = @transaction.atomically(t => queue.pop(t))
  let b = @transaction.atomically(t => queue.pop(t))
  let c = @transaction.atomically(t => queue.pop(t))
  inspect(a + b + c, content="abc")
}

///|
test "tqueue pop retries while empty" {
  let queue : @transaction.TQueue[Int32] = @transaction.TQueue::new()
  try @transaction.atomically(t => queue.pop(t)) catch {
    err => assert_true(@transaction.is_retry(err))
  } noraise {
    _ => fail("expected Retry to propagate")
  }
}

///|
test "tqueue non-blocking reads and writes" {
  let queue = @transaction.TQueue::new()
  let txn = @transaction.Txn::begin()
  txn.run(t => {
    queue.push(t, 1)
    queue.push(t, 2)
  })
  inspect(@transaction.atomically(t => queue.length(t)), content="2")
  assert_true(@transaction.atomically(t => queue.peek(t)) is Some(1))
  assert_true(@transaction.atomically(t => queue.try_pop(t)) is Some(1))
  assert_true(@transaction.atomically(t => queue.try_pop(t)) is Some(2))
  assert_true(@transaction.atomically(t => queue.try_pop(t)) is None)
  assert_true(@transaction.atomically(t => queue.peek(t)) is None)
  inspect(@transaction.atomically(t => queue.is_empty(t)), content="true")
}

///|
test "committed arrays are never mutated in place" {
  let cell = @transaction.TVar::new([1])
  let snapshot = @transaction.atomically(t => t.read(cell))
  @transaction.atomically(t => {
    t.write(
      cell,
      {
        let grown = snapshot.copy()
        grown.push(2)
        grown
      },
    )
  })
  debug_inspect(snapshot, content="[1]")
  debug_inspect(cell.peek(), content="[1, 2]")
}

///|
test "manual rollback discards buffered writes and frees the handle" {
  let a = @transaction.TVar::new(1)
  let b = @transaction.TVar::new(2)
  let txn = @transaction.Txn::begin()
  txn.write(a, 100)
  txn.write(b, 200)
  txn.rollback()
  inspect(a.peek(), content="1")
  inspect(b.peek(), content="2")
  txn.run(t => {
    t.write(a, 10)
    t.write(b, 20)
  })
  inspect(a.peek(), content="10")
  inspect(b.peek(), content="20")
}

///|
test "manual commit applies buffered writes atomically" {
  let a = @transaction.TVar::new(0)
  let b = @transaction.TVar::new(0)
  let before = @transaction.commit_version()
  let txn = @transaction.Txn::begin()
  txn.write(a, 1)
  txn.write(b, 2)
  txn.commit()
  inspect(a.peek(), content="1")
  inspect(b.peek(), content="2")
  inspect(@transaction.commit_version() - before, content="1")
}

///|
test "manual commit conflicts and rolls back after a foreign commit" {
  let cell = @transaction.TVar::new(0)
  let txn = @transaction.Txn::begin()
  txn.write(cell, 1)
  // A foreign transaction commits the same variable while ours is in flight.
  @transaction.atomically(t => t.write(cell, 5))
  try txn.commit() catch {
    err => assert_true(@transaction.is_conflict(err))
  } noraise {
    _ => fail("expected the stale commit to conflict")
  }
  // The conflicting attempt was rolled back; the foreign value stands.
  inspect(cell.peek(), content="5")
  // And the handle still works afterwards.
  txn.run(t => t.write(cell, 9))
  inspect(cell.peek(), content="9")
}

///|
test "or_else keeps writes made before the branch point" {
  let cell = @transaction.TVar::new(7)
  let observed = @transaction.atomically(txn => {
    txn.write(cell, 10)
    txn.or_else(
      t => {
        t.write(cell, 20)
        (t.retry() : Int32)
      },
      t => t.read(cell),
    )
  })
  inspect(observed, content="10")
  inspect(cell.peek(), content="10")
}

///|
test "or_else retry does not lose the outer write or skip the commit" {
  let cell = @transaction.TVar::new(7)
  let before = @transaction.commit_version()
  @transaction.atomically(txn => {
    txn.write(cell, 10)
    txn.or_else(
      t => {
        t.write(cell, 20)
        (t.retry() : Unit)
      },
      _ => (),
    )
  })
  inspect(cell.peek(), content="10")
  inspect(@transaction.commit_version() - before, content="1")
}

///|
test "reusing a committed handle does not bump the commit clock" {
  let cell = @transaction.TVar::new(0)
  let txn = @transaction.Txn::begin()
  txn.run(t => t.write(cell, 1))
  let v1 = @transaction.commit_version()
  txn.run(_ => ())
  inspect(@transaction.commit_version() - v1, content="0")
}
