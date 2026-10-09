# T2.1 本地诊断体验

## 版本与默认值

本轮为 0.4.1（build 6）。先从旧 LM 菜单退出，再打开新构建的 app。
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

1. 打开新开发包 → LM → 设置 → **本地开发诊断**。确认渠道为 development，
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
- 写盘故障显示日志不可用，写作与剪贴板清理继续；关闭后重开可重试。
  同渠道多个进程时仅一个获得写锁，另一个诊断不可用，避免日志互相覆盖。
- 普通退出仅给日志最多 300 ms 的收尾时间；强退/断电可能丢失末尾事件。
- 日志不作为掌握证据、不上传。实际目录在 Git 工作区外；意外复制进仓库的
  `*.log`、`Diagnostics/`、`LocalLogs/`、`.build/` 也被忽略。

源码与这份合成测试步骤可以提交；真实运行日志和个人反馈仍只留本地。
