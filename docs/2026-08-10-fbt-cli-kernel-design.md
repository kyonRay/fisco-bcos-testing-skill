# FBT CLI 内核骨架 设计文档(子项目 1)

**日期**:2026-08-10(经两轮外部评审修订)
**状态**:待评审(brainstorming 产出,尚未进 writing-plans)
**范围**:`fisco-bcos-testing` CLI 工具的第 1 个子项目——CLI 内核骨架。整体是把三个 skill(`fisco-bcos-release-gate`/`fisco-bcos-testing`/`fisco-bcos-vuln-hunt`)合并为名为 `fisco-bcos-testing`、二进制名 `fbt` 的命令行工具。
**前置依赖**:**子项目 0(引擎信任与可重定位修复)**必须先合入——见 `2026-08-10-fbt-subproject0-engine-trust-fixes-design.md`。本文多处(升级、多节点 stateRoot、可写 case 目录、engine.json)依赖它。

---

## 1. 背景与验收信号

想脚本化跑一轮发布门禁、给退出码、无需 Claude Code 也无需云——今天做不到:引擎只能 skill 触发,行为由约四十个散落环境变量控制。

**验收信号**:在一台**已装引擎运行环境**的 linux/amd64 机器上,`fbt gate run -p production-enterprise` 跑通全量确定性清扫并给出符合 §9 契约的退出码,全程无 Claude Code、无云。

"引擎运行环境"必须诚实列出——`fbt` 二进制**不能**塞进单文件,由 `fbt doctor`(§5)按命令预检、缺失即 `30`:完整 FISCO checkout + `build_chain.sh` + 节点二进制;Java console、(jsd 场景)java-sdk-demo distribution;`bash 4+`/`curl`/`perl`/`pgrep`/`java`;(dual_rpc 场景)Node.js + Viem;`TAMPER_HELPER`(jar 提供)、`WEB3_PRIVATE_KEY`、已构建 UT 二进制。"单静态二进制"只描述宿主 `fbt` 自身。

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│  可选 AI 外壳 (子项目 4/5;本子项目仅解析 --ai,用即返回 20)   │
├─────────────────────────────────────────────────────────────┤
│  确定性内核 (本子项目:Go 宿主 + bash 引擎,零 AI 零云)        │
│   cluster 生命周期 · gate 四族 · 三 oracle · fuzz · UT ·      │
│   升级 · .case 回放 · failures.jsonl + 事件流                 │
├─────────────────────────────────────────────────────────────┤
│  子项目 0 (前置):stateRoot 共享 helper · compat_version ·    │
│    gate 集/upgrade 用法 · 升级 old_bin 起点 · 引擎可重定位     │
└─────────────────────────────────────────────────────────────┘
```

Go 宿主承担:命令面(§6)、配置解析与翻译(§7)、消费引擎事件(§8)、聚合退出码(§9)、进程与清理(§10)。bash 引擎保留全部判决算法。保留 bash(经活链验证、抓到真 Critical DoS,重写会重引入假绿)+ Go 宿主(单二进制、交叉编译、`os/exec`+goroutine 适合 shell out;且是逐函数迁移进 Go 的可回退上坡道)。

## 3. 范围界定

**纳入**:Go 宿主 `fbt`;分发布局 + `fbt doctor`(按命令+选择集算依赖);命令集(§6);分层配置与翻译层;两层事件流与 `--output` 协议;退出码契约;进程/清理/并发模型。
**推迟(§14)**:报告渲染(子 2);testing 方法论收编(子 3);AI 三插件(子 4);vuln-hunt 探索模式(子 5);UI(子 6)。

## 4. 全局约束

- **bash 边界**:不改 oracle/scenario 业务判决算法,但允许新增统一错误分类、`trap`、结构化终止/错误事件(`emit_event`)。
- **引擎可脱离宿主单跑**:`emit_event` 在 fd 3 未打开时 no-op。**不机械把现有 bash stdout 改写成 stderr**——Go 分别捕获子进程 stdout/stderr,machine 模式下宿主只写自己的 stdout 保证纯净,借此保留 standalone bash 行为(修正上一版"人读日志改走 stderr"的过度改动)。
- **分发布局(已决)**:见 §5;引擎脚本随包发布,外部重依赖 config 指向 + doctor 预检。
- **host/engine 协议版本号**:`engine.json`(子项目 0 修复 5)带 `schema_version`,宿主**碰链前**校验;不兼容 → `40`。
- **零 AI、零云**:`--ai on`/未实现旗标用即返回 `20`(显式失败,不静默 no-op);无网络调用。
- **目标平台**:交叉编译 linux/amd64、linux/arm64、darwin/arm64;驱动引擎需 bash 4,缺失由 doctor 报 `30`。
- **Java fuzz jar 外部调用**,不并入 Go 构建。

## 5. 分发布局与依赖预检

**布局**(已决,吸收评审建议):
```
bin/fbt
libexec/fbt/engine.json          # engine_protocol_version + event_schema_version + output_schema_version + 能力列表
libexec/fbt/scripts/             # 引擎脚本;打包时把 sibling 的 cluster_up.sh/run_ut.sh 复制进来(子0 只去硬编码经 _resolve_engine_script,不物理搬迁;此复制是本子项目的打包步骤)
libexec/fbt/tools/tamper-helper.sh
share/fbt/profiles/              # 随包 profile
share/fbt/cases/                 # 随包只读回归 case
$XDG_STATE_HOME/fbt/cases        # fuzz 生成 + 用户维护,可写(子项目 0 修复 5)
$XDG_STATE_HOME/fbt/clusters     # cluster 注册表(§10)
```

**路径规则**:`state = ${XDG_STATE_HOME:-$HOME/.local/state}/fbt`;`config = ${XDG_CONFIG_HOME:-$HOME/.config}/fbt/config.yaml`。CI 中 XDG 与 `HOME` 都不可用时,要求显式 `--state-dir`/`--config`,否则 `20`。`--engine-dir` 指**整个安装根**(含 `libexec/` 与 `share/`),同时覆盖 profiles/cases 的查找基。`engine.json` **三个版本号分列**(engine 协议 / 事件 schema / 对外 output schema,不共用一个名),宿主碰链前校验协议兼容 → 不符 `40`。shipped(`share/fbt/cases`)与 state(`$XDG_STATE_HOME/fbt/cases`)两个 registry 枚举时:并集、按 basename 排序;**同名 basename → 冲突返回 `20`**(不静默覆盖)。

**`fbt doctor`——每个命令一张独立依赖矩阵**(修正上一版"基础依赖对所有碰链命令一刀切"):
- **`gate run`(全量)**:FISCO checkout/节点二进制/console/bash4/curl/pgrep/java + JSD/Node+Viem/UT 二进制/TAMPER helper(对无过滤全量都**必需**)→ 缺失 `30`、启动前终止;`--scenarios malformed` 则不要求 Node/Viem/JSD。
- **`fuzz run`**:可附着已有集群,**不强制** checkout/console;需要 fuzz jar + java + 目标 RPC 可达。
- **`cluster down` / 清理类**:**跳过普通 doctor**,只做目标解析与安全校验(§10)——**绝不**因 java/Viem/console 缺失而拒绝拆链。
- **未选择场景的无关依赖**:不检查。

错误类别:必需项**未配置**(如 `WEB3_PRIVATE_KEY`)→ `20`;已配置但路径**指向不存在** → `30`。doctor 在碰链命令启动前自动跑,依赖问题在碰链前被挡下,不靠"运行中 skip"发现。

## 6. 命令面

**命令集(已决)**:`gate run/plan/upgrade`、`cluster up/down`、`case run/list`、`profile list/show`、`config show/path`、`doctor`,并保留已建的 `fuzz run`。推迟独立 `ut`、AI、报告。理由:`cluster` 是 `gate run` 起链必需路径,绕不开。

### 6.1 头等命令:全量清扫

`fbt gate run -p <profile>`(零过滤)= 一次性跑四个可运行族 `ut/dual_rpc/malformed/jsd` **外加** `.case` 中 `status=active` 的回归夹具(§6.4),统一判决聚合成一个退出码。`upgrade` **不在**此集(独立 `fbt gate upgrade`,子项目 0 修复 3)。

**编排在宿主**:`gate.sh` 只跑场景族、不扫 `.case`。故宿主编排两段并聚合:(1) 调 `gate.sh` 跑四族;(2) 自行枚举 `active` case 调 `run_case.sh`。闭合飞轮缺口。

### 6.2 过滤真值表

**无过滤 = 全量两段;任一过滤旗标出现 = 只跑显式命名的,未提及的段视为空。**

| `--scenarios` | `--cases` | 场景族 | `.case` |
|---|---|---|---|
| 不给 | 不给 | 四族 | 全部 `active` |
| `malformed` | 不给 | 仅 malformed | 空 |
| 不给 | `fuzz_*` | 空 | 匹配的 `active` |
| `malformed` | `fuzz_*` | 仅 malformed | 匹配的 `active` |

匹配 **basename**;结果去重排序;`.case` 符号链接不跟随。**空匹配 → `20`**。**显式选中场景发生 `missing` 类未注册 → 判失败**(子项目 0 修复 3);显式选 `upgrade` → 用法错误 `20`,提示 `fbt gate upgrade`。

### 6.3 其余子命令

| 命令 | 包裹入口 | 说明 |
|---|---|---|
| `fbt gate plan -p <profile> [--scenarios … --cases …]` | `gate.sh --dry-run` + 宿主 `.case` 枚举 | 打印四族 + `active` case 清单,校验名字,不碰链;`.case` 状态在此阶段全部解析校验。 |
| `fbt gate upgrade -p <profile> --old-bin --new-bin --target-ver` | `scenario_upgrade_run`(子项目 0 修复 4 参数化) | 从 old_bin 建 T0 起点滚动升级。 |
| `fbt cluster up -p <profile>` / `fbt cluster down [--run-id\|--workspace]` | `apply_profile.sh` / `stop_all` | 生命周期;`down` 目标定位见 §10。 |
| `fbt fuzz run --transport … [--seed --batch --iters --strategy --restart-cmd]` | `fuzz_bcos.sh` | 探索层;不并入全量;`gate run --with-fuzz` 预留,用即 `20`。 |
| `fbt case run <case>` / `fbt case list [--status active\|pending\|example\|all]` | `run_case.sh` | 单条回放返回**真实结果**(status 只影响 aggregate);list 默认列 active。 |
| `fbt profile list` / `fbt profile show <name>` | `profile_lib.sh` | 解析后四段。 |
| `fbt config show [--command <cmd>] [-p <profile>]` / `fbt config path` | 新增 | 打印最终配置+每项来源;敏感项脱敏(§7.4)。 |
| `fbt doctor [--command <cmd>] [-p <profile>] [--scenarios …]` | 新增(§5) | 按命令+选择集预检。 |

### 6.4 `.case` 状态策略(修正:status 必填,pending 不进门禁)

`.case` 的 `[case]` 段新增 `status`:`active` | `pending` | `example`。**status 必填**——**缺失或非法 → plan 阶段返回 `20`**(修正上一版"缺省视为 example"会让用户已有真实回归 case 升级后静默停跑的假绿)。语义:
- `active`:进全量清扫,判 fail → 门禁失败;
- `pending`:已发现、缺陷未修(如 `fuzz_seed43_idx11.case`),**只由 `fbt case list` 报告,不进 gate 执行**(消除上一版 §6.1"只跑 active"与 §6.4"pending 被清扫报告"的矛盾);
- `example`:格式示例(`example.case`),永不运行。

`fbt case run <case>` 直接回放**返回真实结果**,不看 status(status 只影响聚合门禁)。fuzz 自动生成的 case 落 `status=pending`(子项目 0 修复 5),确认修复后**显式提升为 `active`**。所有 case 的 status 在**启动任何链之前**全部解析校验。落地时给现有两个 case 补 status(`example.case`→example,`fuzz_seed43_idx11.case`→pending)。

### 6.5 全局旗标

`--config`、`--engine-dir`、`--output human|json|jsonl`(§8)、`--ai on|off`(on 即 `20`)、`-v/--verbose`、`--no-color`、`--version`。

## 7. 配置系统

### 7.1 分层与优先级(含 `.profile`)

高覆盖低:**flag > legacy env > `fbt.yaml` > 选定 `.profile` > 内置默认**。
**键域**:genesis/system-config 键(`compatibility_version`、feature flag、回放项)**只来自 `.profile`**;run-env 键(cluster 目录、RPC URL、工具路径、fuzz 参数、funding、JSD)走完整优先级,`.profile` 与 `fbt.yaml` 对同一 run-env 键都有值时 `fbt.yaml` 覆盖 `.profile`。env 逃生阀保留(低于 flag、高于 yaml)。

### 7.2 profile 名字解析与 `fbt.yaml` 查找

`-p <name>`:含 `/` 或以 `.profile` 结尾 → 路径;否则名字,在 `share/fbt/profiles/`(及 `--engine-dir` 覆盖)查找 `<name>.profile`,多处命中 → `20` 冲突。`fbt.yaml` 查找顺序:`--config` > `./fbt.yaml` > `$XDG_CONFIG_HOME/fbt/config.yaml`。

### 7.3 相对路径基准(评审补充)

- **CLI 传入路径**:相对宿主启动 CWD;
- **`fbt.yaml` 内路径**:相对该 YAML 文件所在目录;
- **`.case` 引用的 profile**:见下方 profile spec 规则;
- **引擎子进程 CWD**:FISCO checkout root(`repo.root`);
- **输出/证据路径**:相对 run workspace(§10)。

**`.case` 的 `profile` = 与 `-p` 相同的 profile spec(阻塞项修复)**:不含 `/` → **逻辑名**(如 `production-enterprise`),走统一 profile resolver(§7.2);含 `/` → 路径,相对 **case 文件所在目录**。宿主把它解析成**绝对路径**后再调 `run_case.sh`(或给 standalone bash 传 `FBT_PROFILE_DIR`)。**必要性**:现有 case 写 `profile = profiles/default-latest.profile`,搬进 `share/fbt/cases/` 后会错解成 `share/fbt/cases/profiles/...`(不存在);fuzz 生成的 pending case 放进 XDG state 目录同样失效。故现有两个 case 与 fuzz writer(子项目 0 修复 5)都改用**逻辑名**。

### 7.4 翻译层与全键表

宿主启动子进程前把"配置+旗标"解析成 `map[string]string` export 进 bash(`fuzz.batch=60` → `RG_FUZZ_BATCH=60`)——**唯一知道 env 名字的地方**。`config show` 打印"配置键→注入 env→最终值→来源",**敏感项(`tools.web3_private_key` 等)脱敏**。

配置键 → legacy env → 键域 → 命令(**修正上一版错误映射并补缺项**;实现计划须 grep 全脚本产出**穷尽**表):

| 配置键 | legacy env | 键域 | 命令 |
|---|---|---|---|
| `repo.root` | (新增) | run-env | 全部(引擎子进程 CWD) |
| `tools.fisco_bin` | (新增) | run-env | doctor/cluster/upgrade |
| `tools.java_bin` | `JAVA_BIN` | run-env | ut/fuzz(**注**:`scenario_jsd.sh:145` 今天裸调 `java`、不读 `JAVA_BIN`;子项目 0 修复 5 令 jsd 一并读 `JAVA_BIN`) |
| `tools.fuzz_jar` | `FUZZ_JAR` > `TAMPER_FUZZ_JAR`(别名,前者优先) | run-env | malformed/fuzz |
| `tools.tamper_helper` | `TAMPER_HELPER` | run-env | malformed |
| `tools.web3_private_key` 🔒 | `WEB3_PRIVATE_KEY` | run-env | dual_rpc |
| `tools.console_dir` | `CONSOLE_DIR` | run-env | dual_rpc/gate |
| `tools.build_dir` | `BUILD_DIR` | run-env | doctor/cluster(**≠ repo.root**) |
| `cluster.node_dir` | `NODE_DIR` | run-env | 全部(节点上级目录) |
| `cluster.root` | `RG_CLUSTER_DIR` | run-env | jsd/apply_profile(**集群根,≠ `NODE_DIR`**) |
| `cluster.node_count` | (新增) | run-env | cluster/oracle 发现 |
| `cluster.web3_rpc_url` | **注入 `RG_FUZZ_WEB3_URL` 且 `WEB3_RPC_URL`** | run-env | fuzz **与** dual_rpc(修正:两者是不同 env,须都注入,否则 dual/fuzz 目标不一致) |
| `cluster.bcos_rpc_url` | `BCOS_RPC_URL` | run-env | gate/fuzz/case |
| `cluster.group_id` | `BCOS_GROUP_ID` | run-env | 全部 |
| `cluster.p2p_base_port` | (新增) | run-env | cluster/doctor |
| `cluster.bcos_base_port` | `BCOS_RPC_BASE_PORT` | run-env | cluster/doctor |
| `cluster.web3_base_port` | (新增,子0修6;**base port 权威**,`cluster.web3_rpc_url` 从它派生,冲突→`20`) | run-env | cluster/doctor |
| `crypto.sm_mode` | (新增) | run-env | cluster(国密) |
| `cluster.fund_addresses`/`fund_amount` | `RG_FUND_*` | run-env | apply_profile |
| `oracle.stall_sec`/`once_wait_sec`/`hang_sec` | `RG_STALL_SEC`/`RG_ONCE_WAIT_SEC`/`RG_HANG_SEC` | run-env | gate/fuzz |
| `oracle.stateroot_extra_urls` | `RG_FUZZ_STATEROOT_URLS` | run-env | gate/fuzz(**额外** URL,子项目 0 修复 1) |
| `oracle.receipt_timeout` | `RG_WEB3_RECEIPT_WAIT_SEC` | run-env | dual_rpc |
| `fuzz.transport/seed/batch/iters/strategy/sec/continue/restart_cmd` | `RG_FUZZ_*`(含 `RG_FUZZ_SEC`/`RG_FUZZ_CONTINUE`) | run-env | fuzz |
| `jsd.dir/count/qps/group` | `JSD_*` | run-env | jsd |
| `upgrade.rollback` | `UPGRADE_ROLLBACK` | run-env | upgrade |

**传递方式**:所有 run-env 键均由翻译层 **export 为 env** 注入子进程(与今天 bash 读 env 的方式一致);唯升级测试的 old_bin/new_bin/target_ver/profile 与 §5 拓扑参数走 **argv**(经子项目 0 的共享 argv builder)。此表为**穷尽表**的骨架——实现计划第一步是 `grep -rhoE '\b[A-Z][A-Z0-9_]{3,}\b' scripts/` 核对无遗漏键(已知次要项 `POLL_INTERVAL`/`SAMPLES` 等为脚本内部量,不对外暴露)。

## 8. 两层事件流与输出协议

**三通道**:**fd 3** = engine→host 内部 JSON-Lines(不对外);**`--output json`** = stdout 单个最终 JSON 文档(整轮结果+退出码+证据路径);**`--output jsonl`** = stdout 宿主归一化事件流。人读日志由 Go 分别捕获子进程 stdout/stderr 后转发(不强制引擎改写流向,见 §4)。

**两层事件(修正自相矛盾)**:
- **宿主层**:`run_started` / `run_finished`——宿主拥有,因一轮 `gate run` 由宿主编排 `gate.sh` + 多个 `run_case.sh`;
- **引擎层**:`command_started` / `command_finished`——每个被直接启动的引擎命令(`gate.sh`/`run_case.sh`/`fuzz_bcos.sh`/**`apply_profile.sh`/升级包装入口**,即所有直接启动的 engine command)必须发**且仅发一个** `command_finished`。

**`command_finished` 带权威结果分类**(修正:不让宿主靠前面的 `error` 事件猜):
```
{"ev":"command_finished","cmd":"gate.sh","outcome":"pass|gate_fail|config_error|infra_error|engine_error","engine_exit":1}
```
中间的 `error` 事件只负责**诊断**;最终退出码映射**只认终止事件的 `outcome`**。据此 §9 用"某引擎子进程缺 `command_finished`"判其异常(而非旧稿"缺 `run_finished`")。**`EXIT`/`trap` 必须在参数/profile 解析之前安装**,确保早期配置错误也产出带 `outcome=config_error` 的终止事件,不出现"早退无终止事件"。

**信封归属**:原始 fd 3 事件**只带 `schema_version + ev + payload`**;`run_id`/`seq`/`ts`/`source` 由 **Go 宿主归一化时统一添加**——全局 `seq` 不由多个 bash 进程各自维护。

**JSON 安全**:fd 3 事件的字符串字段(`.case`/profile 文件名、路径可能含引号)经 **`emit_event` 内的真正 JSON 转义 helper**(或百分号编码)输出,宿主再校验;能约束为标识符字符集的字段就约束。自由文本(错误详情、repro、日志片段)**不进事件**,写 `failures.jsonl`(`failures_append` 已有字段)或证据文件,事件只带路径。

**事件字典**:
```
{"ev":"command_started","cmd":"gate.sh"}          # engine
{"ev":"scenario_started","name":"malformed"}
{"ev":"oracle_check","phase":"...","oracle":"crash|liveness|stateroot","verdict":"ok|trip"}
{"ev":"scenario_finished","name":"malformed","result":"pass|fail|skip","skip_reason":"not_applicable|missing"}
{"ev":"case_replayed","file":"...","status":"active","expect":"reject","result":"pass|fail"}
{"ev":"fuzz_batch","idx":1,"tally":{"accepted":27,"rejected":33,"unknown":0}}
{"ev":"trip","oracle":"crash"}   {"ev":"culprit","seed":43,"idx":11,"case_written":"..."}
{"ev":"error","class":"config|infra|engine|host","stage":"cluster_up","code":"RPC_UNAVAILABLE"}
{"ev":"command_finished","cmd":"gate.sh","outcome":"pass|gate_fail|config_error|infra_error|engine_error","engine_exit":1}  # engine, 恰一个
# run_started / run_finished 由宿主发出
```

**`--output json` 顶层 schema(不止错误)**:成功结果、`doctor`、`plan` 各有稳定顶层 JSON schema——成功 = `{"exit":0,"run_id":...,"scenarios":[...],"cases":[...],"oracles":[...]}`;doctor = `{"exit":N,"deps":[{"name":...,"required":bool,"present":bool,"class":"config|infra"}]}`;plan = `{"scenarios":[...],"cases":[...]}`;错误 = §11 的顶层对象。UI/CI 据这些 schema 实现,不靠解析人读文本。

## 9. 退出码契约

| 码 | 含义 | CI |
|---|---|---|
| `0` | 全量清扫干净(`pending` 不参与) | 放行 |
| `10` | 门禁失败:oracle trip 或 `active` 场景/case 判 fail | 拦发布 |
| `20` | 配置错误:profile 不存在/冲突、场景名非法/选 upgrade、空匹配、`.case` status 缺失/非法、`WEB3_PRIVATE_KEY` 未配置、`--ai on` | 修配置 |
| `30` | 设施错误:doctor 依赖缺失、配置路径指向不存在、集群/RPC 起不来、发现 <2 节点 RPC | 修测试机 |
| `40` | 宿主内部错误:事件解析失败、协议版本不符、子进程非预期被信号杀死 | 报 bug |
| `130` | 用户取消(SIGINT/SIGTERM)——**独立语义,非宿主 bug**,不归 `40` | 用户中止 |

映射依据"子进程退出码 + `error.class` + `command_finished`":`error.class=infra` 或集群未起 → `30`;`command_finished.status=fail` 且是门禁判决 → `10`;缺 `command_finished` 且子进程死 → `40`。**超时特判**:宿主因超时主动杀进程组时,**保留先前判定的 `timeout=30`(链无响应),不得因随后"进程被信号杀死"覆盖成 `40`**。多结果按 §10 优先级取最严重。

## 10. 进程、清理与并发模型

- **run_id + workspace**:每轮唯一 `run_id` + 隔离 workspace(cluster 目录、证据、failures.jsonl 在其下)。
- **进程组终止**:独立进程组启动 bash 子树;超时或 SIGINT/SIGTERM 对**整个进程组**先 `TERM`、宽限期后 `KILL`,不留 Java/curl/节点孤儿。
- **端口级并发锁(持久占用,非仅 advisory)**:workspace 唯一目录只隔离文件,**隔离不了固定端口 30300/20200/8545**。故默认**全局单实例锁**;`--allow-parallel` 才放行,且**先验证各实例节点端口区间确实不相交**。锁是**持久 reservation**——`cluster up` 返回后锁**继续存在**代表活动端口占用(不随建链命令退出而释放),直到 `cluster down` 或 stale 回收。
- **cluster 注册表 + `down` 目标 + stale 回收**:活动 cluster 注册到**固定 state 目录** `$XDG_STATE_HOME/fbt/clusters`(非难发现的临时 workspace),记 `run_id`/端口区间/节点 PID。`cluster down` 需 `--run-id`/`--workspace` 指定目标;省略且发现多个活动 cluster → `20`(不猜)。**stale 检测**:注册表项/锁若其记录的节点 PID 已不存在,视为陈旧,`fbt` 启动时自动回收(清锁 + 删注册项),避免崩溃残留永久占用端口。
- **失败后续跑(修正)**:默认续跑**仅适用于门禁失败 `10`**(尽量给全景);遇 `20/30/40` **停止后续 case**(结果已不可信)。`--fail-fast` 则首个 `10` 也即止。
- **退出码优先级**:`40 > 30 > 20 > 10 > 0`(运行期配置错误可能与已有门禁失败并存,`20` 压过 `10`);**`130`(用户取消)压过所有聚合结果**。

## 11. 错误处理

- **超时分类简化**(修正 §9/§11 之间的猜测):命令或阶段到达已配置 deadline → `30`/`TIMEOUT`;**Go 宿主自身**的计时器/状态机/不变量异常 → `40`。**不**根据"最后看到哪条事件"推断宿主 bug;超时判定一旦作出不被随后的进程组信号覆盖。
- 子进程被信号终止且无 `command_finished`(非宿主主动超时所致)→ `40`,原样透出 stderr 尾部。
- 配置解析失败(YAML 语法/未知键/类型)在**任何子进程启动前** `20`,附出错键路径。
- 非 `0` 退出,`--output json` 输出顶层 `{"exit":N,"class":"...","reason":"...","evidence_path":"..."}`。

## 12. 测试策略

- **宿主单测(Go)**,bash 换假脚本(按剧本往 fd 3 吐 `command_*`/中间事件、给定退出码):配置优先级(五层)、翻译层(含 `cluster.web3_rpc_url` 同时注入 `RG_FUZZ_WEB3_URL`+`WEB3_RPC_URL`)、事件解析与信封归一(宿主加 seq/run_id)、退出码映射(§9 各类含 timeout 不被覆盖、`130` 取消)、过滤真值表、`.case` status 必填校验、doctor 分层依赖。
- **现有 20 个 bash 测试保留**;宿主只测接缝。
- **集成测试(不碰链)**:`plan`/`--dry-run` 断言分两半(场景族对 `gate.sh --dry-run`、`.case` 对 active 枚举);`fbt doctor` 在缺依赖沙盒返回 `30`、`WEB3_PRIVATE_KEY` 未配置返回 `20`。
- **真实 E2E(受控 linux/amd64)**:建链→应用 profile→轻量场景→**多节点 stateRoot 比对**→清理→断言退出码。
- **分叉证伪 E2E(评审新增,关键)**:一个 **fake RPC / 注入**测试,构造不同节点 stateRoot 不一致,**证明 gate 与 case 都会失败(`10`)**——证实修复 1 不再假绿(健康链多 URL 可读还不够,必须证伪)。
- **失败模式矩阵**:超时清理无孤儿、信号中断进程组全灭、缺依赖 `30`、事件损坏/协议不符 `40`、并发端口冲突锁拒绝、无匹配 `20`、用户取消 `130`。
- **黄金事件流夹具**:回归比对。

## 13. 已决取舍

1. Go 宿主 + shell out bash 引擎。
2. 分发 = `bin/fbt`+`libexec/fbt/{engine.json,scripts,tools}`+`share/fbt/{profiles,cases}`+`$XDG_STATE_HOME/fbt/{cases,clusters}`;doctor 按命令+选择集算依赖;engine.json 碰链前校验协议。
3. 引擎信任与可重定位修复独立为**子项目 0**,先做(五处)。
4. 头等命令 = 无过滤全量(四族 + `active` case);过滤真值表见 §6.2;`upgrade` 独立子命令、不入 gate 集。
5. 环境变量逃生阀保留;优先级 `flag > env > yaml > .profile > default`,键域界定见 §7.1。
6. `.case` `status` **必填**(active/pending/example);缺失/非法 `20`;pending 只由 `case list` 报告不进 gate;fuzz 自动生成 pending、确认后提升 active。
7. 命令集 = `gate/cluster/case/profile/config/doctor` + 保留 `fuzz`;`--ai on`/`--with-fuzz` 用即 `20`。
8. 两层事件(host `run_*` / engine `command_*`);信封 `run_id/seq/ts/source` 由宿主归一添加;fd 3 事件真正 JSON 转义,自由文本入 failures.jsonl;不强制引擎流向改写。
9. 退出码 `0/10/20/30/40` + 用户取消 `130`;`command_finished` 带权威 `outcome`;超时判定不被信号覆盖;续跑仅限 `10`;优先级 `40>30>20>10>0`、`130` 压过全部。
10. 并发默认全局单实例锁,`--allow-parallel` 须端口区间不相交;cluster 注册表在固定 state 目录,`down` 需显式目标。

## 14. 明确推迟

- **子 0(前置,先做)**:引擎信任与可重定位修复——见独立 spec。
- **子 2** 报告工件;**子 3** 收编 testing 方法论 + 独立 ut;**子 4** AI 三插件 + 确定性兜底;**子 5** 收编 vuln-hunt 探索模式 + fuzz 语料反馈;**子 6** UI(消费 json/jsonl)。
