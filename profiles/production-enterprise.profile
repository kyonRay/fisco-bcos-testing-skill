[meta]
source_chain = wbbc-occnode
captured_at = 2026-08-06
binary_version = <生产当前二进制版本,待补充>
[genesis]
compatibility_version = 3.16.4
[system_config_replay]
# Order in this section is replayed verbatim and the chain enforces a dependency chain on the
# balance flags — Features.cpp:37-46 rejects feature_balance_precompiled unless feature_balance is
# already on, and feature_balance_policy1 unless feature_balance_precompiled is. Keep these three
# in this sequence; a capture that lists them alphabetically fails on the first call.
feature_balance = 1
feature_balance_precompiled = 1
feature_balance_policy1 = 1
feature_evm_address = 1
feature_evm_cancun = 1
feature_evm_timestamp = 1
executor_version = 1
consensus_leader_period = 1
tx_count_limit = 500
tx_gas_limit = 3000000
tx_gas_price = 0x5208
web3_chain_id = 60600
balance_transfer = 1
# auth_check_status LAST, always: switching committee governance on makes every further direct
# setSystemConfigByKey return {"code":-50000,"msg":"Permission denied"} ("Maybe you should use
# 'setSysConfigProposal'"). Any key listed after this one cannot be replayed at all.
auth_check_status = 1
[config_ini_override]
executor.enable_dag = true
consensus.min_seal_time = 500
txpool.limit = 15000
web3_rpc.enable = true
web3_rpc.listen_port = 8545
# rpc.enable_ssl, not rpc.disable_ssl: NodeConfig.cpp:595-598 lets enable_ssl override disable_ssl
# whenever it is present, and build_chain always emits enable_ssl — so disable_ssl never takes
# effect on a generated config. false here means the captured chain's SSL-off RPC.
rpc.enable_ssl = false
