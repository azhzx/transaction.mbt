// Whitebox tests for the internals of `azhzx/transaction`:
// the pending write set, version numbers, and rollback log marks.

///|
test "writes land in the pending set until commit" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  txn.write(tv, 9)
  assert_true(tv.pending.get(txn.id) is Some(9))
  inspect(tv.value, content="0")
  inspect(tv.version, content="0")
}

///|
test "commit applies the pending value and bumps the version" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  txn.write(tv, 9)
  txn.run(_ => ())
  assert_true(tv.pending.get(txn.id) is None)
  inspect(tv.value, content="9")
  inspect(tv.version, content="1")
}

///|
test "rollback removes pending entries" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  txn.write(tv, 9)
  try
    txn.run(t => {
      t.write(tv, 99)
      (fail("boom") : Int)
    })
  catch {
    err => {
      assert_true(!is_retry(err))
      assert_true(!is_conflict(err))
    }
  } noraise {
    _ => fail("expected the body error to propagate")
  }
  assert_true(tv.pending.get(txn.id) is None)
  inspect(tv.value, content="0")
}

///|
test "two writes to one tvar commit as one version bump" {
  let tv = TVar::new(0)
  let before = commit_version()
  atomically(txn => {
    txn.write(tv, 1)
    txn.write(tv, 2)
  })
  inspect(tv.value, content="2")
  inspect(tv.version, content="1")
  inspect(commit_version() - before, content="1")
}

///|
test "pending sets of concurrent transactions coexist" {
  let tv = TVar::new(0)
  let first = Txn::begin()
  let second = Txn::begin()
  first.write(tv, 1)
  second.write(tv, 2)
  assert_true(tv.pending.get(first.id) is Some(1))
  assert_true(tv.pending.get(second.id) is Some(2))
  first.run(_ => ())
  inspect(tv.value, content="1")
  // The second transaction's snapshot is stale now: commit detects the
  // conflict, rolls back, and the pending entry disappears.
  try second.run(_ => ()) catch {
    err => assert_true(is_conflict(err))
  } noraise {
    _ => fail("expected the stale transaction to conflict")
  }
  assert_true(tv.pending.get(second.id) is None)
  inspect(tv.value, content="1")
  // A fresh transaction that re-reads the variable commits cleanly.
  let third = Txn::begin()
  third.run(t => t.write(tv, t.read(tv) + 10))
  inspect(tv.value, content="11")
  inspect(tv.version, content="2")
}

///|
test "reads of committed tvars conflict after a foreign commit" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  ignore(txn.read(tv))
  atomically(t => t.write(tv, 1))
  try txn.read(tv) catch {
    Conflict(_) => ()
  } noraise {
    _ => fail("expected the stale read to conflict")
  }
}

///|
test "or_else truncates the logs back to the branch point" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  ignore(
    txn.or_else(
      t => {
        t.write(tv, 1)
        t.retry()
      },
      t => {
        t.write(tv, 2)
        t.read(tv)
      },
    ),
  )
  inspect(txn.undo.length(), content="1")
  inspect(txn.commits.length(), content="1")
  txn.run(_ => ())
  inspect(tv.value, content="2")
}

///|
test "undo actions clear pending entries for every tvar" {
  let a = TVar::new(0)
  let b = TVar::new(0)
  let txn = Txn::begin()
  txn.write(a, 1)
  txn.write(b, 2)
  txn.rollback()
  assert_true(a.pending.get(txn.id) is None)
  assert_true(b.pending.get(txn.id) is None)
  inspect(a.value, content="0")
  inspect(b.value, content="0")
}

///|
test "begin records the current commit clock" {
  let tv = TVar::new(0)
  atomically(txn => txn.write(tv, 1))
  let txn = Txn::begin()
  inspect(txn.validated_at == commit_version(), content="true")
}

///|
test "revalidate refreshes the clock after foreign commits" {
  let mine = TVar::new(0)
  let other = TVar::new(0)
  let txn = Txn::begin()
  ignore(txn.read(mine)) // records a validator at the initial version
  atomically(txn => txn.write(other, 1)) // clock bumps, `mine` untouched
  ignore(txn.read(mine)) // validators pass, so the read succeeds
  inspect(txn.validated_at == commit_version(), content="true")
}

///|
test "pending sets never leak across many transactions" {
  let tv = TVar::new(0)
  let mut s = 21
  for t in 0..<100 {
    let txn = Txn::begin()
    txn.write(tv, t)
    s = (s * 3 + t) % 997
    if s % 2 == 0 {
      txn.run(_ => ())
    } else {
      txn.rollback()
    }
  }
  inspect(tv.pending.length(), content="0")
}

///|
test "commit listeners observe post-commit state" {
  let tv = TVar::new(0)
  let seen = Ref(-1)
  on_commit(() => seen.val = tv.peek())
  atomically(txn => txn.write(tv, 5))
  inspect(seen.val, content="5")
}

///|
test "nested or_else keeps every branch point isolated" {
  let tv = TVar::new(0)
  let txn = Txn::begin()
  ignore(
    txn.or_else(
      t => {
        t.or_else(
          t2 => {
            t2.write(tv, 1)
            t2.retry()
          },
          t2 => {
            t2.write(tv, 2)
            t2.retry()
          },
        )
      },
      t => {
        t.write(tv, 3)
        t.read(tv)
      },
    ),
  )
  // Only the outer second branch survives: its pending value and one log
  // entry each, everything from the inner branches was rolled back.
  assert_true(tv.pending.get(txn.id) is Some(3))
  inspect(txn.undo.length(), content="1")
  inspect(txn.commits.length(), content="1")
  txn.run(_ => ())
  inspect(tv.value, content="3")
}

///|
test "error predicates discriminate" {
  assert_true(is_retry(Retry(1)))
  assert_true(is_conflict(Conflict(1)))
  assert_false(is_retry(Conflict(1)))
  assert_false(is_conflict(Retry(1)))
  assert_false(is_retry(Failure("x")))
}
