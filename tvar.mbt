///|
/// Monotonic identifier source for transactional variables.
let tvar_next_id : Ref[Int] = Ref(0)

///|
/// A shared transactional variable, the unit of state an STM program is built
/// from.
///
/// Inside a transaction, read it with `Txn::read` and update it with
/// `Txn::write` or `Txn::modify`; the updates become visible to other
/// transactions only when the transaction commits. Outside a transaction,
/// `peek` returns the last committed value.
///
/// Values stored in a `TVar` should be immutable: for `Array` or `Map` values,
/// write a fresh copy instead of mutating the value returned by `Txn::read`.
/// Two `TVar` handles are equal exactly when they refer to the same variable.
///
/// # Example
/// ```mbt check
/// test {
///   let account = @transaction.TVar::new(100)
///   @transaction.atomically(txn => {
///     let balance = txn.read(account)
///     txn.check(balance >= 10)
///     txn.write(account, balance - 10)
///   })
///   inspect(account.peek(), content="90")
/// }
/// ```
pub struct TVar[T] {
  priv id : Int
  priv mut value : T
  priv mut version : Int
  priv pending : Map[Int, T]
}

///|
/// Create a transactional variable with an initial committed value.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new([1, 2, 3])
///   inspect(cell.peek().length(), content="3")
/// }
/// ```
pub fn[T] TVar::new(value : T) -> TVar[T] {
  let id = tvar_next_id.val
  tvar_next_id.val = id + 1
  { id, value, version: 0, pending: Map([]), }
}

///|
/// Read the last committed value without taking part in a transaction.
///
/// This is a plain read: it never blocks, never conflicts, and may race with
/// in-flight transactions by design. Use it for inspection and for code that
/// runs outside transactions; inside a transaction, use `Txn::read` so the
/// read joins the transaction's snapshot.
///
/// # Example
/// ```mbt check
/// test {
///   let cell = @transaction.TVar::new(5)
///   inspect(cell.peek(), content="5")
/// }
/// ```
pub fn[T] TVar::peek(self : TVar[T]) -> T {
  self.value
}

///|
/// Two `TVar` handles are equal exactly when they refer to the same variable.
pub impl[T] Eq for TVar[T] with fn equal(self, other) {
  self.id == other.id
}

///|
pub extend TVar with Eq::{equal, not_equal}

///|
/// `TVar` hashes by identity, so it can be used as a `Map` or `Set` key.
pub impl[T] Hash for TVar[T] with fn hash_combine(self, hasher) {
  hasher.combine(self.id)
}

///|
pub extend TVar with Hash::{hash, hash_combine}
