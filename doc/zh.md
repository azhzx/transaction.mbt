# azhzx/transaction — 用户与设计手册（中文）

[MoonBit](https://moonbitlang.com) 的软件事务内存（STM）：以 `TVar` 共享状态、以
原子且可组合的事务更新状态，用 `retry` / `or_else` 实现"会组合的阻塞"而不是死锁。

- [项目目标](#项目目标)
- [安装](#安装)
- [核心概念](#核心概念)
- [API 参考](#api-参考)
- [语义与使用规则](#语义与使用规则)
- [组合式阻塞模式](#组合式阻塞模式)
- [设计内幕](#设计内幕)
- [并发模型与后端](#并发模型与后端)
- [测试与持续集成](#测试与持续集成)
- [与其他方案对比](#与其他方案对比)
- [常见问题](#常见问题)
- [参考文献与致谢](#参考文献与致谢)

## 项目目标

1. 让多个 MoonBit 任务之间的共享可变状态**安全且可组合**：任意两个事务合并为
   一个原子步骤，无需锁、无需考虑加锁顺序、不会错过唤醒（唤醒是保守的：
   任意提交都会唤醒挂起事务，条件不满足时它会再次挂起）。
2. 核心包零第三方依赖，在所有后端（wasm、wasm-gc、js、native）均可构建。
3. 提供"会组合的阻塞"：`retry` 阻塞到**事务读过的变量发生变化**为止；
   `or_else` 把两个阻塞操作合并为一个。
4. 保持小而可审计：核心仅数百行，采用 TL2 风格设计（全局提交时钟、按变量
   版本号、私有写集）。

## 安装

```sh
moon add azhzx/transaction
```

在 `moon.pkg` 中按需导入：

```toml
import {
  "azhzx/transaction" @transaction,
  "azhzx/transaction/runner" @runner, // 仅异步事务需要
  "moonbitlang/async" @aio,           // 仅 runner 需要
}
```

核心包（`@transaction`）无依赖。runner 包（`@runner`）额外依赖
`moonbitlang/async`，用于事务体内需要 `await` 的场景。

## 核心概念

（README 中有这些片段的可运行版本。）

**TVar** —— 事务变量。`TVar::new(v)` 创建；事务外用 `tv.peek()` 读取最后提交
的值。

**atomically** —— 把一段代码作为一个事务运行：

```moonbit
@transaction.atomically(txn => {
  let funds = txn.read(alice)
  txn.check(funds >= 30)
  txn.write(alice, funds - 30)
  txn.modify(bob, b => b + 30)
})
```

所有读取都经由 `Txn` 句柄完成；写入只有提交后才对其他事务可见。

**retry / check** —— `txn.retry()` 表示"当前无法推进"并中止本次尝试；
`txn.check(cond)` 在条件不成立时重试。在异步 runner 下，任务会**挂起**，直到
全局提交时钟越过本事务最后一次校验的快照，然后从头重跑事务体；若挂起期间
已经发生过相关提交，则立即重跑，而不是等待下一次提交。

**or_else** —— 组合备选：`txn.or_else(first, second)` 先跑 `first`；若其
retry，则丢弃其全部效果改跑 `second`。在 runner 下，组合后的操作在**任一**
数据源变化时被唤醒。

**TMVar / TQueue** —— 现成结构：单槽"空/满"单元（空时 `take` 重试、满时
`put` 重试）与事务性 FIFO 队列（空时 `pop` 重试）。

**atomically_async** —— runner 的入口，事务体内可以 `await`：

```moonbit
@runner.atomically_async(txn => {
  let v = txn.read(cell)
  @aio.pause()               // 可任意挂起
  txn.write(cell, v + 1)     // 下次读取/提交时重新校验
})
```

## API 参考

### 核心包 `azhzx/transaction`

| 条目 | 签名 | 用途 |
|---|---|---|
| `TVar::new` | `(T) -> TVar[T]` | 以初始值创建 |
| `TVar::peek` | `(TVar[T]) -> T` | 事务外读最后提交值 |
| `Txn::read` | `(Txn, TVar[T]) -> T raise Conflict` | 事务内读取（可见自己未提交的写） |
| `Txn::write` | `(Txn, TVar[T], T) -> Unit` | 缓冲写入，提交时生效 |
| `Txn::modify` | `(Txn, TVar[T], (T) -> T raise) -> Unit raise` | 读-改-写 |
| `Txn::check` | `(Txn, Bool) -> Unit raise Retry` | 条件不成立则重试 |
| `Txn::retry` | `(Txn) -> T raise Retry` | 阻塞当前事务 |
| `Txn::or_else` | `(Txn, (Txn) -> T raise, (Txn) -> T raise) -> T raise` | 组合式选择 |
| `Txn::commit` | `(Txn) -> Unit raise Conflict` | 手动提交（自定义 runner） |
| `Txn::rollback` | `(Txn) -> Unit` | 手动回滚（自定义 runner） |
| `atomically` | `((Txn) -> T raise) -> T raise` | 运行一个同步事务 |
| `is_retry` / `is_conflict` | `(Error) -> Bool` | 在抽象 `raise` 上做错误分派 |
| `commit_version` | `() -> Int64` | 全局提交时钟（自定义 runner 用） |
| `on_commit` | `(() -> Unit) -> Unit` | 提交后回调（自定义 runner 用） |
| `TMVar::*` | 见 `.mbti` | 空/满单槽单元 |
| `TQueue::*` | 见 `.mbti` | 事务性 FIFO 队列 |

`TVar` 的 `Eq`/`Hash` 按身份实现：两个句柄相等当且仅当指向同一个变量。

### runner 包 `azhzx/transaction/runner`

| 条目 | 用途 |
|---|---|
| `atomically_async(f)` | 运行可 await 的事务；`Retry` 挂起任务直到时钟越过其快照（挂起期间已发生的提交会立即触发重跑），`Conflict` 让出一次后自动重跑 |

自定义 runner 可用的底层原语：`Txn::begin`、`Txn::run`、
`Txn::run_async`、`Txn::commit`、`Txn::rollback`、`commit_version`、
`on_commit`。自定义 runner 的驱动方式是 `begin` → 事务体（`run` /
`run_async`，或手动 `write` + `commit`），并在 `Retry` / `Conflict` 时重启
——正是 `atomically` 与 `atomically_async` 内部的做法。`commit` 校验读集并
原子应用缓冲写入（快照过期则回滚后抛 `Conflict`）；`rollback` 丢弃全部
写入，且都会清空句柄日志，因此之后句柄仍可复用。

## 语义与使用规则

- **原子性。** 每个 `atomically` 块的所有写入要么全部生效、要么全部丢弃。
- **隔离性。** 事务体看到的是一个一致快照；其他事务未提交的写入永不可见
  （`pending` 写集按事务 id 隔离）。
- **验证保证一致性。** 每次读取都登记版本校验；一旦读过的变量被他人提交，
  事务体回滚并重跑——`atomically` / `atomically_async` 下全自动。
- **事务体可能重跑。** 把 I/O、日志等副作用移出事务体，或做成幂等。
- **值必须不可变。** 容器采用写时复制（`copy()` 后改副本再 `write` 回去）。
- **事务不可嵌套。** 内层 `atomically` 独立提交；若其使外层快照失效，外层自动
  重启——若内层每次都使外层失效，外层会永久重启。不要把嵌套 `atomically`
  写进事务体。
- **阻塞的事务没有任何效果。** `retry` 触发时，本次尝试的全部写入都会回滚——
  见下文屏障模式。
- **错误原样传播。** 事务体抛出的错误回滚后直达调用方；用 `is_retry`
  区分"被阻塞"与"失败"。
- **取消不是事务性的。** 在事务体内挂起时取消任务会展开事务体、回滚事务且
  不提交；若事务体捕获取消错误后正常返回，事务仍会照常提交。

## 组合式阻塞模式

**生产者/消费者** —— `TQueue::pop` 空时重试；runner 下消费者挂起，下次 push
即唤醒：

```moonbit
@runner.atomically_async(txn => jobs.pop(txn))
```

**选择** —— 哪个邮箱有信就服务哪个：

```moonbit
@runner.atomically_async(txn =>
  txn.or_else(t => urgent.take(t), t => regular.take(t)))
```

**屏障（易错点）。** 阻塞的事务会回滚自己的写入，因此"先增加到达计数、再
等待"必须拆成**两个**事务——计数单独提交，等待单独阻塞：

```moonbit
@runner.atomically_async(txn => txn.modify(arrived, v => v + 1)) // 提交
@runner.atomically_async(txn => txn.check(txn.read(arrived) == n)) // 阻塞
```

若把两步写进同一个事务会死锁：每次尝试的计数增量都被回滚，计数永远不涨。

**信号量** —— 许可数放 `TVar`；一个事务里 `check` 并减一获取，另一个事务里
加一释放。

**有界缓冲** —— push 前先 `txn.check(queue.length(txn) < cap)`；缓冲满则
生产者挂起。

## 设计内幕

整体布局遵循 TL2 系列算法，并针对协作式单线程运行时做了适配：

- 一个**全局提交时钟**，每个含写事务的提交使其加一。
- 每个 `TVar` 保存：**value**（已提交值）、单调递增的 **version**、按事务 id
  索引的 **pending** 写集（异步事务体带着未提交写入挂起而不泄漏，靠的就是
  它）。
- 每个 `Txn` 维护三份日志：**validators**（重检每个读过变量版本的闭包）、
  **commits**（提交时回写的闭包）、**undo**（回滚时清理 pending 的动作，
  逆序执行）。
- `Txn::read` 仅在全局时钟自上次校验后发生变化时才重验读集，然后优先返回
  本事务的 pending 值，否则返回已提交值。
- `Txn::retry` 携带最后一次校验的快照时钟；runner 等到时钟与之不同再重跑，
  因此挂起期间已发生的提交会触发立即重跑，而不是丢唤醒。
- 验证与提交在同一个**同步段**内完成；协程只在挂起点切换，因此校验与提交
  之间不可能被插入其他事务——无需任何锁。
- `or_else` 在进入第一分支前记录三份日志的长度，retry 后截断回标记处，第二
  分支从干净状态开始。
- runner 在条件变量上挂起；每次写提交都广播（保守做法——被唤醒的事务可能
  重跑后条件仍不满足而再次挂起；不影响正确性。按变量精确唤醒在路线图中）。

复杂度：提交为 O(读集 + 写集)；单次读取 O(1) 加重验证开销（全局时钟未变时
跳过）。

## 并发模型与后端

MoonBit 任务在单线程事件循环上协作调度，任意数量任务共享 `TVar` 都不会有
数据竞争——本库正是为此设计。当前工具链未暴露真正的并行线程；若未来出现
共享内存后端，只需把"验证+提交"同步段包进一把锁即可迁移（时钟与日志结构
已就位）。

后端支持情况：

| 包 | wasm | wasm-gc | js | native |
|---|---|---|---|---|
| core | ✓ | ✓ | ✓ | ✓ |
| runner | ✓ | — | ✓ | ✓ |

核心包零依赖，在所有后端均可类型检查。runner 依赖 `moonbitlang/async`，
其固定版本（0.21.3）没有提供 wasm-gc 入口（`run_async_main`），因此依赖
runner 的包声明了 `supported_targets = "wasm+js+native"`，工具链在
wasm-gc 上自动跳过它们。待 `moonbitlang/async` 后续版本支持 wasm-gc 后，
放宽声明即可。

## 测试与持续集成

- 141 个测试，分四层：文档/README doctest、单元测试（黑盒 + 白盒）、固定
  种子的随机压力测试（模型等价、不变量、回滚完备性）、集成场景（`tests/`，
  真实多任务模式）。压力套件包含 torn-state 检测器：更新者原子推进 8 个
  TVar，观察者读到一半故意挂起——按构造不可能观察到新旧混合值，测试断言其
  恒为零。
- CI（GitHub Actions）执行 `moon check`、`moon build`、wasm/js/native
  三后端 `moon test`、两个可运行示例、覆盖率（`moon test --enable-coverage` +
  `moon coverage report`）与基准测试（`moon bench --target native
  --release`，仅供参考）。

### 基准测试

`transaction_bench_test.mbt` 度量核心路径（`moon bench --target native
--release`）。Apple Silicon 上的参考数据：

| 路径 | 单事务耗时 |
|---|---|
| 纯引用自增（基线，无 STM） | ~8 ns |
| 只读事务，1 个 TVar | ~92 ns |
| 读-改-写事务，1 个 TVar | ~140 ns |
| 只读事务，10 个 TVar | ~256 ns |
| 读-改-写事务，10 个 TVar | ~840 ns |
| 经 `retry` / 事务体错误回滚 | ~140–205 ns |
| `or_else` 分派（两个分支） | ~105–120 ns |
| 手动 `begin` + `write` + `commit` / `rollback` | ~165–240 ns |
| `TQueue` 空队列 push+pop 对 | ~375 ns |
| `TQueue` 长度 100 时 100 push + 100 pop | ~38 µs（O(n) 拷贝） |
| `TMVar` put+take 对 | ~365 ns |

队列两组数字定量呈现了已知技术债：数组拷贝式实现让长队列变贵，这正是
路线图中双列表表示法的动机。表中数字仅供量级参考；硬件与工具链会改变它们，
依赖具体数值前请重跑 `moon bench`。

## 与其他方案对比

| | 互斥锁 | 通道 | 本 STM |
|---|---|---|---|
| 多变量原子更新 | 手工、易死锁 | 不适用 | 一个 `atomically` 块 |
| 阻塞可组合 | 否（嵌套获取易死锁） | 部分 | `retry` + `or_else` |
| 错过唤醒 | 可能（手写条件变量） | 不会 | 不会（版本号驱动） |
| 事务体可能重跑 | 否 | 否 | 是（副作用需移出） |
| 跨后端 | 是 | 是 | 是（核心包零依赖） |

## 常见问题

**事务体里能做 I/O 吗？** 只能做幂等 I/O——冲突或重试都会重跑事务体。建议
在事务外完成 I/O，再用一个短事务提交结果。

**为什么我的计数器在阻塞事务里永远不涨？** 见上文屏障模式：被重试的尝试会
回滚自己的写入。把"产生效果"与"等待条件"拆成两个事务。

**同步 `atomically` 怎么捕获"被阻塞"？** `catch { err => if
@transaction.is_retry(err) ... }` —— `atomically` 声明抽象 `raise`，用谓词分派即可，
不要依赖错误构造器。

**这是 GHC STM 的移植吗？** 不是。语义（retry/orElse、按读集阻塞）遵循已
发表的 STM 文献；实现为原创 MoonBit 代码，结构上参考 TL2 算法族。

**路线图？** 按变量精确唤醒（消除惊群）、双列表队列、TArray/TMap 组合子。

## 参考文献与致谢

设计与语义参考了以下公开文献——未移植任何代码：

- Tim Harris, Simon Marlow, Simon Peyton Jones, Maurice Herlihy,
  *Composable Memory Transactions*（PPoPP 2005）—— `retry`/`orElse` 语义。
- Tim Harris, Keir Fraser, *Language Support for Lightweight Transactions*
  (OOPSLA 2003)。
- Dave Dice, Ori Shalev, Nir Shavit, *Transactional Locking II*（DISC
  2006）—— 全局时钟验证布局。

许可证：Apache-2.0。文献引用仅为致谢；本实现为原创，与所引文献的许可兼容。
