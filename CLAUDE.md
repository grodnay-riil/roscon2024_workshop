# Zenoh RMW Topic Filtering Workshop

## Context

This repo is a ROSCon 2024 tutorial for Zenoh as ROS 2 RMW. We are using it to learn
and prototype **topic-level filtering over a lossy Iridium Certus 200 satellite link**
(~170 kbps total, ~50 kbps for command/telemetry).

**Problem:** The robot and GCS each have 100s of ROS 2 topics. Only a handful should
cross the sat link. Previously used zenoh-bridge-ros2dds but its discovery traffic
(~100 kbit/s) was too high. Switched to rmw_zenoh which has lower overhead, but now
need to filter which topics actually traverse the link.

**Goal:** Default-deny ACL on the sat-link interface, whitelisting only specific
command/telemetry topics. Denied topics must NOT appear in `ros2 topic list` on the
other island.

## Architecture

### Production (Iridium Certus 200)
```
[Robot ROS2 island]           [Sat Link]           [GCS ROS2 island]
  nodes <-> router(A) -------- iridium -------- router(B) <-> nodes
              ^                                     ^
          ACL here                              ACL here
       (egress deny-all,                    (egress deny-all,
        allow whitelist)                     allow whitelist)
```

Both routers need ACL: router A filters robot→GCS, router B filters GCS→robot.

### Test Setup (Docker Compose, single bridge network)

```
docker-compose.yml: 3 containers on zenoh-net bridge
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ container-a  │    │ container-b  │    │ container-c  │
│ (robot side) │    │ (GCS side)   │    │ (hub/relay)  │
│ router + ACL │    │ router       │    │ router       │
│ + talker     │    │ + listener   │    │              │
└──────────────┘    └──────────────┘    └──────────────┘
       all on zenoh-net bridge, reach each other by hostname
```

**Docker notes:**
- All containers share `./zenoh_confs:/ros_ws/zenoh_confs` volume
- `cap_add: NET_ADMIN` + `ip link set lo multicast on` for loopback multicast
- Use `tcp/0.0.0.0:0` (NOT `tcp/[::]:0`) for listen endpoints — IPv6 causes
  peers to advertise `[::1]` loopback which other containers can't reach
- Peer-to-peer multicast scouting works across the bridge network
- Set `ZENOH_ROUTER_CHECK_ATTEMPTS=-1` when running without a router

**Completed exercises:**
- Ex-1: Basic router + talker/listener ✓
- Ex-2: Router-to-router connection ✓
- Ex-4: Direct node connection, peer mode with `peers_failover_brokering` ✓
- Ex-5: Peer-to-peer multicast scouting (no router) ✓

## Key Technical Details

### ROS 2 Topic → Zenoh Key Expression Mapping

```
<DomainID>/[<Namespace/>]<TopicName>/<TopicType>/<TopicHash>
```

Example: `/chatter` on domain 0 →
`0/chatter/std_msgs::msg::dds_::String_/RIHS01_df668c...`

Wildcard shorthand: `*/chatter/**` or `*/chatter/*/*`

### TRANSIENT_LOCAL Advertisement Key Expression

```
*/chatter/*/*/@adv/pub/*/*/_
```

Must also be allowed/denied for TRANSIENT_LOCAL QoS topics.

### Three Zenoh Key Families (ALL must be handled in ACL)

1. **Regular data keys:** `**` — matches `0/chatter/<type>/<hash>`
2. **Liveliness keys:** `@ros2_lv/**` — hermetic prefix, `**` alone does NOT match
3. **Advanced pub/sub keys:** `**/@adv/**` — used for TRANSIENT_LOCAL QoS

### Liveliness Token Key Expression (for `ros2 topic list` visibility)

```
@ros2_lv/<domain_id>/<session_id>/<node_id>/<entity_id>/<entity_kind>/<enclave>/<namespace>/<node_name>/<mangled_topic>/<type>/<hash>/<qos>
```

The `@ros2_lv` prefix is **hermetic** — `**` does NOT match it. Must be explicitly
referenced as `@ros2_lv/**` to match all, or targeted per-topic.

**Topic name mangling:** `/` in topic names is replaced with `%`.
- `/chatter` → `%chatter`
- `/ns/chatter` → `%ns%chatter`

Entity kinds: `NN` (node), `MP` (publisher), `MS` (subscription), `SS` (service server), `SC` (service client).

Per-topic liveliness pattern for publishers and subscribers:
```
@ros2_lv/0/*/*/*/MP/*/*/*/%chatter/*/*/*    (publishers)
@ros2_lv/0/*/*/*/MS/*/*/*/%chatter/*/*/*    (subscribers)
```

### Graph Query Strategy (from ChatGPT analysis)

The smart approach for whitelisting: allow broad graph query mechanics but restrict
which liveliness TOKENS can cross the link:
- **Allow broadly:** `liveliness_query` + `declare_liveliness_subscriber` on `@ros2_lv/0/**`
  (lets the graph cache ask questions)
- **Allow narrowly:** `liveliness_token` ONLY for whitelisted topics
  (controls which answers come back)

### ACL Message Types

**Data messages:** `put`, `delete`, `declare_subscriber`, `query`, `reply`, `declare_queryable`
**Liveliness messages:** `liveliness_token`, `liveliness_query`, `declare_liveliness_subscriber`

### ACL Priority

`explicit deny` > `explicit allow` > `default_permission`

## Completed Exercises

- **Ex-1:** Basic router + talker/listener
- **Ex-2:** Router-to-router connection across containers
- **Ex-4:** Direct node connection, peer mode with `peers_failover_brokering`
- **Ex-5:** Peer-to-peer multicast scouting (no router)
- **Ex-6:** ACL — default-allow with deny (tutorial as-written), then extended
- **Ex-6+:** ACL — default-deny with whitelist (the main goal) — **WORKING**
- **Ex-6c:** ACL — `/sat/*` namespace pattern: data wildcard works (`*/sat/**`),
  but liveliness tokens must list each topic explicitly (mangling flattens `/` → `%`)
- **Ex-7:** Downsampling on top of ACL — **WORKING** (messages correctly dropped at router)

## Working ACL Config (Default-Deny + Whitelist)

Tested and verified in `ROUTER_CONFIG.json5`. This config:
- Allows all traffic on loopback (local nodes unaffected)
- Denies everything on eth0 (remote interface) by default
- Whitelists only `/chatter_public` data + discovery on eth0

```json5
access_control: {
  enabled: true,
  default_permission: "deny",

  rules: [
    {
      // Loopback: allow everything. Three key families needed because
      // @ros2_lv is hermetic — ** alone does NOT match it.
      id: "allow_lo",
      permission: "allow",
      messages: [
        "put", "delete", "declare_subscriber", "query", "reply", "declare_queryable",
        "liveliness_token", "liveliness_query", "declare_liveliness_subscriber",
      ],
      key_exprs: ["**", "**/@adv/**", "@ros2_lv/**"],
    },
    {
      // Remote: topic data + TRANSIENT_LOCAL for whitelisted topics
      id: "allow_remote_data",
      permission: "allow",
      messages: ["put", "delete", "declare_subscriber", "query", "reply", "declare_queryable"],
      key_exprs: ["*/chatter_public/*/*", "*/chatter_public/*/*/@adv/**"],
    },
    {
      // Remote: broad graph queries (lets graph cache ask questions)
      id: "allow_remote_discovery",
      permission: "allow",
      messages: ["liveliness_query", "declare_liveliness_subscriber"],
      key_exprs: ["@ros2_lv/**"],
    },
    {
      // Remote: graph tokens ONLY for whitelisted topics
      // (controls which topics appear in `ros2 topic list`)
      // Topic names are mangled: /chatter_public → %chatter_public
      id: "allow_remote_tokens",
      permission: "allow",
      messages: ["liveliness_token"],
      key_exprs: ["@ros2_lv/*/*/*/*/*/*/*/*/%chatter_public/**"],
    },
  ],

  subjects: [
    { id: "lo", interfaces: ["lo"] },
    { id: "remote", interfaces: ["eth0"] },
  ],

  policies: [
    { rules: ["allow_lo"], subjects: ["lo"] },
    { rules: ["allow_remote_data", "allow_remote_discovery", "allow_remote_tokens"], subjects: ["remote"] },
  ],
},
```

**Why 4 rules (can't simplify further):**
- `allow_lo`: single rule for all local traffic (all messages, all 3 key families)
- `allow_remote_data`: data messages on narrow topic key_exprs
- `allow_remote_discovery`: `liveliness_query`/`declare_liveliness_subscriber` on broad `@ros2_lv/**`
- `allow_remote_tokens`: `liveliness_token` on narrow `%chatter_public` pattern
  - Can't merge with discovery because broad `@ros2_lv/**` would let ALL tokens through

**Why `messages: []` is NOT a wildcard:**
- Zenoh uses `NEVec` (non-empty vector) for messages/key_exprs — empty arrays cause parse errors
- `flows` CAN be omitted entirely to mean both ingress+egress

**default-allow + deny-all + selective-allow DOES NOT WORK:**
ACL priority is `deny > allow > default`, so a broad deny always beats a narrow allow.

**WARNING:** ROS 2 daemon caches graph state. Always restart ALL processes after ACL changes.

## Key Findings

- **Data key_exprs:** support namespace wildcards (`*/sat/**` matches all /sat/* topics)
- **Liveliness key_exprs:** topic names are mangled (/ → %), flattened into one chunk.
  Cannot wildcard-match by prefix. Each topic must be listed explicitly:
  `@ros2_lv/*/*/*/*/*/*/*/*/%sat%chatter/**`
- **`messages: []`** is NOT a wildcard — causes parse error (Zenoh uses NEVec/non-empty)
- **`flows`** CAN be omitted entirely to mean both ingress+egress
- **Downsampling** works on top of ACL — dropped messages show as sequence gaps on receiver
- **ROS 2 daemon** caches graph state — restart ALL processes after ACL changes

## Bandwidth Test Results

- **Setup:** 200 blocked topics at 1 Hz + 1 allowed (`/chatter_public`) at ~100 Hz
- **Observation:** ~8 kbit/s on eth0, actual /chatter_public data is ~600 bytes/s
- **Cause:** Broad `allow_remote_discovery` rule (`@ros2_lv/**`) lets graph queries
  for all 200 blocked topics cross eth0. Data is blocked but discovery queries leak.
- **TODO:** Test restricting discovery queries to whitelisted topics only

## Next Steps

- **Reduce discovery overhead:** Narrow `allow_remote_discovery` to only whitelisted
  topic patterns instead of broad `@ros2_lv/**`
- **Production config:** Replace `interfaces: ["eth0"]` with actual sat modem interface
  (`ppp0` or similar). Alternatively use `link_protocols: ["udp"]` / `["tcp"]`

## Open Questions / Risks

1. **Liveliness key expression segment count:** The `%chatter` pattern position
   and total segment count in `@ros2_lv/0/*/*/*/MP/*/*/*/%chatter/*/*/*` needs
   empirical verification. Use `RUST_LOG=trace` on the router to see actual
   liveliness key expressions being exchanged.
2. **Node liveliness tokens:** `NN` entity kind tokens (no topic suffix) may still
   propagate, causing `ros2 node list` to show remote nodes. May need to either
   allow or block `@ros2_lv/0/*/*/*/NN/**` separately.
3. **Service/action discovery:** Services use `query`/`reply`/`declare_queryable` +
   `SS`/`SC` liveliness. Actions are 3 topics + 2 services. Each needs explicit
   allow rules if they must cross the link.
4. **ROS 2 daemon graph cache:** The daemon caches discovered graph state. After
   any ACL change, ALL ROS 2 processes (including daemon) must be restarted on
   both sides to get a clean test. Stale cache is the #1 source of confusion.
5. **`link_protocols` vs `interfaces` for subjects:** In Docker with `--net host`,
   `link_protocols: ["udp"]` is simpler than interface names. In production with
   the real Iridium interface, `interfaces: ["ppp0"]` (or whatever the sat modem
   presents) may be more appropriate.
6. **Broad liveliness_query allow:** The graph query split (broad query, narrow
   token) means the remote side CAN ask about all topics — it just won't get
   answers for non-whitelisted ones. Measured at ~8 kbit/s overhead with 200
   blocked topics — NOT negligible for a 50 kbps sat link. Needs narrowing.

## Commands Reference

```bash
# Start router with custom config
ZENOH_ROUTER_CONFIG_URI=/ros_ws/zenoh_confs/ROUTER_CONFIG.json5 ros2 run rmw_zenoh_cpp rmw_zenohd

# Start router with ACL trace logging
RUST_LOG=info,zenoh::net::routing::interceptor=trace \
  ZENOH_ROUTER_CONFIG_URI=/ros_ws/zenoh_confs/ROUTER_CONFIG.json5 ros2 run rmw_zenoh_cpp rmw_zenohd

# Docker container management
docker/create_container.sh
docker/login_container.sh
docker/stop_container.sh

# Test publishers
ros2 topic pub /chatter std_msgs/msg/String "data: Hello just me!"
ros2 topic pub /chatter_public std_msgs/msg/String "data: Hello World!"

# Verify filtering
ros2 topic list
ros2 topic echo /chatter_public
ros2 topic echo /chatter
```
