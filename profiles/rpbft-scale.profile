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
# Gate runs drive the chain through the console, which is configured SSL-off; leaving RPC SSL on
# means the console cannot connect at all (handshake dies as "end of stream"). RPC SSL is not an
# axis any of these archetypes exists to test, so turn it off.
rpc.enable_ssl = false
sync.send_txs_by_tree = true
sync.sync_block_by_tree = true
sync.tree_width = 3
