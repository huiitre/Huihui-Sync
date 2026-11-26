#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/profile.sh"
source "$SCRIPT_DIR/lib/update.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/watch.sh"

# Options ssh communes : on abandonne vite si le NAS ne répond pas
SSH_OPTS=(-o ConnectTimeout=10)

# Codes retour d'un profil (utilisés par le service watch pour savoir quoi notifier)
RC_REMOTE_NEWER=3   # push refusé : le NAS a une version plus récente
RC_LOCAL_PENDING=4  # pull refusé : des modifications locales n'ont pas été poussées

# Vérification des dépendances
for dep in rsync ssh jq; do
  command -v "$dep" &>/dev/null || { echo "[huihuisync] Dépendance manquante : $dep"; exit 1; }
done

# Usage
usage() {
  echo "Usage: huihuisync.sh [--verbose] <push|pull> <profile1|all> [profile2...]"
  echo "       huihuisync.sh profile <list|name> [--verbose] [--sync]"
  echo "       huihuisync.sh profile <enable|disable> <name>"
  echo "       huihuisync.sh watch <install|uninstall|enable|disable|restart|status>"
  echo ""
  echo "Commandes :"
  echo "  push/pull        Synchronise les données (local <-> remote)"
  echo "  profile list     Liste tous les profils"
  echo "  profile <name>   Affiche les détails d'un profil spécifique"
  echo "  profile enable   Active un profil"
  echo "  profile disable  Désactive un profil"
  echo "  watch install    Installe et démarre le service d'auto-push (systemd utilisateur)"
  echo "  watch disable    Arrête le service et le désactive au démarrage"
  echo "  watch enable     Réactive et démarre le service"
  echo "  watch restart    Redémarre le service (après une mise à jour du script)"
  echo "  watch uninstall  Supprime le service"
  echo "  watch status     État du service et profils en attente"
  echo ""
  echo "Options :"
  echo "  --verbose        Détails rsync et contenu des profils"
  echo "  --sync           Vérification du statut NAS (Metadata)"
  echo "  --force          push malgré un NAS plus récent / pull malgré des modifications locales en attente"
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
  ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "mkdir -p '$profile_dir'"
  rsync -az \
    -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
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
  
  local auto_push_on=false
  profile_auto_push_delay "$profile_file" >/dev/null && auto_push_on=true

  # Service watch : si l'empreinte locale n'a pas bougé depuis le dernier push/pull, il n'y a rien à pousser.
  # On s'arrête sans contacter le NAS, pour ne pas faire croire aux autres machines qu'une nouvelle version existe.
  if [[ "$AUTO" == true && "$action" == "push" ]]; then
    local changed_rc=0
    snapshot_changed "$profile" "$profile_file" || changed_rc=$?
    if [[ $changed_rc -eq 1 ]]; then
      pending_clear "$profile"
      log_info "Rien à pousser pour '$profile' (fichiers identiques au dernier push/pull)."
      return 0
    fi
    # Le service ne doit jamais rester bloqué : si le lock est pris, on réessaiera au tour suivant
    lock_timeout=0
  fi

  # Acquire lock
  if ! lock_acquire "$remote_host" "$remote_port" "$lock_file" "$lock_timeout"; then
    log_error "Impossible d'acquérir le lock pour le profil '$profile'"
    return 1
  fi

  local status=0
  case "$action" in
    push)
      # Garde-fou : une autre machine a poussé depuis notre dernier push/pull, on écraserait son travail
      if [[ "$FORCE" != true ]]; then
        local newer_machine newer_rc=0
        newer_machine="$(remote_is_newer "$remote_host" "$remote_port" "$remote_base" "$profile")" || newer_rc=$?
        if [[ $newer_rc -eq 0 ]]; then
          log_error "Push refusé : le NAS a une version plus récente de '$profile' (poussée par $newer_machine). Faites un pull, ou push --force pour l'écraser."
          status=$RC_REMOTE_NEWER
        elif [[ $newer_rc -eq 2 ]]; then
          log_error "NAS injoignable, push de '$profile' annulé."
          status=1
        fi
      fi

      if [[ $status -eq 0 ]]; then
        # Empreinte prise AVANT l'envoi : un fichier modifié pendant le push sera vu comme une nouvelle modification
        [[ "$auto_push_on" == true ]] && snapshot_prepare "$profile" "$profile_file"
        [[ "$backup" == "true" ]] && backup_remote "$remote_host" "$remote_port" "$remote_base" "$profile"
        sync_push "$remote_host" "$remote_port" "$remote_base" sources excludes
        status=$?
      fi
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
        local local_state_file="$STATE_LOCAL_FILE"

        # Update NAS (plus robuste : on met à jour localement puis on écrase le remote)
        log_verbose "Mise à jour index NAS : $remote_state_file"
        
        # 1. On récupère l'état actuel du NAS (ou {} si vide)
        local current_remote_state
        current_remote_state=$(ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "cat '$remote_state_file' 2>/dev/null" || echo "{}")
        [[ -z "$current_remote_state" ]] && current_remote_state="{}"
        
        # 2. On le met à jour localement avec jq
        local new_remote_state
        new_remote_state=$(echo "$current_remote_state" | jq -c ".[\"$profile\"] = {\"machine\":\"$machine_id\", \"timestamp\":$ts}")
        
        # 3. On réécrit le fichier sur le NAS
        ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "echo '$new_remote_state' > '$remote_state_file'"
        
        # Update Local
        [[ -f "$local_state_file" ]] || echo "{}" > "$local_state_file"
        jq ".[\"$profile\"] = $ts" "$local_state_file" > "$local_state_file.tmp" && mv "$local_state_file.tmp" "$local_state_file"

        # Push réussi (manuel ou auto) : plus rien en attente, le service arrête de réessayer
        snapshot_commit "$profile"
        pending_clear "$profile"
      else
        snapshot_discard "$profile"
      fi
      ;;
    pull)
      # Garde-fou : le pull (rsync --delete) écraserait des modifications locales pas encore poussées
      if [[ "$FORCE" != true ]]; then
        local local_changed=false
        if pending_exists "$profile"; then
          local_changed=true
        elif [[ "$auto_push_on" == true ]] && snapshot_changed "$profile" "$profile_file"; then
          local_changed=true
        fi
        if [[ "$local_changed" == true ]]; then
          log_error "Pull refusé : '$profile' a des modifications locales pas encore poussées (le pull les écraserait). Faites un push, ou pull --force pour les écraser."
          status=$RC_LOCAL_PENDING
        fi
      fi

      if [[ $status -eq 0 ]]; then
        sync_pull "$remote_host" "$remote_port" "$remote_base" sources excludes
        status=$?
      fi
      if [[ $status -eq 0 ]]; then
        if [[ -n "$post_pull" ]]; then
          log_verbose "Exécution post_pull : $post_pull"
          eval "$post_pull"
        fi
        upload_profile "$remote_host" "$remote_port" "$remote_base" "$profile_file" "$machine_id"
        # --- MISE À JOUR STATE CENTRALISÉ ---
        local remote_state_dir=$(dirname "$remote_base")
        local remote_state_file="$remote_state_dir/.huihuisync_state.json"
        local local_state_file="$STATE_LOCAL_FILE"

        log_verbose "Alignement index local depuis NAS"
        local remote_ts=$(ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "jq -r '.[\"$profile\"].timestamp // 0' '$remote_state_file' 2>/dev/null || echo 0")
        [[ -f "$local_state_file" ]] || echo "{}" > "$local_state_file"
        jq ".[\"$profile\"] = $remote_ts" "$local_state_file" > "$local_state_file.tmp" && mv "$local_state_file.tmp" "$local_state_file"

        # Les fichiers locaux sont maintenant ceux du NAS : nouvelle empreinte de référence.
        # Sans ça, le service watch verrait les fichiers reçus comme des modifications et les repousserait.
        if [[ "$auto_push_on" == true ]]; then
          snapshot_prepare "$profile" "$profile_file"
          snapshot_commit "$profile"
        fi
        pending_clear "$profile"
      fi
      ;;
  esac

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
FORCE=false
AUTO=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --sync) SYNC_CHECK=true ;;
    --force) FORCE=true ;;
    # Interne : appel par le service watch (pas de lock bloquant, pas de saisie de mot de passe ssh)
    --auto) AUTO=true; SSH_OPTS+=(-o BatchMode=yes) ;;
    *) ARGS+=("$arg") ;;
  esac
done

[[ ${#ARGS[@]} -lt 1 ]] && usage

# Vérification des mises à jour (pas depuis le service watch : personne pour lire le message)
if [[ "$AUTO" != true && "${ARGS[0]}" != "watch" ]]; then
  update_check "$SCRIPT_DIR"
fi

# Commande watch
if [[ "${ARGS[0]}" == "watch" ]]; then
  log_init
  watch_command "${ARGS[1]:-status}"
  exit $?
fi

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
  run_profile "$ACTION" "$P" || GLOBAL_STATUS=$?
done

exit $GLOBAL_STATUS