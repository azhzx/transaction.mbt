// Deterministic stress and model-equivalence tests for the core API.
//
// "Random" operation sequences come from `pseudo`, a fixed arithmetic chain,
// so every run exercises the same scenarios on every backend and failures are
// reproducible. Each test compares transactional execution against a plain
// sequential model or a global invariant that must survive the whole run.

///|
/// A deterministic pseudo-random value in `0..32767`. Chaining
/// `pseudo(pseudo(s, a), b)` yields reproducible streams; the xorshift-style
/// final mix decorrelates consecutive draws (a bare linear chain makes
/// `pseudo(s, t)` and `pseudo(s, t+1)` near-duplicates, which silently
/// narrows the scenarios a stress test visits). All intermediate products
/// stay far below `2^31`, so behavior is identical on every backend.
fn pseudo(seed : Int, salt : Int) -> Int {
  let mut x = ((seed & 0x7FFF) * 11549 + (salt & 0x7FFF) * 7887 + 12345) &
    0x7FFF
  x = x ^ (x >> 7)
  x = (x * 49297) & 0x7FFF
  x = x ^ (x >> 4)
  x
}

///|
test "bank stress: conservation and per-account correctness" {
  let accounts = 8
  let transfers = 400
  let balances : Array[@transaction.TVar[Int]] = []
  let model : Array[Int] = []
  let mut s = 7
  for i in 0..<accounts {
    let initial = 100 + i * 10
    balances.push(@transaction.TVar::new(initial))
    model.push(initial)
  }
  for t in 0..<transfers {
    s = pseudo(s, t)
    let from = s % accounts
    s = pseudo(s, t + 1)
    let to = s % accounts
    s = pseudo(s, t + 2)
    let amount = s % 50
    if from == to {
      continue
    }
    let moved = @transaction.atomically(txn => {
      let funds = txn.read(balances[from])
      if funds < amount {
        None
      } else {
        txn.write(balances[from], funds - amount)
        txn.modify(balances[to], balance => balance + amount)
        Some(amount)
      }
    })
    match moved {
      Some(a) => {
        model[from] = model[from] - a
        model[to] = model[to] + a
      }
      None => ()
    }
  }
  let mut total = 0
  for i in 0..<accounts {
    inspect(balances[i].peek() == model[i], content="true")
    total = total + model[i]
  }
  inspect(total, content="1080")
}

///|
test "random write sequences match a sequential model" {
  let cell = @transaction.TVar::new(0)
  let mut model = 0
  let mut s = 42
  for op in 0..<500 {
    s = pseudo(s, op)
    match s % 3 {
      0 => model = model + s
      1 => model = (model * 2 + s) % 1000003
      _ => model = model - s
    }
    @transaction.atomically(txn => txn.write(cell, model))
    if op % 10 == 0 {
      let seen = @transaction.atomically(txn => txn.read(cell))
      inspect(seen == model, content="true")
    }
  }
  inspect(cell.peek(), content="\{model}")
}

///|
test "multi-tvar transactions match a sequential model" {
  let vars = 6
  let tvs : Array[@transaction.TVar[Int]] = []
  let model : Array[Int] = []
  for _ in 0..<vars {
    tvs.push(@transaction.TVar::new(0))
    model.push(0)
  }
  let mut s = 99
  for t in 0..<300 {
    s = pseudo(s, t)
    let i = s % vars
    s = pseudo(s, t + 1)
    let j = s % vars
    @transaction.atomically(txn => {
      let vi = txn.read(tvs[i])
      let vj = txn.read(tvs[j])
      txn.write(tvs[i], vj + 1)
      txn.write(tvs[j], vi + 1)
    })
    let mi = model[i]
    model[i] = model[j] + 1
    model[j] = mi + 1
  }
  for i in 0..<vars {
    inspect(tvs[i].peek() == model[i], content="true")
  }
}

///|
test "or_else picks the branch the model expects" {
  let mut mismatches = 0
  for t in 0..<200 {
    let first_can_proceed = pseudo(t, 3) % 2 == 0
    let a : @transaction.TMVar[String] = @transaction.TMVar::new()
    if first_can_proceed {
      @transaction.atomically(txn => a.put(txn, "first"))
    }
    let picked = @transaction.atomically(txn => {
      txn.or_else(t => a.take(t), _ => "second")
    })
    let expected = if first_can_proceed { "first" } else { "second" }
    if picked != expected {
      mismatches = mismatches + 1
    }
  }
  inspect(mismatches, content="0")
}

///|
test "coupled accounts keep their sum invariant" {
  let x = @transaction.TVar::new(100)
  let y = @transaction.TVar::new(100)
  let z = @transaction.TVar::new(100)
  let mut s = 11
  for t in 0..<400 {
    s = pseudo(s, t)
    let which = s % 3
    s = pseudo(s, t + 1)
    let amount = s % 60
    @transaction.atomically(txn => {
      match which {
        0 => {
          txn.modify(x, v => v + amount)
          txn.modify(y, v => v - amount)
        }
        1 => {
          txn.modify(y, v => v + amount)
          txn.modify(z, v => v - amount)
        }
        _ => {
          txn.modify(z, v => v + amount)
          txn.modify(x, v => v - amount)
        }
      }
    })
    if x.peek() + y.peek() + z.peek() != 300 {
      fail("invariant broken at iteration \{t}")
    }
  }
  inspect(x.peek() + y.peek() + z.peek(), content="300")
}

///|
test "retry surfaces to synchronous callers and composes with loops" {
  let cell = @transaction.TVar::new(0)
  let attempts = Ref(0)
  let mut result = -1
  for _ in 0..<20 {
    attempts.val = attempts.val + 1
    let outcome = @transaction.atomically(txn => {
      let v = txn.read(cell)
      txn.check(v >= 10)
      v
    }) catch {
      err => {
        assert_true(@transaction.is_retry(err))
        // Simulate a foreign commit that eventually unblocks the check.
        @transaction.atomically(txn => txn.modify(cell, v => v + 1))
        -1
      }
    }
    if outcome >= 0 {
      result = outcome
      break
    }
  }
  inspect(result, content="10")
  inspect(attempts.val, content="11")
}

///|
test "commit clock advances exactly once per write transaction" {
  let cell = @transaction.TVar::new(0)
  let mut expected = @transaction.commit_version()
  for i in 0..<200 {
    if i % 3 == 0 {
      @transaction.atomically(txn => txn.write(cell, i))
      expected = expected + 1
    } else {
      ignore(@transaction.atomically(txn => txn.read(cell)))
    }
    // Exact, not just monotonic: read-only and empty transactions must
    // leave the clock untouched, writes must bump it exactly once.
    inspect(@transaction.commit_version() == expected, content="true")
  }
}

///|
test "randomized failures roll back every write" {
  let vars = 5
  let tvs : Array[@transaction.TVar[Int]] = []
  let model : Array[Int] = []
  for _ in 0..<vars {
    tvs.push(@transaction.TVar::new(0))
    model.push(0)
  }
  let mut s = 33
  for t in 1..<=300 {
    s = pseudo(s, t)
    let fail_at = s % (vars + 1) // == vars means "commit"
    let committed = Ref(true)
    @transaction.atomically(txn => {
      for i in 0..<vars {
        txn.write(tvs[i], t)
      }
      if fail_at < vars {
        fail("planned failure")
      }
    }) catch {
      err => {
        // A planned body failure must surface as a body error, never as a
        // misrouted Retry/Conflict from the STM machinery itself.
        assert_true(!@transaction.is_retry(err))
        assert_true(!@transaction.is_conflict(err))
        committed.val = false
      }
    }
    if fail_at < vars {
      assert_false(committed.val)
    } else {
      assert_true(committed.val)
      for i in 0..<vars {
        model[i] = t
      }
    }
  }
  for i in 0..<vars {
    inspect(tvs[i].peek() == model[i], content="true")
  }
}

///|
test "tvar identity holds at creation scale" {
  let created : Array[@transaction.TVar[Int]] = []
  let seen : Map[@transaction.TVar[Int], Int] = Map([])
  for i in 0..<300 {
    let tv = @transaction.TVar::new(i)
    created.push(tv)
    seen[tv] = i
  }
  inspect(seen.length(), content="300")
  for k = 0; k < 300; k = k + 37 {
    inspect(seen[created[k]], content="\{k}")
  }
}

///|
test "tqueue matches a sequential deque model" {
  let queue : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let model : Array[Int] = [] // front at index 0
  let mut head = 0
  let mut s = 5
  for t in 0..<400 {
    s = pseudo(s, t)
    if s % 2 == 0 {
      @transaction.atomically(txn => queue.push(txn, s))
      model.push(s)
    } else {
      let got = @transaction.atomically(txn => queue.try_pop(txn))
      match got {
        Some(v) => {
          assert_true(v == model[head])
          head = head + 1
        }
        None => assert_true(head == model.length())
      }
    }
  }
  let remaining = @transaction.atomically(txn => queue.length(txn))
  inspect(remaining == model.length() - head, content="true")
  // Drain the rest; order must match the model exactly.
  for _ in head..<model.length() {
    let got = @transaction.atomically(txn => queue.try_pop(txn))
    match got {
      Some(v) => assert_true(v == model[head])
      None => fail("queue drained before the model did")
    }
    head = head + 1
  }
  inspect(@transaction.atomically(txn => queue.is_empty(txn)), content="true")
}

///|
test "tmvar matches a model cell" {
  let box : @transaction.TMVar[Int] = @transaction.TMVar::new()
  let mut model : Int? = None
  let mut s = 13
  for t in 0..<300 {
    s = pseudo(s, t)
    match s % 3 {
      0 => {
        let stored = @transaction.atomically(txn => box.try_put(txn, s))
        inspect(stored == (model is None), content="true")
        if model is None {
          model = Some(s)
        }
      }
      1 => {
        let taken = @transaction.atomically(txn => box.try_take(txn))
        inspect(taken == model, content="true")
        model = None
      }
      _ => {
        let seen = @transaction.atomically(txn => box.read(txn))
        inspect(seen == model, content="true")
        let empty = @transaction.atomically(txn => box.is_empty(txn))
        inspect(empty == (model is None), content="true")
      }
    }
  }
}

///|
test "empty and read-only transactions leave no trace" {
  let cell = @transaction.TVar::new(3)
  let before = @transaction.commit_version()
  for i in 0..<100 {
    ignore(@transaction.atomically(_ => i))
    ignore(@transaction.atomically(txn => txn.read(cell)))
  }
  inspect(@transaction.commit_version() - before, content="0")
  inspect(cell.peek(), content="3")
}

///|
test "all-or-nothing across many tvars" {
  let vars = 40
  let tvs : Array[@transaction.TVar[Int]] = []
  for _ in 0..<vars {
    tvs.push(@transaction.TVar::new(0))
  }
  let mut committed_value = 0
  for t in 1..<=25 {
    // Even rounds always commit, odd rounds fail at a random write index:
    // without the guaranteed commits, a run where every round happened to
    // fail would assert only the all-zero state and prove nothing.
    let fail_at = if t % 2 == 0 { vars } else { pseudo(t, 8) % vars }
    @transaction.atomically(txn => {
      for tv in tvs {
        txn.write(tv, t)
      }
      if fail_at < vars {
        fail("planned failure")
      }
    }) catch {
      err => {
        assert_true(!@transaction.is_retry(err))
        assert_true(!@transaction.is_conflict(err))
      }
    }
    if fail_at == vars {
      committed_value = t
    }
    // A failed round rolls back to the last committed value, not to zero.
    let expected = committed_value
    let mut wrong = 0
    for tv in tvs {
      if tv.peek() != expected {
        wrong = wrong + 1
      }
    }
    inspect(wrong, content="0")
  }
  // The deterministic commit rounds must actually have run.
  inspect(tvs[0].peek(), content="24")
}
