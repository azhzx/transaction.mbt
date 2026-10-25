// Integration scenarios for the core package, exercised exactly the way an
// external user would: only public API, realistic small patterns
// (allocators, latches, bulk moves, booking) instead of primitive features.

///|
/// Deterministic pseudo-random value in `0..16383`; see the core package's
/// `stress_test.mbt` for the rationale.
fn pseudo(seed : Int, salt : Int) -> Int {
  let mut x = ((seed & 0x7FFF) * 11549 + (salt & 0x7FFF) * 7887 + 12345) &
    0x7FFF
  x = x ^ (x >> 7)
  x = (x * 49297) & 0x7FFF
  x = x ^ (x >> 4)
  x
}

///|
/// A user-defined error, to prove body errors keep their identity through
/// `atomically` even though its `raise` is abstract.
suberror PlannedFailure {
  PlannedFailure(String)
}

///|
fn is_planned_failure(err : Error) -> Bool {
  err is PlannedFailure(_)
}

///|
fn planned_message(err : Error) -> String? {
  if err is PlannedFailure(message) {
    Some(message)
  } else {
    None
  }
}

///|
/// Raise the user error with a `Unit` result type, so transaction bodies can
/// end with it without leaving the result type unresolved.
fn planned_raise(message~ : String) -> Unit raise {
  raise PlannedFailure(message)
}

///|
test "id allocator never repeats" {
  let next = @transaction.TVar::new(0)
  let seen : Map[Int, Unit] = Map([])
  for _ in 0..<300 {
    let id = @transaction.atomically(txn => {
      let current = txn.read(next)
      txn.write(next, current + 1)
      current
    })
    seen[id] = ()
  }
  inspect(seen.length(), content="300")
  inspect(next.peek(), content="300")
}

///|
test "copy-on-write config keeps old snapshots intact" {
  let config = @transaction.TVar::new({ "retries": 3, "timeout": 30 })
  let snapshot = @transaction.atomically(txn => txn.read(config))
  @transaction.atomically(txn => {
    let current = txn.read(config)
    txn.write(config, {
      "retries": current["retries"] + 1,
      "timeout": current["timeout"],
      "extra": 1,
    })
  })
  inspect(snapshot["retries"], content="3")
  inspect(snapshot.length(), content="2")
  inspect(config.peek()["retries"], content="4")
  inspect(config.peek().length(), content="3")
}

///|
test "ticket booking sells exactly the available seats" {
  let seats = @transaction.TVar::new(10)
  let mut sold = 0
  for _ in 0..<25 {
    let bought = @transaction.atomically(txn => {
      txn.check(txn.read(seats) > 0)
      txn.modify(seats, s => s - 1)
      true
    }) catch {
      err => {
        assert_true(@transaction.is_retry(err))
        false
      }
    }
    if bought {
      sold = sold + 1
    }
  }
  inspect(sold, content="10")
  inspect(seats.peek(), content="0")
}

///|
test "bulk queue transfer is atomic" {
  let inbox : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let archive : @transaction.TQueue[Int] = @transaction.TQueue::new()
  for i in 1..<=50 {
    @transaction.atomically(txn => inbox.push(txn, i))
  }
  // One transaction moves the whole inbox, reading its own writes as it goes.
  @transaction.atomically(txn => {
    let count = inbox.length(txn)
    for _ in 0..<count {
      let v = inbox.pop(txn)
      archive.push(txn, v)
    }
  })
  inspect(@transaction.atomically(txn => inbox.length(txn)), content="0")
  inspect(@transaction.atomically(txn => archive.length(txn)), content="50")
  inspect(@transaction.atomically(txn => archive.pop(txn)), content="1")
  inspect(
    @transaction.atomically(txn => archive.peek(txn)) is Some(2),
    content="true",
  )
}

///|
test "countdown latch opens exactly at zero" {
  let remaining = @transaction.TVar::new(5)
  for _ in 0..<3 {
    @transaction.atomically(txn => txn.modify(remaining, v => v - 1))
  }
  let early = @transaction.atomically(txn => {
    txn.check(txn.read(remaining) == 0)
    true
  }) catch {
    err => {
      assert_true(@transaction.is_retry(err))
      false
    }
  }
  inspect(early, content="false")
  for _ in 0..<2 {
    @transaction.atomically(txn => txn.modify(remaining, v => v - 1))
  }
  let opened = @transaction.atomically(txn => {
    txn.check(txn.read(remaining) == 0)
    true
  }) catch {
    _ => false
  }
  inspect(opened, content="true")
}

///|
test "or_else chains pick the only ready source" {
  let a : @transaction.TMVar[String] = @transaction.TMVar::new()
  let b : @transaction.TMVar[String] = @transaction.TMVar::new()
  let c = @transaction.TMVar::full("c")
  let picked = @transaction.atomically(txn => {
    txn.or_else(t => a.take(t), t => {
      t.or_else(t2 => b.take(t2), t2 => c.take(t2))
    })
  })
  inspect(picked, content="c")
  // Now fill the middle source; the chain must pick it over the last one.
  let a2 : @transaction.TMVar[String] = @transaction.TMVar::new()
  let b2 = @transaction.TMVar::full("b")
  let c2 = @transaction.TMVar::full("c")
  let picked2 = @transaction.atomically(txn => {
    txn.or_else(t => a2.take(t), t => {
      t.or_else(t2 => b2.take(t2), t2 => c2.take(t2))
    })
  })
  inspect(picked2, content="b")
  assert_true(c2.peek() is Some("c"))
}

///|
test "body errors keep their identity" {
  let cell = @transaction.TVar::new(0)
  try
    @transaction.atomically(txn => {
      txn.write(cell, 9)
      planned_raise(message="nope")
    })
  catch {
    err => {
      assert_true(is_planned_failure(err))
      assert_true(planned_message(err) is Some("nope"))
      assert_false(@transaction.is_retry(err))
    }
  } noraise {
    _ => fail("expected the body error to propagate")
  }
  inspect(cell.peek(), content="0")
}

///|
test "peek only ever shows committed values" {
  let cell = @transaction.TVar::new(7)
  let mut model = 7
  for i in 0..<50 {
    let commits = i % 2 == 1
    @transaction.atomically(txn => {
      txn.write(cell, i)
      if !commits {
        (fail("planned rollback") : Unit)
      }
    }) catch {
      err => {
        assert_true(!@transaction.is_retry(err))
        assert_true(!@transaction.is_conflict(err))
      }
    }
    if commits {
      model = i
    }
    if cell.peek() != model {
      fail("peek showed an uncommitted value at iteration \{i}")
    }
  }
  inspect(cell.peek(), content="49")
}

///|
test "guarded permits never go negative" {
  let permits = @transaction.TVar::new(5)
  let mut s = 4
  for step in 0..<200 {
    s = pseudo(s, step)
    let amount = s % 3
    let acquired = @transaction.atomically(txn => {
      let p = txn.read(permits)
      txn.check(p >= amount)
      txn.write(permits, p - amount)
      true
    }) catch {
      err => {
        assert_true(@transaction.is_retry(err))
        false
      }
    }
    assert_true(permits.peek() >= 0)
    if acquired {
      @transaction.atomically(txn => txn.modify(permits, v => v + amount))
    }
  }
  inspect(permits.peek(), content="5")
}
