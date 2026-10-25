// Heavier async stress beyond runner/stress_test.mbt: wider task fan-out,
// higher volumes, and longer coordination runs. Deterministic outcomes by
// construction (conservation and counts, never timings).

///|
async test "eight tasks hammering one tvar stay consistent" {
  let counter = @transaction.TVar::new(0)
  let tasks = 8
  let per_task = 100
  @aio.with_task_group(group => {
    for t in 0..<tasks {
      group.spawn_bg(() => {
        // Task t writes exactly `t + 1` times, reading between suspensions.
        for _ in 0..<(t + 1) {
          @runner.atomically_async(txn => {
            let v = txn.read(counter)
            @aio.pause() // invite conflicts from the other seven tasks
            txn.write(counter, v + 1)
          })
        }
        // Fill the remaining operations with read-only transactions.
        for _ in (t + 1)..<per_task {
          @runner.atomically_async(txn => ignore(txn.read(counter)))
        }
      })
    }
  })
  // 1 + 2 + ... + 8 increments, each applied exactly once.
  inspect(counter.peek(), content="36")
}

///|
async test "high-volume queue churn conserves every item" {
  let producers = 4
  let items = 250
  let consumers = 4
  let queue : @transaction.TQueue[Int32] = @transaction.TQueue::new()
  let consumed : Array[Int32] = []
  @aio.with_task_group(group => {
    for _ in 0..<consumers {
      group.spawn_bg(() => {
        for _ in 0..<(producers * items / consumers) {
          consumed.push(@runner.atomically_async(txn => queue.pop(txn)))
        }
      })
    }
    for p in 0..<producers {
      group.spawn_bg(() => {
        for i in 0..<items {
          @runner.atomically_async(txn => queue.push(txn, p * 10000 + i))
        }
      })
    }
  })
  inspect(consumed.length(), content="1000")
  let mut sum = 0
  for v in consumed {
    sum = sum + v
  }
  // 10000 * 250 * (0 + 1 + 2 + 3) + 4 * sum(0..249)
  inspect(sum, content="15124500")
  for p in 0..<producers {
    let mut prev = p * 10000 - 1
    for v in consumed {
      if v >= p * 10000 && v < (p + 1) * 10000 {
        assert_true(v == prev + 1)
        prev = v
      }
    }
    assert_true(prev == p * 10000 + items - 1)
  }
}

///|
async test "long tmvar handshake stays exact" {
  let rounds = 500
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
  assert_true(ping.peek() is Some(1000))
  assert_true(pong.peek() is None)
}

///|
async test "retry storm: many parked tasks survive heavy wakeup traffic" {
  let parked = 6
  let flag = @transaction.TVar::new(false)
  let noise = @transaction.TVar::new(0)
  let completed = Ref(0)
  @aio.with_task_group(group => {
    for _ in 0..<parked {
      group.spawn_bg(() => {
        @runner.atomically_async(txn => txn.check(txn.read(flag)))
        completed.val = completed.val + 1
      })
    }
    @aio.sleep(5) // let every task park
    inspect(completed.val, content="0")
    for i in 0..<50 {
      // Each commit broadcasts and wakes all six tasks; they re-run,
      // still see `false`, and park again.
      @runner.atomically_async(txn => txn.write(noise, i))
      @aio.pause()
    }
    inspect(completed.val, content="0")
    @runner.atomically_async(txn => txn.write(flag, true))
  })
  inspect(completed.val, content="6")
}
