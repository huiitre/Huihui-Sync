#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/sync.sh"

# Vérification des dépendances
for dep in rsync ssh jq; do
  command -v "$dep" &>/dev/null || { echo "[huihuisync] Dépendance manquante : $dep"; exit 1; }
done

# Usage
usage() {
  echo "Usage: huihuisync.sh [--verbose] <push|pull> <profile>"
  echo "       huihuisync.sh push dbeaver"
  echo "       huihuisync.sh --verbose pull dotfiles"
  exit 1
}

# Parse arguments
VERBOSE=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

[[ ${#ARGS[@]} -lt 2 ]] && usage

ACTION="${ARGS[0]}"
PROFILE="${ARGS[1]}"
PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.json"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Init logs
log_init

log_verbose "VERBOSE activé"
log_verbose "Lecture config : $CONFIG_FILE"
log_verbose "Lecture profil : $PROFILE_FILE"

# Vérification des fichiers
[[ -f "$CONFIG_FILE" ]]  || { log_error "config.json introuvable"; exit 1; }
[[ -f "$PROFILE_FILE" ]] || { log_error "Profil '$PROFILE' introuvable"; exit 1; }

# Lecture config globale
REMOTE_HOST="$(jq -r '.remote_host' "$CONFIG_FILE")"
REMOTE_PORT="$(jq -r '.remote_port' "$CONFIG_FILE")"
LOCK_TIMEOUT="$(jq -r '.lock_timeout' "$CONFIG_FILE")"

# Surcharge par profil si présent
PROFILE_HOST="$(jq -r '.remote_host // empty' "$PROFILE_FILE")"
PROFILE_PORT="$(jq -r '.remote_port // empty' "$PROFILE_FILE")"
[[ -n "$PROFILE_HOST" ]] && REMOTE_HOST="$PROFILE_HOST"
[[ -n "$PROFILE_PORT" ]] && REMOTE_PORT="$PROFILE_PORT"

# Vérification enabled
ENABLED="$(jq -r '.enabled // false' "$PROFILE_FILE")"
if [[ "$ENABLED" != "true" ]]; then
  log_info "Profil '$PROFILE' désactivé (enabled: false). Ignoré."
  exit 0
fi

# Lecture profil
REMOTE_BASE="$(jq -r '.remote_base' "$PROFILE_FILE")"
BACKUP="$(jq -r '.backup' "$PROFILE_FILE")"
POST_PUSH="$(jq -r '.post_push // empty' "$PROFILE_FILE")"
POST_PULL="$(jq -r '.post_pull // empty' "$PROFILE_FILE")"
mapfile -t SOURCES < <(jq -r '.sources[]' "$PROFILE_FILE")
mapfile -t EXCLUDES < <(jq -r '.exclude[] // empty' "$PROFILE_FILE")

LOCK_FILE="$REMOTE_BASE/lock"

# Validation
[[ -z "$REMOTE_HOST" ]] && { log_error "remote_host non configuré"; exit 1; }

log_info "Action : $ACTION | Profil : $PROFILE | Remote : $REMOTE_HOST:$REMOTE_BASE"
log_verbose "Port : $REMOTE_PORT | Lock timeout : ${LOCK_TIMEOUT}s | Backup : $BACKUP"
log_verbose "Sources : ${SOURCES[*]}"
[[ ${#EXCLUDES[@]} -gt 0 ]] && log_verbose "Exclusions : ${EXCLUDES[*]}"

# Acquire lock
lock_acquire "$REMOTE_HOST" "$REMOTE_PORT" "$LOCK_FILE" "$LOCK_TIMEOUT" || exit 1

# Cleanup lock en cas d'interruption
trap 'lock_release "$REMOTE_HOST" "$REMOTE_PORT" "$LOCK_FILE"' EXIT

case "$ACTION" in
  push)
    [[ "$BACKUP" == "true" ]] && backup_remote "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_BASE" "$PROFILE"
    sync_push "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_BASE" SOURCES EXCLUDES
    if [[ -n "$POST_PUSH" ]]; then
      log_verbose "Exécution post_push : $POST_PUSH"
      eval "$POST_PUSH"
      log_info "post_push exécuté : $POST_PUSH"
    fi
    ;;
  pull)
    sync_pull "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_BASE" SOURCES EXCLUDES
    if [[ -n "$POST_PULL" ]]; then
      log_verbose "Exécution post_pull : $POST_PULL"
      eval "$POST_PULL"
      log_info "post_pull exécuté : $POST_PULL"
    fi
    ;;
  *)
    usage
    ;;
esac

log_info "Terminé."