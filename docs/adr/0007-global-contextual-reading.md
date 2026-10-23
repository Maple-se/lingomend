# ADR 0007：全局写作与独立的语境阅读

状态：T3 核心实现；0.5.2 补充选区接口兼容。真实应用体验待用户反馈。

## 产品边界

- ⌃⌥L 是写作求助；⌃⌥D 是选词/选句阅读。学习操作不推断成编辑权限。
- 既保留当前句表达辅助，也支持只读网页、文字 PDF 和其他应用的可访问选区。
- 微信、备忘录、Safari、VS Code、Codex、预览均为目标；不能以应用白名单代替能力适配。
- 不主动续写观点，不改变作者风格；无闲时内容分析、无隐藏复制、无 OCR。

## 阅读实现

`MacOSReadingSelectionReader` 优先读取当前元素及其父级的标准选区或文本标记。
对于 PDF 等焦点在容器上的情况，限定在前台窗口查找，最多 80 个节点、深度 8、
搜索预算 2 秒，每次 AX 调用另有短超时；单次调用/最终重验可能越过搜索预算。
窗口未暴露聚焦编辑元素时，允许只读捕获从该前台窗口开始；窗口/焦点身份仍在返回前重验。
密码控件拒绝，且不遍历其子树。未读取到选区时明确提示，不从剪贴板补取。

标准范围路径对照实际文本与选中内容，取得所在句；大文档通过参数化范围读取有限片段。
WebKit 路径通过系统 `AXTextMarkerRangeCopyStartMarker` / `CopyEndMarker` 取端点，
查询暴露的 `AXIndexForTextMarker` 与句/段范围，再对照偏移处文字。没有暴露所需能力时
保留实际拿到的选区，标记缺少语境，不以同名词搜索代替位置证据。
标准范围也支持 `AXSelectedTextRanges` 只有一个条目、单数属性缺失的控件。
若阅读选区由多个片段组成，只使用实际 `AXSelectedText`，不把片段间未选中文字并入语境；
保留片段范围元数据重验，任一范围变化使结果失效。
PDF 物理换行可归并为间隔，软连字符可消除；可见连字符保留，避免破坏真实复合词。

纯值 `ReadingScope` 不含编辑授权；`ReadingRequest` 分离 selection/before/after/context_kind。
选区最多 1200 UTF-16，合计最多 2000；超限选区拒绝，不截断后假装完整。
只返回 meaning/context_meaning/usage，严格字段与长度检查。无语境时 context_meaning 必须为空。
UI 展示实际读取的上下文及完整/片段/缺失状态；模型仍可能理解错误，结构校验不是语义保证。

模型复用现有安全端点配置、钥匙串密钥和联网开关；1400 output tokens / 20 秒。
阅读请求独立 3 秒节流、30 秒限流/凭据冷却、8 条 60 秒内存缓存；不落盘，不自动重试。
写作与阅读共享 UI 操作代次，新请求/取消/焦点变化会撤销旧结果。源元素订阅仅在活跃请求中存在。
只读解释卡不抢编辑焦点，也不注册接受键。选区坐标不可用时卡片靠近指针，仅作显示定位。

其他应用的访问开关默认关闭；旧设置迁移保留原有模型、联网选择和 TextEdit 许可，
不会因新增字段解码失败而重置。开启后仍只在用户快捷键触发时读取。
诊断增加固定阅读事件和语境等级，不写选区/语境/模型正文/应用名称。

## 依据与验证

- [Apple 选区属性](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)
- [Apple 非连续选区属性](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangesattribute)
- [Apple 文本标记端点](https://developer.apple.com/documentation/applicationservices/3882828-axtextmarkerrangecopystartmarker)
- [WebKit AX 参数实现](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm)

按接口行为独立实现，未复制上游模块。上述扩展属性按运行时能力读取；不是所有第三方控件都提供。
自动检查使用合成文本、内存 HTTP 响应和隔离原生编辑器；不等于目标应用实测通过。
真实网页/PDF/微信/备忘录/VS Code/Codex 的选区与语境覆盖需要用户体验反馈。
