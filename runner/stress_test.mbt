// Concurrency stress tests for the async runner.
//
// These tests exercise the properties that matter for shared state under
// interleaved tasks: conservation of values, isolation of multi-TVar
// updates (no torn reads), wakeup correctness for parked transactions
// (including spurious wakeups and thundering herds), and liveness.

///|
/// Deterministic pseudo-random value in `0..16383`; see `stress_test.mbt` in
/// the core package for the rationale.
fn pseudo(seed : Int, salt : Int) -> Int {
  let mut x = ((seed & 0x7FFF) * 11549 + (salt & 0x7FFF) * 7887 + 12345) &
    0x7FFF
  x = x ^ (x >> 7)
  x = (x * 49297) & 0x7FFF
  x = x ^ (x >> 4)
  x
}

///|
async test "queue stress: conservation and per-producer order" {
  let producers = 3
  let items = 30
  let consumers = 2
  let total = producers * items
  let queue : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let consumed : Array[Int] = []
  @aio.with_task_group(group => {
    for _ in 0..<consumers {
      group.spawn_bg(() => {
        for _ in 0..<(total / consumers) {
          let v = @runner.atomically_async(txn => queue.pop(txn))
          consumed.push(v)
        }
      })
    }
    for p in 0..<producers {
      group.spawn_bg(() => {
        for i in 0..<items {
          @runner.atomically_async(txn => queue.push(txn, p * 1000 + i))
        }
      })
    }
  })
  inspect(consumed.length(), content="90")
  let mut sum = 0
  for v in consumed {
    sum = sum + v
  }
  inspect(sum, content="91305")
  // Every producer's items must be consumed in push order (FIFO per source).
  for p in 0..<producers {
    let mut prev = p * 1000 - 1
    for v in consumed {
      if v >= p * 1000 && v < (p + 1) * 1000 {
        assert_true(v == prev + 1)
        prev = v
      }
    }
    assert_true(prev == p * 1000 + items - 1)
  }
}

///|
async test "concurrent bank stress keeps the total" {
  let accounts = 5
  let rounds = 60
  let balances : Array[@transaction.TVar[Int]] = []
  for _ in 0..<accounts {
    balances.push(@transaction.TVar::new(200))
  }
  @aio.with_task_group(group => {
    for t in 0..<3 {
      group.spawn_bg(() => {
        let mut s = 100 + t
        for r in 0..<rounds {
          s = pseudo(s, r)
          let from = s % accounts
          s = pseudo(s, r + 1)
          let to = s % accounts
          s = pseudo(s, r + 2)
          let amount = s % 40 + 1
          if from != to {
            @runner.atomically_async(txn => {
              let funds = txn.read(balances[from])
              if funds >= amount {
                txn.write(balances[from], funds - amount)
                txn.modify(balances[to], balance => balance + amount)
              }
            })
          }
        }
      })
    }
  })
  let mut total = 0
  for b in balances {
    total = total + b.peek()
  }
  inspect(total, content="1000")
}

///|
async test "observers never see a torn multi-tvar update" {
  let nvars = 8
  let rounds = 40
  let observations = 100
  let tvs : Array[@transaction.TVar[Int]] = []
  for _ in 0..<nvars {
    tvs.push(@transaction.TVar::new(0))
  }
  let torn = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for r in 1..<=rounds {
        @runner.atomically_async(txn => {
          @aio.pause() // suspend mid-transaction to invite interference
          for tv in tvs {
            txn.write(tv, r)
          }
        })
      }
    })
    for _ in 0..<2 {
      group.spawn_bg(() => {
        for _ in 0..<(observations / 2) {
          @runner.atomically_async(txn => {
            let first = txn.read(tvs[0])
            @aio.pause() // snapshot may go stale here; a torn read must not pass
            for i in 1..<nvars {
              if txn.read(tvs[i]) != first {
                torn.val = torn.val + 1
              }
            }
          })
        }
      })
    }
  })
  inspect(torn.val, content="0")
  for tv in tvs {
    inspect(tv.peek(), content="40")
  }
}

///|
async test "all parked consumers wake and complete" {
  let n = 5
  let queue : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let consumed : Array[Int] = []
  @aio.with_task_group(group => {
    for _ in 0..<n {
      group.spawn_bg(() => {
        consumed.push(@runner.atomically_async(txn => queue.pop(txn)))
      })
    }
    @aio.sleep(5) // let every consumer run once and park on retry
    inspect(consumed.length(), content="0")
    for i in 1..<=n {
      @runner.atomically_async(txn => queue.push(txn, i))
    }
  })
  inspect(consumed.length(), content="5")
  let counts : Map[Int, Int] = Map([])
  for v in consumed {
    counts[v] = counts.get(v).unwrap_or(0) + 1
  }
  inspect(counts.length(), content="5")
  for i in 1..<=n {
    assert_true(counts.get(i) is Some(1))
  }
}

///|
async test "tmvar handshake ping-pong many rounds" {
  let rounds = 100
  let ping = @transaction.TMVar::full(0)
  let pong = @transaction.TMVar::new()
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<rounds {
        let v = @runner.atomically_async(txn => ping.take(txn))
        @runner.atomically_async(txn => pong.put(txn, v + 1))
      }
    })
    for _ in 0..<rounds {
      let v = @runner.atomically_async(txn => pong.take(txn))
      @runner.atomically_async(txn => ping.put(txn, v + 1))
    }
  })
  assert_true(ping.peek() is Some(200))
  assert_true(pong.peek() is None)
}

///|
async test "or_else retries the first branch after waking" {
  let a : @transaction.TMVar[String] = @transaction.TMVar::new()
  let b : @transaction.TMVar[String] = @transaction.TMVar::new()
  let picked = Ref("")
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      picked.val = @runner.atomically_async(txn => {
        txn.or_else(t => a.take(t), t => b.take(t))
      })
    })
    @aio.sleep(5) // the consumer parks: both branches retry
    @runner.atomically_async(txn => a.put(txn, "first"))
    // On wake the body restarts: the first branch now succeeds.
  })
  inspect(picked.val, content="first")
  assert_true(a.peek() is None)
  assert_true(b.peek() is None)
}

///|
async test "or_else falls back when only the second source fills" {
  let a : @transaction.TMVar[String] = @transaction.TMVar::new()
  let b : @transaction.TMVar[String] = @transaction.TMVar::new()
  let picked = Ref("")
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      picked.val = @runner.atomically_async(txn => {
        txn.or_else(t => a.take(t), t => b.take(t))
      })
    })
    @aio.sleep(5)
    @runner.atomically_async(txn => b.put(txn, "second"))
    // On wake the first branch still retries, so the second one runs.
  })
  inspect(picked.val, content="second")
  assert_true(a.peek() is None)
  assert_true(b.peek() is None)
}

///|
async test "parked transactions survive spurious wakeups" {
  let flag = @transaction.TVar::new(false)
  let noise = @transaction.TVar::new(0)
  let done = Ref(false)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      @runner.atomically_async(txn => txn.check(txn.read(flag)))
      done.val = true
    })
    @aio.sleep(5) // parked
    assert_false(done.val)
    for i in 0..<10 {
      // Unrelated commits broadcast wakeups; the parked transaction must
      // re-run, still observe `false`, and park again.
      @runner.atomically_async(txn => txn.write(noise, i))
      @aio.pause()
    }
    inspect(done.val, content="false")
    @runner.atomically_async(txn => txn.write(flag, true))
  })
  inspect(done.val, content="true")
}

///|
async test "bodies restart until they beat the interference" {
  let rounds = 30
  let total_runs = Ref(0)
  for _ in 0..<rounds {
    let cell = @transaction.TVar::new(0)
    let runs = Ref(0)
    @aio.with_task_group(group => {
      group.spawn_bg(() => @runner.atomically_async(txn => txn.write(cell, 1)))
      let result = @runner.atomically_async(txn => {
        runs.val = runs.val + 1
        let _ = txn.read(cell)
        @aio.pause() // the writer commits while we are suspended
        txn.read(cell)
      })
      inspect(result, content="1")
    })
    total_runs.val = total_runs.val + runs.val
  }
  // Every round: first attempt conflicts after the suspension and restarts.
  inspect(total_runs.val, content="60")
}

///|
async test "async body errors propagate and roll back" {
  let cell = @transaction.TVar::new(1)
  try
    @runner.atomically_async(txn => {
      txn.write(cell, 2)
      (fail("stop") : Unit)
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
  @runner.atomically_async(txn => txn.write(cell, 10))
  inspect(cell.peek(), content="10")
}

///|
async test "or_else second-branch errors propagate and roll back" {
  let a : @transaction.TMVar[Int] = @transaction.TMVar::new()
  let cell = @transaction.TVar::new(0)
  try
    @runner.atomically_async(txn => {
      txn.or_else(
        t => a.take(t), // retries: empty
        t => {
          t.write(cell, 99)
          fail("second branch failed")
        },
      )
    })
  catch {
    err => {
      assert_true(!@transaction.is_retry(err))
      assert_true(!@transaction.is_conflict(err))
    }
  } noraise {
    _ => fail("expected the second branch error to propagate")
  }
  inspect(cell.peek(), content="0")
}

///|
async test "many sequential transactions complete" {
  let counter = @transaction.TVar::new(0)
  for _ in 0..<1000 {
    @runner.atomically_async(txn => txn.modify(counter, v => v + 1))
  }
  inspect(counter.peek(), content="1000")
}

///|
async test "high-volume single-tvar contention stays consistent" {
  let counter = @transaction.TVar::new(0)
  let increments = 200
  @aio.with_task_group(group => {
    for _ in 0..<4 {
      group.spawn_bg(() => {
        for _ in 0..<increments {
          @runner.atomically_async(txn => {
            let v = txn.read(counter)
            @aio.pause() // widen the conflict window inside every body
            txn.write(counter, v + 1)
          })
        }
      })
    }
  })
  inspect(counter.peek(), content="800")
}
