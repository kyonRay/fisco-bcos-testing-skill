[meta]
source_chain = archetype-rpbft-scale
captured_at = 2026-08-06
binary_version = <archetype, no specific production binary>
node_count = 7
[genesis]
compatibility_version = 3.16.4
consensus_type = rpbft
epoch_sealer_num = 4
epoch_block_num = 1000
[system_config_replay]
feature_rpbft = 1
tx_count_limit = 1000
[config_ini_override]
sync.send_txs_by_tree = true
sync.sync_block_by_tree = true
sync.tree_width = 3
