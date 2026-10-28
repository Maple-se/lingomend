# T2.1 本地诊断体验

## 版本与默认值

当前体验包版本见 [交付状态](status.md)。先退出旧进程，再打开新构建的 app。

build 16 在明确写作/阅读快捷键时各记录一条 `captureChecked`，与同次操作共用关联编号。build 20 的写作解释请求使用 `shortcut=explain`，与候选所属操作共用关联编号；它只记录开始、完成或失败等固定事件，不记录解释原因、变体、原文或建议。
嵌套 `capture` 只含固定类别、有限长度/计数和 AX 接口结果码；不保存正文、标题、控件描述或完整界面树。
`focus`/`focusRole` 标识焦点来源和类别，`role` 是最后尝试/成功的文本节点类别，
`textLength`、`selectionLocation`、`selectionLength` 是有限数值，缺失表示未取得，不等于 0。
阅读成功时的 `textLength` 指所取得选中文字的长度；Word 阅读失败时可能是正文字符数。
写作时它指取得文本快照的长度。build 17 的 `valueSettable`、`rangeSettable` 和
`wordCompatibility` 都是布尔值；前两项记录所有写作控件的能力，最后一项标明是否匹配 Word 正文特例。
`emptyValues` 记录写作读取中遇到的空/空白直接值次数，`nodes`/`depth` 为结构查找统计。
`stop` 区分 matched、exhausted、nodeLimit、depthLimit、timeLimit、refused。
`results` 中 code=0 表示调用成功，但不证明返回了正文或非空选区；同类 API 保留最后一次调用结果。
模型后的校验与接受前重读不逐次输出采集摘要，避免重复日志。

候选因变化失效时，`candidateDismissed.reason` 区分 sourceChanged、selectionChanged、focusChanged、sourceReadFailed。
模型层的 CancellationError 仍会记录 userCancelled；判断触发原因应与同一 operation 的 candidateDismissed 一起查看。
开发包：`.build/LingoMend.app`，首次默认开启日志；你手动关闭后，重启仍关闭。
正式渠道默认关闭，不继承开发渠道的手选开关；渠道缺失或错误也默认关闭。
更新临时签名后如 macOS 不再认可辅助功能权限，按既有 T2 指引重新添加同一路径的 app。

构建不会启动 app，也不会发送模型请求：

```sh
sh Scripts/build-local-app.sh
sh Scripts/build-local-app.sh release
```

第一条生成 development 包，第二条生成独立的 `.build/LingoMend-Release.app`。
两者都使用 release 编译优化；默认值由 bundle 的 `LingoMendBuildChannel` 决定。
它们是同一个产品身份，不建议同时运行。

## 请你帮忙体验

1. 打开新开发包 → 菜单栏图标 → 设置… → **本地开发诊断**。确认渠道为 development，
   首次/恢复默认后开启，状态为正在记录。开关不需要点“保存设置”。
2. 用 TextEdit 合成句 `This works 轻载条件下.` 按 ⌃⌥L。
   先取消一次，再重新求助并明确接受一次，最后在 TextEdit 按一次 ⌘Z。
   这一步同时复查 T2 写回/撤销；不强制开启联网。若保留原有联网配置，求助仍可能付费。
3. 点击“打开日志目录”，打开 `runtime.log`。正常记录包括
   `helpStarted → scopeResolved → modelStarted → providerInvoked/modelCompleted → candidateShown`；
   缓存命中会出现 `cacheHit` 且不调用 provider。接受链另有 preflight、format、clipboard、
   dispatch、verification、caret、cleanup 和完成/失败事件。
   同一次求助至接受应共享 `operation`；日志不应出现上述中英文原文或生成建议。
4. 关闭日志，等待设置操作完成后再求助/取消。文件内容不再增加；重启仍关闭。
   再开启会有新随机 session 和会话头。关闭不会删除旧文件。
5. 先关闭再点“清空日志…”并确认，五个日志应消失。重新开启后可再次记录。
   若开启时清空，旧事件被丢弃，只保留新会话头与之后的新事件。
   清空不可恢复，只影响当前渠道的模块日志，不改 API/学习设置。
6. 点“恢复渠道默认”：development 开启。可选打开正式渠道包检查默认关闭；
   如过去手动开启过 release，先恢复它自己的默认再检查。

反馈请给版本、操作步骤、现象，以及有问题的固定事件/随机 operation 编号即可。
不必发送原文或完整日志；模块不自动导出或上传。失败日志中的 `dispatched: false`
表示未发送粘贴；`true` 且 unconfirmed 表示要检查 TextEdit，不能据此直接重试。

## 日志位置、上限与安全

- 开发：`~/Library/Logs/LingoMend/Development/`
- 正式：`~/Library/Logs/LingoMend/Release/`
- 缺失/错误渠道手动开启：`~/Library/Logs/LingoMend/Unknown/`
- `runtime.log` 与 `runtime.1.log`～`runtime.4.log`，每个最多 1 MiB。
  最多 5 MiB 日志，加一个不包含事件的空 `owner.lock`。7 天保留期在开启/轮转时清理。
- 内存队列最多 256 条，后台串行写入；过载优先丢低级别事件并汇总数量。
- 只记录固定事件、时间、随机编号、目标长度、耗时、状态及固定错误分类。
  不记录文本、建议、提示词、剪贴板、URL/模型自由字符串、密钥、网络正文或文档路径。
  与一次按需操作关联的事件会额外记录当前前台应用的系统名称和 bundle identifier，
  用于区分 Codex、微信、TextEdit 等兼容性问题；不记录窗口标题、文档名或编辑内容。
- 写盘故障显示日志不可用，写作与剪贴板清理继续；关闭后重开可重试。
  同渠道多个进程时仅一个获得写锁，另一个诊断不可用，避免日志互相覆盖。
- 普通退出仅给日志最多 300 ms 的收尾时间；强退/断电可能丢失末尾事件。
- 日志不作为掌握证据、不上传。实际目录在 Git 工作区外；意外复制进仓库的
  `*.log`、`Diagnostics/`、`LocalLogs/`、`.build/` 也被忽略。

源码与这份合成测试步骤可以提交；真实运行日志和个人反馈仍只留本地。
