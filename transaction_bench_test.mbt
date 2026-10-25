// Benchmarks for the core transaction paths, run with `moon bench`
// (use `--target native --release` for stable numbers). They measure the
// primitives a real workload pays for: transaction entry/exit, read and
// write set sizes, rollback, or_else dispatch, and the ready-made
// structures. The plain-reference baseline anchors the STM overhead.
// Benchmarks assume success, so raising calls are wrapped in `try!`.

///|
test "bench baseline: plain reference increment" (it : @bench.T) {
  let cell = Ref(0)
  it.bench(() => {
    cell.val = cell.val + 1
    it.keep(cell.val)
  })
}

///|
test "bench read-only transaction (1 tvar)" (it : @bench.T) {
  let cell = @transaction.TVar::new(41)
  it.bench(() => {
    let v = try! @transaction.atomically(txn => txn.read(cell))
    it.keep(v)
  })
}

///|
test "bench read-modify-write transaction (1 tvar)" (it : @bench.T) {
  let cell = @transaction.TVar::new(0)
  it.bench(() => {
    try! @transaction.atomically(txn => txn.modify(cell, v => v + 1))
    it.keep(cell.peek())
  })
}

///|
test "bench read-only transaction (10 tvars)" (it : @bench.T) {
  let tvs : Array[@transaction.TVar[Int]] = []
  for i in 0..<10 {
    tvs.push(@transaction.TVar::new(i))
  }
  it.bench(() => {
    let sum = try! @transaction.atomically(txn => {
      let mut total = 0
      for tv in tvs {
        total = total + txn.read(tv)
      }
      total
    })
    it.keep(sum)
  })
}

///|
test "bench read-modify-write transaction (10 tvars)" (it : @bench.T) {
  let tvs : Array[@transaction.TVar[Int]] = []
  for _ in 0..<10 {
    tvs.push(@transaction.TVar::new(0))
  }
  it.bench(() => {
    try! @transaction.atomically(txn => {
      for tv in tvs {
        txn.modify(tv, v => v + 1)
      }
    })
    it.keep(tvs[0].peek())
  })
}

///|
test "bench rollback via retry (write then block)" (it : @bench.T) {
  let cell = @transaction.TVar::new(0)
  it.bench(() => {
    @transaction.atomically(txn => {
      txn.write(cell, 1)
      txn.check(false)
    }) catch {
      _ => ()
    }
    it.keep(cell.peek())
  })
}

///|
test "bench rollback via body error" (it : @bench.T) {
  let cell = @transaction.TVar::new(0)
  it.bench(() => {
    @transaction.atomically(txn => {
      txn.write(cell, 1)
      (fail("bench") : Unit)
    }) catch {
      _ => ()
    }
    it.keep(cell.peek())
  })
}

///|
test "bench or_else with a successful first branch" (it : @bench.T) {
  let cell = @transaction.TVar::new(1)
  it.bench(() => {
    let v = try! @transaction.atomically(txn => {
      txn.or_else(t => t.read(cell), t => t.retry())
    })
    it.keep(v)
  })
}

///|
test "bench or_else falling back to the second branch" (it : @bench.T) {
  let empty : @transaction.TMVar[Int] = @transaction.TMVar::new()
  it.bench(() => {
    let v = try! @transaction.atomically(txn => {
      txn.or_else(t => empty.take(t), _ => 7)
    })
    it.keep(v)
  })
}

///|
test "bench manual begin, write, and commit" (it : @bench.T) {
  let cell = @transaction.TVar::new(0)
  it.bench(() => {
    let txn = @transaction.Txn::begin()
    txn.write(cell, 1)
    try! txn.commit()
    it.keep(cell.peek())
  })
}

///|
test "bench manual begin, write, and rollback" (it : @bench.T) {
  let cell = @transaction.TVar::new(0)
  it.bench(() => {
    let txn = @transaction.Txn::begin()
    txn.write(cell, 1)
    txn.rollback()
    it.keep(cell.peek())
  })
}

///|
test "bench tqueue push and pop pair (empty queue)" (it : @bench.T) {
  let queue : @transaction.TQueue[Int] = @transaction.TQueue::new()
  it.bench(() => {
    try! @transaction.atomically(txn => queue.push(txn, 1))
    let v = try! @transaction.atomically(txn => queue.pop(txn))
    it.keep(v)
  })
}

///|
test "bench tqueue batch of 100 push/pop at length 100" (it : @bench.T) {
  let queue : @transaction.TQueue[Int] = @transaction.TQueue::new()
  it.bench(() => {
    try! @transaction.atomically(txn => {
      for i in 0..<100 {
        queue.push(txn, i)
      }
      for _ in 0..<100 {
        ignore(queue.pop(txn))
      }
    })
    let len = try! @transaction.atomically(txn => queue.length(txn))
    it.keep(len)
  })
}

///|
test "bench tmvar put and take pair" (it : @bench.T) {
  let box : @transaction.TMVar[Int] = @transaction.TMVar::new()
  it.bench(() => {
    try! @transaction.atomically(txn => box.put(txn, 1))
    let v = try! @transaction.atomically(txn => box.take(txn))
    it.keep(v)
  })
}
