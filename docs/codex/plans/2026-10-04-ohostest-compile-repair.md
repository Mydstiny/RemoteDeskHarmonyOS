# ohosTest 编译修复与单元测试全量覆盖（2026-10-04）

用户 2026-10-04 同意按“清孤儿测试 → 更新过期测试 → 机械修复严格写法 → 纳入门禁并覆盖全部测试”执行。只改测试代码与流程文档，不改业务逻辑。

## 背景

- `default@OhosTestCompileArkTS` 只编译主代码，从不编译 `entry/src/test`（`default@UnitTestArkTS` 同样不编译测试文件）。
- 单元测试只由 `ohosTest@OhosTestCompileArkTS` 按严格 ArkTS 编译，但设备列表只引用了约 295 个共享用例中的 73 个，另有 8 个测试文件哪里都没登记；这 73 个就已有 300 个编译错误，设备上的 hypium 测试一直无法运行。
- 让设备列表覆盖全部用例后错误为 658 个。

## 执行

| 阶段 | 内容 | 提交 |
|---|---|---|
| 1 | 修复原有列表的 300 个错误；删除被测源码从未进入 git 历史的 4 个 RustDesk Pro 地址簿测试及其编译探针；按当前批量发送接口重写 `RemoteKeyDispatcher.test`（旧用例针对从未落地的 `dispatchSemanticAction`/`sendModifierDown`） | `91fe77272` |
| 2 | 共享列表登记全部测试文件，设备列表改为调用共享列表；修复其余错误；删除针对从未落地的 RustDesk Pro 二次验证/登录挑战设计的测试（`RustDeskProTwoFactorPolicy.test`、`RustDeskProApiService.test` 及其夹具、`RustDeskProSyncService.test`，`RustDeskProApiPolicy.test` 中 10 个用例、`RustDeskProSyncPolicy.test` 中 1 个用例）；`RustDeskProApiPolicy` 的 404 用例按 `8acb5b64a` 已落地的“404/400/405 回退”契约改写，并补充已落地登录解析的用例 | `c266d8b23` |
| 3 | `ohosTest@OhosTestCompileArkTS` 与 `scripts/tests/test_unit_test_registration.cjs --self-test` 成为所有改动的必跑门禁（项目与工作区 `AGENTS.md`、DECISIONS D-025） | 与本记录同一文档提交 |

严格 ArkTS 的测试写法统一放在 `entry/src/test/helpers/RecordTestUtils.ets`：`withoutKey` 代替 `delete`，`withOverrides` 代替对象展开（严格模式拒绝 `Partial<T>` 与 `Object.assign`），`jsonRecord` 用于检查序列化结果的键。

## 验证方法

每阶段除三项 Hvigor、登记检查、Light 与 diff 外，用宿主机运行器（TS 转译 + vm，平台 kit 为调用即报错的桩）分别运行修改前（git archive）与修改后的同一批测试，比较失败集合：

- 阶段 1：17 个套件，HEAD 261/290，修改后 270/287；失败集合除重写的 `RemoteKeyDispatcher`（旧 12 个全失败，新 9 个全通过）外完全一致。
- 阶段 2：56 个套件，HEAD 565/631（6 个无法加载），修改后 595/657（2 个无法加载，均为宿主机环境限制）；62 个失败前后一致；新出现的失败只在 HEAD 无法加载的 `RustDeskProApiPolicy` 中，已按上文处理，现 10/10。

## 遗留

- 宿主机上前后一致失败的用例（阶段 1 的 17 个、阶段 2 的 62 个）未逐一定性：可能是宿主机桩的限制，也可能是过期断言；需在设备上运行 ohosTest 后再判断。本轮按用户要求未装机。
- `entry/src/test` 与 `entry/src/ohosTest/ets/test` 有 18 个同名但内容不同的测试文件，多数 describe 名相同，设备运行时两份都会执行，待合并。
- 设计待定：当前 `parseRustDeskProLoginResponse` 先识别 `type=email_check` 再检查 `error` 字段；被删除的旧用例期望相反顺序（先处理服务器错误）。是否调整由 RustDesk Pro 二次验证工作决定。
- `RemoteKeyDispatcher` 的批量发送抛异常时 once 锁存不会被清除（复核 P3，未覆盖）。
