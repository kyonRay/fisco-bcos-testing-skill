#!/usr/bin/env bash
# The console prints a deploy result as:
#     transaction hash: 0x<64 hex>
#     contract address: 0x<40 hex>
#     currentAccount:   0x<40 hex>
# An unanchored `grep -oE '0x[0-9a-fA-F]{40}' | head -n1` therefore returns the first 40 hex chars
# of the TRANSACTION HASH, not the contract address. A live gate round hit this: the scenario went
# on to call set() against an address that had never existed. Both the extraction behaviour and a
# static guard against reintroducing the unanchored form are checked here.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

SAMPLE='transaction hash: 0xc6b6389b355db61bdaf28d2b8785f1774aa9a86cd70afd0a6d642d1300a121ce
contract address: 0x6849f21d1e455e9f0712b1e99fa4fcd23758e8f1
currentAccount: 0x272e28168a7df9dfc39d8399e3d559b3eb675916'

anchored="$(printf '%s' "$SAMPLE" | sed -E -n 's/.*contract address:[[:space:]]*(0x[0-9a-fA-F]{40}).*/\1/p' | head -n1)"
assert_eq "0x6849f21d1e455e9f0712b1e99fa4fcd23758e8f1" "$anchored" "anchored parse returns the contract address"

# Negative control: prove the old form really did return the truncated tx hash, so this test is
# guarding against a real failure and not a hypothetical one.
unanchored="$(printf '%s' "$SAMPLE" | grep -oE '0x[0-9a-fA-F]{40}' | head -n1)"
assert_eq "0xc6b6389b355db61bdaf28d2b8785f1774aa9a86c" "$unanchored" "unanchored parse returns the truncated tx hash (the bug)"

for f in scripts/scenarios/scenario_dual_rpc.sh scripts/scenarios/scenario_malformed.sh; do
    body="$(cat "$f")"
    assert_not_contains "$body" "grep -oE '0x[0-9a-fA-F]{40}'" "$f does not use the unanchored address grep"
    assert_contains "$body" "contract address:" "$f anchors address extraction on the console label"
done

# --- constant-call return value -------------------------------------------------------------
# Verbatim console 3.8.0 output for `call HelloWorld <addr> get`, captured from a live chain. Note
# the block closes with a rule AND a trailing blank line: `tail -n1` reads the blank line.
GET_OUT='---------------------------------------------------------------------------------------------
Return code: 0
description: transaction executed successfully
Return message: Success
---------------------------------------------------------------------------------------------
Return value size:1
Return types: (STRING)
Return values:(42)
---------------------------------------------------------------------------------------------
'
GET_OUT+=$'\n'   # the console emits a blank line after the closing rule — that is what tail -n1 read
got="$(printf '%s' "$GET_OUT" | sed -E -n 's/^Return values:\((.*)\)[[:space:]]*$/\1/p' | head -n1 | tr -d '[:space:]')"
assert_eq "42" "$got" "get() return value parsed from the 'Return values:(...)' label"
assert_eq "" "$(printf '%s' "$GET_OUT" | tail -n1 | tr -d '[:space:]')" "tail -n1 yields the blank trailing line (the bug)"

# --- transaction hash + receipt block number ------------------------------------------------
# Verbatim `call ... set 42` output: it carries the hash and status but NO block number line, so
# the height must come from getTransactionReceipt.
SET_OUT='transaction hash: 0x0feb243236bd81517fdc9dd64c2deb16ed28acde02541eb6ef2c99f9a6a89100
---------------------------------------------------------------------------------------------
transaction status: 0
description: transaction executed successfully
---------------------------------------------------------------------------------------------
Receipt message: Success
Return message: Success
Return value size:0
Return types: ()
Return values:()
---------------------------------------------------------------------------------------------
'
tx_hash="$(printf '%s' "$SET_OUT" | sed -E -n 's/^transaction hash:[[:space:]]*(0x[0-9a-fA-F]{64}).*/\1/p' | head -n1)"
assert_eq "0x0feb243236bd81517fdc9dd64c2deb16ed28acde02541eb6ef2c99f9a6a89100" "$tx_hash" "transaction hash parsed from call output"
assert_eq "" "$(printf '%s' "$SET_OUT" | sed -E -n 's/.*block number[^0-9]*([0-9]+).*/\1/p' | head -n1)" \
    "console call output contains no 'block number' line (the old height parse always matched nothing)"

RECEIPT_OUT='    "status":0,
    "blockNumber":18,
    "from":"0xb711ffc5eb3b73fd842d3ebdcd949e8350e00788",'
height="$(printf '%s' "$RECEIPT_OUT" | sed -E -n 's/.*"blockNumber"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
assert_eq "18" "$height" "blockNumber parsed from getTransactionReceipt"

dual="$(cat scripts/scenarios/scenario_dual_rpc.sh)"
assert_contains "$dual" "getTransactionReceipt" "height comes from the receipt, not the call output"
assert_not_contains "$dual" 'block number[^0-9]' "no leftover 'block number' grep"

# --- listSystemConfigs row parsing (scenario_upgrade's T6 flag snapshot) -------------------
# getSystemConfigByKey answers {"code":3008,"msg":"Entry: <k> does not exists!"} for a flag that was
# never set — which is precisely the pre-bump state T6 has to read — so the value comes from
# listSystemConfigs' table instead. Rows are verbatim from a live chain.
CONFIGS_OUT='| bugfix_auth_check                                   | null           | 0            |
| bugfix_call_noaddr_return                           | 1              | 0            |
| compatibility_version                               | 3.16.0         | 0            |'
row_val() {
    printf '%s' "$CONFIGS_OUT" | awk -F'|' -v k="$1" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            if ($2 == k) { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }
        }'
}
assert_eq "null" "$(row_val bugfix_auth_check)" "unset flag reads as null from listSystemConfigs"
assert_eq "1" "$(row_val bugfix_call_noaddr_return)" "set flag reads its value"
assert_eq "3.16.0" "$(row_val compatibility_version)" "compatibility_version readable the same way"
assert_eq "" "$(printf '%s' "$CONFIGS_OUT" | tail -n1 | tr -d '[:space:]' | sed 's/^|.*|$//')" \
    "tail -n1 does not yield a usable value (the bug: every flag read back as '}')"

upg="$(cat scripts/scenarios/scenario_upgrade.sh)"
assert_contains "$upg" "listSystemConfigs" "T6 reads flags via listSystemConfigs"
assert_contains "$upg" '"code"' "T5 checks the console success envelope rather than exit status alone"

# --- T5 governance fallback ------------------------------------------------------------------
# With auth_check_status=1 the direct set is refused and the bump must be a committee proposal.
# The proposal command never prints a {"code":0} envelope — success is "Proposal Status : finished"
# — and it may print a "Switch to group ... failed" line AFTER the change already took effect.
PROPOSAL_OK='Set system config proposal created, ID is: 2
Proposal Status : finished
Agree Voters:
0xb16a69f5341a03dc6069f68403b93af715d9cb49
Switch to group group0 failed! null, please check the existence of the group group0'
ok=0; grep -q "Proposal Status *: *finished" <<<"$PROPOSAL_OK" && ok=1
assert_eq "1" "$ok" "finished proposal recognised as success despite the trailing switch-group error"
assert_eq "" "$(grep -oE '"code"[[:space:]]*:[[:space:]]*0' <<<"$PROPOSAL_OK")" \
    "proposal output carries no code:0 envelope (so the direct-path check cannot be reused)"

DENIED='{
    "code":-50000,
    "msg":"Permission denied"
}
Maybe you should use setSysConfigProposal command to change system config.'
ok=0; grep -q "Permission denied" <<<"$DENIED" && ok=1
assert_eq "1" "$ok" "governance refusal detected, triggering the proposal fallback"

upg2="$(cat scripts/scenarios/scenario_upgrade.sh)"
assert_contains "$upg2" "setSysConfigProposal" "T5 has a committee-proposal fallback"
assert_contains "$upg2" "Proposal Status" "T5 checks proposal completion, not an exit code"

assert_done
