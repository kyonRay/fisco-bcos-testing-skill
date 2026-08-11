# 子项目 0:引擎信任与可重定位修复 设计文档

**日期**:2026-08-10(依第二轮外部评审扩充)
**状态**:待评审
**定位**:`fbt` CLI 的**前置**子项目。六处 bash 引擎缺口会让"全量确定性清扫"给出假绿,或让引擎无法脱离原 skill 目录布局安装。在 Go 宿主(子项目 1)包裹前必须先修。纯 bash 引擎改动,与 Go 宿主解耦,各带 bash 测试。

## 为什么先做

子项目 1 的验收信号是 `fbt gate run` 给出**可信**退出码,且引擎能从 `libexec` 安装布局运行。但今天引擎在六处"绿得不对"或"搬不动":分叉发现不了、升级起点是错的、没跑的场景算通过、脚本硬编码 sibling skill 路径、fuzz 往只读安装目录写 case。Go 宿主无法修这些——判决与路径都在 bash 里。故六处修复单列为子项目 0。

## 全局约束

- 只改错误/判决可信性与路径可重定位,不改任何 oracle 的判定算法(`oracle_*_decide` 不动)。
- 每处修复配 `tests/*_test.sh` 断言(纯函数 / dry-run / fake-spy),复用 `tests/assert.sh`。
- 现有 20 个测试文件保持全绿。
- bash 4+;脚本约定(`set -euo pipefail`、`getopts`、`-h`)不变。

---

## 修复 1:多节点 stateRoot——提取共享 helper,覆盖全部调用点,真运行解析 config.ini

**失败场景**:四节点链中某节点在同一高度 stateRoot 分叉。**当前行为**:不 trip、门禁 PASS。**根因**:比对只传了一个 RPC,`oracle_stateroot.sh` 拿到 <2 个 URL 时短路返回 OK("nothing to compare")。

**三个调用点都有此病**(而非只 gate.sh):
- `scripts/gate.sh:252` —— `oracle_stateroot.sh ... -r "$RPC_URL"` 单 URL;
- `scripts/run_case.sh:229` —— 自注 GAP:"only one -r URL is passed ... can never observe a real cross-node divergence";
- `scripts/scenarios/scenario_upgrade.sh:306` —— 滚动升级采样同样单 URL。

**修复**:提取共享 helper `_discover_stateroot_urls`(放入被三处 source 的库,如 `oracle_lib.sh`),供 gate.sh / run_case.sh / scenario_upgrade.sh 复用;fuzz 保留其现有"主 URL + extra URLs"行为,但复用同一解析/校验逻辑。helper 语义(**统一**,消除旧稿"完整显式列表"与 fuzz 现"额外 URL"的矛盾):

1. **真运行**:遍历集群 `NODE_DIR` 下每个节点目录,解析各自 `config.ini` 的 Web3 RPC 监听地址/端口,得到每节点真实 URL(不靠 `base+i` 盲推);
2. `RG_FUZZ_STATEROOT_URLS`(配置 `oracle.stateroot_urls`)语义统一为**在发现结果上追加的额外 URL**(向后兼容 fuzz),不是替换;
3. **解析结果 <2 个 URL → 基础设施错误**(非零、明确报"无法发现≥2 个节点 RPC"),**不再退化成"只有一个节点,nothing to compare"的假绿**;
4. **dry-run**:此刻集群目录尚不存在,无法枚举——dry plan 打印**计划语义**("运行时从各节点 config.ini 发现 Web3 RPC 并传 ≥2 个 `-r`"),而非具体 URL。旧稿"production dry-run 打印多个真实 `-r`"不可实现,删去。
5. **地址归一**:从 `config.ini` 读到 `0.0.0.0`/`::` 时转成可连接的 loopback(`127.0.0.1`/`[::1]`),IPv6 URL 用方括号;并确认该节点 `[web3_rpc] enable=true` 才纳入(未启用的节点不作比对源)。

**验证**:
- `bash tests/stateroot_discovery_test.sh` —— 用 fake 节点目录(每个含一个 `config.ini`)断言 `_discover_stateroot_urls` 解析出 N 个 URL、追加 extra、去重排序;<2 个时返回基础设施错误码。
- 三处调用点各一条 dry-run 断言:打印"运行时发现"计划行,不再是单 `-r`。
- 现有 `bash tests/oracle_test.sh` 全绿(判定算法未动)。

---

## 修复 2:genesis `compatibility_version` 透传——必填字段 + 共享 argv + spy 测试

**失败场景**:`upgrade-legacy` 冻结在旧 genesis 版本,升级应从该版本起。**当前行为**:链从 `build_chain` 默认版本起,profile 的 genesis 版本被忽略(`apply_profile.sh:101` 自注此 GAP)。

**修正评审发现的两个测试陷阱**:
- `default-latest.profile` 实际含 `compatibility_version = 3.17.0`(并非旧稿说的"未冻结"),且 `apply_profile.sh` 当前已要求该字段存在——故不能拿它做"无版本"反例;
- 当前 dry-run **已经**打印 `-v`,即使真实路径没把它传给 `cluster_up.sh`。故旧稿"dry-run 断言含 `-v`"在修复前就通过 = 无效测试。

**修复**:
1. 把 `compatibility_version` 明确定义为 profile **必填**字段,缺失 → 配置错误;
2. 提取真实与 dry-run **共用**的 `_cluster_up_build_chain_argv`(单一真相),真实路径确实把 `-v <ver>` 传给 `build_chain`;
3. 用 **fake `build_chain.sh` / spy** 断言最终收到 `-v <ver>`(如 `-v 3.0.0`)——测真实路径,而非只测 dry-run 字符串。

**验证**:
- `bash tests/build_chain_argv_test.sh` —— spy 断言 `_cluster_up_build_chain_argv` 对含版本 profile 产出 `... -v 3.0.0 ...`;缺字段 profile 返回配置错误。
- `bash tests/apply_profile_test.sh` 扩断言:真实与 dry-run 共用同一 argv 构造。

---

## 修复 3:gate 场景集与 upgrade 用法——不再"选了 upgrade 却什么都不跑还成功"

**修正评审发现的根因误判**:现有 `dual_rpc/jsd/malformed/ut` 在依赖缺失时是 `return 1`(直接失败),**并不内部 SKIP**。真正的 skip 只有三种:场景未注册、gate 裸分发对 `upgrade` 的 needs-args 跳过、upgrade 内部可选 rollback。故"依赖缺失→内部 skip 假绿"不是当前根因;依赖缺失应由子项目 1 的 command-aware `doctor` 在碰链前返回 `30`,不转成门禁失败。

**真正的问题**:显式 `gate.sh --scenarios upgrade` 仍会**什么都不跑并返回成功**(裸分发跳过它)。

**修复**:
1. gate 默认集合**直接定义为四个可运行族** `ut/dual_rpc/malformed/jsd`;
2. `upgrade` **不进入** gate 的 scenario 名单(它有独立入口 `fbt gate upgrade`);
3. 显式选择 `upgrade`(`--scenarios upgrade`)→ 返回**用法错误**(配置错误码),提示改用 `fbt gate upgrade`;
4. **未注册的必跑场景**(显式选中或在全量集内)→ 直接计为失败,不允许退出 0;
5. needs-args 类跳过(`GATE_SCENARIOS_NEEDS_ARGS`)——`upgrade` 移出 gate 集后该集合已无成员,**直接删除**这一不可达语义,不留空壳。

**验证**:
- `bash tests/gate_test.sh` 扩断言:(a)`--scenarios upgrade` → 用法错误退出;(b)全量集默认只含四族;(c)显式选未注册场景 → 聚合非 0;(d)needs-args 跳过不失败。

---

## 修复 4:升级测试真实旧版起点——old_bin 建 T0、profile 参数化、原子换二进制

**失败场景**:`fbt gate upgrade -p <profile> --old-bin <旧版>` 应从旧版本二进制建起 T0 基线再滚动升级。**当前行为**(锚点):
- `scenario_upgrade.sh:345` 的 T0 = `apply_profile.sh -p profiles/production-enterprise.profile`,用**默认 build 目录里的节点二进制**建链,`old_bin` 只在 T2-T4 换入与 T8 回滚用——**旧版起点根本没建立**;
- `scenario_upgrade_run` 签名 `<outdir> <old_bin> <new_bin> <target_ver>` **无 profile 参数**,且场景头注"production-enterprise profile only"——`fbt gate upgrade -p <profile>` 的 `-p` 无法兑现;
- `scenario_upgrade.sh:318` 用 `cp "$bin" "$root/fisco-bcos"` 覆盖**正在运行**的共享二进制,有 `ETXTBSY` 风险。

**修复**:
1. `apply_profile.sh` / `cluster_up.sh` 接受**显式节点二进制路径**参数(缺省保持默认 build 目录二进制);
2. `scenario_upgrade_run` 接受 **profile 参数**,T0 用该 profile;
3. **T0 用 `old_bin` 建链**,真正建立旧版本起点;
4. 滚动换二进制改为**复制到临时文件 + 原子 `rename`**(替 `cp`),避免覆盖执行中文件的 `ETXTBSY`;临时文件须创建在**与目标同一目录**,以保证同文件系统 `rename` 的原子性。

**验证**:
- `bash tests/upgrade_argv_test.sh` —— 断言 T0 建链 argv 含 `old_bin` 与传入 profile;换二进制走 temp+rename(可用 spy 观察 `mv`/`rename` 调用序)。
- `SCENARIO_DRY=1` 的 T0-T8 计划打印显示 T0 用 old_bin + 指定 profile。

---

## 修复 5:引擎可重定位——去 sibling 硬编码、可写 case 目录、fuzz 写 status、engine.json

**失败场景**:从 `libexec/fbt/scripts/` 只读安装布局运行引擎。**当前行为**(锚点):
- `apply_profile.sh:99` 硬编码 `$SCRIPT_DIR/../../fisco-bcos-testing/scripts/cluster_up.sh`——依赖 sibling skill 目录结构,安装布局下不存在;
- UT 场景同样依赖原 skill 相对路径;
- `fuzz_bcos.sh:745` 把新 case 写到 `$SCRIPT_DIR/../scenarios/`——安装目录旁,通常**只读**;
- `_fuzz_write_case` **不写 `status`**——新发现的 case 在子项目 1 的策略下会变成 `example`,飞轮断裂(见子项目 1 §6.4)。

**修复**:
1. **去 sibling 硬编码**(执行期修订):`apply_profile.sh`/`scenario_ut.sh` 对 `cluster_up.sh`/`run_ut.sh` 的引用改为经 `_resolve_engine_script`(查找序 `$FBT_ENGINE_SCRIPTS` → 脚本自身目录 → sibling `../../fisco-bcos-testing/scripts`),不再硬编码 `../../`。**子项目 0 不物理搬迁/复制这两个脚本**(那会 fork sibling 的改动、造成漂移);物理把脚本装进 `libexec/fbt/scripts/` 是**子项目 1 的打包步骤**。装好后 `FBT_ENGINE_SCRIPTS` 指向 libexec 即可无 sibling 运行。
2. **可写 case 目录**:fuzz 生成的 case 写入**可写 state 目录**(子项目 1 定为 `$XDG_STATE_HOME/fbt/cases`),而非只读安装目录;随包只读 case 与用户/生成 case 分离。
3. **fuzz 写 `status=pending` + 逻辑 profile 名**:`_fuzz_write_case` 落 `status = pending`(新发现默认待确认,不污染门禁,见子项目 1 §6.4);且 `profile =` 写**逻辑名**(如 `production-enterprise`),而非当前的路径 `profiles/production-enterprise.profile`——后者搬进可写 state 目录后会解析失败。现有两个 case 的 `profile =` 也一并改为逻辑名(见子项目 1 §7.3 的 `.case` profile 解析规则)。
4. **`engine.json` 清单**:引擎根放一个 `engine.json`,含**三个独立版本号** `engine_protocol_version` / `event_schema_version` / `output_schema_version`(不共用一个 `schema_version`,与子项目 1 §5/§8 对齐)+ 能力列表,供宿主碰链前校验协议兼容(而非等第一条事件才发现不兼容)。

**验证**:
- `bash tests/relocatable_test.sh` —— 在临时目录模拟 `libexec` 布局(无 sibling),断言 apply_profile / UT 场景能解析到收编后的脚本;fuzz 的 case 目标路径落在配置的可写 state 目录。
- `_fuzz_write_case` 单测:产出的 `.case` 含 `status = pending`。
- `engine.json` 存在且含 `schema_version`,与子项目 1 §8 事件信封版本一致。

---

## 修复 6:运行拓扑参数化透传——让端口/节点数/国密真正落到引擎

**失败场景**:子项目 1 依赖 node count、P2P/BCOS/Web3 端口、SM 模式来实现"端口不相交的并行运行"(§10)与配置优先级。**当前行为**(锚点):`cluster_up.sh:7-12` 虽支持 `-n/-e/-o/-p/-s`,但 `apply_profile.sh` **不传** `-n/-p/-s`;`cluster_up.sh:92` `WEB3_BASE=8545` **硬编码**(靠 perl 把 node`<i>` 改成 8545+i);且 profile 的 `web3_rpc.listen_port` 会在 apply 阶段被写回 `config.ini`,故即便 YAML 的 run-env 优先级更高,实际监听端口也未必跟着变。结论:`--allow-parallel` 与配置优先级目前只是宿主侧声明,落不到真实节点。

**修复**:把拓扑参数并入修复 2 的共享 argv builder,`apply_profile.sh` **完整透传**给 `cluster_up.sh`(真实路径与 dry-run 共用同一 builder):
```
cluster_up argv: node_count · fisco_bin · output_dir · p2p_base_port
                 · bcos_base_port · web3_base_port · sm_mode · compatibility_version
```
其中 `web3_base_port` 成为 `cluster_up.sh` 的显式参数(替硬编码 8545),apply 阶段写回 `config.ini` 时用它而非常量。**`cluster.web3_rpc_url` 与 `web3_base_port` 的关系**:以 **base port 为权威**,URL 从它派生;两者都配置且不一致 → 配置错误(子项目 1 `20`)。

**验证**:
- `bash tests/cluster_up_argv_test.sh` —— spy 断言 `apply_profile.sh` 把 node_count/三个 base port/sm_mode/version 全部传入 `cluster_up.sh`;非默认 `web3_base_port` 真正写进各节点 `config.ini`(node`<i>` = base+i)。
- 缺省(未配置拓扑)时 argv 与今天等价,行为不变。

## 交付与顺序

六处修复相对独立,可各自成 commit(纯 bash + 对应测试)。修复 1/2/4/6 引入共享 helper 与参数透传,建议先做;修复 5 的收编与去硬编码影响面最大,建议末位并全量回归。全部合入后,子项目 1 的 Go 宿主才有一条"可信 + 可重定位 + 拓扑可控"的引擎地基。子项目 0 不引入 Go、不引入新外部依赖。
