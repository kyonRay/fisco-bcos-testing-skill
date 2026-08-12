# FBT CLI 内核骨架 设计文档(子项目 1)

**日期**:2026-08-10(经两轮外部评审修订)
**状态**:**已进入实现**。子项目 1A(CLI 内核核心)已按本文落地(见 `internal/`);1B(命令面与进程模型)进行中。
**权威性**:**本文件是唯一权威副本**——它随代码一起版本控制,克隆本仓即可看到。任何外部工作区里的同名文件都是镜像,以本文为准。
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
- **零 AI、零云**:`--ai on`/未实现旗标用即返回 `20`(显式失败,不静默 no-op)。**"无网络调用"是运行期约束**——`fbt` 跑起来后不发任何网络请求(除了对本地链 RPC 的探测);**构建期不在此约束内**,`go build` 需要拉取一次 `gopkg.in/yaml.v3`。要求完全离线构建的环境须 `go mod vendor` 后提交 `vendor/`。
- **`--ai` 只接受 `on`/`off`**:其余值(含拼写错误)返回 `20`,不得因"不等于 on"而当作 `off` 静默放行。
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

**路径规则**:`state = ${XDG_STATE_HOME:-$HOME/.local/state}/fbt`;`config = ${XDG_CONFIG_HOME:-$HOME/.config}/fbt/config.yaml`。CI 中 XDG 与 `HOME` 都不可用时,要求**同时**显式给出 `--state-dir` **和** `--config`(缺任一即 `20`)——两者各自的默认位置都依赖这两个环境变量,只补其一仍有一个无处可寻。

**`--config` 的存在性语义**(两种缺失必须区别对待):
- **显式** `--config <path>` 指向不存在的文件 → `30`。用户点名的配置消失了却被当作空配置,等于他的全部设置被静默丢弃。
- 默认位置(`./fbt.yaml`、XDG、HOME)没有配置文件 → 正常空配置,不报错。

**`fbt.yaml` 内相对路径**的基准是该 YAML 文件所在目录(见 §7.3),因此宿主必须在解析后立即把它们绝对化;判定 `./fbt.yaml` 是否存在所用的**启动 CWD 也是解析器的显式输入**,不得直接读进程 CWD——否则测试无法隔离,且仓库里一旦出现同名文件就会改变行为。`--engine-dir` 指**整个安装根**(含 `libexec/` 与 `share/`),同时覆盖 profiles/cases 的查找基。`engine.json` **三个版本号分列**(engine 协议 / 事件 schema / 对外 output schema,不共用一个名),宿主碰链前校验协议兼容 → 不符 `40`。shipped(`share/fbt/cases`)与 state(`$XDG_STATE_HOME/fbt/cases`)两个 registry 枚举时:并集、按 basename 排序;**同名 basename → 冲突返回 `20`**(不静默覆盖)。

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
| `fbt config show [--command <cmd>] [-p <profile>] [--all-keys]` / `fbt config path` | 新增 | 打印最终配置+每项来源;敏感项脱敏(§7.4)。`--command` 按该命令的依赖面过滤;`--all-keys` 列出注册表全部可用键(含未设值的)——未知键的报错会提示用户"用 `config show` 查看完整键表",若只枚举已设值的键,这句提示就是空头支票。**"最终配置"指五层合并后的结果**,必须含内置默认值层与 flag 层,而不只是配置文件里写了什么。 |
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

**`.profile` 的重复键语义**(权威实现是 `scripts/profile_lib.sh:75,79`):

```bash
[[ -v PROFILE_REPLAY["$key"] ]] || PROFILE_REPLAY_ORDER+=("$key")
PROFILE_REPLAY["$key"]="$value"
```

即**首次出现决定顺序位置,末次赋值决定最终值,同一个 key 只回放一次**。`[system_config_replay]` 与 `[config_ini_override]` 两段都适用。任何重新实现(如 Go 宿主的解析器)必须一致——若改成逐条追加,同一个 key 会被回放两次,而 `auth_check_status` 这类一次性开关的第二次调用会直接返回 `Permission denied`。

`[genesis] compatibility_version` **必填**:它驱动 `build_chain -v` 与整条升级路径,缺失时应在解析阶段即报 `20`,而不是把空值一路带到起链命令。

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
| `repo.root` | `FBT_REPO_ROOT`(子0 引入) | run-env | 全部(引擎子进程 CWD) |
| `tools.fisco_bin` | (新增) | run-env | doctor/cluster/upgrade |
| `tools.java_bin` | `JAVA_BIN` | run-env | ut/fuzz(**注**:`scenario_jsd.sh:145` 今天裸调 `java`、不读 `JAVA_BIN`;子项目 0 修复 5 令 jsd 一并读 `JAVA_BIN`) |
| `tools.fuzz_jar` | `FUZZ_JAR` > `TAMPER_FUZZ_JAR`(别名,前者优先) | run-env | malformed/fuzz |
| `tools.tamper_helper` | `TAMPER_HELPER` | run-env | malformed |
| `tools.tamper_block_limit` | `TAMPER_BLOCK_LIMIT` | run-env | malformed(**读取点在 `tools/tamper-fuzz/tamper-helper.sh:20`,不在 `scripts/` 下**——穷尽核对的扫描面必须含 `tools/`) |
| `cluster.contract_name` | `BCOS_CONTRACT_NAME`(默认 `HelloWorld`) | run-env | dual_rpc |
| `fuzz.profile_path` | `RG_FUZZ_PROFILE` | run-env | fuzz |
| `fuzz.profile_name` | `RG_FUZZ_PROFILE_NAME`(子0 引入,写 `.case` 时必需) | run-env | fuzz |
| `engine.scripts_dir` | `FBT_ENGINE_SCRIPTS`(子0 引入) | run-env | 全部(引擎脚本解析) |
| `engine.profile_dir` | `FBT_PROFILE_DIR`(子0 引入) | run-env | case/fuzz |
| `engine.state_cases` | `FBT_STATE_CASES`(子0 引入) | run-env | fuzz(蒸馏 `.case` 的可写目录) |
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

**传递方式**:所有 run-env 键均由翻译层 **export 为 env** 注入子进程(与今天 bash 读 env 的方式一致);唯升级测试的 old_bin/new_bin/target_ver/profile 与 §5 拓扑参数走 **argv**(经子项目 0 的共享 argv builder)。

**穷尽性已核对(2026-08-11)**,扫描 `${VAR:-}` 形式的读取点,覆盖**三个目录**:`fisco-bcos-release-gate/scripts`、`fisco-bcos-release-gate/tools`、sibling `fisco-bcos-testing/scripts`,共 18 个 `.sh`、55 个变量。核对必须**断言扫描结果非空**(文件数与变量数的下限),否则路径写错时会空跑通过。

**确认为脚本内部量、不对外暴露**(在脚本内被赋值,或为脚本自身 flag 的默认值):

| 变量 | 位置 | 为什么不暴露 |
|---|---|---|
| `RPC_URL` / `POLL_INTERVAL` / `SAMPLES` | `oracle_liveness.sh:32-34` | 该脚本自己的 flag 默认值,宿主通过 `-r`/`-b` 传参而非 env |
| `BIN` | `run_ut.sh:43` | 脚本内先算出再校验 |
| `COMPAT_VERSION` | `cluster_up.sh` getopts | argv 驱动(`-v`),不走 env |
| `JSD_RUNS` / `MAL_CASES` / `CLUSTER_OUTDIR` / `CLUSTER_OUTDIR_ABS` / `FAILURES_FILE` / `FAILURES_OUTDIR` / `FILE_ID` / `SHEET_ID` / `FISCO_BIN_FOR_T0` | 各自脚本内 | 无条件赋值 |
| `APPLY_PROFILE` | `gate.sh:167` | 无条件赋值,env 覆盖不了(**不属于下节的剥离名单**) |
| `HOME` / `XDG_STATE_HOME` | — | 宿主自己拥有的环境,不是穿透项 |

### 7.5 剥离名单(必须从继承环境中主动删除)

引擎里有一类变量,值决定的不是"用什么参数",而是**执行哪个脚本**或**要不要真干活**。它们存在的目的是让 bash 单测注入 spy。宿主若把自己的环境原样传给子进程,这些变量会被继承:

| 变量 | 读取点 | 被继承的后果 |
|---|---|---|
| `STATEROOT_ORACLE` | `oracle_lib.sh:153` `bash "${STATEROOT_ORACLE:-…}"` | stateRoot oracle 被替换;换成恒打印 OK 的脚本,跨节点分叉永不报告 |
| `CLUSTER_UP` | `apply_profile.sh:174` 守卫、`:190` 执行 | 起链脚本被替换 |
| `_SELF_DIR` | `apply_profile.sh:43` | 移动 `_resolve_engine_script` 的搜索起点,间接换掉引擎脚本 |
| `SCENARIO_UT_SELF_DIR` | `scenario_ut.sh:26` | 同上,`run_ut.sh` 的解析位置 |
| `SCENARIO_DRY` | `scenario_dual_rpc.sh:375` `[[ "${SCENARIO_DRY:-0}" == 1 ]]` | **场景打印计划后直接返回 0,一行活不干,整轮门禁全绿** |

要求:这五个变量**不绑定任何配置键**、**不接受 env 输入**、**在启动子进程前从继承环境中删除**。`SCENARIO_DRY` 尤其要紧——开发机上跑过一次 dry-run、变量留在 shell 里,之后每次 `fbt gate run` 都会静默变成空跑却仍返回 `0`,这正是本工具存在所要防的事故形态。剥离是正确性措施,不是可选加固。

### 7.6 env 是输入方向,需要反向映射

§7.1 把 env 列为配置层之一,但 env 里的名字是 **legacy 名**(`RG_FUZZ_BATCH`),不是 canonical 键(`fuzz.batch`)。本节的表描述的是 canonical → env(注入子进程)的**正向**;作为配置层读取环境需要**反向**映射 env → canonical。两个方向共用同一张表,但反向映射必须:

- 忽略表未绑定的任何环境变量(不能把 `PATH` 变成配置);
- 忽略 §7.5 的全部剥离名;
- 同一键有主名与别名同时存在时(`FUZZ_JAR` 与 `TAMPER_FUZZ_JAR`),**主名优先**。

### 7.7 host-only 键也进同一张表

宿主自己消费、不注入引擎的键(`run.fail_fast`、`run.allow_parallel`、`run.timeout_sec`,以及 `cluster.node_count`、`cluster.p2p_base_port`、`crypto.sm_mode` 这类只影响 argv 组装的键)**同样登记在这张表里,只是 env 列为空**。理由:配置文件的键合法性、类型、枚举、范围校验只能有一个来源;把 host-only 键放进另一个没有类型信息的集合,会让 `fuzz.batch: abc` 被挡下而 `run.timeout_sec: abc` 溜过去。

### 7.8 `[config_ini_override]` 只有显式列出的条目成为配置键

`.profile` 的 `[config_ini_override]` 绝大多数条目(`executor.enable_dag`、`txpool.limit`、`rpc.enable_ssl` …)是**节点 `config.ini` 的补丁**,由 `apply_profile.sh` 直接从 profile 文件读取并写入节点配置,**不是 fbt 的配置键**。只有同时决定宿主行为的条目才映射成 canonical 键,当前仅一条:

| profile 条目 | canonical 键 | 为什么 |
|---|---|---|
| `web3_rpc.listen_port` | `cluster.web3_base_port` | 宿主的 oracle URL 发现与 `cluster_up -w` 透传都需要它 |

映射表**显式列举,不做前缀通配猜测**;未列出的条目原样留给引擎。

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

**信封归属**:原始 fd 3 事件**只带 `schema_version`、`ev`,以及若干扁平的 payload 字段**;`run_id`/`seq`/`ts`/`source` 由 **Go 宿主归一化时统一添加**——全局 `seq` 不由多个 bash 进程各自维护。

**事件是扁平的,不是嵌套的**(事件字典里每一条都形如 `{"ev":"scenario_started","name":"malformed"}`)。宿主把除 `ev`/`schema_version` 之外的顶层字段收进自己的 payload 结构。**顶层若出现名为 `payload` 的键,视为协议不符 → `40`**:那意味着引擎换了封装方式,静默产生双层嵌套会让所有下游取不到字段。

**`schema_version` 必填**。宿主在读流前已从 `engine.json` 拿到 `event_schema_version`(§5),归一化时须逐条校验:缺失、非字符串、或 major 与 manifest 不符 → `40`。("fd 3 未打开时 `emit_event` 是 no-op"只说明**事件不会产生**,并不意味着已产生的事件可以缺字段;manifest 校验也只证明引擎声称的版本,不证明每条事件真的符合。)

**交付顺序**:多个引擎进程并发写 fd 3 时,宿主分配 `seq` 与向消费者交付事件**必须在同一临界区内**,否则 `seq` 顺序可能与实际交付顺序相反,黄金事件流夹具将不可复现。

**数值精度**:payload 解析必须保留数值原始文本(Go 侧用 `json.Decoder.UseNumber()`),不得一律转成浮点——区块高度、wei 数额等大整数经 `float64` 会丢精度。

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

**超时特判只压制"信号致死"这一类,不压制真实宿主错误。** 聚合器需要区分两个入口:"子进程被信号杀死"在超时已判定后被忽略(那是宿主自己发的 kill),而事件解析失败、协议不符等真实宿主错误**在任何情况下都不被压制**。若笼统地在超时后忽略一切 `40`,一个真实缺陷会被一条无关的慢链掩盖。

**退出码归一**:聚合器对任何不在这六个码之内的输入一律归为 `40`,不得原样透出——否则一次编码疏漏就能让进程以任意状态码退出,而所有按这六个码分支的 CI 规则都会误读。

**并发契约**:聚合器会被多个引擎子进程的读取协程并发调用,其状态变更必须加锁。特别是"超时判定"与"信号致死"两者若发生竞态,可能把宿主主动发起的 kill 误判成 `40`。

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

**所有失败路径都必须走结构化输出,无一例外。** 下列路径极易被漏掉,实现时逐条对照:全局旗标解析失败、未知命令、未知子命令、子命令自身的局部旗标解析失败、`profile show` 缺少参数、`--ai` 取值非法、`--config` 指向不存在的文件。任何一条只往 stderr 打印散文而不产出 envelope,消费方就必须回退到解析人读文本——这正是 `--output json` 要消灭的东西。

**静态命令与 `jsonl` 的关系必须明确。** `--output jsonl` 的语义是"宿主归一化后的事件流",而 `config`/`profile`/`plan` 这类不产生事件的静态命令没有流可发。二选一并写死:要么输出**单条 JSONL**(把该命令的 json 文档压成一行),要么直接返回 `20` 表示该命令不支持 jsonl。**不允许的做法是静默退化成 human 表格**——那会让 `--output jsonl` 的调用方拿到无法解析的内容却得到退出码 `0`。本设计取**单条 JSONL**。

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
