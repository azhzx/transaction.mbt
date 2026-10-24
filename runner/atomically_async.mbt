///|
/// Broadcasts a wake-up after every write transaction commits.
let commit_cond : @cond_var.Cond = @cond_var.Cond()

///|
/// Guards the one-time listener installation.
let listener_installed : Ref[Bool] = Ref(false)

///|
fn ensure_commit_listener() -> Unit {
  if !listener_installed.val {
    listener_installed.val = true
    @transaction.on_commit(() => commit_cond.broadcast())
  }
}

///|
/// Wait until the global commit version is no longer `observed`.
async fn wait_for_change(observed : Int) -> Unit {
  while @transaction.commit_version() == observed {
    commit_cond.wait()
  }
}

///|
/// Run `f` as one atomic transaction, blocking the current task when the
/// transaction retries.
///
/// - `Retry` parks the task until some transaction commits, then runs `f`
///   again from the beginning.
/// - `Conflict` yields once and immediately runs `f` again.
///
/// The body may await. Only TVar effects are transactional: I/O, logging and
/// other side effects are not rolled back and may run more than once.
///
/// # Example
/// ```mbt check
/// async test {
///   let cell = @transaction.TVar::new(41)
///   let result = @runner.atomically_async(txn => txn.read(cell) + 1)
///   inspect(result, content="42")
/// }
/// ```
pub async fn[T] atomically_async(f : async (@transaction.Txn) -> T) -> T {
  ensure_commit_listener()
  while true {
    let txn = @transaction.Txn::begin()
    try {
      return txn.run_async(f)
    } catch {
      @transaction.Retry(clock) => wait_for_change(clock)
      @transaction.Conflict(_) => @aio.pause()
      err => raise err
    }
  } nobreak {
    abort("unreachable")
  }
}
