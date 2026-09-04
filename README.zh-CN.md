# dbbbb

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml/badge.svg)](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml)

[English](README.md) | **简体中文**

dbbbb 是一个本地优先的开源 macOS 数据库客户端，支持 PostgreSQL、MySQL、MongoDB 和 SQLite。它是基于 Swift 6 + SwiftUI + SwiftPM 的原生应用，要求 macOS 15 或更高版本。目标：打开连接、定位数据、安全地做审慎修改，而不背上全功能数据库管理套件的视觉重量。

> **说明：** 仓库中的 `src/` 是已废弃的第一代 Electron 实现，仅作历史参考，不再开发。现行产品全部位于 `swift/` 目录下。

## 目前已实现的功能

- 四个引擎的真实连接：PostgreSQL、MySQL 支持 `disable`、`require`、`verify-full` SSL 模式；MongoDB 支持 SRV URI 并强制 TLS；SQLite 打开本地数据库文件，可选只读。
- 对象浏览、生成预览与查询执行：结果有界（每结果 500 行 / 5 MiB，单值 8 MiB 并附显式截断标记）、可定向取消、错误信息脱敏（绝不泄露密码、URI 或本地路径）。
- 只读连接双重强制：客户端语句分类器 + 服务端只读设置。
- 四引擎均可审查的单条记录更新/删除：草稿 → 复核两段式流程、乐观冲突检测、production 环境须输入文字二次确认。编辑是 fail-closed 能力——只读配置、非预览结果或不支持的适配器根本不会显示编辑入口。
- 导入导出：CSV 导入 SQL 表、JSONL 导入 MongoDB 集合（分批、有界、可取消）；当前有界结果可导出为 CSV 或 canonical JSONL，原子写盘。
- 精度安全展示：bigint、decimal、非有限数、日期一律以字符串呈现；MongoDB 结果经 canonical Extended JSON 往返，Decimal128 位级保真。
- 可选的保存连接：连接清单位于 `~/Library/Application Support/dbbbb`，权限收紧；密码与含凭据的 MongoDB URI 只存 macOS Keychain。保存的连接启动时自动重连，重连失败只弹脱敏横幅、绝不丢条目。
- 本地查询历史与收藏库（有上限，绝不持久化凭据）。
- 浅色、深色、跟随系统三种主题。

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

集成测试在未提供服务器 URL 时自动跳过（`DBBBB_TEST_POSTGRES_URL` / `DBBBB_TEST_MYSQL_URL` / `DBBBB_TEST_MONGO_URL`），默认测试套件无需真实数据库。

## 本地打包

```bash
swift/Scripts/make-app.sh
```

产出 ad-hoc 签名的 `swift/release/dbbbb.app` 与 `swift/release/dbbbb-<version>-macOS-<arch>.zip`。版本号取自 `HEAD` 上的精确 git tag（无 tag 时回退到脚本内常量）。升级为 Developer ID 签名与公证的命令写在脚本头注释中。

## 仓库结构

- `swift/` — 现行产品：`dbbbbCore`（类型契约）、`dbbbbKit`（引擎适配器、持久化、导入导出）、`dbbbbApp`（SwiftUI 外壳），以及测试与打包脚本。
- `src/`、`docs/`、`package.json` — 已废弃的 Electron 实现及其文档，仅作历史参考。
- `HANDOVER.md` — 当前项目状态与交接说明。

## 许可证

dbbbb 是开源项目，基于 [MIT 许可证](LICENSE)发布。
