#!/usr/bin/env bash
set -euo pipefail

ETCD_NODE="${ETCD_NODE:-http://etcd1:2379}"
SERVICE_PREFIX="/services/backend"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
TMP_CFG="/etc/haproxy/haproxy.cfg.tmp"
HAPROXY_PID="/run/haproxy.pid"
ETCD_REVISION="0"
DEBOUNCE_SECONDS=0.5
PENDING_RELOAD=0

log() {
    # Usage: log "INFO" "message"
    local level="$1"
    shift
    printf '[%s] %s\n' "$level" "$*" >&2
}

log INFO "Starting Load Balancer Node: ${HOSTNAME}"

mkdir -p /etc/haproxy /run

# --------------------------------------------------
# Helpers
# --------------------------------------------------
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
prefix_range_end() { printf '%s\xff' "$1" | base64 | tr -d '\n'; }

reload_haproxy() {
    local old_pid=""
    if [[ -f "$HAPROXY_PID" ]]; then old_pid="$(cat "$HAPROXY_PID" || true)"; fi

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        log INFO "Reloading HAProxy (old pid: $old_pid)..."
        haproxy -f "$HAPROXY_CFG" -p "$HAPROXY_PID" -sf "$old_pid"
    else
        log INFO "Starting HAProxy..."
        haproxy -f "$HAPROXY_CFG" -p "$HAPROXY_PID"
    fi
}

# --------------------------------------------------
# Wait for etcd
# --------------------------------------------------
log INFO "Waiting for etcd at ${ETCD_NODE} ..."
until curl -sf "${ETCD_NODE}/health" >/dev/null; do sleep 1; done
log INFO "etcd is ready!"

# --------------------------------------------------
# Render HAProxy config
# Accepts optional KVS JSON array as argument
# --------------------------------------------------
render_config() {
    local kvs="${1:-}"
    log INFO "Rendering HAProxy config..."

    if [[ -z "$kvs" ]]; then
        kvs="$(
            curl -sf -X POST -H "Content-Type: application/json" \
            "${ETCD_NODE}/v3/kv/range" \
            -d @- <<JSON
{
  "key": "$(b64 "${SERVICE_PREFIX}/")",
  "range_end": "$(prefix_range_end "${SERVICE_PREFIX}/")"
}
JSON
        )" | jq -c '.kvs // []'
    fi

    log DEBUG "KVS for rendering: $kvs"

    {
        cat <<'EOF'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http-in
    bind *:80
    default_backend app

backend app
    balance roundrobin
EOF

        echo "$kvs" | jq -r 'sort_by(.key)[] | @base64' | while read -r kv; do
            key="$(echo "$kv" | base64 -d | jq -r '.key'   | base64 -d)"
            val="$(echo "$kv" | base64 -d | jq -r '.value' | base64 -d)"
            name="$(basename "$key")"
            log DEBUG "Adding server $name -> $val"
            echo "    server ${name} ${val} check"
        done

        cat <<'EOF'

listen stats
    bind *:8404
    stats enable
    stats uri /
EOF
    } > "$TMP_CFG"

    haproxy -c -f "$TMP_CFG" >/dev/null
    mv "$TMP_CFG" "$HAPROXY_CFG"
    log INFO "HAProxy config updated"
}

# --------------------------------------------------
# Debounced reconcile
# --------------------------------------------------
reconcile() {
    if [[ "$PENDING_RELOAD" -eq 1 ]]; then return; fi
    PENDING_RELOAD=1
    (
        sleep "$DEBOUNCE_SECONDS"
        log INFO "Reconciling HAProxy..."
        render_config
        reload_haproxy
        PENDING_RELOAD=0
    ) &
}

# --------------------------------------------------
# Initial poll
# --------------------------------------------------
log INFO "Checking for initial backends..."

RESPONSE="$(
  curl -sf -X POST -H "Content-Type: application/json" \
  "${ETCD_NODE}/v3/kv/range" \
  -d @- <<JSON
{
  "key": "$(b64 "${SERVICE_PREFIX}/")",
  "range_end": "$(prefix_range_end "${SERVICE_PREFIX}/")"
}
JSON
)"

log DEBUG "Raw etcd response during initial poll: $RESPONSE"

ETCD_REVISION="$(echo "$RESPONSE" | jq -r '.header.revision')"
INITIAL_KVS="$(echo "$RESPONSE" | jq -c '.kvs // []')"
COUNT="$(echo "$INITIAL_KVS" | jq 'length')"

log INFO "Found $COUNT backend(s) in etcd"

# --------------------------------------------------
# Start watch immediately
# --------------------------------------------------
WATCH_BODY=$(cat <<JSON
{
  "create_request": {
    "key": "$(b64 "${SERVICE_PREFIX}/")",
    "range_end": "$(prefix_range_end "${SERVICE_PREFIX}/")",
    "start_revision": $ETCD_REVISION
  }
}
JSON
)

log DEBUG "etcd watch request body: $WATCH_BODY"

curl -sN -X POST -H "Content-Type: application/json" \
  "${ETCD_NODE}/v3/watch" \
  -d "$WATCH_BODY" \
| jq -c --unbuffered '.result.events[]? | {type: .type, key: .kv.key, value: .kv.value, lease: .kv.lease}' \
| while IFS= read -r line; do
    type=$(echo "$line" | jq -r '.type // "PUT"')
    key=$(echo "$line" | jq -r '.key' | base64 -d)
    value=$(echo "$line" | jq -r '.value // empty' | base64 -d || true)

    if [[ "$type" == "DELETE" ]]; then
        log INFO "Backend removed: $key"
    else
        log INFO "Backend added/updated: $key -> $value"
    fi
    
    reconcile
done &

# --------------------------------------------------
# Render initial HAProxy config from polled KVS
# --------------------------------------------------
render_config <<< "$INITIAL_KVS"
reload_haproxy
