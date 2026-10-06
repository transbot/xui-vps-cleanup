#!/usr/bin/env bash
# xui-vps-cleanup.sh
# Conservative cleanup/audit helper for an Ubuntu/Debian VPS whose only application workload should be x-ui/Xray.
# Default behavior is read-only (audit). Destructive pruning requires an explicit command.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.1.1"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-200M}"
JOURNAL_KEEP_FREE="${JOURNAL_KEEP_FREE:-1G}"
ASSUME_YES=0
CONFIRM_XUI_ONLY=0
REBOOT_AFTER=0
NETWORK_CHANGED=0
MUTATING_RUN=0
REPORT_DONE=0
STATE_DIR=""
REPORT_FILE=""
RUN_COMMAND=""

usage() {
  cat <<'USAGE'
Usage:
  xui-vps-cleanup.sh audit
  xui-vps-cleanup.sh clean [--yes]
  xui-vps-cleanup.sh prune-xui-only --confirm-xui-only [--yes]
  xui-vps-cleanup.sh fix-network [--yes]
  xui-vps-cleanup.sh upgrade [--yes] [--reboot]
  xui-vps-cleanup.sh verify
  xui-vps-cleanup.sh all --confirm-xui-only [--yes] [--reboot]

Commands:
  audit             Read-only inventory: OS, RAM, disk, services, listeners, logs, packages.
  clean             Low-risk cleanup only: journal cap/vacuum, apt cache, snap cache.
  prune-xui-only    Remove known desktop/RDP/printing/mDNS/Node/PM2 leftovers.
                    Requires --confirm-xui-only. Unknown data outside known locations is NOT deleted.
  fix-network       If Netplan + systemd-networkd clearly own the default NIC, retire legacy
                    /etc/network/interfaces management. Does not restart networking in-place.
  upgrade           apt update + normal apt upgrade. Does not full-upgrade. Optional reboot.
  verify            Check x-ui, fail2ban, failed units, sockets, RAM, swap and disk.
  all               audit -> clean -> prune-xui-only -> fix-network -> upgrade -> verify.
                    Modifying commands automatically write a before -> after Markdown report.

Options:
  --confirm-xui-only  You explicitly confirm this VPS should have no application workload except x-ui/Xray.
  --yes               Non-interactive confirmations for supported steps.
  --reboot            Reboot after upgrade/all when finished.

Environment overrides:
  JOURNAL_MAX_USE=200M
  JOURNAL_KEEP_FREE=1G

Notes:
  * "x-ui only" means only application workload. Core OS services such as SSH, systemd,
    networking, DNS, cron, journald and optionally fail2ban are intentionally retained.
  * This script never deletes /usr/local/x-ui, x-ui.service, x-ui databases/configs, or SSH config.
  * Unknown project directories in /root or elsewhere are reported, not blindly deleted.
  * clean/prune-xui-only/fix-network/upgrade/all generate /root/xui-vps-cleanup-report-*.md
    with disk/RAM/Swap changes, removed packages/services, and remaining network-facing listeners.
USAGE
}

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

confirm() {
  local prompt="$1"
  if (( ASSUME_YES )); then
    log "$prompt -> yes (--yes)"
    return 0
  fi
  local ans
  read -r -p "$prompt [y/N] " ans </dev/tty || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

pkg_installed() {
  dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed
}

pkg_manual() {
  apt-mark showmanual 2>/dev/null | grep -Fxq "$1"
}

backup_state() {
  local ts backup
  ts="$(date '+%Y%m%d-%H%M%S')"
  backup="/root/xui-cleanup-backup-${ts}"
  mkdir -p "$backup"
  log "Saving configuration/state snapshot to $backup"

  cp -a /etc/network/interfaces "$backup/interfaces" 2>/dev/null || true
  cp -a /etc/netplan "$backup/netplan" 2>/dev/null || true
  cp -a /etc/systemd/system/x-ui.service "$backup/" 2>/dev/null || true
  cp -a /etc/systemd/system/x-ui.service.d "$backup/" 2>/dev/null || true
  cp -a /etc/systemd/journald.conf "$backup/" 2>/dev/null || true
  cp -a /etc/systemd/journald.conf.d "$backup/" 2>/dev/null || true
  cp -a /etc/x-ui "$backup/etc-x-ui" 2>/dev/null || true

  if [[ -d /usr/local/x-ui ]]; then
    find /usr/local/x-ui -maxdepth 3 -type f \( -name '*.db' -o -name 'config.json' \) -print0 2>/dev/null |
      while IFS= read -r -d '' f; do
        mkdir -p "$backup/xui-files$(dirname "$f")"
        cp -a "$f" "$backup/xui-files$f" 2>/dev/null || true
      done
  fi

  dpkg --get-selections > "$backup/dpkg-selections.txt" 2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-pager > "$backup/enabled-units.txt" 2>/dev/null || true
  ss -lntup > "$backup/listeners.txt" 2>/dev/null || true
  ip addr > "$backup/ip-addr.txt" 2>/dev/null || true
  ip route > "$backup/ip-route.txt" 2>/dev/null || true
  log "Backup snapshot complete."
}



human_bytes() {
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if have numfmt; then
    numfmt --to=iec-i --suffix=B "$n" 2>/dev/null || printf '%s B' "$n"
  else
    printf '%s B' "$n"
  fi
}

capture_network_listeners() {
  local out="$1" line proto local_addr proc
  : > "$out"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    proto="$(awk '{print $1}' <<<"$line")"
    local_addr="$(awk '{print $5}' <<<"$line")"
    case "$local_addr" in
      127.*|"[::1]:"*|localhost:*) continue ;;
    esac
    proc="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line")"
    [[ -n "$proc" ]] || proc="-"
    printf '%s\t%s\t%s\n' "$proto" "$local_addr" "$proc" >> "$out"
  done < <(ss -H -lntup 2>/dev/null || true)
  sort -u -o "$out" "$out" 2>/dev/null || true
}

capture_known_services() {
  local out="$1" unit load active enabled
  local units=(
    gdm3.service
    xrdp.service
    xrdp-sesman.service
    cups.service
    cups-browsed.service
    avahi-daemon.service
    pm2-root.service
  )
  while IFS= read -r unit; do
    [[ -n "$unit" ]] && units+=("$unit")
  done < <(systemctl list-unit-files --no-legend 'pm2-*.service' 2>/dev/null | awk '{print $1}')

  : > "$out"
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
    [[ -n "$load" ]] || load="not-found"
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ -n "$active" ]] || active="unknown"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    [[ -n "$enabled" ]] || enabled="unknown"
    printf '%s\t%s\t%s\t%s\n' "$unit" "$load" "$active" "$enabled" >> "$out"
  done < <(printf '%s\n' "${units[@]}" | sort -u)
}

capture_state() {
  local label="$1" dir envfile
  dir="$STATE_DIR"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  envfile="$dir/${label}.env"

  local root_total root_used root_avail root_pct
  IFS=' ' read -r root_total root_used root_avail root_pct < <(
    df -P -B1 / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $2,$3,$4,$5}'
  )
  root_total="${root_total:-0}"; root_used="${root_used:-0}"; root_avail="${root_avail:-0}"; root_pct="${root_pct:-0}"

  local mem_total mem_used mem_free mem_available swap_total swap_used swap_free
  IFS=' ' read -r mem_total mem_used mem_free mem_available < <(
    free -b 2>/dev/null | awk '/^Mem:/ {print $2,$3,$4,$7}'
  )
  IFS=' ' read -r swap_total swap_used swap_free < <(
    free -b 2>/dev/null | awk '/^Swap:/ {print $2,$3,$4}'
  )
  mem_total="${mem_total:-0}"; mem_used="${mem_used:-0}"; mem_free="${mem_free:-0}"; mem_available="${mem_available:-0}"
  swap_total="${swap_total:-0}"; swap_used="${swap_used:-0}"; swap_free="${swap_free:-0}"

  local journal_bytes snap_cache_bytes failed_count xui_state fail2ban_state default_target kernel node_procs pm2_apps
  journal_bytes="$(du -sb /var/log/journal 2>/dev/null | awk 'NR==1{print $1}')"; journal_bytes="${journal_bytes:-0}"
  snap_cache_bytes="$(du -sb /var/lib/snapd/cache 2>/dev/null | awk 'NR==1{print $1}')"; snap_cache_bytes="${snap_cache_bytes:-0}"
  failed_count="$(systemctl --failed --no-legend 2>/dev/null | awk 'NF{c++} END{print c+0}')"; failed_count="${failed_count:-0}"
  xui_state="$(systemctl is-active x-ui 2>/dev/null || true)"; xui_state="${xui_state:-unknown}"
  if systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
    fail2ban_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
  else
    fail2ban_state="not-installed"
  fi
  fail2ban_state="${fail2ban_state:-unknown}"
  default_target="$(systemctl get-default 2>/dev/null || true)"; default_target="${default_target:-unknown}"
  kernel="$(uname -r 2>/dev/null || true)"; kernel="${kernel:-unknown}"
  node_procs="$(pgrep -c node 2>/dev/null || true)"; node_procs="${node_procs:-0}"
  if have pm2; then
    pm2_apps="$(pm2 jlist 2>/dev/null | grep -o '"pm_id"' | wc -l || true)"
  else
    pm2_apps=0
  fi
  pm2_apps="${pm2_apps:-0}"

  {
    printf 'ROOT_TOTAL_BYTES=%q\n' "$root_total"
    printf 'ROOT_USED_BYTES=%q\n' "$root_used"
    printf 'ROOT_AVAIL_BYTES=%q\n' "$root_avail"
    printf 'ROOT_USE_PCT=%q\n' "$root_pct"
    printf 'MEM_TOTAL_BYTES=%q\n' "$mem_total"
    printf 'MEM_USED_BYTES=%q\n' "$mem_used"
    printf 'MEM_FREE_BYTES=%q\n' "$mem_free"
    printf 'MEM_AVAILABLE_BYTES=%q\n' "$mem_available"
    printf 'SWAP_TOTAL_BYTES=%q\n' "$swap_total"
    printf 'SWAP_USED_BYTES=%q\n' "$swap_used"
    printf 'SWAP_FREE_BYTES=%q\n' "$swap_free"
    printf 'JOURNAL_BYTES=%q\n' "$journal_bytes"
    printf 'SNAP_CACHE_BYTES=%q\n' "$snap_cache_bytes"
    printf 'FAILED_UNITS=%q\n' "$failed_count"
    printf 'XUI_STATE=%q\n' "$xui_state"
    printf 'FAIL2BAN_STATE=%q\n' "$fail2ban_state"
    printf 'DEFAULT_TARGET=%q\n' "$default_target"
    printf 'KERNEL=%q\n' "$kernel"
    printf 'NODE_PROCS=%q\n' "$node_procs"
    printf 'PM2_APPS=%q\n' "$pm2_apps"
  } > "$envfile"

  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$dir/${label}.packages" || true
  capture_known_services "$dir/${label}.services"
  capture_network_listeners "$dir/${label}.listeners"
  systemctl --failed --no-pager > "$dir/${label}.failed-units.txt" 2>/dev/null || true
  ip route > "$dir/${label}.routes.txt" 2>/dev/null || true
}

load_state_prefixed() {
  local prefix="$1" file="$2" key value
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    eval "${prefix}_${key}=${value}"
  done < "$file"
}

service_changes_to_file() {
  local before="$1" after="$2" out="$3" unit bload bactive benabled aline aload aactive aenabled
  declare -A amap_load=() amap_active=() amap_enabled=()
  while IFS=$'\t' read -r unit aload aactive aenabled; do
    [[ -n "$unit" ]] || continue
    amap_load["$unit"]="$aload"
    amap_active["$unit"]="$aactive"
    amap_enabled["$unit"]="$aenabled"
  done < "$after"

  : > "$out"
  while IFS=$'\t' read -r unit bload bactive benabled; do
    [[ -n "$unit" ]] || continue
    aload="${amap_load[$unit]:-not-found}"
    aactive="${amap_active[$unit]:-unknown}"
    aenabled="${amap_enabled[$unit]:-unknown}"
    if [[ "$bload" != "not-found" ]] && { [[ "$bactive" == "active" ]] || [[ "$benabled" == "enabled" ]]; }; then
      if [[ "$aload" == "not-found" ]] || { [[ "$aactive" != "active" ]] && [[ "$aenabled" != "enabled" ]]; }; then
        printf '%s\t%s/%s -> %s/%s\n' "$unit" "$bactive" "$benabled" "$aactive" "$aenabled" >> "$out"
      fi
    fi
  done < "$before"
}

write_listener_table() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo '_none_'
    return
  fi
  echo '| Protocol | Bind address | Process |'
  echo '|---|---|---|'
  while IFS=$'\t' read -r proto addr proc; do
    printf '| %s | `%s` | `%s` |\n' "$proto" "$addr" "$proc"
  done < "$file"
}

generate_report() {
  local exit_code="${1:-0}"
  local before_env="$STATE_DIR/before.env" after_env="$STATE_DIR/after.env"
  [[ -f "$before_env" && -f "$after_env" ]] || return 0

  load_state_prefixed B "$before_env"
  load_state_prefixed A "$after_env"

  local removed_packages="$STATE_DIR/removed-packages.txt"
  local added_packages="$STATE_DIR/added-packages.txt"
  local service_changes="$STATE_DIR/service-changes.txt"
  local removed_listeners="$STATE_DIR/removed-listeners.txt"
  local added_listeners="$STATE_DIR/added-listeners.txt"
  comm -23 "$STATE_DIR/before.packages" "$STATE_DIR/after.packages" > "$removed_packages" 2>/dev/null || true
  comm -13 "$STATE_DIR/before.packages" "$STATE_DIR/after.packages" > "$added_packages" 2>/dev/null || true
  service_changes_to_file "$STATE_DIR/before.services" "$STATE_DIR/after.services" "$service_changes"
  comm -23 "$STATE_DIR/before.listeners" "$STATE_DIR/after.listeners" > "$removed_listeners" 2>/dev/null || true
  comm -13 "$STATE_DIR/before.listeners" "$STATE_DIR/after.listeners" > "$added_listeners" 2>/dev/null || true

  local disk_freed=0 pct_delta=0 removed_pkg_count=0 service_change_count=0 listener_after_count=0 listener_removed_count=0
  if (( B_ROOT_USED_BYTES >= A_ROOT_USED_BYTES )); then disk_freed=$((B_ROOT_USED_BYTES-A_ROOT_USED_BYTES)); fi
  pct_delta=$((B_ROOT_USE_PCT-A_ROOT_USE_PCT))
  removed_pkg_count="$(awk 'NF{c++} END{print c+0}' "$removed_packages")"
  service_change_count="$(awk 'NF{c++} END{print c+0}' "$service_changes")"
  listener_after_count="$(awk 'NF{c++} END{print c+0}' "$STATE_DIR/after.listeners")"
  listener_removed_count="$(awk 'NF{c++} END{print c+0}' "$removed_listeners")"

  {
    echo '# xui-vps-cleanup before -> after report'
    echo
    printf -- '- Generated: %s\n' "$(date '+%F %T %z')"
    printf -- '- Script version: %s\n' "$VERSION"
    printf -- '- Command: `%s`\n' "$RUN_COMMAND"
    printf -- '- Exit status at report time: `%s`\n' "$exit_code"
    printf -- '- Transcript: `%s`\n' "$LOGFILE"
    printf -- '- State snapshots: `%s`\n' "$STATE_DIR"
    if [[ -f /var/run/reboot-required ]] || (( NETWORK_CHANGED )); then
      echo '- Reboot recommended/required: **yes**'
    else
      echo '- Reboot recommended/required: no indication from this run'
    fi
    echo
    echo '## Summary'
    echo
    echo '| Metric | Before | After |'
    echo '|---|---:|---:|'
    printf '| Root disk used | %s (%s%%) | %s (%s%%) |\n' "$(human_bytes "$B_ROOT_USED_BYTES")" "$B_ROOT_USE_PCT" "$(human_bytes "$A_ROOT_USED_BYTES")" "$A_ROOT_USE_PCT"
    printf '| Root disk available | %s | %s |\n' "$(human_bytes "$B_ROOT_AVAIL_BYTES")" "$(human_bytes "$A_ROOT_AVAIL_BYTES")"
    printf '| RAM used | %s | %s |\n' "$(human_bytes "$B_MEM_USED_BYTES")" "$(human_bytes "$A_MEM_USED_BYTES")"
    printf '| RAM available | %s | %s |\n' "$(human_bytes "$B_MEM_AVAILABLE_BYTES")" "$(human_bytes "$A_MEM_AVAILABLE_BYTES")"
    printf '| Swap used | %s | %s |\n' "$(human_bytes "$B_SWAP_USED_BYTES")" "$(human_bytes "$A_SWAP_USED_BYTES")"
    printf '| systemd journal | %s | %s |\n' "$(human_bytes "$B_JOURNAL_BYTES")" "$(human_bytes "$A_JOURNAL_BYTES")"
    printf '| Snap download cache | %s | %s |\n' "$(human_bytes "$B_SNAP_CACHE_BYTES")" "$(human_bytes "$A_SNAP_CACHE_BYTES")"
    printf '| Failed systemd units | %s | %s |\n' "$B_FAILED_UNITS" "$A_FAILED_UNITS"
    printf '| x-ui | %s | %s |\n' "$B_XUI_STATE" "$A_XUI_STATE"
    printf '| Fail2Ban | %s | %s |\n' "$B_FAIL2BAN_STATE" "$A_FAIL2BAN_STATE"
    printf '| Node processes | %s | %s |\n' "$B_NODE_PROCS" "$A_NODE_PROCS"
    printf '| PM2 apps | %s | %s |\n' "$B_PM2_APPS" "$A_PM2_APPS"
    printf '| Default systemd target | %s | %s |\n' "$B_DEFAULT_TARGET" "$A_DEFAULT_TARGET"
    printf '| Kernel | %s | %s |\n' "$B_KERNEL" "$A_KERNEL"
    echo
    if (( disk_freed > 0 )); then
      printf '**Disk reclaimed during this run:** %s; root usage changed by %s percentage points.\n\n' "$(human_bytes "$disk_freed")" "$pct_delta"
    else
      printf '**Disk reclaimed during this run:** none measured (upgrades may have increased usage); root usage changed by %s percentage points.\n\n' "$pct_delta"
    fi
    printf '**Removed packages:** %s  \n' "$removed_pkg_count"
    printf '**Cleanup-target services stopped/removed:** %s  \n' "$service_change_count"
    printf '**Network-facing listeners removed:** %s  \n' "$listener_removed_count"
    printf '**Network-facing listeners remaining:** %s\n' "$listener_after_count"
    echo
    echo '> “Network-facing” here means bound to a non-loopback address. Actual Internet reachability still depends on host firewall and cloud firewall/security-group rules.'
    echo
    echo '## Cleanup-target services stopped or removed'
    echo
    if [[ -s "$service_changes" ]]; then
      while IFS=$'\t' read -r unit change; do printf -- '- `%s`: %s\n' "$unit" "$change"; done < "$service_changes"
    else
      echo '_none detected in this run_'
    fi
    echo
    echo '## Network-facing listeners: before'
    echo
    write_listener_table "$STATE_DIR/before.listeners"
    echo
    echo '## Network-facing listeners: after'
    echo
    write_listener_table "$STATE_DIR/after.listeners"
    echo
    echo '## Network-facing listeners removed'
    echo
    write_listener_table "$removed_listeners"
    echo
    echo '## Network-facing listeners added'
    echo
    write_listener_table "$added_listeners"
    echo
    echo '## Removed packages'
    echo
    if [[ -s "$removed_packages" ]]; then
      while IFS= read -r p; do printf -- '- `%s`\n' "$p"; done < "$removed_packages"
    else
      echo '_none_'
    fi
    echo
    echo '## Packages added'
    echo
    if [[ -s "$added_packages" ]]; then
      while IFS= read -r p; do printf -- '- `%s`\n' "$p"; done < "$added_packages"
    else
      echo '_none_'
    fi
    echo
    echo '## Failed units after cleanup'
    echo
    echo '```text'
    cat "$STATE_DIR/after.failed-units.txt" 2>/dev/null || true
    echo '```'
    echo
    echo '## Routes after cleanup'
    echo
    echo '```text'
    cat "$STATE_DIR/after.routes.txt" 2>/dev/null || true
    echo '```'
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE" 2>/dev/null || true
}

start_report() {
  MUTATING_RUN=1
  STATE_DIR="/root/xui-vps-cleanup-state-${RUN_TS}"
  REPORT_FILE="/root/xui-vps-cleanup-report-${RUN_TS}.md"
  capture_state before
  trap 'finalize_report $?' EXIT
}

schedule_post_reboot_report() {
  local helper="$STATE_DIR/post-reboot-report.sh"
  local unit="/etc/systemd/system/xui-vps-cleanup-post-report.service"
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  cp -a "$script_path" "$helper"
  chmod 700 "$helper"

  cat > "$unit" <<EOFUNIT
[Unit]
Description=xui-vps-cleanup post-reboot final report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="XUI_REPORT_STATE_DIR=$STATE_DIR"
Environment="XUI_REPORT_FILE=$REPORT_FILE"
Environment="XUI_REPORT_LOGFILE=$LOGFILE"
Environment="XUI_REPORT_RUN_COMMAND=$RUN_COMMAND"
ExecStart=/bin/bash $helper _post-reboot-report

[Install]
WantedBy=multi-user.target
EOFUNIT
  systemctl daemon-reload
  systemctl enable xui-vps-cleanup-post-report.service >/dev/null
  log "Post-reboot final report scheduled; it will overwrite/finalize $REPORT_FILE after the next boot."
}

finalize_report() {
  local exit_code="${1:-0}"
  (( MUTATING_RUN )) || return 0
  (( REPORT_DONE )) && return 0
  REPORT_DONE=1
  set +e
  capture_state after
  generate_report "$exit_code"
  log "Before -> after report written to $REPORT_FILE"
  printf '\n===== BEFORE -> AFTER SUMMARY =====\n'
  awk '
    /^## Summary$/ {show=1; next}
    /^## Cleanup-target services stopped or removed$/ {show=0}
    show {print}
  ' "$REPORT_FILE" | sed -n '1,45p'
  printf '\nFull report: %s\n' "$REPORT_FILE"
  set -e
}

print_cmd() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@" || true
}

audit() {
  log "Audit only; no changes will be made."
  print_cmd cat /etc/os-release
  print_cmd uname -a
  print_cmd uptime
  print_cmd free -h
  print_cmd df -h /
  print_cmd systemctl --failed
  print_cmd systemctl status x-ui --no-pager
  print_cmd systemctl status fail2ban --no-pager
  print_cmd ss -lntup
  print_cmd journalctl --disk-usage

  printf '\n== Large top-level directories ==\n'
  du -xhd1 / 2>/dev/null | sort -h | tail -20 || true
  printf '\n== /var breakdown ==\n'
  du -xhd1 /var 2>/dev/null | sort -h | tail -20 || true
  printf '\n== /root breakdown ==\n'
  du -xhd1 /root 2>/dev/null | sort -h | tail -20 || true
  printf '\n== Largest /var/log entries ==\n'
  du -ahx /var/log 2>/dev/null | sort -rh | head -20 || true
  printf '\n== Desktop/RDP/printing/mDNS/Node packages ==\n'
  dpkg -l 2>/dev/null | grep '^ii' | grep -E 'ubuntu-desktop|gnome-shell|gdm3|xfce4|xubuntu-desktop|kubuntu-desktop|lubuntu-desktop|lxde|lxqt|xrdp|xorgxrdp|cups|avahi|nodejs|npm' || true
  printf '\n== PM2 ==\n'
  if have pm2; then pm2 list || true; else echo 'pm2 not installed/in PATH'; fi
  printf '\n== Netplan/network ownership ==\n'
  ls -lah /etc/netplan 2>/dev/null || true
  cat /etc/netplan/*.yaml 2>/dev/null || true
  systemctl is-active systemd-networkd 2>/dev/null || true
  systemctl is-enabled systemd-networkd 2>/dev/null || true
  cat /etc/network/interfaces 2>/dev/null || true
  printf '\n== x-ui protection check ==\n'
  [[ -x /usr/local/x-ui/x-ui ]] && echo '/usr/local/x-ui/x-ui present' || warn '/usr/local/x-ui/x-ui not found'
}

configure_journal_limit() {
  log "Configuring journald cap: SystemMaxUse=$JOURNAL_MAX_USE, SystemKeepFree=$JOURNAL_KEEP_FREE"
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOFJ
[Journal]
SystemMaxUse=$JOURNAL_MAX_USE
SystemKeepFree=$JOURNAL_KEEP_FREE
EOFJ
  systemctl restart systemd-journald || true
  journalctl --vacuum-size="$JOURNAL_MAX_USE" || true
}

clean_low_risk() {
  backup_state
  configure_journal_limit

  if [[ -d /var/lib/snapd/cache ]]; then
    local before after
    before="$(du -sh /var/lib/snapd/cache 2>/dev/null | awk '{print $1}')"
    find /var/lib/snapd/cache -type f -delete 2>/dev/null || true
    after="$(du -sh /var/lib/snapd/cache 2>/dev/null | awk '{print $1}')"
    log "Snap cache: ${before:-unknown} -> ${after:-unknown}"
  fi

  apt-get clean || true
  log "Low-risk cleanup complete."
}

protected_pkg_regex='^(openssh-server|openssh-client|ssh|systemd|systemd-sysv|systemd-resolved|udev|netplan.io|network-manager|ifupdown|isc-dhcp-client|networkd-dispatcher|iproute2|linux-generic|linux-image-generic|grub-pc|grub-common|ubuntu-minimal|cloud-init|fail2ban|ca-certificates|curl|wget|tar|unzip|bash|coreutils|apt|dpkg|python3|sudo)$'

apt_sim_guard() {
  local mode="$1"; shift
  local tmp removed bad
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  if [[ "$mode" == purge ]]; then
    apt-get -s purge "$@" >"$tmp" 2>&1 || { cat "$tmp"; return 1; }
  elif [[ "$mode" == autoremove ]]; then
    apt-get -s autoremove --purge >"$tmp" 2>&1 || { cat "$tmp"; return 1; }
  else
    return 1
  fi

  removed="$(awk '/^Remv / {print $2}' "$tmp" | sort -u)"
  bad="$(printf '%s\n' "$removed" | grep -E "$protected_pkg_regex" || true)"
  if [[ -n "$bad" ]]; then
    cat "$tmp"
    die "APT simulation wants to remove protected packages: $(echo "$bad" | tr '\n' ' ')"
  fi

  printf '%s\n' "$removed"
}

purge_known_desktop_stack() {
  local candidates=(
    ubuntu-desktop ubuntu-desktop-minimal xubuntu-desktop kubuntu-desktop lubuntu-desktop
    xfce4 lxde lxqt gdm3 gnome-shell xrdp xorgxrdp
  )
  local pkgs=() p

  for p in "${candidates[@]}"; do
    if pkg_installed "$p"; then
      pkgs+=("$p")
    fi
  done

  if ((${#pkgs[@]})); then
    log "Known desktop/RDP entry packages detected: ${pkgs[*]}"
    apt_sim_guard purge "${pkgs[@]}" >/dev/null
    apt-get -y purge "${pkgs[@]}"
  else
    log "No manually-installed desktop/RDP entry packages found."
  fi

  local auto_removed
  auto_removed="$(apt_sim_guard autoremove)"
  if [[ -n "$auto_removed" ]]; then
    log "Running guarded apt autoremove --purge. Package count: $(printf '%s\n' "$auto_removed" | sed '/^$/d' | wc -l)"
    apt-get -y autoremove --purge
  fi
}

purge_printing_mdns() {
  local candidates=(cups cups-browsed avahi-daemon avahi-autoipd avahi-utils)
  local pkgs=() p
  for p in "${candidates[@]}"; do pkg_installed "$p" && pkgs+=("$p"); done
  if ((${#pkgs[@]})); then
    log "Removing printing/mDNS packages: ${pkgs[*]}"
    apt_sim_guard purge "${pkgs[@]}" >/dev/null
    apt-get -y purge "${pkgs[@]}"
    apt_sim_guard autoremove >/dev/null
    apt-get -y autoremove --purge
  fi
}

pm2_has_apps() {
  have pm2 || return 1
  if pm2 jlist >/tmp/xui-pm2-jlist.$$ 2>/dev/null; then
    local count
    count="$( (grep -o '"pm_id"' /tmp/xui-pm2-jlist.$$ || true) | wc -l )"
    rm -f /tmp/xui-pm2-jlist.$$
    (( count > 0 ))
  else
    rm -f /tmp/xui-pm2-jlist.$$
    pm2 list 2>/dev/null | grep -qE 'online|stopped|errored'
  fi
}

purge_node_pm2() {
  if have pm2; then
    if pm2_has_apps; then
      warn "PM2 still has managed apps. Because --confirm-xui-only is set, they will be removed."
      pm2 delete all || true
      pm2 save --force || true
    fi
    pm2 kill || true
    while read -r unit; do
      [[ -n "$unit" ]] && systemctl disable --now "$unit" || true
    done < <(systemctl list-unit-files --no-legend 'pm2-*.service' 2>/dev/null | awk '{print $1}')
  fi

  if pgrep -a node >/dev/null 2>&1; then
    warn "Node processes are still running; refusing to purge Node.js automatically."
    pgrep -a node || true
  else
    local nodepkgs=()
    pkg_installed nodejs && nodepkgs+=(nodejs)
    pkg_installed npm && nodepkgs+=(npm)
    if ((${#nodepkgs[@]})); then
      log "Purging unused Node.js/npm packages: ${nodepkgs[*]}"
      apt_sim_guard purge "${nodepkgs[@]}" >/dev/null
      apt-get -y purge "${nodepkgs[@]}"
      apt_sim_guard autoremove >/dev/null
      apt-get -y autoremove --purge
    fi
    rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources 2>/dev/null || true
    rm -rf /root/.pm2 2>/dev/null || true
    if [[ -d /usr/lib/node_modules ]]; then
      warn "Residual /usr/lib/node_modules exists; leaving it in place for review."
      du -sh /usr/lib/node_modules 2>/dev/null || true
    fi
  fi
}

report_unknown_web_content() {
  if [[ -d /var/www ]] && find /var/www -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    warn "/var/www is not empty. Unknown application data is NOT deleted automatically."
    du -sh /var/www/* 2>/dev/null || true
  fi
  printf '\n== Large non-hidden /root entries for manual review ==\n'
  du -xhd1 /root 2>/dev/null | sort -h | tail -15 || true
}

prune_xui_only() {
  (( CONFIRM_XUI_ONLY )) || die "prune-xui-only requires --confirm-xui-only"
  systemctl is-active --quiet x-ui || die "x-ui is not active; refusing to prune."
  backup_state
  purge_known_desktop_stack
  purge_printing_mdns
  purge_node_pm2
  apt-get clean || true
  report_unknown_web_content
  log "Known extra application stacks pruned. Unknown user data was left untouched."
}

fix_network() {
  backup_state

  local iface netfile
  iface="$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')"
  [[ -n "$iface" ]] || { warn "No default-route interface found; skipping network cleanup."; return 0; }

  if ! systemctl is-active --quiet systemd-networkd; then
    warn "systemd-networkd is not active; skipping legacy networking cleanup."
    return 0
  fi
  compgen -G '/etc/netplan/*.yaml' >/dev/null || { warn "No Netplan YAML found; skipping."; return 0; }

  netfile="$(networkctl status "$iface" --no-pager 2>/dev/null | sed -n 's/^[[:space:]]*Network File:[[:space:]]*//p' | head -1)"
  if [[ "$netfile" != /run/systemd/network/*netplan*.network ]]; then
    warn "Default interface $iface is not clearly managed by Netplan/systemd-networkd ($netfile); skipping."
    return 0
  fi

  log "Default interface $iface is managed by Netplan/systemd-networkd ($netfile)."
  if [[ -f /etc/network/interfaces ]]; then
    log "Retiring legacy ifupdown configuration without restarting networking."
    cat > /etc/network/interfaces <<'EOFIF'
auto lo
iface lo inet loopback
EOFIF
  fi
  if systemctl list-unit-files networking.service >/dev/null 2>&1; then
    systemctl disable networking.service || true
    systemctl reset-failed networking.service || true
  fi
  NETWORK_CHANGED=1
  warn "Network ownership changed for next boot. Current network was NOT restarted. Reboot is recommended."
}

upgrade_system() {
  backup_state
  apt-get update
  log "Running normal apt upgrade (not full-upgrade)."
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -y -o Dpkg::Options::=--force-confold upgrade
  apt_sim_guard autoremove >/dev/null
  apt-get -y autoremove --purge
  apt-get clean

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required (likely new kernel or libraries)."
    cat /var/run/reboot-required || true
  fi
}

verify() {
  local rc=0
  printf '\n===== VERIFY =====\n'
  uname -r
  uptime
  free -h
  df -h /

  if systemctl is-active --quiet x-ui; then
    echo 'x-ui: active'
  else
    echo 'x-ui: NOT ACTIVE'
    rc=1
  fi

  if systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
    systemctl is-active --quiet fail2ban && echo 'fail2ban: active' || echo 'fail2ban: inactive'
  fi

  printf '\nFailed units:\n'
  systemctl --failed --no-pager || true
  if systemctl --failed --no-legend 2>/dev/null | grep -q .; then rc=1; fi

  printf '\nListeners:\n'
  ss -lntup || true

  printf '\nKnown extra listeners/processes:\n'
  ss -lntup 2>/dev/null | grep -E ':3389\b|:631\b|:5353\b|node|PM2|xrdp|cupsd|avahi' || echo 'none detected'

  printf '\nJournal usage:\n'
  journalctl --disk-usage || true

  printf '\nDefault target:\n'
  systemctl get-default || true

  printf '\nNetwork manager:\n'
  systemctl is-active systemd-networkd 2>/dev/null || true
  ip route || true

  if (( rc == 0 )); then
    log "Verification passed: x-ui is active and no failed units are present."
  else
    warn "Verification found issues. Review output before rebooting or disconnecting."
  fi
  return "$rc"
}

COMMAND="${1:-audit}"
shift || true
while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --confirm-xui-only) CONFIRM_XUI_ONLY=1 ;;
    --reboot) REBOOT_AFTER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root

if [[ "$COMMAND" == "_post-reboot-report" ]]; then
  STATE_DIR="${XUI_REPORT_STATE_DIR:-}"
  REPORT_FILE="${XUI_REPORT_FILE:-}"
  LOGFILE="${XUI_REPORT_LOGFILE:-/root/xui-vps-cleanup-post-reboot.log}"
  RUN_COMMAND="${XUI_REPORT_RUN_COMMAND:-all}"
  [[ -n "$STATE_DIR" && -f "$STATE_DIR/before.env" ]] || die "Missing post-reboot baseline state."
  [[ -n "$REPORT_FILE" ]] || die "Missing post-reboot report path."
  MUTATING_RUN=1
  exec > >(tee -a "$LOGFILE") 2>&1
  log "Post-reboot final report: waiting briefly for x-ui/network services to settle."
  for _ in {1..15}; do
    systemctl is-active --quiet x-ui && break
    sleep 2
  done
  finalize_report 0
  systemctl disable xui-vps-cleanup-post-report.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xui-vps-cleanup-post-report.service
  systemctl daemon-reload || true
  rm -f "$STATE_DIR/post-reboot-report.sh" 2>/dev/null || true
  exit 0
fi

RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOGFILE="/root/xui-vps-cleanup-${RUN_TS}.log"
RUN_COMMAND="$COMMAND"
exec > >(tee -a "$LOGFILE") 2>&1
log "xui-vps-cleanup v$VERSION; transcript: $LOGFILE"

case "$COMMAND" in
  audit)
    audit
    ;;
  clean)
    confirm "Run low-risk cleanup?" || exit 0
    start_report
    clean_low_risk
    verify
    ;;
  prune-xui-only)
    (( CONFIRM_XUI_ONLY )) || die "Use --confirm-xui-only for this command."
    confirm "Purge known desktop/RDP/printing/mDNS/Node/PM2 stacks, keeping x-ui?" || exit 0
    start_report
    prune_xui_only
    verify
    ;;
  fix-network)
    confirm "Attempt conservative Netplan/systemd-networkd legacy cleanup?" || exit 0
    start_report
    fix_network
    verify
    ;;
  upgrade)
    confirm "Run apt update + normal apt upgrade?" || exit 0
    start_report
    upgrade_system
    verify
    if (( REBOOT_AFTER )); then
      schedule_post_reboot_report
      trap - EXIT
      log "Rebooting; the final before -> after report will be generated automatically after boot."
      if ! systemctl reboot; then
        trap 'finalize_report $?' EXIT
        die "Reboot request failed."
      fi
      exit 0
    fi
    ;;
  verify)
    verify
    ;;
  all)
    (( CONFIRM_XUI_ONLY )) || die "all requires --confirm-xui-only"
    confirm "Run full staged cleanup for an x-ui-only VPS?" || exit 0
    start_report
    audit
    clean_low_risk
    prune_xui_only
    fix_network
    upgrade_system
    verify
    if (( REBOOT_AFTER )); then
      schedule_post_reboot_report
      trap - EXIT
      log "Rebooting; the final before -> after report will be generated automatically after boot."
      if ! systemctl reboot; then
        trap 'finalize_report $?' EXIT
        die "Reboot request failed."
      fi
      exit 0
    else
      warn "Final reboot recommended after upgrade/network cleanup."
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
