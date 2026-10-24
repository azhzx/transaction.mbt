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
    _ => ()
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
