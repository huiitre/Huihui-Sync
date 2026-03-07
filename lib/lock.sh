#!/bin/bash

# Attend que le lock soit libéré, puis le crée
# Usage: lock_acquire <remote_host> <remote_port> <lock_file> <timeout>
lock_acquire() {
  local remote_host="$1"
  local remote_port="$2"
  local lock_file="$3"
  local timeout="$4"
  local elapsed=0

  log_verbose "Vérification lock : $lock_file"

  while ssh -p "$remote_port" "$remote_host" "[ -f '$lock_file' ]" 2>/dev/null; do
    if (( elapsed >= timeout )); then
      log_error "Timeout : lock présent depuis ${timeout}s sur $lock_file"
      return 1
    fi
    log_info "Lock présent, attente..."
    sleep 2
    (( elapsed += 2 ))
  done

  local lock_dir
  lock_dir="$(dirname "$lock_file")"
  ssh -p "$remote_port" "$remote_host" "mkdir -p '$lock_dir' && echo '$(hostname) $(date +%Y%m%d_%H%M%S)' > '$lock_file'"
  log_verbose "Lock créé : $lock_file"
}

# Supprime le lock
# Usage: lock_release <remote_host> <remote_port> <lock_file>
lock_release() {
  local remote_host="$1"
  local remote_port="$2"
  local lock_file="$3"

  ssh -p "$remote_port" "$remote_host" "rm -f '$lock_file'"
  log_verbose "Lock supprimé : $lock_file"
}