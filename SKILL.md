---
name: fisco-bcos-release-gate
description: >-
  Run a release gate against FISCO-BCOS (AIR mode) that reproduces a production chain's exact
  config profile locally, replays it through four gate scenario families, and judges the result
  under three failure oracles (crash / consensus-halt / state-mismatch), recording any defect
  found. Use this skill WHENEVER the user wants to run a release gate, continuously loop-test a
  build, regression-test before shipping, reproduce a production config profile locally, replay a
  captured profile, test an upgrade path before rollout, validate a release candidate, or run one
  round of the gate — even if they don't say the word "skill" or "gate". Triggers on: "发布门禁",
  "release gate", "持续循环测试", "回归测试", "生产配置复现", "profile 回放", "升级路径测试",
  "发布前验证", "跑一轮门禁".
---

# FISCO-BCOS Release Gate

## Step 0: 框定

Placeholder: this step frames the gate run's scope and inputs before anything else executes.

## 加载 profile

Placeholder: this step loads a production config profile that the gate will reproduce locally.

## apply_profile 回放

Placeholder: this step replays the loaded profile onto a local cluster to match production config.

## gate 四场景族

Placeholder: this step runs the gate's four scenario families against the reproduced cluster.

## 三 oracle

Placeholder: this step judges each scenario run against the three failure oracles (crash / consensus-halt / state-mismatch).

## 探索层

Placeholder: this step allows exploratory runs beyond the fixed scenario families to surface unknown defects.

## 飞轮沉淀

Placeholder: this step feeds newly found defects and scenarios back into the gate's scenario/profile library.

## 报告

Placeholder: this step emits a report of what ran, what passed, and what defects were recorded.
