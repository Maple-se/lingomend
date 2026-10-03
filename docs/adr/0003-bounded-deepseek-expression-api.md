# ADR 0003：有限范围的 DeepSeek 表达 API

状态：API 切片实现；真实凭据/延迟/交互由用户体验验证。

## 决策

不直接把整段 `CompatibleCoachingProvider` 接进伴随候选。该接口生成段落与学习点，
不适合低干扰输入。保留它作为独立基础，新增 `ExpressionProviding`：

1. 候选请求只接收中文占位、截断的左右语境与写作偏好；只返回短替换词或 abstain。
2. 本地 `InlineProposal` 重建原范围，模型不能指定位置，也不能改动其他英文。
3. 用户主动学习时单独请求固定候选的解释，不允许重新指定目标文本。
4. `ExpressionService` 为原生体验编辑器与伴随共享服务会话、短期缓存和节流。
5. 服务配置保存后替换会话，取消两个编辑器和学习任务；从不把旧端点的密钥转到新端点。

依照官方文档使用 DeepSeek Chat Completions 的 JSON object、显式关闭思考与有限输出。
采用 Swift URLSession，暂不增加 SDK、流式 UI、工具调用或后端。完整响应通过本地检查后
才显示候选；HTTP 错误、空响应、截断、无效结构都拒绝。无自动重试或演示回退。

## 边界

格式/长度校验和位置安全不等于语义准确，也无法靠提示词保证免疫所有错误或注入。
短句可能全部落在有限上下文内。开启联网与允许观察必须清楚告知用户；浏览器授权
不等同按网站许可。默认离线与默认禁止跨应用接受不变。临时签名的钥匙串/系统权限体验
仍需用户验证；本轮不自动发起真实付费请求。

## 依据

- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
- [DeepSeek JSON output](https://api-docs.deepseek.com/guides/json_mode/)
- [分阶段开发与交付](../development-stages.md)
