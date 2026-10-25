// Heavier chaos stress beyond stress_test.mbt: mixed operation types at
// large volume, deep or_else chains, very wide transactions, and
// rollback-heavy churn. Still deterministic (seeded pseudo-random chains,
// via `pseudo` from stress_test.mbt — all *_test.mbt files share one scope).

///|
test "chaos: mixed operations at volume match a sequential model" {
  let cell = @transaction.TVar::new(1000)
  let mut model = 1000
  let mut s = 3
  for op in 0..<5000 {
    s = pseudo(s, op)
    match s % 5 {
      0 => @transaction.atomically(txn => txn.write(cell, model))
      1 => {
        let seen = @transaction.atomically(txn => txn.read(cell))
        if seen != model {
          fail("model divergence at op \{op}")
        }
      }
      2 => {
        let delta = s % 100
        model = model + delta
        @transaction.atomically(txn => txn.modify(cell, v => v + delta))
      }
      3 =>
        // Write then fail: the whole attempt must roll back.
        @transaction.atomically(txn => {
          txn.write(cell, model + 12345)
          (fail("planned") : Unit)
        }) catch {
          err => {
            assert_true(!@transaction.is_retry(err))
            assert_true(!@transaction.is_conflict(err))
          }
        }
      _ => {
        // or_else with a full fallback source.
        let box = @transaction.TMVar::full(s)
        let picked : Int32 = @transaction.atomically(txn => {
          txn.or_else(t => t.retry(), t => box.take(t))
        })
        if picked != s {
          fail("or_else picked \{picked}, expected \{s}")
        }
      }
    }
    if op % 500 == 0 && cell.peek() != model {
      fail("invariant broken at op \{op}")
    }
  }
  inspect(cell.peek() == model, content="true")
}

///|
test "deep or_else chains stay correct at every depth" {
  let depth = 8
  for ready in 0..<depth {
    // `ready`-th cell full, all others empty; the chain must reach it.
    let cells : Array[@transaction.TMVar[Int32]] = []
    for i in 0..<depth {
      let cell = @transaction.TMVar::new()
      if i == ready {
        @transaction.atomically(txn => cell.put(txn, i * 7))
      }
      cells.push(cell)
    }
    let picked = @transaction.atomically(txn => {
      // Fold the cells into one right-nested or_else chain.
      fn go(i : Int32) -> Int32 raise {
        if i >= cells.length() {
          txn.retry()
        } else {
          txn.or_else(t => cells[i].take(t), _ => go(i + 1))
        }
      }
      go(0)
    })
    inspect(picked == ready * 7, content="true")
  }
}

///|
test "thousand-tvar transactions are all-or-nothing" {
  let n = 1000
  let tvs : Array[@transaction.TVar[Int32]] = []
  for _ in 0..<n {
    tvs.push(@transaction.TVar::new(0))
  }
  // Committing version: every variable advances together.
  @transaction.atomically(txn => {
    for tv in tvs {
      txn.write(tv, 1)
    }
  })
  // Failing version in the same shape: nothing changes.
  @transaction.atomically(txn => {
    for tv in tvs {
      txn.write(tv, 2)
    }
    fail("planned")
  }) catch {
    err => {
      assert_true(!@transaction.is_retry(err))
      assert_true(!@transaction.is_conflict(err))
    }
  }
  let mut ones = 0
  let mut others = 0
  for tv in tvs {
    if tv.peek() == 1 {
      ones = ones + 1
    } else {
      others = others + 1
    }
  }
  inspect(ones, content="1000")
  inspect(others, content="0")
}

///|
test "rollback-heavy churn keeps state stable" {
  let cell = @transaction.TVar::new(42)
  for t in 0..<2000 {
    @transaction.atomically(txn => {
      txn.write(cell, t)
      txn.check(false)
    }) catch {
      err => assert_true(@transaction.is_retry(err))
    }
    if cell.peek() != 42 {
      fail("rollback leaked a write at iteration \{t}")
    }
  }
  // State remains usable afterwards.
  @transaction.atomically(txn => txn.modify(cell, v => v + 1))
  inspect(cell.peek(), content="43")
}

///|
test "interleaved live handles commit and rollback independently" {
  let n = 50
  let tvs : Array[@transaction.TVar[Int32]] = []
  for _ in 0..<n {
    tvs.push(@transaction.TVar::new(-1))
  }
  let handles : Array[@transaction.Txn] = []
  for i in 0..<n {
    let txn = @transaction.Txn::begin()
    txn.write(tvs[i], i)
    handles.push(txn)
  }
  // No transaction has committed yet: every variable still holds -1.
  for tv in tvs {
    assert_true(tv.peek() == -1)
  }
  let mut s = 77
  for i in 0..<n {
    s = pseudo(s, i)
    if s % 2 == 0 {
      handles[i].commit()
    } else {
      handles[i].rollback()
    }
    if s % 2 == 0 {
      assert_true(tvs[i].peek() == i)
    } else {
      assert_true(tvs[i].peek() == -1)
    }
  }
}
