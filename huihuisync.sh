#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/profile.sh"

# Vérification des dépendances
for dep in rsync ssh jq; do
  command -v "$dep" &>/dev/null || { echo "[huihuisync] Dépendance manquante : $dep"; exit 1; }
done

# Usage
usage() {
  echo "Usage: huihuisync.sh [--verbose] <push|pull> <profile1|all> [profile2...]"
  echo "       huihuisync.sh profile <list|name> [--verbose] [--sync]"
  echo "       huihuisync.sh profile <enable|disable> <name>"
  echo ""
  echo "Commandes :"
  echo "  push/pull        Synchronise les données (local <-> remote)"
  echo "  profile list     Liste tous les profils"
  echo "  profile <name>   Affiche les détails d'un profil spécifique"
  echo "  profile enable   Active un profil"
  echo "  profile disable  Désactive un profil"
  echo ""
  echo "Options :"
  echo "  --verbose        Détails rsync et contenu des profils"
  echo "  --sync           Vérification du statut NAS (Metadata)"
  echo ""
  echo "Exemples :"
  echo "  huihuisync pull all"
  echo "  huihuisync profile list --sync"
  echo "  huihuisync profile gemini-cli disable"
  exit 1
}

# Identifiant unique de la machine
get_machine_id() {
  local machine_id
  if [[ -f /etc/machine-id ]]; then
    machine_id="$(cat /etc/machine-id)"
  else
    machine_id="unknown"
  fi
  echo "$(whoami)@$(hostname)-${machine_id}"
}

# Upload du fichier de profil sur le remote
upload_profile() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local profile_file="$4"
  local machine_id="$5"
  local profile_dir="$remote_base/profiles/$machine_id"

  log_verbose "Upload profil : $profile_file → $remote_host:$profile_dir/"
  ssh -p "$remote_port" "$remote_host" "mkdir -p '$profile_dir'"
  rsync -az \
    -e "ssh -p $remote_port" \
    "$profile_file" \
    "$remote_host:$profile_dir/" >> "$LOG_FILE" 2>&1
  log_info "Profil uploadé : $profile_dir/$(basename "$profile_file")"
}

run_profile() {
  local action="$1"
  local profile="$2"
  local profile_file="$SCRIPT_DIR/profiles/${profile}.json"
  local config_file="$SCRIPT_DIR/config.json"

  log_info "--- Début profil : $profile ---"

  # Vérification des fichiers
  [[ -f "$config_file" ]]  || { log_error "config.json introuvable"; return 1; }
  [[ -f "$profile_file" ]] || { log_error "Profil '$profile' introuvable"; return 1; }

  # Lecture config globale
  local remote_host remote_port lock_timeout
  remote_host="$(jq -r '.remote_host' "$config_file")"
  remote_port="$(jq -r '.remote_port' "$config_file")"
  lock_timeout="$(jq -r '.lock_timeout' "$config_file")"

  # Surcharge par profil si présent
  local profile_host profile_port
  profile_host="$(jq -r '.remote_host // empty' "$profile_file")"
  profile_port="$(jq -r '.remote_port // empty' "$profile_file")"
  [[ -n "$profile_host" ]] && remote_host="$profile_host"
  [[ -n "$profile_port" ]] && remote_port="$profile_port"

  # Vérification enabled
  local enabled
  enabled="$(jq -r '.enabled // false' "$profile_file")"
  if [[ "$enabled" != "true" ]]; then
    log_info "Profil '$profile' désactivé (enabled: false). Ignoré."
    return 0
  fi

  # Lecture profil
  local remote_base backup post_push post_pull
  remote_base="$(jq -r '.remote_base' "$profile_file")"
  backup="$(jq -r '.backup' "$profile_file")"
  post_push="$(jq -r '.post_push // empty' "$profile_file")"
  post_pull="$(jq -r '.post_pull // empty' "$profile_file")"
  
  local sources excludes
  mapfile -t sources < <(jq -r '.sources[]' "$profile_file")
  mapfile -t excludes < <(jq -r '.exclude[] // empty' "$profile_file")

  local lock_file="$remote_base/lock"
  local machine_id
  machine_id="$(get_machine_id)"

  # Validation
  [[ -z "$remote_host" ]] && { log_error "remote_host non configuré"; return 1; }

  log_info "Action : $action | Profil : $profile | Remote : $remote_host:$remote_base"
  
  # Acquire lock
  if ! lock_acquire "$remote_host" "$remote_port" "$lock_file" "$lock_timeout"; then
    log_error "Impossible d'acquérir le lock pour le profil '$profile'"
    return 1
  fi

  local status=0
  case "$action" in
    push)
      [[ "$backup" == "true" ]] && backup_remote "$remote_host" "$remote_port" "$remote_base" "$profile"
      sync_push "$remote_host" "$remote_port" "$remote_base" sources excludes
      status=$?
      if [[ $status -eq 0 ]]; then
        if [[ -n "$post_push" ]]; then
          log_verbose "Exécution post_push : $post_push"
          eval "$post_push"
        fi
        upload_profile "$remote_host" "$remote_port" "$remote_base" "$profile_file" "$machine_id"
        # --- MISE À JOUR STATE CENTRALISÉ ---
        local ts=$(date +%s)
        local remote_state_dir=$(dirname "$remote_base")
        local remote_state_file="$remote_state_dir/.huihuisync_state.json"
        local local_state_file="$SCRIPT_DIR/profiles/.sync_state.json"

        # Update NAS (plus robuste : on met à jour localement puis on écrase le remote)
        log_verbose "Mise à jour index NAS : $remote_state_file"
        
        # 1. On récupère l'état actuel du NAS (ou {} si vide)
        local current_remote_state
        current_remote_state=$(ssh -p "$remote_port" "$remote_host" "cat '$remote_state_file' 2>/dev/null" || echo "{}")
        [[ -z "$current_remote_state" ]] && current_remote_state="{}"
        
        # 2. On le met à jour localement avec jq
        local new_remote_state
        new_remote_state=$(echo "$current_remote_state" | jq -c ".[\"$profile\"] = {\"machine\":\"$machine_id\", \"timestamp\":$ts}")
        
        # 3. On réécrit le fichier sur le NAS
        ssh -p "$remote_port" "$remote_host" "echo '$new_remote_state' > '$remote_state_file'"
        
        # Update Local
        [[ -f "$local_state_file" ]] || echo "{}" > "$local_state_file"
        jq ".[\"$profile\"] = $ts" "$local_state_file" > "$local_state_file.tmp" && mv "$local_state_file.tmp" "$local_state_file"
      fi
      ;;
    pull)
      sync_pull "$remote_host" "$remote_port" "$remote_base" sources excludes
      status=$?
      if [[ $status -eq 0 ]]; then
        if [[ -n "$post_pull" ]]; then
          log_verbose "Exécution post_pull : $post_pull"
          eval "$post_pull"
        fi
        upload_profile "$remote_host" "$remote_port" "$remote_base" "$profile_file" "$machine_id"
        # --- MISE À JOUR STATE CENTRALISÉ ---
        local remote_state_dir=$(dirname "$remote_base")
        local remote_state_file="$remote_state_dir/.huihuisync_state.json"
        local local_state_file="$SCRIPT_DIR/profiles/.sync_state.json"

        log_verbose "Alignement index local depuis NAS"
        local remote_ts=$(ssh -p "$remote_port" "$remote_host" "jq -r '.[\"$profile\"].timestamp // 0' '$remote_state_file' 2>/dev/null || echo 0")
        [[ -f "$local_state_file" ]] || echo "{}" > "$local_state_file"
        jq ".[\"$profile\"] = $remote_ts" "$local_state_file" > "$local_state_file.tmp" && mv "$local_state_file.tmp" "$local_state_file"
      fi
      ;;
  esac
  status=$?

  lock_release "$remote_host" "$remote_port" "$lock_file"
  
  if [[ $status -eq 0 ]]; then
    log_info "--- Fin profil : $profile (OK) ---"
  else
    log_error "--- Fin profil : $profile (ÉCHEC) ---"
  fi
  
  return $status
}

# Parse arguments
VERBOSE=false
SYNC_CHECK=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --sync) SYNC_CHECK=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

[[ ${#ARGS[@]} -lt 1 ]] && usage

# Commande profile
if [[ "${ARGS[0]}" == "profile" ]]; then
  CMD="${ARGS[1]:-}"
  TARGET="${ARGS[2]:-}"
  
  case "$CMD" in
    enable)
      [[ -z "$TARGET" ]] && usage
      profile_set_enabled "$TARGET" "true"
      ;;
    disable)
      [[ -z "$TARGET" ]] && usage
      profile_set_enabled "$TARGET" "false"
      ;;
    list|*)
      # Si c'est 'list' ou un nom de profil
      [[ -z "$CMD" ]] && usage
      profile_list "$CMD" "$VERBOSE" "$SYNC_CHECK"
      ;;
  esac
  exit 0
fi

[[ ${#ARGS[@]} -lt 2 ]] && usage

ACTION="${ARGS[0]}"
PROFILES_ARGS=("${ARGS[@]:1}")
PROFILES=()

# Résolution des profils
for P in "${PROFILES_ARGS[@]}"; do
  if [[ "$P" == "all" ]]; then
    for profile_file in "$SCRIPT_DIR/profiles"/*.json; do
      [[ -f "$profile_file" ]] || continue
      p_name="$(basename "$profile_file" .json)"
      # On ne garde que les actifs pour 'all'
      if [[ "$(jq -r '.enabled // false' "$profile_file")" == "true" ]]; then
        PROFILES+=("$p_name")
      fi
    done
  else
    PROFILES+=("$P")
  fi
done

# Suppression des doublons potentiels et tri
if [[ ${#PROFILES[@]} -gt 0 ]]; then
  mapfile -t PROFILES < <(printf "%s\n" "${PROFILES[@]}" | sort -u)
fi

# Init logs
log_init

GLOBAL_STATUS=0
for P in "${PROFILES[@]}"; do
  run_profile "$ACTION" "$P" || GLOBAL_STATUS=1
done

exit $GLOBAL_STATUS