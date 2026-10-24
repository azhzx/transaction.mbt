///|
/// A transactional variable that is either empty or holds exactly one value.
///
/// `take` retries while the cell is empty, and `put` retries while it is full,
/// which makes `TMVar` a one-slot meeting point: a `take` and a `put` pair up
/// inside one atomic step. Use `TQueue` when any number of values may be
/// pending.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full("gift")
///   let got = @transaction.atomically(txn => box.take(txn))
///   inspect(got, content="gift")
///   assert_true(box.peek() is None)
/// }
/// ```
pub struct TMVar[T] {
  priv cell : TVar[T?]
}

///|
/// Read the current contents without removing them; `None` when empty.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full(9)
///   assert_true(box.peek() is Some(9))
/// }
/// ```
pub fn[T] TMVar::peek(self : TMVar[T]) -> T? {
  self.cell.peek()
}

///|
/// Create an empty `TMVar`.
pub fn[T] TMVar::new() -> TMVar[T] {
  { cell: TVar::new(None), }
}

///|
/// Create a `TMVar` that already holds `value`.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full(1)
///   assert_true(box.peek() is Some(1))
/// }
/// ```
pub fn[T] TMVar::full(value : T) -> TMVar[T] {
  { cell: TVar::new(Some(value)), }
}

///|
/// Read the current contents without removing them.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full(9)
///   let value = @transaction.atomically(txn => box.read(txn))
///   assert_true(value is Some(9))
/// }
/// ```
pub fn[T] TMVar::read(self : TMVar[T], txn : Txn) -> T? raise {
  txn.read(self.cell)
}

///|
/// Return whether the `TMVar` is empty in this transaction.
///
/// # Example
/// ```mbt check
/// test {
///   let box : @transaction.TMVar[Int] = @transaction.TMVar::new()
///   let empty = @transaction.atomically(txn => box.is_empty(txn))
///   inspect(empty, content="true")
/// }
/// ```
pub fn[T] TMVar::is_empty(self : TMVar[T], txn : Txn) -> Bool raise {
  match txn.read(self.cell) {
    None => true
    Some(_) => false
  }
}

///|
/// Take the value, retrying while the `TMVar` is empty.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full("x")
///   let value = @transaction.atomically(txn => box.take(txn))
///   inspect(value, content="x")
/// }
/// ```
pub fn[T] TMVar::take(self : TMVar[T], txn : Txn) -> T raise {
  match txn.read(self.cell) {
    Some(value) => {
      txn.write(self.cell, None)
      value
    }
    None => txn.retry()
  }
}

///|
/// Take the value if present, without retrying.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full(1)
///   let txn = @transaction.Txn::begin()
///   assert_true(txn.run(_ => box.try_take(txn)) is Some(1))
///   assert_true(txn.run(_ => box.try_take(txn)) is None)
/// }
/// ```
pub fn[T] TMVar::try_take(self : TMVar[T], txn : Txn) -> T? raise {
  match txn.read(self.cell) {
    Some(value) => {
      txn.write(self.cell, None)
      Some(value)
    }
    None => None
  }
}

///|
/// Put `value`, retrying while the `TMVar` is full.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::new()
///   let txn = @transaction.Txn::begin()
///   txn.run(_ => box.put(txn, "v"))
///   assert_true(box.peek() is Some("v"))
/// }
/// ```
pub fn[T] TMVar::put(self : TMVar[T], txn : Txn, value : T) -> Unit raise {
  match txn.read(self.cell) {
    None => txn.write(self.cell, Some(value))
    Some(_) => txn.retry()
  }
}

///|
/// Put `value` if the `TMVar` is empty, without retrying.
///
/// Returns whether the value was stored.
///
/// # Example
/// ```mbt check
/// test {
///   let box = @transaction.TMVar::full("kept")
///   let txn = @transaction.Txn::begin()
///   inspect(txn.run(_ => box.try_put(txn, "dropped")), content="false")
///   assert_true(box.peek() is Some("kept"))
/// }
/// ```
pub fn[T] TMVar::try_put(self : TMVar[T], txn : Txn, value : T) -> Bool raise {
  match txn.read(self.cell) {
    None => {
      txn.write(self.cell, Some(value))
      true
    }
    Some(_) => false
  }
}
