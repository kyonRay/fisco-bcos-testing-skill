[meta]
source_chain = archetype-sm-gov
captured_at = 2026-08-06
binary_version = <archetype, no specific production binary>
[genesis]
compatibility_version = 3.16.4
sm_crypto = true
[system_config_replay]
[config_ini_override]
p2p.sm_ssl = true
rpc.sm_ssl = true
cert.sm_ca_cert = sm_ca.crt
cert.sm_node_key = sm_ssl.key
cert.sm_node_cert = sm_ssl.crt
cert.sm_ennode_key = sm_enssl.key
cert.sm_ennode_cert = sm_enssl.crt
