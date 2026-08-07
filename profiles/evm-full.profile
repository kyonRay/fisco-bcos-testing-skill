# All real feature_evm_* flags from bcos-framework/bcos-framework/ledger/Features.h turned on.
# There are exactly three as of this writing (cancun, timestamp, address) — do not add more
# without confirming they exist in Features.h's Flag enum first.
[meta]
source_chain = archetype-evm-full
captured_at = 2026-08-06
binary_version = <archetype, no specific production binary>
[genesis]
compatibility_version = 3.16.4
[system_config_replay]
feature_evm_cancun = 1
feature_evm_timestamp = 1
feature_evm_address = 1
[config_ini_override]
# Gate runs drive the chain through the console, which is configured SSL-off; leaving RPC SSL on
# means the console cannot connect at all (handshake dies as "end of stream"). RPC SSL is not an
# axis any of these archetypes exists to test, so turn it off.
rpc.enable_ssl = false
