// Async integration scenarios: realistic multi-task patterns built from the
// runner plus the core structures — blocking coordination, bounded buffers,
// worker pools, mailboxes, and hot-reload watchers. All outcomes are
// deterministic under the cooperative scheduler.

///|
async test "blocking withdrawals wait for deposits" {
  let account = @transaction.TVar::new(100)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      // Four withdrawals of 30; each parks until the balance covers it.
      for _ in 0..<4 {
        @runner.atomically_async(txn => {
          let funds = txn.read(account)
          txn.check(funds >= 30)
          txn.write(account, funds - 30)
        })
      }
    })
    for _ in 0..<20 {
      @runner.atomically_async(txn => txn.modify(account, v => v + 10))
    }
  })
  // 100 + 20 * 10 - 4 * 30, regardless of interleaving.
  inspect(account.peek(), content="180")
}

///|
async test "barrier releases tasks only when all arrive" {
  let n = 3
  let arrived = @transaction.TVar::new(0)
  let entered = Ref(0)
  @aio.with_task_group(group => {
    for _ in 0..<n {
      group.spawn_bg(() => {
        // Two transactions, and the split is the point: a blocked
        // transaction rolls back its own writes, so the arrival increment
        // must commit on its own before the wait blocks on the condition.
        @runner.atomically_async(txn => txn.modify(arrived, v => v + 1))
        @runner.atomically_async(txn => txn.check(txn.read(arrived) == n))
        entered.val = entered.val + 1
      })
    }
  })
  inspect(entered.val, content="3")
  inspect(arrived.peek(), content="3")
}

///|
async test "transactional semaphore caps concurrency" {
  let permits = @transaction.TVar::new(2)
  let inside = Ref(0)
  let max_inside = Ref(0)
  @aio.with_task_group(group => {
    for _ in 0..<6 {
      group.spawn_bg(() => {
        @runner.atomically_async(txn => {
          let p = txn.read(permits)
          txn.check(p > 0)
          txn.write(permits, p - 1)
        })
        inside.val = inside.val + 1
        if inside.val > max_inside.val {
          max_inside.val = inside.val
        }
        @aio.pause() // hold the permit for a while
        inside.val = inside.val - 1
        @runner.atomically_async(txn => txn.modify(permits, v => v + 1))
      })
    }
  })
  inspect(permits.peek(), content="2")
  inspect(max_inside.val, content="2")
}

///|
async test "poison pills stop every worker exactly once" {
  let jobs : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let workers = 3
  let processed = Ref(0)
  @aio.with_task_group(group => {
    for _ in 0..<workers {
      group.spawn_bg(() => {
        for ;; {
          let job = @runner.atomically_async(txn => jobs.pop(txn))
          if job < 0 {
            break
          }
          processed.val = processed.val + 1
        }
      })
    }
    for i in 1..<=10 {
      @runner.atomically_async(txn => jobs.push(txn, i))
    }
    for _ in 0..<workers {
      @runner.atomically_async(txn => jobs.push(txn, -1))
    }
  })
  inspect(processed.val, content="10")
  inspect(@transaction.atomically(txn => jobs.is_empty(txn)), content="true")
}

///|
async test "or_else merges two queues with conservation" {
  let fast : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let slow : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let total = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<20 {
        let v = @runner.atomically_async(txn => {
          txn.or_else(t => fast.pop(t), t => slow.pop(t))
        })
        total.val = total.val + v
      }
    })
    group.spawn_bg(() => {
      for i in 1..<=10 {
        @runner.atomically_async(txn => fast.push(txn, i))
      }
    })
    group.spawn_bg(() => {
      for i in 1..<=10 {
        @runner.atomically_async(txn => slow.push(txn, 100 + i))
      }
    })
  })
  // sum(1..10) + sum(101..110)
  inspect(total.val, content="1110")
}

///|
async test "mailbox server processes commands in order" {
  let mailbox : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let state = @transaction.TVar::new(0)
  let log : Array[Int] = []
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<8 {
        let delta = @runner.atomically_async(txn => mailbox.pop(txn))
        @runner.atomically_async(txn => txn.modify(state, v => v + delta))
        log.push(delta)
      }
    })
    for i in 1..<=8 {
      @runner.atomically_async(txn => mailbox.push(txn, i))
    }
  })
  inspect(state.peek(), content="36")
  for i, v in log {
    inspect(v == i + 1, content="true")
  }
}

///|
async test "watchers wake when the config version changes" {
  let version = @transaction.TVar::new(1)
  let watchers = 3
  let seen = Ref(0)
  @aio.with_task_group(group => {
    for _ in 0..<watchers {
      group.spawn_bg(() => {
        let v = @runner.atomically_async(txn => {
          let current = txn.read(version)
          txn.check(current >= 2)
          current
        })
        if v >= 2 {
          seen.val = seen.val + 1
        }
      })
    }
    @aio.sleep(5) // let every watcher park
    inspect(seen.val, content="0")
    @runner.atomically_async(txn => txn.write(version, 2))
  })
  inspect(seen.val, content="3")
}

///|
async test "bounded buffer applies backpressure" {
  let buffer : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let cap = 3
  let pushed = Ref(0)
  let popped = Ref(0)
  let max_seen = Ref(0)
  // Fill to the cap up front and record one committed observation of it:
  // this pins `max_seen` at the cap, so the observer's "never exceeded"
  // assertion below cannot pass vacuously on a run that never saw a
  // non-empty buffer.
  for i in 1..<=cap {
    @runner.atomically_async(txn => buffer.push(txn, i))
  }
  @runner.atomically_async(txn => {
    let len = buffer.length(txn)
    if len > max_seen.val {
      max_seen.val = len
    }
  })
  inspect(max_seen.val, content="3")
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for i in (cap + 1)..<=20 {
        @runner.atomically_async(txn => {
          txn.check(buffer.length(txn) < cap)
          buffer.push(txn, i)
        })
        pushed.val = pushed.val + 1
      }
    })
    group.spawn_bg(() => {
      for _ in 0..<20 {
        let _ = @runner.atomically_async(txn => buffer.pop(txn))
        popped.val = popped.val + 1
      }
    })
    group.spawn_bg(() => {
      // Observer: sample the committed length; it must never exceed the cap.
      for _ in 0..<40 {
        @runner.atomically_async(txn => {
          let len = buffer.length(txn)
          if len > max_seen.val {
            max_seen.val = len
          }
        })
        @aio.pause()
      }
    })
  })
  // 17 in-group pushes after the 3 pre-fill pushes: 20 items moved overall.
  inspect(pushed.val, content="17")
  inspect(popped.val, content="20")
  inspect(max_seen.val, content="3")
  inspect(@transaction.atomically(txn => buffer.is_empty(txn)), content="true")
}

///|
async test "staged pipeline transforms every item in order" {
  let raw : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let doubled : @transaction.TQueue[Int] = @transaction.TQueue::new()
  let done = @transaction.TVar::new([])
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<5 {
        let v = @runner.atomically_async(txn => raw.pop(txn))
        @runner.atomically_async(txn => doubled.push(txn, v * 2))
      }
    })
    group.spawn_bg(() => {
      for _ in 0..<5 {
        let v = @runner.atomically_async(txn => doubled.pop(txn))
        @runner.atomically_async(txn => {
          txn.modify(done, items => {
            let grown = items.copy()
            grown.push(v + 1)
            grown
          })
        })
      }
    })
    for i in 1..<=5 {
      @runner.atomically_async(txn => raw.push(txn, i))
    }
  })
  let rendered = StringBuilder()
  for i, v in done.peek() {
    if i > 0 {
      rendered.write_string(", ")
    }
    rendered.write_string("\{v}")
  }
  inspect(rendered, content="3, 5, 7, 9, 11")
}
