# 历史 T1 语义与范围案例

这些案例始于 0.3.0/build 4 的只读阶段，现作为可复用验收输入。当前版本、启动与写回操作见 [当前体验](t3-global-experience.md)，阶段定义只看 [开发计划](development-stages.md)，支持证据只看 [状态页](status.md)。本页不再提供独立的“下一阶段”指令。

| 输入/操作 | 验收目标 |
| --- | --- |
| `This works 轻载条件下.` | 工况表达自然，保留可用英文 |
| `I very like 这个方案.` | 修正英文搭配，同时补中文；不限制为只改中文 |
| `I am 负责 this project.`，只选中文 | 仅替换选区为 responsible for，左右语境不重复 |
| `We need 降低损耗 without 增加成本.` | 两处缺口都补全，保留成本约束 |
| `She go to the lab yesterday.` | 必要的过去时纠正，不添情节 |
| `I made a decision yesterday.` | 无需修改，不为文风升级而换词 |
| `这个方法可能会降低损耗。` | 保留可能性与判断强弱 |
| `First stays. This works 轻载条件下.`，光标第二句中 | 只将第二句作为修改目标，包含光标两侧 |
| `The label reads “轻载条件下”.` | 保留原文引文 |
| `If the load is reduced, we can` | 不替作者续写未完成观点 |
| `Dr. Li checks Fig. 2 at 0.5 A 轻载条件下.` | 不被缩写/小数错误切句；数值、单位和术语保留 |

真实模型允许合理措辞变体。范围、JSON 和数字检查不等同语义正确；当前可执行的合成抽查见 [质量验收](quality-review.md)。当前 T3 已支持显式短段落，不能沿用旧 T1 的“不支持任何多句选区”作为现状。
