#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

YDB_DIR="${YDB_DIR:-$HOME/ydbd-drive}"
IMAGE_PATH="${IMAGE_PATH:-$PWD/ydb-data.raw}"
IMAGE_SIZE="${IMAGE_SIZE:-100G}"
DEVICE_PATH="${DEVICE_PATH:-}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ydb-drive}"
STATE_FILE="$STATE_DIR/state.env"

YES=0
FORCE=0
REMOVE_IMAGE=0

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

sudo_cmd() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

usage() {
    cat <<EOF
Usage:
  ./deploy-ydb-drive-local.sh install
  ./deploy-ydb-drive-local.sh start --device /dev/sdX --yes
  ./deploy-ydb-drive-local.sh start --image ./ydb-data.raw --size 100G --yes
  ./deploy-ydb-drive-local.sh stop
  ./deploy-ydb-drive-local.sh status
  ./deploy-ydb-drive-local.sh detach
  ./deploy-ydb-drive-local.sh clean [--remove-image]

Examples:
  # Запуск на реальном/виртуальном блочном устройстве
  ./deploy-ydb-drive-local.sh start --device /dev/vdb --yes

  # Запуск через raw-файл и loop device
  ./deploy-ydb-drive-local.sh start --image ./ydb-data.raw --size 100G --yes

  # Остановка YDB
  ./deploy-ydb-drive-local.sh stop

  # Отвязать loop device
  ./deploy-ydb-drive-local.sh detach

Options:
  --dir PATH          Каталог установки YDB. Default: ~/ydbd-drive
  --device DEVICE     Блочное устройство, например /dev/sdb, /dev/vdb, /dev/loop7
  --image PATH        Raw-файл виртуального диска. Default: ./ydb-data.raw
  --size SIZE         Размер raw-файла. Default: 100G
  --yes              Подтверждение запуска. Без него YDB не стартует.
  --force            Разрешить устройство с разделами/сигнатурами ФС.
  --remove-image     При clean удалить raw-файл.

WARNING:
  В режиме drive YDB может полностью очистить указанное устройство.
  Не указывай системный диск: /dev/sda, /dev/nvme0n1, если на нем стоит ОС.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            YDB_DIR="$2"
            shift 2
            ;;
        --device)
            DEVICE_PATH="$2"
            shift 2
            ;;
        --image)
            IMAGE_PATH="$2"
            shift 2
            ;;
        --size)
            IMAGE_SIZE="$2"
            shift 2
            ;;
        --yes)
            YES=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --remove-image)
            REMOVE_IMAGE=1
            shift
            ;;
        -h|--help)
            ACTION="help"
            shift
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

save_state() {
    local device="${1:-}"
    local loop_device="${2:-}"

    mkdir -p "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
YDB_DIR='$YDB_DIR'
IMAGE_PATH='$IMAGE_PATH'
DEVICE_PATH='$device'
LOOP_DEVICE='$loop_device'
EOF
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

install_ydb() {
    need_cmd curl
    need_cmd bash

    mkdir -p "$YDB_DIR"

    if [[ -x "$YDB_DIR/start.sh" && -x "$YDB_DIR/stop.sh" ]]; then
        log "YDB already installed: $YDB_DIR"
    else
        log "Installing YDB into: $YDB_DIR"
        (
            cd "$YDB_DIR"
            curl -fsSL https://install.ydb.tech | bash
        )
    fi

    [[ -x "$YDB_DIR/start.sh" ]] || die "start.sh not found after installation"
    [[ -x "$YDB_DIR/stop.sh" ]] || die "stop.sh not found after installation"

    log "Checking whether start.sh supports drive mode..."

    if ! grep -q "drive" "$YDB_DIR/start.sh"; then
        warn "The installed start.sh may not support drive mode."
        warn "Try running manually: cd '$YDB_DIR' && ./start.sh"
        die "drive mode was not found in start.sh"
    fi

    log "YDB installation is ready."
}

absolute_image_path() {
    local dir
    dir="$(dirname "$IMAGE_PATH")"
    mkdir -p "$dir"

    local abs_dir
    abs_dir="$(cd "$dir" && pwd)"
    IMAGE_PATH="$abs_dir/$(basename "$IMAGE_PATH")"
}

create_image() {
    absolute_image_path

    if [[ -f "$IMAGE_PATH" ]]; then
        log "Raw image already exists: $IMAGE_PATH"
        ls -lh "$IMAGE_PATH"
        return 0
    fi

    log "Creating raw image:"
    log "  path: $IMAGE_PATH"
    log "  size: $IMAGE_SIZE"

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "$IMAGE_SIZE" "$IMAGE_PATH" || truncate -s "$IMAGE_SIZE" "$IMAGE_PATH"
    else
        truncate -s "$IMAGE_SIZE" "$IMAGE_PATH"
    fi

    ls -lh "$IMAGE_PATH"
}

attach_loop() {
    need_cmd losetup

    absolute_image_path

    [[ -f "$IMAGE_PATH" ]] || die "Image does not exist: $IMAGE_PATH"

    local existing_loop
    existing_loop="$(sudo_cmd losetup -j "$IMAGE_PATH" | head -n 1 | cut -d: -f1 || true)"

    if [[ -n "$existing_loop" ]]; then
        log "Image already attached:"
        log "  image: $IMAGE_PATH"
        log "  loop:  $existing_loop"

        DEVICE_PATH="$existing_loop"
        save_state "$DEVICE_PATH" "$existing_loop"
        echo "$existing_loop"
        return 0
    fi

    log "Attaching image as loop device..."

    local loop_dev
    if loop_dev="$(sudo_cmd losetup --find --show --direct-io=on "$IMAGE_PATH" 2>/dev/null)"; then
        log "Attached with direct-io=on: $loop_dev"
    else
        warn "direct-io=on is not available, using normal loop mode"
        loop_dev="$(sudo_cmd losetup --find --show "$IMAGE_PATH")"
        log "Attached: $loop_dev"
    fi

    DEVICE_PATH="$loop_dev"
    save_state "$DEVICE_PATH" "$loop_dev"

    echo "$loop_dev"
}

grant_device_access() {
    local dev="$1"

    if command -v setfacl >/dev/null 2>&1; then
        sudo_cmd setfacl -m "u:$USER:rw" "$dev" || true
    else
        warn "setfacl not found. Trying chown for temporary device access."
        sudo_cmd chown "$USER" "$dev" || true
    fi
}

validate_device() {
    local dev="$1"

    need_cmd lsblk
    need_cmd blockdev

    [[ -n "$dev" ]] || die "Device is empty"
    [[ -b "$dev" ]] || die "$dev is not a block device"

    log "Selected device:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$dev" || true
    echo

    local mounted_count
    mounted_count="$(lsblk -nr -o MOUNTPOINTS "$dev" | grep -c '[^[:space:]]' || true)"

    if [[ "$mounted_count" -gt 0 ]]; then
        die "$dev or its child partitions are mounted. Refusing to continue."
    fi

    local bytes
    bytes="$(sudo_cmd blockdev --getsize64 "$dev")"

    local min_bytes
    min_bytes=$((80 * 1024 * 1024 * 1024))

    if [[ "$bytes" -lt "$min_bytes" ]]; then
        die "$dev is smaller than 80 GiB. Use at least 80G for local YDB drive mode."
    fi

    local children_count
    children_count="$(lsblk -nr -o NAME "$dev" | wc -l | awk '{print $1}')"

    if [[ "$children_count" -gt 1 && "$FORCE" -ne 1 ]]; then
        die "$dev has child partitions. Use --force only if this device can be wiped."
    fi

    local fstype
    fstype="$(lsblk -dn -o FSTYPE "$dev" | tr -d ' ' || true)"

    if [[ -n "$fstype" && "$FORCE" -ne 1 ]]; then
        die "$dev has filesystem signature '$fstype'. Use --force only if this device can be wiped."
    fi
}

start_ydb() {
    install_ydb

    local dev="$1"

    validate_device "$dev"

    if [[ "$YES" -ne 1 ]]; then
        die "Refusing to start. YDB may wipe $dev. Add --yes to confirm."
    fi

    grant_device_access "$dev"

    log "Starting YDB in drive mode:"
    log "  YDB dir: $YDB_DIR"
    log "  device:  $dev"
    log "WARNING: first start can wipe and initialize the selected device."

    sleep 3

    (
        cd "$YDB_DIR"
        ./start.sh drive "$dev"
    )

    save_state "$dev" "${LOOP_DEVICE:-}"

    log "YDB started."
    log "Web UI:   http://localhost:8765"
    log "Endpoint: grpc://localhost:2136"
    log "Database: /Root/test"
    log "Full DSN: grpc://localhost:2136/Root/test"
}

stop_ydb() {
    load_state

    local dir="${YDB_DIR:-$HOME/ydbd-drive}"

    if [[ ! -x "$dir/stop.sh" ]]; then
        warn "stop.sh not found: $dir/stop.sh"
        return 0
    fi

    log "Stopping YDB..."
    (
        cd "$dir"
        ./stop.sh || sudo ./stop.sh || true
    )

    log "YDB stopped."
}

detach_loop() {
    need_cmd losetup
    load_state

    local loop_dev="${LOOP_DEVICE:-}"

    if [[ -z "$loop_dev" ]]; then
        warn "No loop device in state file: $STATE_FILE"
        return 0
    fi

    if ! sudo_cmd losetup "$loop_dev" >/dev/null 2>&1; then
        warn "Loop device is not active: $loop_dev"
        return 0
    fi

    log "Detaching loop device: $loop_dev"
    sudo_cmd losetup -d "$loop_dev"
    log "Detached."
}

status_ydb() {
    load_state

    echo "YDB dir:     ${YDB_DIR:-}"
    echo "Image path:  ${IMAGE_PATH:-}"
    echo "Device:      ${DEVICE_PATH:-}"
    echo "Loop device: ${LOOP_DEVICE:-}"
    echo

    if [[ -n "${DEVICE_PATH:-}" && -b "${DEVICE_PATH:-}" ]]; then
        echo "Device info:"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "${DEVICE_PATH:-}" || true
        echo
    fi

    echo "Listening ports:"
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -E ':(2135|2136|8765|9092)\b' || true
    else
        warn "ss command not found"
    fi

    echo
    echo "YDB processes:"
    pgrep -af 'ydbd|ydb' || true
}

clean_all() {
    stop_ydb
    detach_loop

    if [[ "$REMOVE_IMAGE" -eq 1 ]]; then
        absolute_image_path
        if [[ -f "$IMAGE_PATH" ]]; then
            log "Removing image: $IMAGE_PATH"
            rm -f "$IMAGE_PATH"
        fi
    fi

    log "Clean done."
}

case "$ACTION" in
    install)
        install_ydb
        ;;
    start)
        if [[ -n "$DEVICE_PATH" ]]; then
            start_ydb "$DEVICE_PATH"
        else
            create_image
            LOOP_DEVICE="$(attach_loop | tail -n 1)"
            DEVICE_PATH="$LOOP_DEVICE"
            start_ydb "$DEVICE_PATH"
        fi
        ;;
    stop)
        stop_ydb
        ;;
    status)
        status_ydb
        ;;
    detach)
        detach_loop
        ;;
    clean)
        clean_all
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        die "Unknown action: $ACTION"
        ;;
esac