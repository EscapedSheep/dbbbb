# dbbbb

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) | **简体中文**

dbbbb 是一个本地优先的开源 Electron 数据库客户端，支持 PostgreSQL、MongoDB、MySQL 和 SQLite。它把 SQL 的表/行和 MongoDB 的集合/文档作为各自独立的原生工作流，同时共享连接管理、对象导航、查询历史、主题和安全控制。

项目目前处于早期开发构建阶段，可以正常使用。内置演示连接，真实的 PostgreSQL、MongoDB、MySQL 和 SQLite 会话均在 Electron 主进程中实现。

## 目前已实现的功能

- 真实的 PostgreSQL 连接：支持 `disable`、`require`、`verify-full` 三种 SSL 模式；schema/表/视图浏览；生成预览；SQL 执行；有上限的结果集；超时与定向取消。
- 真实的 MongoDB 及 SRV 连接——SRV URI 强制 TLS，对话框会预选；数据库/集合浏览；标准 Extended JSON 的 `find` 和 `aggregate` 输入；保留 BSON 类型的 canonical EJSON 结果；有上限的执行与取消。
- 真实的 MySQL 连接：支持 `disable`、`require`、`verify-full` SSL 模式；基于 `information_schema` 的内省；生成预览；有上限的单语句 SQL 执行；定向 `KILL QUERY` 取消。只读连接双重强制：客户端语句分类器 + 每个池化会话上的 `transaction_read_only`。
- 真实的 SQLite 连接：打开本地数据库文件，可选只读模式；表/视图浏览；生成预览；有上限的单语句 SQL 执行。语句在主进程中同步执行，长查询会阻塞 UI 且无法取消。
- 本地查询历史与收藏库：最多保留 100 条非收藏历史，连续重复的同一条命令会合并进上一条，不持久化连接 URI 和密码。
- 流式导入：CSV 导入到已内省的 PostgreSQL 表，JSONL 导入到已内省的 MongoDB 集合。导入使用一次性不透明文件令牌、有上限的解析器、实时字节进度和取消。
- 导出：当前有上限的行结果导出为 CSV，当前有上限的文档结果导出为 canonical JSONL。文件先写临时文件，成功后原子重命名。
- 可审查的单条记录更新/删除（仅限符合条件的真实可写连接）：PostgreSQL 编辑要求已内省的表有主键、且列类型可无损往返；MongoDB 编辑保留 `_id`。乐观检查会拒绝过期或有歧义的修改。
- 可选的保存连接：凭据受操作系统保护存储，启动时自动重连，**断开**与**忘记**是两个独立操作。
- 浅色、深色、跟随系统三种主题，低饱和度线条风 UI，键盘焦点可见，对话框和结果控件可访问。
- 沙箱化渲染进程、窄化的类型化 preload 桥、经过校验的 IPC 载荷、数据库驱动和文件访问全部在主进程、错误信息脱敏、有上限且可结构化克隆的传输值。

## 保存的连接与凭据

连接默认仅存在于当前会话。勾选 **Remember and reconnect** 后，dbbbb 会在首次连接数据库成功后保存完整连接。该选项是显式 opt-in；不勾选则完全不触碰凭据库。

保存的输入在 Electron 主进程中用 `safeStorage` 加密。Electron 在 macOS 上使用 Keychain，在 Windows 上使用 DPAPI。在 Linux 上，dbbbb 接受 Electron 报告的 `libsecret` 或 KWallet 后端（`gnome_libsecret`、`kwallet`、`kwallet5`、`kwallet6`）。它明确拒绝 Electron 的 `basic_text` 回退、未知后端和加密不可用的情况——绝不写入明文凭据。

启动时，dbbbb 解密已保存的条目并尝试重连。如果解密后的配置无法连通或认证失败，dbbbb 会保留一条已脱敏的 **Unavailable** 条目，让用户可以显式忘记它；用户名、密码或含凭据的 URI 都不会暴露给渲染进程。条目损坏或安全存储不可用时，只产生一条不含凭据的全局警告，因为无法恢复可信的展示元数据，其余条目仍可正常恢复。如果新连接的保存失败，该数据库会话在当前运行中保持打开，标记为未保存并显示警告。

**断开**只关闭活跃会话，保留其加密的已存条目供下次启动使用。**忘记**删除已存条目和受保护的凭据，并在会话活跃时一并关闭。

## 当前限制

- 受保护存储已实现，并通过对本地打包构建做的一次性手动 macOS Keychain 保存/重启/断开冒烟验证；该检查未自动化。Windows DPAPI 和 Linux libsecret/KWallet 的可重复验证仍待完成；平台存储不可用时没有不安全的明文回退。
- MongoDB 驱动和集成测试代码已就绪，测试套件在定时/手动触发的 CI 任务中针对真实的 MongoDB 7 容器运行。本仓库仍不声称已验证托管、SRV 或 TLS 部署，本地运行时除非显式提供 URL，否则套件会跳过。
- 导入目前只面向一个已知的 PostgreSQL 表或 MongoDB 集合。内容预览、字段映射和可下载的错误报告尚未实现。
- 编辑和导入仍仅限 PostgreSQL 和 MongoDB。MySQL 和 SQLite 连接在两条路径上都是 fail-closed，渲染进程和主进程均如此。
- SQLite 语句在主进程事件循环上同步执行：长查询会阻塞 UI 直到完成，且不支持取消（`node:sqlite` 没有中断 API）。
- MySQL 集成套件在定时/手动 CI 任务中针对 `mysql:8` 容器运行。针对托管或 TLS 生产部署的验证仍待完成；本地运行时除非设置 `DBBBB_TEST_MYSQL_URL`，否则套件会跳过。
- 本地打包产物未签名。代码签名、macOS 公证、自动更新和发布渠道基础设施均未实现。

## 本地运行

前置要求：Node.js、npm，以及你想连接的任意 PostgreSQL、MySQL 或 MongoDB 服务器（或一个 SQLite 数据库文件）。

```bash
npm install
npm run dev
```

应用启动时自带演示用的 PostgreSQL 和 MongoDB 连接，无需数据库服务器即可探索 UI。通过 **New connection** 建立真实会话。凭据只在建立连接时跨越 preload 边界，默认留在主进程会话中；可选的 **Remember and reconnect** 路径只保存一条受操作系统保护的加密记录，如上所述。

## 命令行

dbbbb 提供一个小型命令行接口。同一时间只运行一个实例：应用已打开时，参数会被转发给运行中的实例，`add` 也在该实例中执行——因为只有它可以写凭据库。

```bash
dbbbb open [connection]                  # 打开窗口并选中连接（id 或名称）
dbbbb query <connection> "select 1"      # 选中连接、填入编辑器并执行
dbbbb add --engine postgres --host db.internal --database orders [--port 5432] [--user U] [--password W] [--name N] [--read-only]
dbbbb add --engine mysql --host 127.0.0.1 --database shop [--port 3306] ...
dbbbb add --engine mongodb --uri mongodb://localhost:27017/catalog [--name N] [--read-only]
dbbbb add --engine sqlite --file /path/to/audit.db [--name N] [--read-only]
dbbbb --help
```

`add` 会先连接一次验证输入，像对话框的 **Remember and reconnect** 一样记住连接，打印 `added <name> (<id>)`，然后不开窗口直接退出。MongoDB URI 必须在路径中携带数据库；`mongodb+srv://` 会自动启用 TLS。`query` 对 PostgreSQL/MySQL/SQLite 把命令当作 SQL，对 MongoDB 当作 canonical EJSON 的 `find` 过滤条件（作用于第一个集合）。

开发模式下，`--` 之后的参数会传给应用：

```bash
npm run dev -- query mydb "select 1"
```

针对打包后的 macOS 构建：

```bash
/Applications/dbbbb.app/Contents/MacOS/dbbbb query mydb "select 1"
open -a dbbbb --args query mydb "select 1"
```

## 验证

运行常规的类型检查、单元/组件测试和生产构建：

```bash
npm run typecheck
npm test
npm run build
```

`npm run build` 生成编译后的 Electron bundle，不生成安装包。

这三项检查也会在每次 push 和 pull request 时跑 CI（Ubuntu 和 macOS）。定时或手动触发的 CI 任务还会针对 `postgres:16`、`mongo:7`、`mysql:8` 服务容器运行三套集成测试，包括 PostgreSQL 和 MongoDB 的写路径。`npm run test:integration` 可在本地按顺序运行全部三套 opt-in 套件。

### 可选的 PostgreSQL 集成测试

除非设置 `DBBBB_TEST_POSTGRES_URL`，否则 PostgreSQL 套件会跳过。默认路径是只读的，覆盖连接、内省、有上限的执行和取消。

```bash
DBBBB_TEST_POSTGRES_URL='postgresql://user:password@127.0.0.1:5432/database?sslmode=disable' \
  npm run test:integration:postgres
```

写集成测试是额外的 opt-in 开关。请只用允许创建和删除临时 schema 的一次性数据库账号；测试会执行 CSV 导入、可审查的更新、过期写拒绝和删除，然后清理自己的 fixture。

```bash
DBBBB_TEST_POSTGRES_URL='postgresql://user:password@127.0.0.1:5432/disposable_database?sslmode=disable' \
DBBBB_TEST_POSTGRES_ENABLE_WRITE=1 \
  npm run test:integration:postgres
```

### 可选的 MongoDB 集成测试

MongoDB 套件是独立的，默认跳过。提供 URL 后启用连接、集合列表和有上限的 canonical EJSON 查询检查。套件会自建并删除自己的 fixture 集合，不依赖已有数据。该命令只是一套测试工具，不代表已验证过真实 MongoDB 环境。

```bash
DBBBB_TEST_MONGO_URL='mongodb://127.0.0.1:27017/database' \
DBBBB_TEST_MONGO_DATABASE='database' \
  npm run test:integration:mongo
```

写覆盖——JSONL 导入、乐观更新、过期写拒绝和对第二个一次性 fixture 集合的删除——是额外的 opt-in 开关。请只用一次性数据库：

```bash
DBBBB_TEST_MONGO_URL='mongodb://127.0.0.1:27017/disposable_database' \
DBBBB_TEST_MONGO_DATABASE='disposable_database' \
DBBBB_TEST_MONGO_ENABLE_WRITE=1 \
  npm run test:integration:mongo
```

可选的长查询取消用例可用 `DBBBB_TEST_MONGO_ENABLE_LONG_QUERY=1` 开启；它要求服务器/配置允许该测试管道的服务端函数。

### 可选的 MySQL 集成测试

除非设置 `DBBBB_TEST_MYSQL_URL`，否则 MySQL 套件会跳过。URL 使用 `mysql` 协议，包含主机、用户名和数据库，接受可选的 `sslmode` 查询参数（`disable`、`require` 或 `verify-full`，默认 `disable`）。套件是只读的：覆盖连接、`information_schema` 内省、有上限的执行、会话只读强制和定向取消，不创建任何 fixture 数据。

```bash
DBBBB_TEST_MYSQL_URL='mysql://user:password@127.0.0.1:3306/database?sslmode=disable' \
  npm run test:integration:mysql
```

## 本地打包

```bash
# 当前平台的免安装应用目录
npm run package:dir

# macOS DMG 和 ZIP
npm run package:mac
```

产物写入 `release/`。它们是未签名、未公证的开发产物，macOS Gatekeeper 或 Windows SmartScreen 可能会警告。构建配置也声明了 Windows NSIS 和 Linux AppImage/DEB 目标，但本仓库尚未提供经过验证的对应发布脚本。

参见[开发计划](docs/DEVELOPMENT_PLAN.md)和[架构说明](docs/ARCHITECTURE.md)。

## 许可证

dbbbb 是开源项目，基于 [MIT 许可证](LICENSE)发布。
