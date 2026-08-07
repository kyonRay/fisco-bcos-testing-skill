# Old chain frozen at an early compatibility_version, for testing a long-distance upgrade
# (e.g. replaying this profile then upgrading straight to 3.17.x).
[meta]
source_chain = archetype-upgrade-legacy
captured_at = 2026-08-06
binary_version = <archetype, old production binary>
[genesis]
compatibility_version = 3.0.0
[system_config_replay]
[config_ini_override]
# Gate runs drive the chain through the console, which is configured SSL-off; leaving RPC SSL on
# means the console cannot connect at all (handshake dies as "end of stream"). RPC SSL is not an
# axis any of these archetypes exists to test, so turn it off.
rpc.enable_ssl = false
