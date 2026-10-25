// Lowering probes for the proof pipeline, phase A of the verification plan.
// Each probe answers one feasibility question for verifying the STM core.
// Run with `moon prove proofs`; every probe must report proved.
//
// Probe findings recorded here shape the pilot design:
// - logic bodies support FixedArray indexing/arithmetic/quantifiers and
//   .mbtp predicate calls, but not struct field access or Array::length;
// - contracted bodies support FixedArray element writes but not struct
//   field mutation; named lambda parameters are required in contracts;
// - require clauses are caller obligations; a require on a function with
//   no caller floats up as an unprovable goal — self-contained contracted
//   functions (locals only, no cross-function state mutation) are the
//   reliable proof shape on this toolchain.

///|
/// Probe 1: does the lowering track heap mutation against a stale local
/// snapshot? The STM proofs constantly relate a mutated slot back to a
/// value captured before the write.
fn probe_mutation_snapshot() -> Unit {
  let arr : FixedArray[Int32] = FixedArray::make(1, 41)
  let before = arr[0]
  arr[0] = before + 1
  proof_assert arr[0] == before + 1
  proof_assert arr[0] == 42
}

///|
/// Probe 2a: a helper's postcondition is trusted at the call site — the
/// prover uses the contract, not the body.
fn helper_make_cell(
  v : Int32,
) -> FixedArray[Int32] where {
  proof_ensure: result => cell_is(result, v),
} {
  let arr : FixedArray[Int32] = FixedArray::make(1, v)
  arr
}

///|
/// Probe 2b (frame): a pure helper must provably leave the array alone —
/// this is what lets "rollback restores" go through, since rollback in the
/// record-log design never reaches into the committed-value array.
fn helper_bump_own(
  n : Int32,
) -> Int32 where {
  proof_ensure: result => result == n + 1,
} {
  n + 1
}

///|
fn probe_frame() -> Unit {
  let arr = helper_make_cell(41)
  let bumped = helper_bump_own(7)
  proof_assert bumped == 8
  proof_assert cell_is(arr, 41)
}

///|
/// Probe 3: quantified predicates over FixedArray-backed parallel logs, the
/// layout the log-based STM proofs use.
fn probe_logic_over_array() -> Unit {
  let ids : FixedArray[Int32] = FixedArray::make(4, 0)
  let values : FixedArray[Int32] = FixedArray::make(4, 0)
  ids[0] = 3
  values[0] = 10
  proof_assert log_size_ok(ids, values, 1)
  proof_assert has_write(ids, 3, 1)
  proof_assert no_write_upto(ids, 4, 1)
  proof_assert staged_value_is(ids, values, 3, 1, 10)
  proof_assert distinct_upto(ids, 1)
}
