# Fresh open-source default chain: no production feature-flag drift (system_config_replay is
# empty on purpose), genesis pinned to the current latest compatible version. Re-derive that
# version instead of trusting this literal:
#   grep DEFAULT_VERSION bcos-framework/bcos-framework/protocol/Protocol.h
[meta]
source_chain = archetype-default-latest
captured_at = 2026-08-06
binary_version = <archetype, tracks upstream latest release>
[genesis]
compatibility_version = 3.17.0
[system_config_replay]
[config_ini_override]
# Gate runs drive the chain through the console, which is configured SSL-off; leaving RPC SSL on
# means the console cannot connect at all (handshake dies as "end of stream"). RPC SSL is not an
# axis any of these archetypes exists to test, so turn it off.
rpc.enable_ssl = false
