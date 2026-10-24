///|
/// Showcase for the STM library. Run with `moon run cmd/main` (add
/// `--target native` for a native build).
async fn main {
  // 1. An atomic transfer between two accounts: both writes commit together,
  //    and `check` retries the transaction while funds are insufficient.
  let alice = @transaction.TVar::new(100)
  let bob = @transaction.TVar::new(20)
  @runner.atomically_async(txn => {
    let funds = txn.read(alice)
    txn.check(funds >= 30)
    txn.write(alice, funds - 30)
    txn.modify(bob, balance => balance + 30)
  })
  println("after transfer: alice=\{alice.peek()}, bob=\{bob.peek()}")
  // 2. A consumer that parks on an empty queue until a producer commits,
  //    both tasks sharing the same transactional queue.
  let jobs = @transaction.TQueue::new()
  let results = @transaction.TVar::new([])
  @aio.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<3 {
        let job = @runner.atomically_async(txn => jobs.pop(txn))
        @runner.atomically_async(txn => {
          txn.modify(results, done => {
            let grown = done.copy()
            grown.push(job * 10)
            grown
          })
        })
      }
    })
    for i in 1..<=3 {
      @runner.atomically_async(txn => jobs.push(txn, i))
    }
  })
  let rendered = StringBuilder()
  for i, v in results.peek() {
    if i > 0 {
      rendered.write_string(", ")
    }
    rendered.write_string("\{v}")
  }
  println("consumer received: [\{rendered}]")
}
