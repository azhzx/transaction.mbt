///|
/// The global commit version. It starts at zero and advances once for every
/// transaction that commits at least one write.
let commit_clock : Ref[Int32] = Ref(0)

///|
/// Callbacks invoked after a transaction commits writes. Listeners are
/// permanent and must not raise or block.
let commit_listeners : Array[() -> Unit] = []

///|
/// The current global commit version.
///
/// A transaction that retried at version `v` should run again after this value
/// becomes greater than `v`. Blocking runners use it to decide when to wake a
/// parked transaction.
pub fn commit_version() -> Int32 {
  commit_clock.val
}

///|
/// Register a callback that is invoked after every write transaction commits.
///
/// This is the integration point used by blocking runners. A listener must not
/// call back into `atomically` and must not block. Listeners are permanent for
/// the lifetime of the program.
pub fn on_commit(listener : () -> Unit) -> Unit {
  commit_listeners.push(listener)
}

///|
fn bump_commit_version() -> Unit {
  commit_clock.val = commit_clock.val + 1
  for listener in commit_listeners {
    listener()
  }
}

///|
/// Run `f` as one atomic transaction.
///
/// All TVar operations performed through the supplied `Txn` are applied
/// together, or not at all. The transaction body observes a consistent
/// snapshot: if a variable it read is committed by another transaction while
/// the body is still running, the body is discarded and run again from the
/// beginning, so `f` must be prepared to run more than once. Keep side effects
/// such as I/O and logging out of `f`, or make them idempotent.
///
/// - If `f` raises `Retry` (via `Txn::retry` or `Txn::check`), the transaction
///   rolls back and `Retry` is re-raised to the caller. Synchronous code cannot
///   block; use `@transaction/runner.atomically_async` to park until the
///   watched variables change.
/// - If `f` raises any other error, every write is discarded and the error is
///   re-raised as-is.
/// - The body must not suspend. Use
///   `@transaction/runner.atomically_async` when the body needs to await.
///
/// # Example
/// ```mbt check
/// test {
///   let balance = @transaction.TVar::new(100)
///   @transaction.atomically(txn => {
///     let current = txn.read(balance)
///     txn.write(balance, current - 30)
///   })
///   inspect(balance.peek(), content="70")
/// }
/// ```
pub fn[T] atomically(f : (Txn) -> T raise) -> T raise {
  while true {
    let txn = Txn::begin()
    try {
      return txn.run(f)
    } catch {
      Conflict(_) => continue
      err => raise err
    }
  } nobreak {
    abort("unreachable")
  }
}
