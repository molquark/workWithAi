# AI Coding Conventions Kit

给「多模块 Java + 自建/本地模型 + CLI Agent」环境用的一套最小约束工具。

不引入任何服务，不需要部署，不需要 API token。三个 PowerShell 脚本、两个模板文件，
全部在本地跑。目的只有一个：**让 AI 少犯那些它一定会犯的错，让你少花时间在收尾上。**

---

## 它解决什么

| 你遇到的 | 对应工具 |
|---|---|
| AI 不知道 `Result` / `Tuple` / `UserHolder` 是干嘛的，自己造一套 | `templates/AGENTS.md` |
| 光写文档没人看，AI 照样违规 | `templates/archunit/` —— 把约定变成构建失败 |
| 工具类散在多个包，AI 找不到就新建一个 | `scan-conventions.ps1` —— **自动生成**清单 |
| 白天没空做 code review，堆着过夜 | `night-review.ps1` —— 夜间只读评审队列 |
| 多需求并行，worktree 越开越多，最后不知道哪个是哪个 | `wt.ps1` —— 加上限和回收 |

核心判断：**文档会被忽略，报错不会。** 凡是能变成测试或脚本的约定，都不该只写在文档里。

---

## 环境要求

- Windows（PowerShell **5.1 或 7.x**，两个都测过）
- Git
- 只有 `night-review.ps1` 额外需要 `traecli` 在 PATH 里（`-DryRun` 模式不需要）

```powershell
# 执行策略拦截时统一这么调
powershell -ExecutionPolicy Bypass -File <脚本路径> <参数>
```

---

## 目录结构

```
.
├── README.md
├── scripts/
│   ├── scan-conventions.ps1      # 生成项目地图 + 工具类清单
│   ├── night-review.ps1          # 夜间只读评审队列
│   ├── wt.ps1                    # worktree 管理
│   └── prompts/
│       └── review-mr.md          # 评审提示词模板（改这个，不要改 ps1）
└── templates/
    ├── AGENTS.md.template        # 复制并重命名为 AGENTS.md
    └── archunit/
        ├── ConventionRules.java  # 复制到测试模块
        └── pom-snippet.xml       # 依赖片段
```

---

## 快速上手

### 第 1 步：把现状照出来（10 分钟，先做这个）

```powershell
cd <你的 Maven 仓库根目录>
powershell -ExecutionPolicy Bypass -File <本仓库>\scripts\scan-conventions.ps1 -Repo .
```

产出两个文件，**先自己读一遍**：

- `docs/PROJECT_MAP.md` —— 模块清单、分层分布、关键类型的全限定名
- `docs/UTILITIES.md` —— 每个工具类的全限定名和**带参数类型**的方法签名

重点看 UTILITIES.md 顶部的「⚠️ 重名工具类」。如果有好几组同名 `DateUtil` / `StringUtil`
散在不同包里，那基本就是 AI「重复造轮子」的直接原因：它搜到三个，不知道用哪个，于是建了第四个。

### 第 2 步：装软约束（当天见效）

1. `templates/AGENTS.md.template` → 复制到目标仓库根目录、改名 `AGENTS.md`，替换里面三处 `TODO`。
2. 上一步生成的两个 `docs/*.md` 一起提交。
3. **先不要上 ArchUnit。** 观察两三天。

### 第 3 步：上硬约束（一周后）

1. `templates/archunit/pom-snippet.xml` 的依赖加进测试模块。
2. `templates/archunit/ConventionRules.java` 放进 `src/test/java/<你的包>/architecture/`。
3. 改掉 `@AnalyzeClasses(packages = "...")` 和文件开头的 `package`。
4. `mvn -q test -Dtest=ConventionRules`

第一次会挂出一片存量违规，**这是正常的**。第 3 条规则已经用 `FreezingArchRule` 冻结存量，
只拦新增；前两条如果存量太多，同样用 `FreezingArchRule.freeze(...)` 包一层。

---

## 脚本详解

### 1. scan-conventions.ps1

扫描 Maven 多模块仓库，生成给 AI 和人共用的索引。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\scan-conventions.ps1 `
    -Repo D:\work\myproject `
    -OutDir docs
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Repo` | `.` | 仓库根目录（含根 `pom.xml` 的那层） |
| `-OutDir` | `docs` | 输出目录，相对仓库根 |
| `-KeyTypes` | `Result,Tuple,UserHolder` | 需要在地图里定位的关键类型简单名 |

**做什么**

- 找所有 `pom.xml`（跳过 `target/`）→ 模块清单
- 找所有 `src/main/java/**/*.java` → 包名、类名、所在模块
- 按包名归类到 controller / service / mapper / util / … → 分层分布
- 在源码里定位 `-KeyTypes` 指定的类型 → 全限定名
- 提取所有 `*Util` / `*Utils` / `*Helper` / `*Tool` 类 → 签名 + JavaDoc 首行
- 检测简单名重复的类

**为什么是"生成"而不是"维护"**

工具类散在多个模块时，人工维护的清单必然过期。而过期的清单比没有清单更糟——
AI 会照着错的清单找，找不到就放弃，然后自己新建一个。所以每次重跑，不靠记忆。

**注意**

- 只扫 `src/main/java`，不扫测试代码。
- 用正则解析，不是 AST。生成索引够用，但别拿它的结果当重构依据。
- 不解析模块间依赖关系（谁依赖谁），只按目录归类。
- 找不到 `-KeyTypes` 里的类型时会明确标出来。**那种情况要手工补一行 import**——
  它可能就在依赖 jar 里。这一行对 AI 的价值高于整份文档。

---

### 2. night-review.ps1

夜间批量做 MR 评审，早上看结论。**只读，改不了任何东西。**

```powershell
# 先干跑，确认它会挑哪些 MR（不需要 traecli）
powershell -ExecutionPolicy Bypass -File scripts\night-review.ps1 `
    -Repo D:\work\myproject -Base uat -DryRun

# 确认后正式跑
powershell -ExecutionPolicy Bypass -File scripts\night-review.ps1 `
    -Repo D:\work\myproject -Base uat -MaxItems 2
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Repo` | **必填** | 本地仓库路径（要有 `origin` 远程） |
| `-Base` | `main` | diff 的基线分支。提交 PR 时的目标分支就填这里 |
| `-OutRoot` | `%USERPROFILE%\ai-reviews` | 输出根目录 |
| `-MaxItems` | `3` | 一晚最多处理几个 |
| `-Model` | 空 | 传给 `traecli -m`，不填用默认模型 |
| `-DryRun` | — | 只列出会处理哪些，不执行 |

**流程**

```
git ls-remote 探测 MR 引用
      ↓  和上次的 sha 比对（state.json）
git fetch 到 refs/ai/mr-<iid>
      ↓
traecli exec --sandbox read-only --ask-for-approval never -C <repo> -o <文件> -
      ↓  提示词从 stdin 读，来自 prompts/review-mr.md
写 mr-<iid>.md，更新 state.json
      ↓
生成 index.md（每条只摘「结论」一行）
```

**关键设计：不需要 API token**

探测 MR 走的是 `git ls-remote`，纯 git 协议，和 `git fetch` 同一层权限：

```powershell
git ls-remote origin 'refs/merge-requests/*/head'   # GitLab
git ls-remote origin 'refs/pull/*/head'             # Gitee / GitHub
```

脚本两个都试，命中哪个用哪个。**上线前先确认你们平台用的是哪个命名空间**：

```powershell
git -C <repo> ls-remote origin | findstr /i "refs/"
```

如果两个都对不上，把实际的 glob 加进脚本里的 `$patterns`。

**刻意不做的事**

- 不自动提交、不自动建 MR、不自动合并。这些既需要凭证，也不该由 AI 以你的身份做。
  目标不是「AI 提 PR」，而是「AI 把 PR 准备好，你点一下」。
- 不并行跑。并发受限时一次跑太多只会互相排队，不如串行做完几个。

**输出**

```
%USERPROFILE%\ai-reviews\
├── state.json                     # ref -> sha，用来跳过已评过的
└── 2026-11-03\
    ├── index.md                   # 先读这个
    ├── mr-7.md
    └── mr-8.md
```

**失败语义**

- `traecli` 返回非 0，或没生成输出文件 → 不写入 `state.json`，下次自动重试。
- 已经评过且 sha 没变 → 直接跳过，不重复花 token。
- **没有硬超时。** 万一某次卡住，只会占掉一晚，第二天在日志里能看到。
  需要硬超时的话用 `Start-Process -PassThru` + `WaitForExit(毫秒)` 包一层。

**调优提示词**

改 `prompts/review-mr.md`，不要改 `.ps1`。里面有 `{{IID}}` 和 `{{BASE}}` 两个占位符。
建议跑两周后按你们的实际误报情况再调——第一版提示词不可能刚好合适。

模板里的「我不确定的地方」一节**不要删**。宁可让它承认没把握，也不要编一个看起来很像的理由，
那比漏报更浪费时间。

---

### 3. wt.ps1

给 git worktree 加上限和回收机制。

```powershell
.\wt.ps1 new PROJ-1024     # 基于 origin/main 建工作树 + 建分支
.\wt.ps1 ls                # 存活数、未提交改动、几天没动
.\wt.ps1 rm PROJ-1024      # 删树；分支已合入才删
.\wt.ps1 clean             # 列出可回收的（不会自动删未合入的）
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Cmd` | **必填** | `new` / `ls` / `rm` / `clean` |
| `-Ticket` | — | 需求号或短名，用作目录名和分支名 |
| `-Repo` | `.` | 任意一个工作树里的路径都行 |
| `-Prefix` | `feat` | 分支前缀，`fix/` `chore/` 自己传 |
| `-Base` | `origin/main` | 从哪个分支拉 |
| `-Root` | 仓库同级的 `wt/` | 工作树放哪 |
| `-StaleDays` | `7` | `clean` 判定"多久没动" |
| `-MaxAlive` | `3` | 超过就告警 |

**目录布局**

```
D:\work\
├── myproject\              # 主工作树
└── wt\
    ├── myproject-PROJ-1024\
    └── myproject-PROJ-1025\
```

放在**仓库同级**而不是仓库内部——否则 IDE 会把副本当成模块扫描进去。

**行为说明**

- `new` 在存活数 ≥ `-MaxAlive` 时**只告警，不阻止**。拦不拦是你的事，但你要看见这个数字。
- `rm` 有未提交改动时会要求确认；分支用 `git branch -d`（已合并才删），
  没合并会保留并提示你怎么手动删。
- `clean` **只列不删**。它会把「已合入 / 未合入」标出来，由你逐个决定。

**为什么上限是 3**

你能同时有效推进的需求就是 2~3 个，多出来的只会分走注意力。真需要第 4 个，先关掉一个。
这个数字可以调，但**别调到你觉得舒服**——你觉得舒服的时候就是没起作用的开始。

---

## 模板落地

### templates/AGENTS.md.template

复制到目标仓库根目录。`traecli`（以及 Claude Code、Cursor、Codex 等）会自动读取仓库根的
`AGENTS.md`。

写这类文件的三个要点，比内容本身重要：

1. **写禁令，不写偏好。**
   「请使用我们的 Result」会被违反；「禁止 import `ResponseEntity`」不会。
   模型在压力下会放弃偏好，但会遵守禁令。

2. **一页以内。** 超过一页就不会被完整读进去，人和 AI 都一样。

3. **给可验证的完工标准。** 「PR 描述必须写四件事」比「写好 PR 描述」有效。

### templates/archunit/

四个规则，包名一律用 `..` 通配符写，所以**不需要先知道你的基础包**：

| 规则 | 拦住什么 |
|---|---|
| `controllers_must_not_use_response_entity` | Controller 用了 `ResponseEntity` |
| `only_user_holder_touches_security_context` | 绕过 `UserHolder` 直接读 `SecurityContextHolder` |
| `utils_live_in_util_packages` | 新建的工具类乱放（存量已冻结） |
| `controllers_do_not_touch_components` | Controller 越过 Service 直接注入 Mapper |

为什么用 `..util..` 就能覆盖散落的工具类：`..` 表示**任意层级的包**，
所以 `com.x.biz.order.util` 和 `com.x.service.common.util` 都会被命中。

存量违规用 `FreezingArchRule.freeze(rule)`：第一次跑会把当前违规记到
`src/test/resources/archunit_store/`，之后只对**新增**违规失败。你不用先还债也能止损。

---

## 参数速查

```powershell
# 生成索引
scan-conventions.ps1 -Repo . [-OutDir docs] [-KeyTypes Result,Tuple,UserHolder]

# 夜间评审
night-review.ps1 -Repo <path> [-Base main] [-MaxItems 3] [-OutRoot <dir>] [-Model <name>] [-DryRun]

# 工作树
wt.ps1 <new|ls|rm|clean> [ticket] [-Repo .] [-Prefix feat] [-Base origin/main] [-Root <dir>] [-StaleDays 7] [-MaxAlive 3]
```

---

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 脚本报语法错误，中文变成乱码 | `.ps1` 文件必须是 **UTF-8 with BOM**。Windows PowerShell 5.1 无 BOM 时按 ANSI 解，中文会导致解析失败 |
| `scan-conventions` 生成的注释全是乱码 | 当前版本已显式按 UTF-8 读源码。若仍出现，检查源文件本身是不是 GBK |
| `night-review` 说「没探测到 MR 引用」 | 平台命名空间不同。跑 `git ls-remote origin \| findstr refs/` 看实际前缀，加进 `$patterns` |
| `night-review` 报找不到 traecli | `traecli --version` 先确认能跑。`-DryRun` 不需要它 |
| `night-review` 每次都重评同一个 MR | `state.json` 没写进去，通常是上次跑失败了。看 `OutRoot` 目录是否可写 |
| ArchUnit 显示 0 个测试 | surefire 版本太老，JUnit5 的 `@ArchTest` 不执行。升到 2.22.2+ |
| ArchUnit 第一次就挂一片 | 正常。用 `FreezingArchRule.freeze(...)` 冻结存量 |
| `wt new` 失败说目录已存在 | 上次 `rm` 中断了。手工确认后删目录，再 `git worktree prune` |

---

## 设计取舍

写下来是因为过几个月会想问"为什么这么设计"。

- **不引入服务。** 类似的 Agent 编排平台需要常驻服务 + 数据库，没有服务器时起不来。
  用定时任务 + 脚本能拿到 80% 的价值，成本是 1%。
- **不需要 API token。** 探测走 git 协议，提交留给人。这不是妥协，是权限边界。
- **只读优先。** 评审环节完全只读，所以可以放心无人值守。写入环节一律留给人。
- **串行而非并行。** 并发受限时，一个 session 串行做 N 件事，比开 N 个 session 快得多——
  固定成本（认路、读约定）只付一次。
- **生成而非维护。** 索引、状态、清单都从源头重新算，不靠人记。
- **中文注释，英文标识符。** 说明写中文，变量和参数写英文（跨工具兼容）。

---

## 贡献者注意

**`.ps1` 文件必须保存为 UTF-8 with BOM。** 用 VS Code 时右下角选 `UTF-8 with BOM`，
用 PowerShell 写入时：

```powershell
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))
```

`.java` 和 `.md` 保持 UTF-8 **无** BOM（Java 工具链对 BOM 不友好）。

---

## 日常节奏建议

这套东西只有在固定的节奏里才起作用。建议：

- **每天开始**：看昨天的 `index.md`，只处理「必须改」和「我不确定的地方」。
- **每天下班前**：`traecli review --uncommitted`，五分钟，带着意见结束当天。
- **每周一次**：重跑 `scan-conventions.ps1`，看重名工具类有没有变多。
- **每周一次**：`wt.ps1 clean`，把死掉的工作树收掉。

最后一条比看起来重要：**未闭合的环会一直占着注意力**，哪怕你没在看它。

---

## License

未指定。自己用不加也无所谓；要给别人用，建议补一个。
