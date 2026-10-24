///|
/// Raised by `Txn::retry` to abort the current attempt because it cannot make
/// progress yet. The payload is the global commit version observed at the
/// moment of the retry.
///
/// A blocking runner (such as `@transaction/runner.atomically_async`) parks
/// until the commit version advances, then runs the body again from the
/// beginning. Under `atomically` the error propagates to the caller.
pub suberror Retry {
  Retry(Int)
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
  Conflict(Int)
}

///|
/// Whether `err` is the `Retry` raised by `Txn::retry` or `Txn::check`.
///
/// `atomically` declares an abstract `raise` (the body can raise anything),
/// so a caller's `catch` binds an abstract `Error` that cannot be pattern
/// matched with constructors. Use this predicate to detect the blocking
/// condition instead:
///
/// # Example
/// ```mbt check
/// test {
///   let cell : @transaction.TVar[Int] = @transaction.TVar::new(0)
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
