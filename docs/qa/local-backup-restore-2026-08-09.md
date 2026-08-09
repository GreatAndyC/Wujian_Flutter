# 可校验本地备份包与原子恢复 QA 记录

验证日期：2026-08-09 至 2026-08-10

## 1. 目标与非目标

本切片为物见建立一个不依赖云服务的本地备份闭环：导出可自校验、可移植的版本化 ZIP 包，在隔离区完成全量校验后，以可回滚并可在下次启动收敛的方式替换或合并目录与媒体。

本轮目标包括：

- 备份业务目录、待确认队列和被引用媒体，不导出设置或认证信息。
- 对 catalog 和每份唯一媒体记录实际字节数与实际 SHA-256，而不是信任媒体文件名中的旧摘要。
- 同一内容只在包内保存一份，恢复到新的文档根时重写媒体路径。
- 导出失败不发布半成品；恢复校验失败或提交前写入失败时，原 catalog 和媒体保持不变。
- 对进程中断留下的恢复 journal、已发布新媒体和临时媒体提供确定性的 OLD/NEW 收敛。
- 把路径、链接、重复条目、压缩比、条目数和展开字节等不可信归档风险挡在活跃数据写入之前。
- 提供独立于现有 UI 的 domain model、service、controller 和测试接口。

明确不在本轮范围内的事项：

- 不做自动云上传、同步、远端备份、部署或付费 API 调用。
- 不读取平台凭证，也不实现备份包加密、签名或密钥管理；SHA-256 提供完整性校验，不等同于来源认证或保密。
- 不修改或接线现有设置页、主题和其他 UI；当前只有可供后续 UI 调用的 controller。
- 不重写现有 catalog/media 整体架构，也不把所有应用写操作迁移到同一个 generation/pointer 存储模型。
- 不宣称已经完成真机磁盘耗尽、操作系统强杀或跨进程并发验证。

实现与验证主要分布在：

- `lib/domain/entities/backup_restore.dart`
- `lib/data/services/backup_file_system.dart`
- `lib/data/services/backup_restore_service.dart`
- `lib/data/services/storage_mutation_coordinator.dart`
- `lib/data/repositories/local_catalog_repository.dart`
- `lib/data/services/media_storage_service.dart`
- `lib/features/backup/backup_restore_controller.dart`
- `lib/features/shell/app_controller.dart`
- `test/backup_file_system_test.dart`
- `test/backup_restore_controller_test.dart`
- `test/backup_restore_service_test.dart`

## 2. 备份包格式 v1

当前新建备份使用 ZIP 容器和受控的三类条目：

| 条目 | 数量 | 内容与约束 |
| --- | ---: | --- |
| `manifest.json` | 1 | 包标识、格式版本、UTC 创建时间、catalog 元数据和去重媒体清单 |
| `data/catalog.json` | 1 | `schemaVersion: 1`、`items`、`pendingItems`；包内媒体引用改写为逻辑相对路径 |
| `media/<sha256>.<ext>` | 0 至上限 | 仅允许 `jpg`、`png`、`webp`；名称中的 64 位小写十六进制摘要来自文件实际字节 |

manifest v1 的核心字段为：

- `package`: 固定为 `wujian-local-backup`。
- `formatVersion`: 当前为 `1`。
- `createdAt`: 创建时刻的 UTC ISO 8601 字符串。
- `catalog.path`: 固定为 `data/catalog.json`。
- `catalog.schemaVersion`: 当前为 `1`。
- `catalog.byteLength` 与 `catalog.sha256`: 对实际 catalog JSON 字节计算。
- `catalog.itemCount` 与 `catalog.pendingItemCount`: 用于与解码后的列表数量交叉校验。
- `media[]`: 每项记录受控逻辑路径、实际 `byteLength` 和实际 `sha256`。

媒体去重规则：

1. 导出时先把被引用源文件复制到隔离工作区并刷新。
2. 对隔离副本的真实字节解码图片、计算 SHA-256 和长度。
3. 逻辑路径使用 `media/<sha256>.<检测到的真实格式>`。
4. 多个 item 或 pending item 引用相同字节时，共享同一个逻辑路径和包内媒体条目。
5. catalog 中全部非空媒体引用必须与 manifest 媒体集合形成严格引用闭包；缺失、额外或未引用媒体都会被拒绝。

新建包使用 ZIP `STORE` 写入，避免对已经压缩的图片重复压缩。导入会先对 `STORE`/`DEFLATE` 的声明展开字节和压缩比做安全预检；实际解包保守地只接受能精确证明输入边界的 `STORE`。当前依赖的 raw DEFLATE 解码器不暴露“已观测到合法最终块”状态，因此低压缩比 DEFLATE 也会以 `invalidArchive` 拒绝，避免把合法前缀+非法终止块误当完整流。包内不会保留源设备的绝对媒体路径。

## 3. 导出提交协议

导出流程按以下顺序执行：

1. 对目标文档根取得跨 catalog/media/backup service 共享的根目录 mutation 锁，并先收敛任何已存在的恢复 journal。
2. 在文档根内建立唯一 `.wujian-create-*` 工作区。
3. 加载 catalog，拒绝空 ID 或跨 items/pending 的重复 ID。
4. 要求每个非空媒体引用是当前 `images/` 下的普通文件；拒绝缺失文件、软链接和解析后逃出媒体目录的路径。
5. 流式复制媒体到工作区，执行文件刷新；复制前后比较源文件大小和修改时间，避免备份过程中源文件被静默替换。
6. 解码媒体，按真实字节计算 SHA-256/尺寸并去重；写入并刷新 catalog 与 manifest。
7. 先核算 `backups/` 顶层全部普通文件的逻辑字节和最终包数量；达到默认 1 GiB 或 8 份上限时，在准备媒体或写 `.partial` 前拒绝继续累积。
8. 在 `backups/` 中写入唯一的 `.partial` ZIP，并刷新该文件。
9. 在第二个隔离工作区完整执行一次与外部导入相同的自校验。
10. 仅当自校验通过后，使用同目录 rename 发布最终 `.wujian-backup` 文件；应用内共享锁、唯一文件名和发布前目标不存在检查共同避免合作调用之间的覆盖。
11. 无论成功或失败，都清理本次唯一工作区；发布前失败会尽最大努力删除 `.partial`。若 partial 删除失败，则保留其 owner marker，供后续启动成对回收，不能先删除所有权证据。

`LocalBackupFileSystem` 将复制目标以 exclusive 模式创建，执行流式写入、sink flush/close 和文件 flush；发布要求源与目标位于同一解析后的父目录，且在 rename 前两次确认目标不存在。它不采用“先删除旧目标再重命名”的降级路径。Dart 没有跨平台暴露 `RENAME_NOREPLACE`/`RENAME_EXCL`，因此不把这条预检描述为对不合作外部进程的文件系统级绝对保证；完成不确定态只有在源临时文件已消失且目标长度与 SHA-256 完全匹配时才收敛为成功。

自动化故障证据已覆盖 `beforeBackupPublish` 抛出 `FileSystemException`：返回安全的 `writeFailed`，`backups/` 中没有最终包或 `.partial`，文档根没有 `.wujian-create-*` 工作区，源 catalog 语义快照和源媒体 SHA-256 均不变。

## 4. 恢复校验、提交与 journal 收敛

### 4.1 活跃数据写入前的校验

恢复不会直接把归档解到活跃 `images/`。它先在唯一 `.wujian-restore-*` 工作区内执行：

1. 检查输入是普通文件而不是软链接，并限制原始包大小。
2. 严格解析位于文件末尾的无注释 EOCD，再以有界、逐条方式读取中央目录；计数必须与 EOCD 一致，中央目录必须被恰好消耗，不允许先将不受限的目录整体分配到内存。
3. 在写出条目前交叉核对 central/local header 的路径、CRC、尺寸、标志和压缩方式；要求每段 local data 不重叠、不越过 central directory，并拒绝路径穿越、链接、重复/大小写冲突、数量、字节和压缩比超限。
4. 预检完成后、创建任何条目输出前拒绝 `DEFLATE`；对 `STORE` 条目用有单项及全局预算的输出流写到隔离区，以实际输出字节再次执行上限、长度和 CRC 校验。
5. 解析 manifest/catalog schema、格式版本和 UTC 时间。
6. 重新计算 catalog 与每份媒体的实际长度和 SHA-256。
7. 先读取图片头信息，拒绝任一边超过 4,096 像素或总像素超过 16,777,216 的媒体，再完整解码并核对真实格式，避免小压缩文件触发过大像素缓冲。
8. 检查 catalog 数量、唯一 ID、媒体 manifest 去重和 catalog/manifest/归档三者的引用闭包。
9. 只有完整校验通过后才加载和准备修改当前 catalog。

### 4.2 提交顺序

校验完成后，恢复按以下顺序准备和提交：

1. 将包内逻辑路径重写为目标文档根内的内容寻址路径 `backup-<sha256>.<ext>`，计算 replace 或 merge 后的下一份 catalog。
2. 在创建任何活跃目录内的恢复临时媒体之前，创建并刷新 `.wujian-restore-journal.json`；journal 只保存 schema、前后 catalog 语义快照 SHA-256 和本次计划新建的安全媒体文件名，不保存业务内容。
3. 把隔离媒体流式复制为活跃 `images/` 下的 `.restore-*.tmp`，并执行文件刷新。
4. 以同目录、不覆盖 rename 发布新媒体。
5. 保存下一份 catalog；catalog 保存成功是本次恢复的提交点。
6. 提交后再按新 catalog 的引用集合清理孤儿媒体，最后删除 journal。清理只删除受管图片或明确的恢复临时文件，保留 sidecar/其他文件，并显式保护本次输入备份包。

捕获到的提交前错误会先删除从未被 catalog 引用的临时媒体；若已经尝试写 catalog，则必须先成功保存旧快照，之后才删除已发布新媒体。若旧 catalog 回写失败，则保留 journal 和新媒体供下次重启根据实际 OLD/NEW 状态收敛，避免形成 NEW catalog + 缺媒体的破坏态。任何未完整回滚都会提升为 `rollbackFailed` 并保留现场，而不会假装恢复成功。

所有 `renameNew` 发布点都处理“目标已落盘但底层随后报错”的完成不确定态：导出最终包仅在 partial 已消失、且目标长度和 SHA-256 与已自校验 partial 完全一致时收敛为成功；journal 同时以源消失和 payload 长度/hash 识别已提交；恢复媒体也只有在源临时文件消失且目标匹配时才纳入本次回滚删除集合。若源仍存在，目标可能属于竞争写入者，恢复不会接管或删除它。媒体 copy 正常返回后还会再次校验临时目标的长度与 SHA-256，避免静默短写或同长坏写被发布。

### 4.3 进程中断后的 OLD/NEW 状态机

每次 create/validate/restore，以及公开的 `recoverInterruptedRestore()`，都会先检查并处理遗留 journal。收敛依据是当前 catalog 的语义快照 SHA-256，不使用文件修改时间猜测：

| 当前状态 | 收敛动作 | 结果 |
| --- | --- | --- |
| 当前 catalog hash 等于 `previousCatalogSha256` | 删除 journal 中列出的本次计划新媒体；删除受控 `.restore-*.tmp`；删除 journal | 收敛为完整 OLD，保留旧 catalog 和旧引用媒体 |
| 当前 catalog hash 等于 `nextCatalogSha256` | 要求每份计划新媒体存在且其实际 SHA-256 与安全文件名一致；按当前 catalog 清理旧孤儿；删除受控临时文件和 journal | 收敛为完整 NEW |
| 当前 hash 两者都不匹配 | 返回 `rollbackFailed`，保留 journal 和现场 | 停止自动猜测，等待人工诊断 |
| journal/schema/媒体名异常，或 NEW 缺少完整媒体 | 返回 `rollbackFailed`，保留现场 | 不执行破坏性推断 |

自动化测试不是通过普通 `throw` 伪装进程强杀，而是手工建立窄化 journal、已发布新媒体和 `.restore-*.tmp`，再创建新的 service 调用公开恢复入口：

- `current=OLD`：新媒体、临时文件和 journal 被删除；旧 catalog 和旧媒体逐字节保留。
- `current=NEW`：新引用媒体通过实际 SHA-256 校验后保留；旧孤儿、临时文件和 journal 被删除。

这证明了当前 journal 协议对两种已知落盘状态的重启收敛逻辑；它不等同于已经在真机上完成操作系统强杀测试。

### 4.4 强杀残留 scavenger

因为进程被 kill 时 `finally` 不会执行，每次取得根目录互斥后还会执行窄化的启动回收：

- `.wujian-create-*` / `.wujian-validate-*` / `.wujian-restore-*` 必须是普通目录，名称匹配严格数字格式，且内部 `.wujian-operation.json` 的 schema、kind、purpose、directoryName、PID 和 UTC 时间完整匹配。
- `backups/*.wujian-backup.partial` 只在同名 `.owner.json` 结构和 partialName 交叉校验通过时删除。
- journal 临时文件只在名称、schema、catalog hash、媒体名、PID 和时间都受控时删除。
- 在 macOS/Linux 上 advisory lock 是进程级而不是 isolate 级；因此检测到既有 fresh same-PID active marker 时会把它当作 lease 并返回 `busy`。正常 finally 会先写入并刷新独立的 `.wujian-cleanup-pending.json`，若目录删除失败，下一次同 PID 操作可立即重试清理；没有 cleanup marker 时只有 owner PID 不同或同 PID 已超过 24 小时才视为 abandoned。它不能消除两个 isolate 同时启动且都在任一 marker 创建前通过扫描的窗口。
- owned workspace 内只要出现软链接就返回 `rollbackFailed` 并保留现场，不跟随、不删除链接目标。相似名称、无 marker 和坏 marker 均保留。
- `.partial` 删除失败时 owner marker 必须继续存在；模拟新 PID 的下一次启动已证明可以把 partial 与 marker 成对清理，避免失去所有权证据后永久残留。

同时，STORE 包在写 `.partial` 前按实际 catalog/manifest/media 字节加 ZIP local/central header 做精确预估；媒体准备阶段也用最小必然包大小提前截断。这避免为注定超过 `maxArchiveBytes` 的包再写一份大型 partial。

### 4.5 本地备份保留门禁

成功发布的备份是用户可转移的交付物，不会被后台静默删除。为避免调用方忘记转移后连续创建把 App 容器重新撑到数 GB，create 使用两阶段非破坏性门禁：

- 媒体准备前先检查既有顶层普通文件字节和最终 `.wujian-backup` 数量；容量已经耗尽时立即返回 `storageLimitExceeded`。
- manifest 完成后以 STORE 精确预计的新包字节再次检查 `existingBytes + estimatedPackageBytes`。
- 默认最多保留 1 GiB 逻辑字节、8 个最终包；所有顶层普通文件（含未知 sidecar、partial 和 owner）均计入字节，避免旧命名或无 owner 残留绕过限制。
- 最终包后缀对应软链接或特殊类型会阻断新建且不会访问链接目标；未知名链接、目录和特殊实体保留且不跟随。
- 门禁只拒绝新的 create，不影响 validate/restore/recover，也不自动删除现有包。后续 UI 接线必须在用户完成分享/转移后提供明确的保留或删除选择。

## 5. 默认安全限制

默认值来自 `BackupRestoreLimits`：

| 限制 | 默认值 | 校验阶段 |
| --- | ---: | --- |
| 原始归档大小 `maxArchiveBytes` | 512 MiB（536,870,912 B） | 打开并解析归档前 |
| ZIP 条目数 `maxEntries` | 10,000 | 读取中央目录后、解压前 |
| 单条目展开大小 `maxSingleEntryBytes` | 32 MiB（33,554,432 B） | 声明尺寸和实际输出双重检查 |
| 全包展开大小 `maxExpandedBytes` | 1 GiB（1,073,741,824 B） | 声明累计值和实际输出预算双重检查 |
| 单条目压缩比 `maxCompressionRatio` | 200:1 | 解压前按中央目录尺寸检查 |
| catalog/manifest/旧 JSON 大小 `maxCatalogBytes` | 16 MiB（16,777,216 B） | JSON 解码前 |
| 唯一媒体数 `maxMediaFiles` | 9,998 | manifest 或旧版媒体扫描时 |
| 图片最大边 `maxImageDimension` | 4,096 | 完整像素解码前的 header 检查 |
| 图片像素数 `maxImagePixels` | 16,777,216 | 完整像素解码前的 header 检查 |
| 本地备份逻辑字节 `maxStoredBackupBytes` | 1 GiB（1,073,741,824 B） | create 前置检查和预计包字节精确检查 |
| 本地最终包数量 `maxStoredBackupFiles` | 8 | create 媒体准备前 |

`9,998` 份媒体加 manifest 和 catalog 恰好不超过默认 10,000 条目的总上限。测试通过注入更小上限，分别证明条目数、展开总字节和压缩比在 schema 解析前生效。

额外结构性限制：

- 条目路径必须是 ASCII 安全集内的受控 POSIX 相对路径，总长最多 1,024 字节、每段最多 255 字节；拒绝绝对路径、盘符、反斜线、Unicode 归一化歧义、Windows 保留名、NUL/控制字符、空段、`.`、`..` 和目录条目。
- 在原始中央目录层检测完全重复名称及大小写折叠冲突，避免解码库覆盖重复 entry 后漏检。
- EOCD 必须恰好位于文件末尾且无注释；中央目录有 64 MiB 独立上限，拒绝条目计数伪报、目录多余字节和 ZIP64/分卷语义。
- 拒绝 ZIP 加密、软链接和非普通文件；实际恢复只接受 `STORE`，`DEFLATE` 只做尺寸/压缩比预检后拒绝。
- 新包只允许 manifest 声明的 catalog 和媒体条目；未知条目不会被静默恢复。
- 备份文件基名只允许 ASCII 字母、数字、下划线和连字符。
- 合作的应用内调用由共享锁、唯一名和目标预检阻止覆盖；跨父目录 rename 被拒绝。不合作外部 writer 在 POSIX lstat→rename 窄窗口内竞争属于明确残余风险。

## 6. 模式、旧格式、错误和 controller 接口

### 6.1 replace 与 merge

- `BackupRestoreMode.replace`：以包内 items/pending 作为下一份完整 catalog；提交后清理旧 catalog 不再引用的媒体。
- `BackupRestoreMode.merge`：保留当前没有同 ID 的记录；包内记录覆盖同 ID 的当前记录，并能在 items 与 pending 之间移动状态。同一包再次 merge 时不会重复增加同 ID 记录或相同内容媒体。

两种模式都会在写入前校验结果中的 ID 唯一性和媒体引用闭包。

### 6.2 旧格式兼容

未包含 `manifest.json` 的 ZIP 会进入受限的 legacy 路径：

- 必须包含根部 `items.json`。
- 可包含根部 `pending_items.json`。
- 媒体只允许位于单层 `images/<name>`。
- 旧记录中的媒体路径只取安全 basename 进行匹配，并支持大小写兼容查找。
- 每份媒体仍会解码并按实际字节 SHA-256 去重，再迁为当前逻辑路径。
- 未引用的旧版媒体会被拒绝。
- 校验摘要返回 `formatVersion: 0` 和 `legacyMigrated: true`。

当前自动化证明了上述双 JSON + 单媒体的迁移恢复；尚未完成从正式发布的历史 App 安装包进行真机端到端升级验证。

### 6.3 领域错误

`BackupRestoreException` 使用结构化 `BackupRestoreErrorCode`，主要分为：

- 互斥：`busy`。
- 输入和命名：`invalidFileName`、`sourceMissing`、`invalidArchive`。
- 版本和 schema：`unsupportedVersion`、`invalidSchema`。
- 归档安全：`unsafePath`、`symbolicLink`、`duplicateEntry`。
- 容量：`entryLimitExceeded`、`expandedSizeExceeded`、`storageLimitExceeded`、`compressionRatioExceeded`。
- 引用和完整性：`missingMedia`、`invalidReference`、`sizeMismatch`、`hashMismatch`、`invalidMedia`。
- 写入与恢复：`writeFailed`、`rollbackFailed`。

service 和 controller 都会把未知底层异常映射为不包含底层异常文本的安全消息。自动化使用合成敏感标记验证了公开错误字符串不回显该标记。

### 6.4 Controller 接口

`BackupRestoreController` 暴露：

- 操作：`create`、`validate`、`restore`。
- 状态：`idle`、`running`、`succeeded`、`failed`。
- 当前操作：`create`、`validate`、`restore`。
- 最近创建结果、检查摘要、恢复结果和结构化错误。
- controller 运行中会直接拒绝第二次调用，并返回 `busy`，不会触发后端。

该 controller 当前是无 UI 的接入点；设置页和其他现有脏 UI 文件没有在本切片中修改。

### 6.5 共享根目录 mutation coordinator

`StorageMutationCoordinator` 在同一 isolate 内以 canonical documents root 为 key，为以下合作调用提供统一锁顺序：

- `LocalCatalogRepository.loadCatalog/saveCatalog`。
- `MediaStorageService` 的持久化、优化、缓存/导出清理与写出。
- `LocalBackupRestoreService` 的 create/validate/restore/recover exclusive 操作。
- `AppController._mutateCatalog` 通过 `MediaStorageService.runStorageTransaction` 把“持久化媒体→保存 catalog→清理”整段放在一个根目录 transaction 内。

入队 ticket 在等待异步 documents provider/canonicalization 之前同步登记，避免后发调用因文件系统调度反而先入锁；不同根的 action 仍可并行。exclusive 一旦入队就占位，外部 catalog/media transaction 立即返回不带路径的安全 `StorageMutationBusyException`，不会排队到 restore 后使用旧引用集。exclusive Zone 内调用 catalog/media 可同根重入，不会自锁。

Backup service 还对根内固定普通文件取得 advisory process lock，并在打开前以 nofollow 类型检查拒绝软链接；这能协调遵守同一锁文件的独立进程。它不等于完整的跨 isolate/process 事务：Dart 在 macOS/Linux 上的 advisory lock 是进程级，同一进程的多个 isolate 仍可能同时成功；普通 catalog/media mutation 也没有取得该进程锁。对外错误只包含安全常量，不回显 canonical root、provider 路径或底层异常标记。

## 7. 自动化测试矩阵与结果

三组备份核心定向测试合计 84 项，均为本轮实际运行结果：

| 测试文件 | 通过/总数 | 覆盖重点 |
| --- | ---: | --- |
| `test/backup_file_system_test.dart` | 8/8 | 流式复制与刷新、不覆盖目标、拒绝源软链接、同目录发布、拒绝跨目录 rename、精确且幂等的清理 |
| `test/backup_restore_controller_test.dart` | 6/6 | create/validate/restore 状态、merge 透传、结构化错误、未知异常脱敏、运行中互斥 |
| `test/backup_restore_service_test.dart` | 70/70 | v1 闭环、实际 hash/尺寸、去重、merge/legacy 幂等、严格 ZIP、容量门禁、故障回滚、rename 不确定态、journal/scavenger lease、孤儿清理、共享事务互斥 |

此外，coordinator + media + AppController reliability + export reliability 四组相关回归已联合实际运行 42/42；MediaStorageService + AppController reliability 单独组合为 26/26，export reliability 单跑为 3/3。最终全仓测试实际为 141/141，包含既有未提交 UI 测试但没有把其文件纳入本切片。

service 的 70 项进一步覆盖：

- 同一 JPEG 被 item 与 pending 共同引用，以及两个不同源文件具有相同字节时，包内唯一媒体数都为 1。
- 新包 create/validate/replace restore 闭环，恢复媒体实际字节与源 fixture 相同，包内 catalog/manifest 不含源绝对路径。
- catalog 的相对媒体路径以 documents root 解析；同一包连续 merge 两次不重复媒体，缺时间字段的 legacy 包用固定回退时间保持语义幂等。
- 修改媒体一个字节、篡改 manifest 媒体尺寸、篡改 manifest catalog hash，均在活跃数据写入前拒绝，旧 catalog 与旧媒体树不变。
- legacy 双 JSON 与媒体迁移；路径穿越、归档软链接、重复条目、EOCD 伪报/注释伪签名、SFX/未声明 gap、Unicode/超长/保留名全部拒绝。
- 条目数、实际展开字节、压缩比、图片边长/像素、STORE-only、预计归档字节和本地保留字节/数量门禁。
- `afterMediaPublish`、`beforeCatalogCommit`、repository 持久化后报错、部分写后抛错、静默同长坏写，以及 OLD 回写成功/失败两分支。
- 三个 rename 发布点的“已落盘后报错”收敛，以及 rename 前竞争目标不被本次回滚误删。
- 手工 journal 的 OLD/NEW、previous=next、相对引用、空媒体、journal 删除失败重试和 planned-media hash/引用保护。
- 导出发布前失败、partial 删除失败仍保留 owner、启动 scavenger 回收至少 14 KiB 合成残留、fresh same-PID active lease 返回 busy、cleanup-pending 同 PID 立即重试、链接 sentinel 不受影响。
- replace 孤儿清理只删受管媒体并保护输入包/sidecar；media transaction 与 restore/optimize 的双向 busy 互斥。
- 操作锁、备份包后缀链接和错误文本都使用合成 sentinel 验证不跟随、不删除、不回显路径或底层标记。

## 8. 量化指标

测试媒体在运行时生成，因此不把某个平台和某次编码器产生的偶然字节常数固化为发布指标；测试直接比较实际读取长度和 SHA-256。可复现的数量及差值如下：

| 场景 | items | pending | 唯一媒体 | 媒体字节变化 | 其他结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| v1 导出 fixture | 1 | 1 | 1 | 包内媒体字节 = 源 JPEG 实际字节，差值 0 B | 两条记录共享同一实际 SHA-256 |
| replace 恢复后 | 1 | 1 | 1 | 恢复媒体字节 = 包内媒体字节，差值 0 B | 恢复文件 SHA-256 与 manifest 相同 |
| 首次 merge | 当前原有 1 + 包内 1 | 1 | 1 | 新增 1 份唯一媒体 | `createdMediaCount = 1` |
| 同包第二次 merge | 2 | 1 | 1 | 相对首次 merge：文件数 +0、媒体字节 +0 B | `createdMediaCount = 0`，catalog 语义快照不变 |
| replace 后孤儿清理 | 1 | 1 | 1 | 最终只保留包内唯一媒体 | `deletedOrphanCount = 2`、`retainedOrphanCount = 0` |
| 导出发布前故障 | 1 | 0 | 源媒体 1 | 源媒体字节和 SHA-256 变化 0 | 最终包 0、`.partial` 0、create 工作区 0 |
| 两个不同源文件、相同字节 | 2 | 0 | 1 | 相对单份内容：包内媒体文件数 +0、媒体字节 +0 B | 实际 SHA-256 去重，不依赖源路径 |
| strong-kill 合成残留回收 | 不涉及 | 不涉及 | 不涉及 | 回收字节不少于 14 KiB | 仅删除带有效 owner/marker 的 workspace、partial 和 journal temp |
| retention 字节边界 | 0 | 0 | 0 | 两包总字节恰等于注入上限时通过；第三包 +1 个包被拒绝 | 最终包保持 2，`.partial`/owner 0 |

这里的“唯一媒体”按实际内容 SHA-256 计数，不按 item 引用数或旧媒体文件名计数。

## 9. 故障注入与不可破坏性证据

| 故障点/残留状态 | 注入方式 | 已证明结果 |
| --- | --- | --- |
| `beforeBackupPublish` | 合成 `FileSystemException` | 导出失败不发布包，不留 `.partial`/工作区；源 catalog 与媒体不变 |
| `afterMediaPublish` | 合成 `FileSystemException` | 新媒体被回滚；旧 catalog 与旧媒体树不变 |
| `beforeCatalogCommit` | 合成 `FileSystemException` | 新媒体被回滚；旧 catalog 与旧媒体树不变 |
| catalog 首次保存失败 | 内存 repository 第一次 save 失败、第二次允许旧快照保存 | save 调用 2 次，最终 catalog 与旧快照相同，新媒体不存在 |
| catalog 已持久化 NEW 后抛错 | repository 先保存再抛；分别允许/拒绝 OLD 回写 | OLD 回写成功时完整回滚；失败时保留 journal 和 NEW 所需媒体，不制造悬空引用 |
| copy 部分写后抛错 | fake filesystem 写半份 `.restore` 后抛错 | 清理临时文件和 journal，OLD catalog/media 逐字节不变 |
| copy 静默同长坏写 | fake filesystem 改变一个字节后正常返回 | 发布前二次 SHA-256 失败，OLD catalog/media 逐字节不变 |
| rename 已落盘后抛错 | fake filesystem 在 final/media/journal rename 完成后抛错 | 源已消失且目标 exact 时按对应提交状态收敛 |
| rename 前同内容目标竞争 | fake filesystem 复制 exact 目标但保留源后抛错 | 不接管、不删除竞争目标；本次 partial/temp 清理，OLD 保持 |
| partial 删除失败 | fake filesystem 第一次删除 `.partial` 失败 | owner marker 保留；模拟新 PID 后下一次启动成对删除 partial+owner |
| journal + current OLD | 手工写入窄化 journal、新媒体和 `.restore-*.tmp` 后创建新 service | 删除计划新媒体/temp/journal，保留 OLD |
| journal + current NEW | 手工写入窄化 journal、新媒体、旧孤儿和 temp 后创建新 service | 验证新媒体实际 SHA-256，保留 NEW，删除旧孤儿/temp/journal |
| 同根并发恢复 | `Completer` 精确暂停第一个 service 于校验后 | 第二个实例确定性返回 `busy`；释放后第一个成功，无基于 sleep 的竞态推测 |

校验失败用例还保存恢复前 catalog 的 JSON 语义签名和 `images/` 相对路径到实际 SHA-256 的映射；失败后再次读取并要求二者完全相等，而不是只检查“没有抛出第二个异常”。

## 10. 数据安全声明

- 全部测试目录由 `Directory.systemTemp.createTemp` 创建，每例结束后只删除该例独立临时目录。
- 全部 item、pending、journal、归档和 JPEG 都是运行时合成 fixture；没有读取、复制、输出或删除真实用户媒体。
- 测试没有访问应用真实文档目录，也没有使用下载媒体、浏览器资料、真实日志或生产数据库。
- 备份格式只包含 catalog 业务记录和其引用媒体；不包含 App 设置、云配置或平台认证材料。
- 没有读取 `.env`、证书、私钥或其他本地凭证文件。
- 没有访问登录态，没有调用云上传、付费 API 或外部部署服务。
- 公开错误脱敏测试只使用明确标注的合成标记，不包含真实秘密或个人信息。

## 11. 未覆盖项与残余风险

以下项目不能从本轮自动化结果推导为已通过：

1. **真实 ENOSPC/磁盘配额**：当前以 `FileSystemException`、部分写后抛错和静默坏写 fake 模拟低磁盘/短写，没有真的填满磁盘，也没有覆盖每个字节位置的真实设备短写。
2. **真机强杀**：journal/scavenger 测试通过手工构造崩溃后状态验证重启收敛，没有在 iOS/Android 真机上于每个提交指令后强杀进程。
3. **目录 fsync**：实现对文件执行 flush，并用同目录 rename 发布；Dart 标准跨平台文件 API 没有在本实现中提供父目录 fsync，因此掉电后的 rename 目录项持久性仍依赖平台文件系统语义。
4. **共享锁范围**：`StorageMutationCoordinator.shared` 是 isolate-local；同一 isolate 的 repository/media/backup 实例共享 canonical-root 顺序和 transaction。backup advisory file lock 可协调遵守它的外部进程，但 macOS/Linux 上同进程不同 isolate 仍可能同时取得；active marker 只能阻止已经可见的 lease，不能关闭两个 isolate 同时通过扫描的启动窗口。普通 catalog/media mutation 也不取得该进程锁，因此不宣称全局跨 isolate/process 原子性。主应用当前只从单 isolate 接入该 service。
5. **外部 rename 竞争**：Dart 不提供跨平台 no-replace rename；应用内合作调用已互斥，完成不确定态也验证源消失+目标内容，但不合作外部 writer 仍可能在 nofollow 检查与 open/rename syscall 的窄窗口内竞争。
6. **cleanup marker 与目录同时写/删失败**：正常 finally 已先刷新 cleanup-pending marker，下一次同 PID 可立即重试；若 marker 写入和目录删除同时失败，active lease 会让后续操作返回 `busy`，避免继续累积，但该单个 workspace 仍需等 24 小时 stale 门槛或人工诊断，当前没有 root-workspace 使用量指标。
7. **本地最终包生命周期**：1 GiB/8 份门禁阻止无上限累积，但不会静默删除已成功发布的用户包；当前 UI 尚未接线，调用方完成转移后仍需提供明确的保留/删除选择。门禁按逻辑文件长度计算，不等同于磁盘 allocation 或可用空间保证。
8. **UI 接线**：controller 已验证但尚未接入设置页；尚无文件选择器、用户确认、进度展示和真实交互测试。
9. **历史真机升级**：legacy 合成包与缺时间字段幂等已验证，但尚未用正式历史版本安装产生的数据执行真机迁移。
10. **超大合法包性能**：默认上限和小上限边界已验证，尚未对接近 512 MiB/10,000 条目的合法包记录耗时、峰值内存和低端设备温升。
11. **真实性与保密性**：备份包没有签名或加密；能检测字节不一致，但不能证明包来自可信设备，也不能防止拿到包的人读取业务内容。
12. **提交后孤儿删除重试**：恢复结果记录 `retainedOrphanCount`，但尚未实现持久 janitor 队列；个别孤儿删除失败会保留文件而不是冒险删除其他数据。

## 12. 实际验证命令

```text
dart format <本切片 15 个 Dart 文件>
# 15 files，0 changed

dart analyze
# No issues found

flutter analyze --no-pub
# No issues found

flutter test --no-pub test/backup_file_system_test.dart
# 8/8 通过

flutter test --no-pub test/backup_restore_controller_test.dart
# 6/6 通过

flutter test --no-pub test/backup_restore_service_test.dart
# 70/70 通过

flutter test --no-pub test/app_controller_reliability_test.dart test/export_services_reliability_test.dart
# 13/13 通过

flutter test --no-pub
# 141/141 通过；包含现有工作区未提交 UI 测试，但未暂存其文件

flutter build apk --debug --no-pub
# 成功生成 Debug APK

flutter build macos --debug --no-pub
# 成功生成 Debug icheck.app；只有 Xcode Run Script 每次执行的非阻断 warning

git diff --check
# 通过，无空白错误
```

全部自动化只使用临时目录和合成 fixture。提交前仍需在未暂存范围和精确暂存范围各执行一轮不回显匹配值的信息泄漏硬门禁，并核对敏感文件跟踪状态、`.gitignore`、ahead/behind 及既有 UI/主题脏改动隔离；门禁结果在最终交付中单独报告。
