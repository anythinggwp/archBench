#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_TARGETS="${DEPLOY_TARGETS:-redis,tarantool}"

normalize_targets() {
    if [[ "$DEPLOY_TARGETS" == "all" ]]; then
        DEPLOY_TARGETS="redis,tarantool,postgres,citus,ydb"
    fi

    DEPLOY_TARGETS="$(echo "$DEPLOY_TARGETS" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
}

run_target() {
    local target="$1"

    case "$target" in
        redis)
            "$SCRIPT_DIR/deploy_redis.sh" "$ACTION"
            ;;
        tarantool)
            "$SCRIPT_DIR/deploy_tarantool_stack.sh" "$ACTION"
            ;;
        postgres)
            "$SCRIPT_DIR/deploy_postgres.sh" "$ACTION"
            ;;
        citus|postgres-citus|postgres_citus)
            "$SCRIPT_DIR/deploy_postgres_citus.sh" "$ACTION"
            ;;
        ydb)
            "$SCRIPT_DIR/deploy_ydb_container.sh" "$ACTION"
            ;;
        *)
            echo "ERROR: unknown DEPLOY_TARGETS item: $target" >&2
            exit 1
            ;;
    esac
}

normalize_targets

IFS=',' read -r -a targets <<< "$DEPLOY_TARGETS"
for target in "${targets[@]}"; do
    run_target "$target"
done
