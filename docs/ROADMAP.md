# dbbbb 开发计划（Swift 版）

> 2026-09-04 制定。依据：全面审计 + 对照 DataGrip 日常操作的差距分析（见当日讨论）。
> 定位边界（不可越）：calm、local-first，"打开连接、定位数据、安全地做审慎修改"。
> **不做**：ER 图、可视化建表/改表向导、schema diff/迁移生成、数据生成器、用户权限管理、AI 功能、Oracle/SQL Server。
> 工程纪律：每个特性含单测 + SessionStore 测试（env 门控集成测试能写则写）；`swift build` 零警告（编译强制）；错误脱敏（`dbbbbError.userMessage` 边界）；可选能力一律 fail-closed；标识符 quoting 沿用各引擎现有规则。
> **状态（2026-09-08）：M1、M2、M3 全部完成并验证（零警告；319 Swift Testing + XCTest 全套全绿）。另新增 Schema 查看器（表结构 + 全库外键关系总览，PG/MySQL/SQLite，用户拍板）。仅剩"schema 感知自动补全"缓议。**

## 分期概览

| 里程碑 | 内容 | 目标版本 | 状态 |
|---|---|---|---|
| M1 浏览与编辑闭环 | ①preview 翻页 ②网格过滤/排序 ③INSERT 新行/复制行 ④对象快速搜索 ⑤外键跳转 | v0.4.0 | ✅ 完成（2026-09-05） |
| M2 效率与可观测 | ⑥行详情侧栏 ⑦导出/复制为 INSERT ⑧EXPLAIN 查看器 ⑨进程列表+kill ⑩表统计 | v0.5.0 | ✅ 完成（2026-09-05） |
| M3 工作区增强 | 多结果标签、值编辑器、批量编辑暂存、查询格式化 | v0.4.0 | ✅ 完成（2026-09-08） |
| 明确缓议 | schema 感知自动补全（工程量最大，与"轻"定位冲突，单独评估后再定） | — |

---

## M1 · 浏览与编辑闭环

### ① Preview 翻页（P0，M）

- **契约**：`swift/Sources/dbbbbKit/Adapter.swift` 的 `previewObject(_:)` 扩展为 `previewObject(_ object: DatabaseObject, offset: Int = 0, limit: Int = 100)`（默认参数保源兼容；demo 适配器同样支持）。
- **适配器**：SQL 三引擎 `LIMIT l OFFSET o`（preview 已走 quoting 后的限定名，只追加子句）；Mongo 用 `skip`/`limit`（注释注明大 skip 性能差，这是浏览工具可接受的折衷）。适配器返回时多取 1 行用于"是否有下一页"判定（沿用现有 maxRows+1 截断思路）。
- **SessionStore/UI**：`preview(object, offset:)` 记住当前页状态；结果视图状态栏加 上一页/下一页/页码；切对象、切连接、刷新时归零。编辑/删除行后停留在当前页（复查刷新按同 offset 重取）。
- **测试**：各引擎 preview SQL/命令断言（offset 进查询）；SessionStore 翻页状态机（翻页、越界钳制、切对象归零）；SQLite 真实库分页往返。
- **验收**：10 万行表可逐页浏览，页切换有取消能力（沿用 requestID 路径）。

### ② 网格过滤/排序（P0，M；与①同一 `PreviewRequest`）

- **契约**：①的扩展位统一改为 `PreviewRequest { object, offset, limit, sort: (column: String, ascending: Bool)?, filter: (column: String, contains: String)? }`。过滤先做"文本包含"一种操作（覆盖 80% 场景），值一律参数绑定，列名一律 quoteIdentifier。
- **SQL 生成**（各引擎 preview 规划处）：PG `"col"::text LIKE $n ESCAPE '\'`、MySQL `CAST(`col` AS CHAR) LIKE ?`、SQLite `CAST("col" AS TEXT) LIKE ?`；通配符 `%`/`_`/`\` 在客户端转义后拼接 `%value%` 作为绑定值。排序追加 `ORDER BY "col" ASC|DESC`（quote 后）。Mongo：sort 走 BSON 文档 `{col: 1/-1}`；filter 走 `{col: {$regex: 转义后的子串}}`（正则元字符转义，防 ReDoS 与注入）。
- **UI**：列头点击循环 asc→desc→无；结果工具栏过滤条（列下拉 + 输入框 + 清除）。过滤/排序变化重置 offset=0。
- **测试**：三引擎 SQL 字符串与绑定顺序断言（含 `%` 转义、危险列名 quoting）；Mongo 过滤文档断言；SessionStore 过滤状态测试。
- **验收**：不用手写 SQL 即可在任意 preview 上按列排序/过滤。

### ③ INSERT 新行 / 复制行（P0，M-L）

- **契约**：`dbbbbKit/Adapter.swift` 的 `DataChange` 新增 insert 形态（携带目标对象 + 列值字典；不携带 original）。
- **规划器**（四引擎，照现有 update/delete 模式）：PG `INSERT … VALUES ($1…) RETURNING *`（0 行=触发器/RLS 拦截，沿用冲突文案）；MySQL/SQLite 检查 affectedRows/changes()==1；Mongo `insertOne`（`_id` 缺省由服务端生成；显式给 `_id` 走现有 tagged EJSON 编解码）。列元数据内省完全复用（生成列/拒绝清单/类型绑定已有）。
- **UI**：结果视图工具栏 "Add Row"（空白草稿进 `RecordEditingView` 两段式）；选中行右键 "Duplicate Row"（预填该行全部可编辑列值，主键列留空待用户填写——避免直接撞唯一约束）。production 二次确认复用（输入 APPLY）。
- **测试**：四规划器单测（绑定顺序、生成列表缺省值省略、拒绝清单）；env 集成四引擎真实库；SessionStore 门控测试（demo/只读/非单表 fail-closed 与编辑一致）。
- **验收**：新行/复制行走与编辑完全相同的复核与确认管线。

### ④ 对象快速搜索（P0，S）

- ObjectListView 顶部搜索框（`@FocusState` + Cmd+F 聚焦）：大小写不敏感 contains 过滤 `objectTree`，命中节点保留祖先链自动展开；Esc 清空恢复。纯客户端，无适配器改动。
- **测试**：树过滤纯函数单测（命中保留路径、无命中空态）。
- **验收**：500+ 对象的库里 1 秒内定位目标表。

### ⑤ 外键跳转（P0/P1 交界，M；依赖②的过滤管线）

- **契约**：dbbbbCore 加 `ForeignKey { columns, referencedObject, referencedColumns }`；dbbbbKit 加可选能力 `SupportsForeignKeys.foreignKeys(for:) async throws -> [ForeignKey]`（fail-closed，Mongo 不实现）。
- **元数据**：PG `pg_constraint contype='f'` 配 conkey/confkey 列序解析；MySQL `information_schema.KEY_COLUMN_USAGE`（REFERENCED_TABLE_SCHEMA/TABLE/COLUMN，server-wide 兼容）；SQLite 表值函数 `pragma_foreign_key_list(?)`。
- **UI**：选中行右键，对 FK 列显示 "Jump to Referenced Row" → 以该行的 FK 值为等值过滤，对被引用表发起带过滤的 preview（复用②的 `PreviewRequest.filter`，等值作为 contains 的精确形态或新增 `equals` 操作，绑定参数化）。
- **测试**：三引擎元数据 SQL/解析单测；SQLite 真实库建 FK 往返；SessionStore 跳转目标构造测试。
- **验收**：订单表点 FK 直达用户表对应行。

---

## M2 · 效率与可观测

### ⑥ 行详情侧栏（P1，S-M）
- ResultsView 右侧可折叠 pane：选中行的列名/值竖排；长文本截断展开、JSON 文本 pretty print、`DisplayValue.binary` hex 展示。纯 UI（复用 RowModel）。
- 测试：格式化纯函数单测。

### ⑦ 导出/复制为 INSERT 语句（P1，S）
- `ResultExport.swift` 加 `.sqlInsertStatements` 格式：表名/列名 quoting 沿用各引擎规则？——导出层无引擎上下文，取最小公分母：双引号标识符 + 单引号 doubling 字符串 + NULL + 数字原样 + bool `TRUE/FALSE` + binary fail-closed（与现有导出纪律一致），注释注明方言取舍。剪贴板加 "Copy as INSERT"。
- 测试：字面量转义矩阵（引号/反斜杠/NULL/非有限数/binary 拒绝）。

### ⑧ EXPLAIN 查看器（P1，S-M）
- 分类器已放行 `EXPLAIN`（三引擎 allowedStarters 均含；PG 的 `ANALYZE` token 已被拦，保持）。工具栏 "Explain"：对当前 queryText 前置 `EXPLAIN `（SQLite 用 `EXPLAIN QUERY PLAN`）走正常 runQuery 路径展示；Mongo 对 find/aggregate 发 `explain: <cmd>`（queryPlanner 详细度）以文档结果展示。先纯文本/文档，不做图形化。
- 测试：命令构造断言；分类器回归（EXPLAIN 放行、EXPLAIN ANALYZE 仍拒）。

### ⑨ 进程列表 + kill（P1，M-L）
- **契约**：可选能力 `SupportsServerActivity`：`listActivity() async throws -> [ServerActivity]`（pid/用户/库/语句截断/时长/状态）、`killActivity(id:) async throws`。
- **实现**：PG `pg_stat_activity` + `pg_cancel_backend`（复用池外连接机制）；MySQL `SHOW FULL PROCESSLIST` + `KILL`（复用 kill 连接）；Mongo `currentOp` + `killOp`（需 admin 权限，失败脱敏）。kill 门禁：非只读 profile + 二次确认（对照编辑的 production 确认）。
- **UI**：连接工具栏 "Activity…" sheet（表格 + 刷新 + Kill 按钮）。
- 测试：行解析单测；kill 门禁 SessionStore 测试；env 集成。

### ⑩ 表统计（P1，S-M）
- 对象树右键 "Statistics…"（或并入 DDL sheet 一页）：估算行数（PG `pg_class.reltuples`、MySQL `information_schema.TABLES.TABLE_ROWS`、SQLite 有界 `COUNT(*)` 可取消）、表/索引大小（PG `pg_total_relation_size`/`pg_indexes_size`、MySQL `data_length`/`index_length`、SQLite `page_count*page_size`）、Mongo `collStats`（ count/size/storageSize）。
- 测试：SQL 断言 + 字节格式化单测。

---

## M3 · 工作区增强（2026-09-08 用户拍板实施，已全部完成）

- 多结果标签页：SessionStore 状态移入 `QueryTab`（每 tab 独立 queryText/result/翻页过滤/暂存/在飞簿记），SessionStore 以计算属性转发到活动 tab 保持既有 API 与测试零改动；逐 tab 取消，切连接全清。
- 值编辑器（多行文本/JSON/blob hex 弹窗编辑）：`ValueEditorSheet` + 纯函数 `ValueEditing`；JSON 只校验不改写、binary 走 hex；截断值拒绝编辑；提交走既有 DataChange 管线。
- 批量编辑暂存：`PendingChange` 暂存清单 + `BatchReviewSheet` 集中复核；顺序应用、首个失败即停并如实报告部分成功；切连接/切对象清空并提示，刷新保留。
- 查询格式化：自写方言无关 tokenizer + 重排（`SQLFormatter`），逐字保留 token，自检不一致即回退原文；⇧⌘F；Mongo fail-closed。
- Schema 感知自动补全：明确缓议。需要解析器+目录缓存+补全 UI，是把 app 做"重"的分水岭，要做必须单独评审。

## 实施顺序与验收

1. 顺序：① → ②（同契约位）→ ④（纯 UI 穿插）→ ③ → ⑤（依赖②）。M1 完成后打 v0.4.0（tag 派生版本，make-app.sh 自动校验）。
2. 每个特性一个 commit 单元；提交前必过：
   ```bash
   cd swift && swift build
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   ```
3. 有真实库时跑 env 门控集成测试（重建方法见 HANDOVER §7）。
4. 每个里程碑更新 README（功能列表）与 HANDOVER；release 说明列新增能力。
