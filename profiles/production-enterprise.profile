[meta]
source_chain = wbbc-occnode
captured_at = 2026-08-06
binary_version = <生产当前二进制版本,待补充>
[genesis]
compatibility_version = 3.16.4
[system_config_replay]
feature_balance = 1
feature_balance_policy1 = 1
feature_balance_precompiled = 1
feature_evm_address = 1
feature_evm_cancun = 1
feature_evm_timestamp = 1
executor_version = 1
consensus_leader_period = 1
tx_count_limit = 500
tx_gas_limit = 3000000
tx_gas_price = 0x5208
web3_chain_id = 60600
auth_check_status = 1
balance_transfer = 1
[config_ini_override]
executor.enable_dag = true
consensus.min_seal_time = 500
txpool.limit = 15000
web3_rpc.enable = true
web3_rpc.listen_port = 8545
rpc.disable_ssl = true
