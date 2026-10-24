// Blackbox tests for the asynchronous runner. They exercise retry parking,
// conflict restarts, and pipelines built from tasks sharing TVars.

///|
async test "atomically_async commits and returns the body result" {
  let cell = @transaction.TVar::new(41)
  let result = @runner.atomically_async(txn => txn.read(cell) + 1)
  inspect(result, content="42")
  inspect(cell.peek(), content="41")
}

///|
async test "retry parks the task until another task commits" {
  let queue = @transaction.TQueue::new()
  let received = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      received.val = @runner.atomically_async(txn => queue.pop(txn))
    })
    @aio.pause()
    inspect(received.val, content="0")
    @runner.atomically_async(txn => queue.push(txn, 42))
  })
  inspect(received.val, content="42")
}

///|
async test "stale snapshots restart the body after a suspension" {
  let cell = @transaction.TVar::new(1)
  let runs = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => @runner.atomically_async(txn => txn.write(cell, 100)))
    let result = @runner.atomically_async(txn => {
      runs.val = runs.val + 1
      let _ = txn.read(cell)
      @aio.pause()
      txn.read(cell)
    })
    inspect(result, content="100")
    inspect(runs.val, content="2")
  })
  inspect(cell.peek(), content="100")
}

///|
async test "producer and consumer pipeline through a shared queue" {
  let queue = @transaction.TQueue::new()
  let total = Ref(0)
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<5 {
        let job = @runner.atomically_async(txn => queue.pop(txn))
        total.val = total.val + job
      }
    })
    for i in 1..<=5 {
      @runner.atomically_async(txn => queue.push(txn, i))
    }
  })
  inspect(total.val, content="15")
}

///|
async test "or_else picks whichever branch can proceed" {
  let fast = @transaction.TMVar::new()
  let slow = @transaction.TMVar::full("slow-path")
  let picked = @runner.atomically_async(txn => {
    txn.or_else(t => fast.take(t), t => slow.take(t))
  })
  inspect(picked, content="slow-path")
}
