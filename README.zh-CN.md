# dbbbb

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml/badge.svg)](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml)

[English](README.md) | **简体中文**

dbbbb 是一个本地优先的开源 macOS 数据库客户端，支持 PostgreSQL、MySQL、MongoDB、SQLite 和 BullMQ（Redis 任务队列）。它是基于 Swift 6 + SwiftUI + SwiftPM 的原生应用，要求 macOS 15 或更高版本。目标：打开连接、定位数据、安全地做审慎修改，而不背上全功能数据库管理套件的视觉重量。

> **说明：** 已废弃的第一代 Electron 实现已从仓库删除（`src/` 已不存在，见 git 历史）。现行产品全部位于 `swift/` 目录下。

## 目前已实现的功能

- 五个引擎的真实连接：PostgreSQL、MySQL 支持 `disable`、`require`、`verify-full` SSL 模式；MongoDB 支持 SRV URI 并强制 TLS；SQLite 打开本地数据库文件，可选只读。
- 对象浏览、生成预览与查询执行：结果有界（每结果 500 行 / 5 MiB，单值 8 MiB 并附显式截断标记）、可定向取消、错误信息脱敏（绝不泄露密码、URI 或本地路径）。双击表或视图立即运行其 `SELECT … LIMIT 100`（MongoDB 集合则运行 find）。
- 表与视图的 View Create Statement（PostgreSQL / MySQL / SQLite）：DDL 以只读弹窗展示，等宽字体、可复制（fail-closed 能力——MongoDB 与不支持的适配器不会显示入口）。
- Preview 翻页与网格过滤/排序：大表按页浏览（每页 100 行）、点击列头循环排序、任意列按子串或等值过滤——SQL 引擎走服务端参数化查询，MongoDB 用原生 sort/正则。
- 对象快速搜索（⌘F）：过滤对象树并保留命中节点的祖先链展开。
- INSERT 新行 / 复制行：与编辑完全相同的复核管线，省略的列取服务端默认值。
- 外键跳转：在外键列上右键选中行即可直达被引用的行（PostgreSQL / MySQL / SQLite，支持多列与跨 schema 外键）。
- 行详情侧栏：JSON pretty print、二进制 hex 展示、显式截断标记；当前结果可复制/导出为 INSERT 语句。
- 可观测性：EXPLAIN 查看器、表统计（估算行数、表/索引大小）、服务器活动列表 + kill（PostgreSQL / MySQL / MongoDB）。
- Schema 查看器（PostgreSQL / MySQL / SQLite）：展示每张表的列、主键、索引与外键，并给出全库表关系总览。
- 值编辑器弹窗：多行文本、JSON（实时校验、绝不改写）与二进制（hex）编辑——被截断的值一律拒绝编辑，绝不静默覆盖。
- 批量编辑暂存：多处行改动先暂存、集中复核后一次提交；首个失败即停并如实报告部分成功。
- 多结果标签页：每个标签页有独立的查询文本、结果、翻页/过滤状态、暂存改动与取消能力。
- 保守的 SQL 格式化（⇧⌘F）：方言无关的重排器，逐字保留所有 token，自检发现任何不一致即回退原文。MongoDB fail-closed。
- 数据库字段可选：PostgreSQL 空值回退到 `postgres` 维护库；MySQL 空值不设默认 schema，按服务器范围浏览所有非系统 schema。
- 只读连接双重强制：客户端语句分类器 + 服务端只读设置。
- 四引擎均可审查的单条记录更新/删除：草稿 → 复核两段式流程、乐观冲突检测、production 环境须输入文字二次确认。编辑是 fail-closed 能力——只读配置、非预览结果或不支持的适配器根本不会显示编辑入口。
- 导入导出：CSV 导入 SQL 表、JSONL 导入 MongoDB 集合（分批、有界、可取消）；当前有界结果可导出为 CSV 或 canonical JSONL，原子写盘。
- 精度安全展示：bigint、decimal、非有限数、日期一律以字符串呈现；MongoDB 结果经 canonical Extended JSON 往返，Decimal128 位级保真。
- 可选的保存连接：连接清单位于 `~/Library/Application Support/dbbbb`，权限收紧；密码与含凭据的 MongoDB URI 只存 macOS Keychain。保存的连接启动时自动重连，重连失败只弹脱敏横幅、绝不丢条目。
- 本地查询历史与收藏库（有上限，绝不持久化凭据）。
- BullMQ（Redis）任务队列，只读不改 Redis：浏览全部 8 种任务状态——包括 BullMQ 官方 `getJobs` 读不到的 `paused` 和 `waiting-children`；以 JSON 文档查询任务（状态、时间范围、name glob、`where` 点路径匹配 data 字段、`includeLogs` 附带截断日志尾部）；扫描预算 + 断点续扫（Continue scan）安全翻超大队列；每页由单条 Lua 脚本服务端批取。**Sync to local SQL** 把一个队列物化成本地只读 SQLite 表，用完整 SQL（含 `json_extract`）分析；快照文件随会话存在，启动时清扫、退出时删除。
- UI 按旧 Electron 版重设计：calm 暗色风格、单栏侧边栏（连接 + 对象树 + 搜索）、标签条、带行号槽的等宽查询编辑器、完整 design token 层，浅色/深色/跟随系统三主题。

## 本地运行

前置要求：macOS 15+，以及带 Swift 6.x 的 Xcode 工具链（Xcode 16 或更高）。

```bash
cd swift
swift build
swift run
```

应用启动时自带演示连接，无需数据库服务器即可探索 UI。通过 **New connection** 建立真实会话——输入会先经真实往返验证，通过后才入列。

## 验证

```bash
cd swift
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

只有当 `xcode-select` 指向 Command Line Tools（不含 XCTest）时才需要 `DEVELOPER_DIR` 前缀；已选中 Xcode 时直接 `swift test` 即可。项目纪律将警告视为错误——请保持 `swift build` 零警告。

集成测试在未提供服务器 URL 时自动跳过（`DBBBB_TEST_POSTGRES_URL` / `DBBBB_TEST_MYSQL_URL` / `DBBBB_TEST_MONGO_URL` / `DBBBB_TEST_REDIS_URL`，后者为 BullMQ，形如 `redis://127.0.0.1:6379`，fixture 数据隔离在逻辑库 15 的专用前缀下），默认测试套件无需真实数据库。

## 本地打包

```bash
swift/Scripts/make-app.sh
```

产出 ad-hoc 签名的 `swift/release/dbbbb.app` 与 `swift/release/dbbbb-<version>-macOS-<arch>.zip`。版本号取自 `HEAD` 上的精确 git tag（无 tag 时回退到脚本内常量）。升级为 Developer ID 签名与公证的命令写在脚本头注释中。

## 仓库结构

- `swift/` — 现行产品：`dbbbbCore`（类型契约）、`dbbbbKit`（引擎适配器、`Redis/` + `BullMQ/` 下的自写 RESP 客户端与 BullMQ 适配器、持久化、导入导出）、`dbbbbApp`（SwiftUI 外壳），以及测试与打包脚本。
- `docs/` — 开发路线图。已废弃的 Electron 实现及其文档已删除，见 git 历史。
- `HANDOVER.md` — 当前项目状态与交接说明。

## 许可证

dbbbb 是开源项目，基于 [MIT 许可证](LICENSE)发布。
