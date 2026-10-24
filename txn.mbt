///|
/// Monotonic identifier source for transactions.
let txn_next_id : Ref[Int] = Ref(0)

///|
/// A handle to one running transaction.
///
/// A handle records the reads used for validation, the writes to apply on
/// commit, and the undo actions that remove uncommitted values on abort.
/// Prefer `atomically` (or `@transaction/runner.atomically_async` for bodies
/// that need to await) over creating and running a handle manually.
pub struct Txn {
  priv id : Int
  priv undo : Array[() -> Unit]
  priv commits : Array[() -> Unit]
  priv validators : Array[() -> Bool]
  priv mut validated_at : Int
}

///|
/// Create a transaction handle.
///
/// This is a low-level entry point used by runners. Most code should call
/// `atomically` instead.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new(1)
///   let txn = @transaction.Txn::begin()
///   txn.write(cell, 2)
///   txn.run(_ => ())
///   inspect(cell.peek(), content="2")
/// }
/// ```
pub fn Txn::begin() -> Txn {
  let id = txn_next_id.val
  txn_next_id.val = id + 1
  { id, undo: [], commits: [], validators: [], validated_at: commit_version(), }
}

///|
fn[T] Txn::record_read(self : Txn, tv : TVar[T]) -> Unit {
  let version = tv.version
  self.validators.push(() => tv.version == version)
}

///|
/// Re-check the read set if any transaction has committed since the last
/// validation. This detects a stale snapshot before the body observes another
/// value.
fn Txn::revalidate(self : Txn) -> Unit raise Conflict {
  let clock = commit_version()
  if clock != self.validated_at {
    for validate in self.validators {
      if !validate() {
        raise Conflict(clock)
      }
    }
    self.validated_at = clock
  }
}

///|
/// Read `tv` through this transaction.
///
/// If this transaction wrote `tv` already, its own pending value is returned
/// (read-your-own-writes); otherwise the last committed value is returned.
/// Raises `Conflict` when a previously read variable has been committed by
/// another transaction, so an asynchronous transaction stops as soon as its
/// snapshot becomes stale. `atomically` and `atomically_async` restart the
/// body automatically in that case.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new("hello")
///   let value = @transaction.atomically(txn => txn.read(cell))
///   inspect(value, content="hello")
/// }
/// ```
pub fn[T] Txn::read(self : Txn, tv : TVar[T]) -> T raise Conflict {
  self.revalidate()
  self.record_read(tv)
  match tv.pending.get(self.id) {
    Some(value) => value
    None => tv.value
  }
}

///|
/// Write `value` to `tv` inside this transaction.
///
/// The value becomes visible to other transactions only when this transaction
/// commits. Writing the same variable twice keeps only the last value.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new(1)
///   @transaction.atomically(txn => txn.write(cell, 41 + 1))
///   inspect(cell.peek(), content="42")
/// }
/// ```
pub fn[T] Txn::write(self : Txn, tv : TVar[T], value : T) -> Unit {
  self.record_read(tv)
  self.undo.push(() => tv.pending.remove(self.id))
  self.commits.push(() => {
    match tv.pending.get(self.id) {
      Some(value) => {
        tv.value = value
        tv.pending.remove(self.id)
        tv.version = tv.version + 1
      }
      None => ()
    }
  })
  tv.pending.set(self.id, value)
}

///|
/// Read `tv`, apply `f`, and write the result back.
///
/// # Example
/// ```mbt check
/// test {
///   let counter = @transaction.TVar::new(7)
///   @transaction.atomically(txn => txn.modify(counter, x => x + 1))
///   inspect(counter.peek(), content="8")
/// }
/// ```
pub fn[T] Txn::modify(
  self : Txn,
  tv : TVar[T],
  f : (T) -> T raise,
) -> Unit raise {
  let value = self.read(tv)
  self.write(tv, f(value))
}

///|
/// Abort the current attempt because it cannot make progress.
///
/// The transaction is rolled back and `Retry` is raised. Under
/// `@transaction/runner.atomically_async` the current task parks until some
/// transaction commits, then the body runs again from the beginning. Under
/// `atomically` the `Retry` error propagates to the caller, since synchronous
/// code cannot block.
///
/// # Example
/// ```mbt check
/// test {
///   let balance = @transaction.TVar::new(0)
///   try
///     @transaction.atomically(txn => {
///       let funds = txn.read(balance)
///       txn.check(funds >= 100)
///       txn.write(balance, funds - 100)
///     })
///   catch {
///     _ => ()
///   } noraise {
///     _ => fail("expected the transaction to retry")
///   }
///   inspect(balance.peek(), content="0")
/// }
/// ```
pub fn[T] Txn::retry(_self : Txn) -> T raise Retry {
  raise Retry(commit_version())
}

///|
/// Retry unless `condition` holds; a transactional `assert` that blocks
/// instead of failing.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new(3)
///   let value = @transaction.atomically(txn => {
///     txn.check(txn.read(cell) > 0)
///     txn.read(cell)
///   })
///   inspect(value, content="3")
/// }
/// ```
pub fn Txn::check(self : Txn, condition : Bool) -> Unit raise Retry {
  if !condition {
    self.retry()
  }
}

///|
fn Txn::rollback_to(
  self : Txn,
  undo_mark : Int,
  commit_mark : Int,
  validator_mark : Int,
) -> Unit {
  for i = self.undo.length() - 1; i >= undo_mark; i = i - 1 {
    self.undo[i]()
  }
  self.undo.truncate(undo_mark)
  self.commits.truncate(commit_mark)
  self.validators.truncate(validator_mark)
}

///|
fn Txn::rollback(self : Txn) -> Unit {
  self.rollback_to(0, 0, 0)
}

///|
fn Txn::commit(self : Txn) -> Unit raise Conflict {
  for validate in self.validators {
    if !validate() {
      self.rollback()
      raise Conflict(commit_version())
    }
  }
  let changed = !self.commits.is_empty()
  for action in self.commits {
    action()
  }
  self.undo.clear()
  self.validators.clear()
  if changed {
    bump_commit_version()
  }
}

///|
/// Run `f` as one attempt of this transaction.
///
/// On success the writes are validated and committed together. On any error
/// the attempt is rolled back and the error is re-raised. `f` must not
/// suspend; use `run_async` for an asynchronous body. Runners that want
/// automatic restarts on `Retry` and `Conflict` build their loop around this
/// method, like `atomically` does.
pub fn[T] Txn::run(self : Txn, f : (Txn) -> T raise) -> T raise {
  let result = f(self) catch {
    Retry(clock) => {
      self.rollback()
      raise Retry(clock)
    }
    Conflict(clock) => {
      self.rollback()
      raise Conflict(clock)
    }
    err => {
      self.rollback()
      raise err
    }
  }
  self.commit()
  result
}

///|
/// Run an asynchronous transaction body.
///
/// The body may suspend. Uncommitted writes stay private to this transaction
/// (other transactions keep reading the last committed value), and the read
/// set is validated whenever the body observes another value and again at
/// commit time, so a body that awaited resumes on a checked snapshot.
///
/// This is the low-level primitive behind
/// `@transaction/runner.atomically_async`; prefer calling that instead.
pub async fn[T] Txn::run_async(self : Txn, f : async (Txn) -> T) -> T {
  let result = f(self) catch {
    Retry(clock) => {
      self.rollback()
      raise Retry(clock)
    }
    Conflict(clock) => {
      self.rollback()
      raise Conflict(clock)
    }
    err => {
      self.rollback()
      raise err
    }
  }
  self.commit()
  result
}

///|
/// Run `first`; if it retries, discard its writes and reads, then run
/// `second`.
///
/// This composes blocking choices: take from either queue, answer from either
/// cache, and so on, without races. A `Retry` raised by `second` propagates.
/// Other errors, including `Conflict`, propagate without running `second`.
/// The two branches must have the same result type.
///
/// # Example
/// ```mbt check
/// test {
///   let inbox = @transaction.TMVar::new()
///   let draft = @transaction.TMVar::full("draft")
///   let picked = @transaction.atomically(txn => {
///     txn.or_else(t => inbox.take(t), t => draft.take(t))
///   })
///   inspect(picked, content="draft")
/// }
/// ```
pub fn[T] Txn::or_else(
  self : Txn,
  first : (Txn) -> T raise,
  second : (Txn) -> T raise,
) -> T raise {
  let undo_mark = self.undo.length()
  let commit_mark = self.commits.length()
  let validator_mark = self.validators.length()
  first(self) catch {
    Retry(_) => {
      self.rollback_to(undo_mark, commit_mark, validator_mark)
      second(self)
    }
    err => raise err
  }
}
