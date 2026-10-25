// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "azhzx/transaction"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/azhzx/transaction.mbt"

license = "Apache-2.0"

keywords = [
  "stm",
  "transactional-memory",
  "concurrency",
  "async",
  "tvar",
  "tmvar",
  "tqueue",
]

preferred_target = "wasm"

description = "Software Transactional Memory for MoonBit: TVars, atomic and composable transactions, retry/or_else blocking, TMVar and TQueue, plus an async runner."

import {
  "moonbitlang/async@0.21.3",
}
