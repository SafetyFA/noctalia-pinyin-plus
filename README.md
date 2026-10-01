# Pinyin Plus · 中文应用的拼音搜索（Noctalia v5 启动器插件）

> 像 Listary 一样：输入 `wx` 找到**微信**，`rwzx` / `renwuzhongxin` 找到**任务中心**，`ylkz` 找到**音量控制**。
> 纯 Luau · 无 Python · 无预生成数据 · 运行时索引 · **不与内置搜索结果重复**

**English summary** · [安装](#安装) · [示例](#示例) · [工作原理](#工作原理) · [调参](#可调常量) · [维护与排错](#维护与排错) · [已知限制](#已知限制) · [更新日志](CHANGELOG.md)

---

## 特性

- **全拼 / 首字母 / 紧凑子序列**：`weixin`、`wx`、`wxin` 都能命中「微信」
- **中文查询自动转拼音**：打 `任务` 也能找到 `任務中心`（繁简不一致照样命中）
- **运行时索引**：直接读 XDG `applications` 目录 → **不需要 Python、不需要预生成数据**；**新装的中文软件最迟 60 秒自动可搜**（打开启动器或任意一次输入都会触发检查）
- **不产生重复行**：名称 / GenericName / Keywords 能直接命中的查询交给 Noctalia 内置 provider；只有"内置搜不到"的拼音命中才由本插件补一条
- **使用频率记忆**：合并 Noctalia 自己的激活统计（`usage_counts.json`），你常用的应用自然排在前面
- **免维护**：改脚本即热重载；索引**分片构建 + 看门狗**，不会因为 Luau 回调的 CPU 预算被掐断而永久失效
- **可调**：匹配阈值、返回条数、频率权重都在 `provider.luau` 顶部常量里

## 示例（实测）

| 输入 | 结果 |
|---|---|
| `wx` · `weixin` · `wxin` | 微信 |
| `rwzx` · `renwu` · `renwuzhongxin` | 任務中心 |
| `任务` · `任务中心` | 任務中心 |
| `ylkz` · `yinliang` | 音量控制 |
| `ddqd` · `dida` | 滴答清单 |
| `微信` · `音量` · `qq` · `wechat` | 由内置 provider 给出，**插件不出重复行** |

## 安装

```bash
# 从 GitHub 克隆（目录名必须叫 pinyin-plus，插件 id 与之一致）
git clone https://github.com/SafetyFA/noctalia-pinyin-search.git \
  ~/.local/share/noctalia/plugins/pinyin-plus

# 启用
noctalia msg plugins enable safety/pinyin-plus
noctalia msg plugins list          # 应显示 enabled
```

手动安装：把 `plugin.toml`、`provider.luau`、`pinyin.luau`、`pinyin-data.bin` 四个文件放进
`~/.local/share/noctalia/plugins/pinyin-plus/`，然后在上面的启用步骤里启用；
也可以在 `~/.local/state/noctalia/settings.toml` 的 `[plugins] enabled` 数组里加上 `"safety/pinyin-plus"`。

**要求**：Noctalia v5（`plugin_api = 22` ⇒ 需要 ≥ v5.0.0-beta.8）。没有其它依赖。

> 想用自己的作者名：改 `plugin.toml` 里的 `id = "<作者>/pinyin-plus"`，并同步改启用列表与 `[[launcher_provider]]` 无需改动。

## 文件

| 文件 | 说明 |
|---|---|
| `plugin.toml` | 插件清单：`[[launcher_provider]] id = "pinyin"`、`include_in_global_search = true` |
| `provider.luau` | 主逻辑：分片索引、匹配打分、启动应用、使用频率 |
| `pinyin.luau` | 汉字 → 拼音查表（惰性读取 `pinyin-data.bin`，惰性避免加载超预算） |
| `pinyin-data.bin` | 拼音数据：首字母表 + uint16 偏移表 + 全拼数据区（U+4E00–U+9FFF，20,992 字） |
| `tests/run.lua` | 本地测试桩：用 `lua5.4` 直接跑匹配逻辑，可追加查询词 |
| `tests/fixtures/pxdg/` | 假 XDG 目录，用来回归验证"刚装好的中文应用能被搜到" |

## 工作原理

### 1. 索引（运行时）

遍历 `$XDG_DATA_HOME/applications` 与 `$XDG_DATA_DIRS/*/applications`（含 Flatpak 导出目录、
`/usr/local/share`、`/usr/share`），解析 `.desktop`：

- 按 **XDG 优先级**去重：先扫到的（用户级）胜出 → 每个应用最多 1 行
- 跳过：`Type != Application`、`NoDisplay=true`、`Hidden=true`、`OnlyShowIn`/`NotShowIn` 与当前桌面不符、没有 `Exec`
- 只对**含中文**的名字计算拼音；用户级/系统级两条路径的同 id 条目只索引一条
- 索引最长缓存 60 秒；`touch provider.luau` 可立即重建

### 2. 匹配与打分（从高到低）

| 规则 | 分数 |
|---|---|
| 全拼完全相等 | 1200 |
| 首字母完全相等（查询 ≥2 字） | 1180 |
| 全拼 / 首字母 前缀 | 1120 / 1100 |
| 全拼 / 首字母 包含（查询 ≥3 字） | 1000 / 980 |
| 紧凑子序列（跳过 ≤2 字，查询 ≥3 字） | 900 / 880 |
| 描述包含 · 可执行名包含 · 可执行名子序列 · 图标名包含 | 700 / 640 / 600 / 520 |

后一组"弱匹配"只对**用户实际输入的查询**生效且长度 ≥3，避免单字母查询带出噪音。
最终分数再叠加**使用频率加权** `min(次数 × 8, 400)`。

### 3. 为什么不会重复

- 查询是应用**名称 / GenericName / Keywords**的子串 → 跳过（内置 provider 已经能搜到）
- 纯 ASCII 查询对纯 ASCII 名称的子序列匹配 → 跳过（内置是模糊匹配）
- 中文查询若命中名称 → 跳过；只有拼音命中才由本插件输出结果
- 想让本插件也返回这些结果：把 `DEFER_SUBSTRING_TO_BUILTIN` / `DEFER_ASCII_FUZZY_TO_BUILTIN` 改成 `false`

### 4. 使用频率记忆

| 来源 | 位置 | 说明 |
|---|---|---|
| 插件自记 | `~/.local/state/noctalia/pinyin-plus-usage.json` | 每次通过插件启动某应用 +1 |
| Noctalia 统计 | `~/.local/state/noctalia/usage_counts.json` | 按 `.desktop` **条目 id** 汇总（用户级/系统级路径的次数会合并），历史使用立刻生效 |

> 提示：如果你迁移过桌面条目文件，统计会按**路径**留在旧路径上，需要用同一 id 的新路径重新累计（或在统计文件里把旧键的值搬到新键）。

## 可调常量

| 常量 | 默认 | 作用 |
|---|---|---|
| `MAX_RESULTS` | 12 | 最多返回条数 |
| `INDEX_TTL_MS` | 60000 | 索引缓存时长（新装应用可见延迟上限） |
| `BUILD_CHUNK` / `BUILD_YIELD` / `BUILD_STALE_MS` | 4 / `sleep 0.05` / 15000 | 分片构建节奏与看门狗超时（CPU 预算保护） |
| `MAX_SUBSEQ_GAPS` | 2 | 子序列允许跳过几个字 |
| `MIN_SUBSEQ_LEN` | 3 | 子序列匹配的最短查询 |
| `MIN_WEAK_LEN` | 3 | 描述/可执行名等弱匹配的最短查询 |
| `USAGE_WEIGHT` / `USAGE_CAP` | 8 / 400 | 使用频率加权 |
| `USE_NOCTALIA_USAGE` | true | 是否合并 Noctalia 自己的统计 |
| `SHOW_PINYIN_IN_SUBTITLE` | true | 字幕里是否显示命中的拼音 |
| `PINYIN_IN_TITLE` | false | 把拼音/查询词写进标题（宿主若按标题打分可能更靠前，但标题会变长） |
| `MAX_SUBTITLE` | 64 | 字幕描述截断长度 |

## 维护与排错

- **新装应用搜不到**：等 60 秒或在启动器里随便打一个字触发重建；也可以 `touch ~/.local/share/noctalia/plugins/pinyin-plus/provider.luau`
- **日志**：`~/.cache/noctalia/noctalia.log`
  - `PinyinPlus: building index (chunk=4)` / `PinyinPlus: indexed N apps` → 正常
  - `PinyinPlus: index build stalled, retrying with chunk=N` → 看门狗自动降档重试（无需干预）
- **手动重载**：保存 `provider.luau` 即热重载（索引会随之重建）
- `onIpc` 支持 `rebuild` / `dump-index` / `explain <词>`；⚠️ 但 Noctalia 5.2.0 的 `noctalia msg plugin …`
  无法投递到 launcher provider（实测 `no target matched`），这些入口目前只在将来版本可用

## 已知限制

- **跨 provider 的最终排序由 Noctalia 决定**：宿主把所有 provider 的结果按**它自己算的 relevance score** 合并，
  而插件结果**无法提供分数**（官方文档的插件 API 3–32 级能力清单里没有这一项，配置层与清单层也没有权重开关）。
  后果：内置 provider 的模糊匹配行可能排在插件行之前。实例：搜 `wx` 时
  `NVIDIA X 服务器设置` 会因 `Name[pl]=Ustawienia serwera X NVIDIA` 命中 `w…x` 子序列而排在第一，
  本插件的「微信」只能排第二。
- 彻底的解法在上游：允许 provider 提供 score/rank，或让"激活次数加权"作用于插件返回的行。
- 生僻字（超出 U+4E00–U+9FFF 的 20,992 字表）不参与拼音匹配，但该应用的其它字、名称、描述匹配照常。

## 与旧版 pinyin-search 的差异

| | pinyin-search | **pinyin-plus（本插件）** |
|---|---|---|
| 数据来源 | Python 预生成 `apps-data.luau` + 每次加载后台跑脚本 | **运行时索引**，无 Python、无预生成 |
| 新装应用 | 依赖后台脚本重跑 | 60 秒内自动可搜 |
| 索引去重 | 无 → 用户级/系统级两条路径会各出一行 | 按 XDG 优先级去重，每个应用最多 1 行 |
| 与内置结果 | 名称命中也会再返回一条 → 重复行 | 名称/关键字命中**让给内置**，不重复 |
| 中文查询 | 直接匹配（与内置重复） | 自动转拼音（跨繁简：`任务` → `任務中心`） |
| 匹配 | 名称子串 / 全拼 / 首字母 | + 紧凑子序列 / 描述 / 可执行名 + **使用频率加权** |
| `Name[zh_CN]` 解析 | 键名正则漏掉含下划线的键（由 Python 绕过） | 已修正 |
| 启动方式 | `runAsync(exec)` | `setsid -f sh -c …` 分离启动；`Terminal=true` 自动套终端 |
| 加载开销 | 加载即解析预生成表 | 分片异步构建 + 惰性读表（不超 CPU 预算） |

## 开发 / 测试

```bash
# 用你真实的 XDG 目录跑匹配逻辑
lua5.4 tests/run.lua

# 追加查询词
lua5.4 tests/run.lua wx ddqd rwzx

# 模拟"刚装好的中文应用"（回归测试）
XDG_DATA_HOME="$PWD/tests/fixtures/pxdg" lua5.4 tests/run.lua csyy ceshiyingyong
# → 测试应用（拼音 ceshiyingyong / 首字母 csyy）

# 校验二进制拼音表的解码（与 python 参考实现逐字节对比）
lua5.4 tests/bin-probe.lua
```

## 归属与许可

- **拼音数据** `pinyin-data.bin` 源自 [dms-pinyin-search](https://github.com/AvengeMedia/dms-pinyin-search)
  的汉字→拼音映射表（MIT），此处以紧凑二进制格式重新打包
- 本插件代码：MIT，见 [LICENSE](LICENSE)

---

## English summary

**Pinyin Plus** is a launcher provider plugin for [Noctalia v5](https://github.com/noctalia-dev/noctalia)
that lets you search Chinese applications by pinyin — full pinyin, initials, or compact subsequences
(`wx` / `weixin` → 微信, `rwzx` / `renwuzhongxin` → 任务中心). It indexes `.desktop` files at runtime
(no Python, no pre-generated data, new apps are picked up within 60 s), de-duplicates by XDG priority,
and deliberately defers to the built-in Applications provider whenever the query already matches an
app's name/keywords — so it never produces duplicate rows. Results are weighted by real usage counts,
merged from Noctalia's own `usage_counts.json`. MIT licensed; pinyin table derived from dms-pinyin-search.
