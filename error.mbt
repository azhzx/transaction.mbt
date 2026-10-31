///|
/// Raised by `Txn::retry` to abort the current attempt because it cannot make
/// progress yet. The payload is the commit version at which the transaction's
/// read set was last validated (its snapshot clock), which may be older than
/// the current global clock when an asynchronous body suspended.
///
/// A blocking runner (such as `@transaction/runner.atomically_async`) waits
/// until `commit_version()` differs from the payload, then runs the body again
/// from the beginning. If a commit happened after that snapshot — for example
/// while the body was suspended — the runner restarts immediately instead of
/// waiting for a future commit, so the commit is never missed. Compare with
/// `!=` rather than `>`; the 64-bit counter will not wrap in practice. Under
/// `atomically` the error propagates to the caller.
pub suberror Retry {
  Retry(Int64)
}

///|
/// Raised when a TVar read earlier by the transaction has been committed by
/// another transaction, so the transaction can no longer return a consistent
/// result.
///
/// The payload is the global commit version at which the conflict was
/// detected. `atomically` and `atomically_async` restart the body
/// automatically; only custom runners see this error.
pub suberror Conflict {
  Conflict(Int64)
}

///|
/// Whether `err` is the `Retry` raised by `Txn::retry` or `Txn::check`.
///
/// `atomically` declares an abstract `raise` (the body can raise anything),
/// so a caller's `catch` binds an abstract `Error`. Use this predicate to
/// detect the blocking condition without depending on the constructor:
///
/// # Example
/// ```mbt check
/// test {
///   let cell : @transaction.TVar[Int32] = @transaction.TVar::new(0)
///   try
///     @transaction.atomically(txn => {
///       txn.check(txn.read(cell) > 0)
///       txn.read(cell)
///     })
///   catch {
///     err => assert_true(@transaction.is_retry(err))
///   } noraise {
///     _ => fail("expected the transaction to block")
///   }
/// }
/// ```
pub fn is_retry(err : Error) -> Bool {
  err is Retry(_)
}

///|
/// Whether `err` is the `Conflict` raised when a transaction's snapshot went
/// stale.
///
/// `atomically` and `atomically_async` restart the body automatically on
/// conflict, so only custom runners need this predicate.
pub fn is_conflict(err : Error) -> Bool {
  err is Conflict(_)
}
