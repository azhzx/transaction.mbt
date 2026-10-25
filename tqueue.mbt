///|
/// A transactional FIFO queue backed by one `TVar` holding an immutable array.
///
/// `pop` retries while the queue is empty, so a consumer parks (under
/// `@transaction/runner.atomically_async`) until a producer pushes. Pushes and
/// pops copy the array, so committed values are never mutated in place; this
/// keeps the implementation simple, and a two-list or linked-node
/// representation can replace it later without changing the API.
///
/// # Example
/// ```mbt check
/// test {
///   let jobs = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   txn.run(_ => {
///     jobs.push(txn, "a")
///     jobs.push(txn, "b")
///   })
///   inspect(txn.run(t => jobs.pop(t)), content="a")
/// }
/// ```
pub struct TQueue[T] {
  priv items : TVar[Array[T]]
}

///|
/// Create an empty queue.
///
/// # Example
/// ```mbt check
/// test {
///   let queue : @transaction.TQueue[Int32] = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   inspect(txn.run(t => queue.is_empty(t)), content="true")
/// }
/// ```
pub fn[T] TQueue::new() -> TQueue[T] {
  { items: TVar::new([]), }
}

///|
/// Append `value` to the queue.
///
/// # Example
/// ```mbt check
/// test {
///   let queue = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   txn.run(t => queue.push(t, 1))
///   inspect(@transaction.atomically(t => queue.length(t)), content="1")
/// }
/// ```
pub fn[T] TQueue::push(self : TQueue[T], txn : Txn, value : T) -> Unit raise {
  let items = txn.read(self.items)
  let next = items.copy()
  next.push(value)
  txn.write(self.items, next)
}

///|
/// Remove and return the front element, retrying while the queue is empty.
///
/// # Example
/// ```mbt check
/// test {
///   let queue = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   txn.run(t => queue.push(t, 42))
///   inspect(txn.run(t => queue.pop(t)), content="42")
/// }
/// ```
pub fn[T] TQueue::pop(self : TQueue[T], txn : Txn) -> T raise {
  match txn.read(self.items) {
    [] => txn.retry()
    [head, .. tail] => {
      txn.write(self.items, tail.to_owned())
      head
    }
  }
}

///|
/// Remove and return the front element, or `None` when the queue is empty.
///
/// # Example
/// ```mbt check
/// test {
///   let queue : @transaction.TQueue[Int32] = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   assert_true(txn.run(t => queue.try_pop(t)) is None)
/// }
/// ```
pub fn[T] TQueue::try_pop(self : TQueue[T], txn : Txn) -> T? raise {
  match txn.read(self.items) {
    [] => None
    [head, .. tail] => {
      txn.write(self.items, tail.to_owned())
      Some(head)
    }
  }
}

///|
/// Return the front element without removing it.
///
/// # Example
/// ```mbt check
/// test {
///   let queue = @transaction.TQueue::new()
///   let txn = @transaction.Txn::begin()
///   txn.run(t => queue.push(t, "head"))
///   assert_true(txn.run(t => queue.peek(t)) is Some("head"))
/// }
/// ```
pub fn[T] TQueue::peek(self : TQueue[T], txn : Txn) -> T? raise {
  match txn.read(self.items) {
    [] => None
    [head, ..] => Some(head)
  }
}

///|
/// Return the number of elements in the queue.
///
/// This is a transactional read: outside a transaction it reports the last
/// committed length.
pub fn[T] TQueue::length(self : TQueue[T], txn : Txn) -> Int32 raise {
  txn.read(self.items).length()
}

///|
/// Return whether the queue is empty.
pub fn[T] TQueue::is_empty(self : TQueue[T], txn : Txn) -> Bool raise {
  txn.read(self.items).is_empty()
}
