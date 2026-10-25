///|
/// Minimal bank-withdrawal demo showing transactional rollback.
///
/// Three scenes: a withdrawal blocked by insufficient funds, a withdrawal
/// that writes first and is then rejected by a policy rule (the write is
/// rolled back — the balance never dips), and a legal withdrawal that
/// commits. Run with `moon run examples/rollback`.
fn main raise {
  let balance = @transaction.TVar::new(100)
  let min_required = 50

  // Scene 1: overdraft. `check` raises Retry, the body aborts, and nothing
  // is written — the caller sees the balance untouched.
  @transaction.atomically(txn => {
    let funds = txn.read(balance)
    txn.check(funds >= 500)
    txn.write(balance, funds - 500)
  }) catch {
    err => {
      assert_true(@transaction.is_retry(err))
      println("withdraw 500: blocked (insufficient funds)")
    }
  }
  println("  balance: \{balance.peek()}")

  // Scene 2: the write happens, then a policy rule rejects it. The whole
  // transaction rolls back — the deduction never becomes visible, even
  // though the body already performed it.
  @transaction.atomically(txn => {
    let funds = txn.read(balance)
    txn.check(funds >= 60)
    txn.write(balance, funds - 60)
    // Business rule: the account must always keep at least 50.
    if funds - 60 < min_required {
      (fail("would drop below the minimum balance of 50") : Unit)
    }
  }) catch {
    err => {
      assert_true(!@transaction.is_retry(err))
      println("withdraw 60: rejected and rolled back")
      println("  reason: would drop below the minimum balance of 50")
      ignore(err)
    }
  }
  println("  balance: \{balance.peek()}")

  // Scene 3: a legal withdrawal commits as one atomic step.
  @transaction.atomically(txn => {
    let funds = txn.read(balance)
    txn.check(funds - 30 >= min_required)
    txn.write(balance, funds - 30)
  })
  println("withdraw 30: committed")
  println("  balance: \{balance.peek()}")
}
