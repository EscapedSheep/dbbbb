# HANDOVER · dbbbb 项目交接

> 写给下一个 session / 下一个 agent：本文件让你零上下文接手。
> 更新时间：2026-09-02 · 交接时项目状态：Swift 版全部既定里程碑完成（v1 + 持久化 + 四引擎编辑闭环 + 导入导出 + 打包 + 宽表/mongoAggregate UI/ping-at-add）。swift build 零警告，355 测试全绿且**全部集成测试已对真实 PG/MySQL/Mongo 跑通**（曾借此发现并修复 PG 编辑的权限内省 bug）。`swift/release/dbbbb-0.2.0-macOS-arm64.zip` 已产出（ad-hoc 签名）。旧 Electron 版已拍板废弃。
> **下一步：无既定开发项。剩余：拿到 Apple Developer 凭据后正式签名+公证（命令在 make-app.sh 头注释）；人工过一遍 NSTableView 编辑/聚合切换的 GUI（无辅助功能权限，自动化点不了）（见 §6）。**

## 1. 这是什么项目

dbbbb：本地优先的 macOS 数据库客户端，支持 PostgreSQL / MySQL / MongoDB / SQLite 四引擎。定位：打开连接、定位数据、安全地做审慎修改，不要全功能 DBA 套件的视觉重量。

仓库里有两代实现（无 git 仓库，本地目录）：

- `swift/` — **现行版**。Swift 6.3 + SwiftUI 原生重写（SwiftPM，macOS 15+）。
  - 构建：`cd swift && swift build`；运行：`swift run`（或 `.build/debug/dbbbb`）
  - 测试：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（CLT 无 XCTest，必须指 Xcode）
- `src/`（+ `docs/`、`package.json`）— **已废弃的 Electron 版**（electron-vite + React + TS）。
  仅作语义参考（尤其 `src/main/adapters/*.ts` 是适配器语义金标准），不再开发。
  验证命令：`npm run typecheck && npm test && npm run build`（最近实测 418 测试全绿、audit 零漏洞）。

## 2. 真源地图（哪份文档管什么）

| 文档 | 管什么 | 状态 |
|---|---|---|
| 本文件 | 交接入口 | 现行 |
| `docs/ARCHITECTURE.md` / `docs/DEVELOPMENT_PLAN.md` / `README.md` | Electron 版架构/计划/说明 | 历史（仅描述 Electron 版） |
| `swift/Package.swift` | Swift 版依赖与 target 布局（dbbbbCore/dbbbbKit/dbbbbApp） | 现行 |
| `swift/Sources/dbbbbCore/Model.swift` | Swift 版类型契约（引擎/命令/DisplayValue/结果） | 现行，改契约先改这里 |
| `swift/Sources/dbbbbKit/Adapter.swift` | 适配器协议 + DataChange | 现行 |

设计与代码冲突时：以 `swift/` 代码为准，Electron 文档不再更新。

## 3. 当前状态

**Swift 版 v1 已完成**（2026-09-01 实测）：
- 四引擎适配器全实现：连接/对象树/预览/有界查询（500 行/5 MiB + 单值 8 MiB 截断标记）/取消/错误脱敏；只读分类器（含 PG `E''`、MySQL `/*!` 两个已知坑的回归测试）；Mongo 自写 BSON/canonical EJSON 编解码（Decimal128 位级保真，MongoKitten 自带的是 stub）。
- 优于 Electron 版的点：SQLite 用 GRDB `interrupt()` 真取消；MySQL 自实现 COM_QUERY 保留空结果集列元数据。
- SwiftUI 外壳：三栏 NavigationSplitView、真实适配器已接线（`SessionStore.makeAdapter` 工厂）、四个 demo 连接自带、新建连接 sheet、亮/暗/系统主题。
- 验证：`rm -rf .build` 全量重建零警告；195 测试全绿（142 XCTest + 53 Swift Testing，14 个集成测试无 env 跳过）；GUI 冒烟 8 秒无崩溃。PG 适配器另通过真实 PostgreSQL 集成测试 7/7（临时 Homebrew 实例，已清理）。

**持久化里程碑已完成**（2026-09-02 实测，223 测试全绿 = 170 XCTest + 53 Swift Testing，14 跳过）：
- `swift/Sources/dbbbbKit/Persistence/`：`KeychainStore`（协议 + Security 实现 + 内存 fake）、`ConnectionStore`（连接清单 JSON + Keychain 密钥）、`QueryLibraryStore`（历史/收藏 JSON）、`AtomicFileWriter`（原子写，目录 0700/文件 0600）。
- 凭据纪律：密码与 Mongo URI 只进 Keychain（generic-password，service `dev.dbbbb.connection`，account = 小写连接 UUID）；`~/Library/Application Support/dbbbb/connections.json` 与 `query-library.json` 均无明文秘密（有测试断言）。
- 连接跨启动恢复：启动时急切重连（适配器构造即连接，惰性连接会波及所有 View）；重连失败只弹脱敏横幅、不丢持久化条目；恢复的 session 保留原 UUID，Keychain 键稳定。删除连接才清清单 + Keychain；demo 连接不持久化。
- 查询历史：只记录成功执行（预览/失败不记）；历史上限 100 条（收藏豁免）、单条 32 KB、总量 4 MB；版本不符绝不覆写用户文件；收藏满显式报错 `storageFullOfFavorites`——以上均对齐 Electron 审计修复语义（`src/renderer/src/lib/query-library.ts`）。UI 入口：查询工作区工具栏 History 按钮弹出 `QueryHistoryView`（点击载入编辑器、星标收藏、删除、清历史保收藏）。
- **仍未做**：Developer ID 签名/公证（本机无签名身份）。

**编辑闭环已完成（PG + Mongo）**（2026-09-02 实测，248 测试全绿 = 183 XCTest + 65 Swift Testing，17 跳过）：
- PG：`PostgresAdapter` 实现 `SupportsEditing.applyDataChange`——事务内元数据内省（参数化 `$1/$2`）→ `PostgresChangePlanner` 规划 → 参数化执行（`PostgresQuery(unsafeSQL:binds:)` 本已存在，新增 `PostgresTextParameter` 文本绑定 + `PostgresChangeMapper` 目录序映射）；`RETURNING *` 0 行 = 乐观锁冲突。Mongo：新纯规划器 `MongoChangePlanner`（整文档 `$eq` 过滤、`_id` 必填不可改、`$set`/`$unset`、经 EJSON 往返 ObjectId/Decimal128 等 tagged 类型），`MongoAdapter` 走自写 BSON wire command，`matchedCount == 0` = 冲突。
- UI：结果视图选中单行右键 "Edit/Delete Row/Document…"（`RecordEditingView`：草稿→复核两段式；production 环境须输入 APPLY 二次确认；删除须输入 DELETE）。Mongo 编辑用 canonical EJSON 文本编辑器 + 复核 diff。
- 失败即关（fail-closed）条件：适配器不遵循 `SupportsEditing`（MySQL/SQLite/Demo）、profile 只读、结果不是单表/集合预览——三者任一即不显示编辑入口；适配器端再查 readOnly，服务端只读设置不动。
- 语义偏差（已拍板）：Mongo 日期 DisplayValue 改为 `{"$date": iso}` 对象（对齐 Electron）——裸字符串会让含日期字段的文档永远无法匹配过滤；Mongo update 无 RETURNING，apply 后统一重新预览刷新。Mongo 编辑不支持删字段（DataChange 表达不了 `$unset`，UI 拒绝并提示设 null）。
- 未验证：dbbbbApp 无测试 target，UI 流程仅 GUI 冒烟覆盖。（编辑/导入集成测试此前未跑——已于当日稍后全部真实跑通，见下。）

**MySQL/SQLite 编辑 + 真实库全量验证 + UI 收尾已完成**（2026-09-02 实测，355 测试全绿 = 280 XCTest + 75 Swift Testing，**0 跳过**）：
- MySQL/SQLite 编辑：`MySQLChangePlanner`/`SQLiteChangePlanner` 纯规划器照 PG 模式（MySQL `<=>`、SQLite `IS` 空值安全等值；OK 包 affectedRows / `changes()` 为 0 = 乐观锁冲突）。MySQL 拒 `bit`+8 种空间类型；SQLite 无拒绝清单（四存储类均可往返，按亲和性决定整型/浮点绑定）。生成列被排除在可编辑元数据外 → 含生成列的表整表拒绝编辑（有测试钉死）。Electron 从未实现 MySQL/SQLite 编辑，语义为对齐 PG 模式的原创。
- **真实库集成测试首跑抓出真 bug**：`listTableChangeColumnsSQL` 里 `has_column_privilege(..., 'DELETE')` 在真实 PG 上报 22023（列级权限无 DELETE，Electron 原版同 bug 一直未被发现）。已修为列级 UPDATE + 表级 `has_table_privilege(c.oid, 'DELETE')`（`PostgresChangePlanner.swift`），修复后 PG 编辑集成测试全过。
- UI 三项：①结果表格换成 NSTableView representable（`Views/ResultsTableView.swift`），9 列上限消除、任意宽表横向滚动；右键编辑/删除语义保留（先选中再出菜单、空区无菜单、单行才显示）。②mongoAggregate UI：Mongo 会话工具栏 Find/Aggregate 分段切换（`SessionStore.mongoQueryMode`），历史条目按文本形状（数组=管道/文档=过滤）恢复模式（`MongoQueryText.isPipeline`）。③添加连接即验证：`addConnection` 在入列前先 `listObjects()` 真实往返，失败则不添加、sheet 内报脱敏错误，四引擎统一。
- 集成测试实测口径：PG 15.18 / MySQL 26.7.0 / MongoDB 8.3.7 临时实例全部跑通（含编辑、导入、聚合、取消、超时、只读拒绝）。实例已拆（见 §7 重建方法）。NSTableView 编辑流与聚合切换只做了构建+冒烟验证，**未人工点击过**。

**导入导出已完成（CSV/JSONL，四引擎）**（2026-09-02 实测，309 测试全绿 = 236 XCTest + 73 Swift Testing，21 跳过）：
- `swift/Sources/dbbbbKit/Transfers/`：`Delimited.swift`（增量 CSV 解析器，RFC4180，**按 unicode scalar 迭代**——Swift `Character` 会合并 CRLF，有回归测试）、`ResultExport.swift`（canonical JSON 排序键、rows→CSV 带表头 CRLF、documents→JSONL）、`Import.swift`/`ImportDriver.swift`（500 条/批、1 GiB 文件上限、100 万行上限、可取消、错误消息无路径）。
- 导出：不需要适配器能力，直接导当前 `QueryResult`（即受 500 行/5 MiB 界的结果），`AtomicFileWriter` 原子写；`DisplayValue.binary` 无可移植编码，导出显式报错 fail-closed。UI：状态栏 "Export…"（NSSavePanel）。
- 导入：`SupportsImporting` 定义为 `importData(_ request: ImportRequest) async throws -> ImportSummary`，四引擎全实现。格式矩阵锁定 CSV→SQL 表 / JSONL→Mongo 集合，其他组合显式拒绝。CSV 字段一律按文本过界由服务端 coercion（PG 类型 OID 文本绑定 / MySQL 字符串绑定 / SQLite 列亲和性 / Mongo EJSON 编解码）；空字段 = 空字符串绝不等于 NULL。PG/MySQL 全文件单事务，SQLite 按批事务（GRDB 限制），Mongo 有序 insert 部分成功计前缀（对齐 Electron）。
- UI：状态栏 "Import…" sheet（选文件→复核[production 输入 IMPORT]→进度→摘要）；fail-closed 门控同编辑（预览单表/集合 + 可写非 demo profile + 适配器遵循协议）。
- 已拍板偏差：未移植 Electron 的"复核后文件未变"二次 stat 与 75ms 进度节流；JSONL→SQL、CSV→Mongo 拒绝。

**打包管线已完成**（2026-09-02 实测）：
- `swift/Scripts/make-app.sh`（幂等、`set -euo pipefail`）：release 构建 → 组装 `dbbbb.app`（bundle id `dev.dbbbb`，版本 0.2.0 脚本常量，LSMinimumSystemVersion 15.0，图标由 `build/icon.png` 经 iconutil 生成）→ ad-hoc 签名（`codesign --force --deep --options runtime --sign -`，hardened runtime 实测不破坏 ad-hoc 启动）→ `swift/release/dbbbb-0.2.0-macOS-arm64.zip`。
- 已验证：二进制完全自包含（SwiftPM 依赖全静态链接，脚本会硬失败于任何非系统 dylib）；`codesign --verify --deep --strict` 通过；直接执行与 `open` 两条路径冒烟均存活 8 秒无崩溃。spctl 拒绝 ad-hoc 属预期（右键打开）。
- **无 Developer ID 身份**（本机 `security find-identity` 为 0），签名/公证做不了；升级命令已写在脚本头注释（正式签名 → notarytool → stapler）。Keychain item 按 service 名键控，ad-hoc → 正式签名不会丢凭据。

**Electron 版**：审计修复全部落地（3 高危 + 一批中危）、M6（MySQL/SQLite）完成、CI 已配（`.github/workflows/ci.yml`）、418 测试全绿。随后用户拍板废弃转 Swift，不再维护。

**在途/后台任务**：无（所有子代理与构建均已结束；session 关闭无影响）。

## 4. 架构与管线（务必延续）

- Swift 版三 target：`dbbbbCore`（纯类型契约）→ `dbbbbKit`（四适配器 + 编辑规划纯函数，目录按引擎分 SQLite/ Postgres/ MySQL/ Mongo/）→ `dbbbbApp`（SwiftUI）。测试在 `swift/Tests/`。
- 不可破坏的纪律：
  - DisplayValue 语义：精度敏感值（bigint/decimal/非有限数/日期）一律字符串；单值超 8 MiB 截断加 `…[dbbbb truncated N bytes]` 标记。
  - 错误消息必须脱敏（无密码/凭据 URI/本地绝对路径），`dbbbbError.userMessage` 是边界。
  - 只读 = 客户端分类器 + 服务端设置双保险；SRV 强制 TLS fail-closed；编辑/导入是可选能力，不实现即 fail-closed。
  - **禁止使用 `#Preview` 宏**（CLT 无 PreviewsMacros 插件，编译直接失败）。
  - Swift 6 严格并发，警告按错误对待。
- 提交前必过检查：
  ```bash
  cd swift && swift build
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
- 集成测试门控（无 env 自动 skip）：`DBBBB_TEST_POSTGRES_URL` / `DBBBB_TEST_MYSQL_URL` / `DBBBB_TEST_MONGO_URL`。

## 5. 关键已拍板（改前先读）

1. **只做 macOS，放弃 Windows/Linux**（2026-09-01 用户拍板）——Electron 版废弃，不需要新旧并存，一切可抛弃。
2. **技术路线 Swift 原生**（同日）：SwiftUI + SwiftPM；MongoKitten（官方 mongo-swift-driver 已死）+ 自写 BSON/EJSON 层；PostgresNIO / MySQLNIO / GRDB。
3. **唯一标准：好看 + 好用**；支持新系统即可（macOS 15+ 部署目标）。
4. 引擎范围锁死四款；Oracle/SQL Server/ER 图/AI 功能等明确不做（源自 Electron 版 DEVELOPMENT_PLAN 的 deferred 清单，仍有效）。
5. Mongo 命令契约：`.mongoFind(collection:filter:)` / `.mongoAggregate(collection:pipeline:)` 显式携带 collection（集成期修复的缺陷，勿回退）。

## 6. 下一步

- **无既定开发项**——v1 以来 HANDOVER 列的里程碑全部完成。剩余尾巴：
  - 拿到 Apple Developer 凭据后正式签名 + 公证（命令在 `swift/Scripts/make-app.sh` 头注释）。
  - 人工 GUI 过一遍：宽表 NSTableView 的右键编辑/删除、Mongo 聚合切换、向死端口添加连接看报错（自动化无辅助功能权限，点不了）。
  - 有真实库时重跑集成测试（重建方法见 §7）。
- ~~Keychain + 查询历史 / 编辑闭环 / 导入导出 / 打包 / MySQL+SQLite 编辑 / 宽表+聚合+ping~~（均 2026-09-02 完成，见 §3）。

## 7. 环境备注

- 机器：macOS 26.5.2 (arm64)，Swift 6.3.3（CLT 在 `/Library/Developer/CommandLineTools`），Xcode.app 存在于 `/Applications/Xcode.app` 但 xcode-select 指向 CLT——**跑 swift test 必须加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`**，不要改全局 xcode-select。
- SwiftPM 的 `.build` 有目录锁，并行代理构建会排队，属正常。
- Electron 版坑：若遇 `Electron uninstall` 报错 → `node node_modules/electron/install.js`（升级 electron 后 postinstall 可能被跳过）。
- 测试框架混用是现状：XCTest（PG/MySQL/SQLite/Core）+ Swift Testing（Mongo），Xcode 环境两者都能跑，勿统一。
- 本机已 brew 安装 `postgresql@15`、`mysql`、`mongodb-community`（mongodb/brew tap，已 `brew trust`）；**实例已全部停止**，临时数据目录在 `/tmp/dbbbb-it/{pg,mysql,mongo}`（/tmp 重启即失）。
- 集成测试实例重建（直接起进程，不用 brew services）：
  - PG：`/opt/homebrew/opt/postgresql@15/bin/initdb -D /tmp/dbbbb-it/pg/data -U $USER` → `pg_ctl -D ... -o "-p 55432" -l /tmp/dbbbb-it/pg/server.log start` → `createdb -p 55432 dbbbb_test`（trust auth）。
  - MySQL：`mysqld --initialize-insecure --datadir=/tmp/dbbbb-it/mysql/data` → `mysqld --datadir=... --port=53306 --bind-address=127.0.0.1 --mysqlx=OFF &` → 建 root 密码 `dbbbb` + `dbbbb_test` 库 + 种子表 `dbbbb_it_seed`（2 行，preview 测试需要）。
  - Mongo：`mongod --dbpath /tmp/dbbbb-it/mongo/db --port 57017 --bind_ip 127.0.0.1 &`（无 auth）。
  - env：`DBBBB_TEST_POSTGRES_URL='postgres://$USER@127.0.0.1:55432/dbbbb_test?sslmode=disable'`、`DBBBB_TEST_MYSQL_URL='mysql://root:dbbbb@127.0.0.1:53306/dbbbb_test'`、`DBBBB_TEST_MONGO_URL='mongodb://127.0.0.1:57017/dbbbb_test'`。
- 无 git 仓库（历史决策只存在于本文件与对话记录）。

## 8. 快速恢复上下文（30 秒版）

读本文件 → `swift/Sources/dbbbbCore/Model.swift`（契约）→ **下一步：无既定项，见 §6 尾巴清单**。
