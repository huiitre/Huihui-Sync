#!/bin/bash

# Service d'auto-push : surveille les sources des profils "auto_push": true et les pousse
# quelques secondes après la dernière modification.
#
# Fonctionnement :
#   1. inotifywait signale qu'un fichier a bougé dans une source surveillée.
#   2. On attend "auto_push_delay" secondes sans nouvelle modification (évite un push par frappe).
#   3. On compare l'empreinte locale à celle du dernier push/pull (voir lib/state.sh) : si un fichier
#      réellement synchronisé a changé (les exclusions sont respectées), le profil passe "en attente".
#   4. Tant qu'il est en attente, on lance "huihuisync.sh --auto push <profil>" toutes les
#      "auto_push_delay" secondes jusqu'à ce que ça passe. Un push manuel réussi efface l'attente.
#   5. Si le NAS a une version plus récente (autre machine), le push est refusé : on notifie une fois
#      et on continue de vérifier, sans jamais faire de pull.
#
# Le service ne fait jamais de pull, ni au démarrage ni après.

WATCH_UNIT_NAME="huihuisync-watch.service"
WATCH_UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$WATCH_UNIT_NAME"
# Quand le NAS est plus récent, rien ne change tant que l'utilisateur n'agit pas : on vérifie moins souvent
WATCH_REMOTE_NEWER_RETRY=60
WATCH_EOF_MARK="__huihuisync_inotify_stopped__"
WATCH_EVENTS=(-e close_write -e create -e delete -e moved_to -e moved_from -e attrib)

# Point d'entrée des sous-commandes "huihuisync watch ..."
# Usage: watch_command <install|uninstall|enable|disable|restart|status|run>
watch_command() {
  case "$1" in
    install)   watch_install ;;
    uninstall) watch_uninstall ;;
    enable)    watch_systemctl_installed && systemctl --user enable --now "$WATCH_UNIT_NAME" && log_info "Service watch activé et démarré." ;;
    disable)   watch_systemctl_installed && systemctl --user disable --now "$WATCH_UNIT_NAME" && log_info "Service watch arrêté et désactivé (réactiver : huihuisync watch enable)." ;;
    restart)   watch_systemctl_installed && systemctl --user restart "$WATCH_UNIT_NAME" && log_info "Service watch redémarré." ;;
    status)    watch_status ;;
    run)       watch_run ;;
    *)         usage ;;
  esac
}

# --- Service systemd ---

watch_check_deps() {
  if ! command -v inotifywait &>/dev/null; then
    log_error "inotifywait introuvable. Installer : sudo apt install inotify-tools"
    return 1
  fi
  if ! command -v systemctl &>/dev/null; then
    log_error "systemctl introuvable : le service watch nécessite systemd."
    return 1
  fi
}

watch_systemctl_installed() {
  if [[ ! -f "$WATCH_UNIT_FILE" ]]; then
    log_error "Service watch non installé. Lancer : huihuisync watch install"
    return 1
  fi
}

watch_install() {
  watch_check_deps || return 1
  mkdir -p "$(dirname "$WATCH_UNIT_FILE")"
  cat > "$WATCH_UNIT_FILE" <<EOF
[Unit]
Description=huihuisync : auto-push des profils (auto_push: true)

[Service]
Type=simple
ExecStart=/bin/bash "$SCRIPT_DIR/huihuisync.sh" watch run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$WATCH_UNIT_NAME" || return 1
  log_info "Service watch installé et démarré : $WATCH_UNIT_FILE"
  log_info "Il démarre à chaque ouverture de session. Sans session (NAS, serveur) : sudo loginctl enable-linger $USER"
}

watch_uninstall() {
  if [[ ! -f "$WATCH_UNIT_FILE" ]]; then
    log_info "Service watch déjà absent."
    return 0
  fi
  systemctl --user disable --now "$WATCH_UNIT_NAME" 2>/dev/null
  rm -f "$WATCH_UNIT_FILE"
  systemctl --user daemon-reload
  log_info "Service watch supprimé. Les modifications en attente sont conservées dans $STATE_PENDING_DIR."
}

# Libellé de l'état du service : actif, arrêté, désactivé, non installé.
# systemd est la seule source de vérité (pas de copie de l'état ailleurs).
watch_state_label() {
  if ! command -v systemctl &>/dev/null || [[ ! -f "$WATCH_UNIT_FILE" ]]; then
    echo "non installé"
    return
  fi
  local enabled active
  enabled="$(systemctl --user is-enabled "$WATCH_UNIT_NAME" 2>/dev/null)"
  active="$(systemctl --user is-active "$WATCH_UNIT_NAME" 2>/dev/null)"
  if [[ "$active" == "active" ]]; then
    echo "actif"
  elif [[ "$enabled" == "enabled" ]]; then
    echo "arrêté (activé au démarrage)"
  else
    echo "désactivé"
  fi
}

watch_status() {
  local dim='\033[2m' bold='\033[1m' reset='\033[0m' orange='\033[0;33m' red='\033[0;31m'
  echo ""
  printf "${bold}watch${reset} : %s\n" "$(watch_state_label)"
  [[ -f "$WATCH_UNIT_FILE" ]] && printf "${dim}%s${reset}\n" "$WATCH_UNIT_FILE"
  echo ""

  local profile_file name delay rc found=false
  for profile_file in "$SCRIPT_DIR/profiles"/*.json; do
    [[ -f "$profile_file" ]] || continue
    name="$(basename "$profile_file" .json)"
    rc=0
    delay="$(profile_auto_push_delay "$profile_file")" || rc=$?
    [[ $rc -eq 1 ]] && continue
    found=true
    if [[ "$(jq -r '.enabled // false' "$profile_file")" != "true" ]]; then
      printf "  %-20s ${dim}profil désactivé${reset}\n" "$name"
    elif [[ $rc -eq 2 ]]; then
      printf "  %-20s ${red}ignoré : auto_push_delay=%s (minimum %ss)${reset}\n" "$name" "$delay" "$AUTO_PUSH_MIN_DELAY"
    elif pending_exists "$name"; then
      printf "  %-20s ${orange}en attente depuis %s${reset}\n" "$name" "$(date -d "@$(cat "$STATE_PENDING_DIR/$name")" '+%Y-%m-%d %H:%M:%S')"
    else
      printf "  %-20s ${dim}à jour (délai %ss)${reset}\n" "$name" "$delay"
    fi
  done
  [[ "$found" == false ]] && printf "  ${dim}Aucun profil avec \"auto_push\": true${reset}\n"
  echo ""
}

# --- Boucle du service ---

watch_notify() {
  log_info "$1"
  command -v notify-send &>/dev/null && notify-send -a huihuisync "huihuisync" "$1" 2>/dev/null
  return 0
}

# Compare l'empreinte et met à jour l'état "en attente" d'un profil.
watch_detect() {
  local name="$1"
  local profile_file="$SCRIPT_DIR/profiles/$name.json"
  local rc=0
  snapshot_changed "$name" "$profile_file" || rc=$?
  case $rc in
    0)
      if ! pending_exists "$name"; then
        pending_mark "$name"
        log_info "watch : modifications détectées sur '$name', push en attente."
      fi
      ;;
    1)
      # Fichiers revenus à l'identique du dernier push/pull : plus rien à pousser
      pending_exists "$name" && { pending_clear "$name"; log_info "watch : '$name' identique au dernier push/pull, attente annulée."; }
      ;;
    2)
      # Première surveillance de ce profil : l'état actuel sert de référence
      snapshot_prepare "$name" "$profile_file"
      snapshot_commit "$name"
      log_info "watch : empreinte de référence créée pour '$name'."
      ;;
  esac
}

# Lance un push automatique et notifie seulement quand l'état change.
watch_attempt() {
  local name="$1"
  local rc=0
  "$SCRIPT_DIR/huihuisync.sh" --auto push "$name" || rc=$?
  last_attempt[$name]="$(date +%s)"

  case $rc in
    0)
      [[ -n "${notified[$name]:-}" ]] && watch_notify "'$name' poussé, auto-push rétabli."
      unset 'notified[$name]'
      ;;
    "$RC_REMOTE_NEWER")
      [[ "${notified[$name]:-}" != "$RC_REMOTE_NEWER" ]] && \
        watch_notify "'$name' : le NAS a une version plus récente. Auto-push suspendu, aucun pull fait. Faites un pull (--force pour écraser vos modifications) ou un push --force."
      notified[$name]="$RC_REMOTE_NEWER"
      ;;
    *)
      [[ "${notified[$name]:-}" != "1" ]] && \
        watch_notify "'$name' : push impossible (NAS injoignable ou lock pris). Nouvel essai toutes les ${delay_of[$name]}s."
      notified[$name]=1
      ;;
  esac
}

# Associe un chemin modifié aux profils concernés. Retourne 1 si un profil a été modifié (rechargement).
watch_dispatch() {
  local path="$1" i

  # Profil ajouté ou modifié : on quitte, systemd relance le service avec la nouvelle liste
  if [[ "$path" == "$SCRIPT_DIR/profiles/"*.json && "$(basename "$path")" != .* ]]; then
    log_info "watch : profils modifiés ($path), redémarrage du service."
    return 1
  fi

  for i in "${!rec_src[@]}"; do
    if [[ "$path" == "${rec_src[$i]}" || "$path" == "${rec_src[$i]}/"* ]]; then
      last_event[${rec_owner[$i]}]="$now"
    fi
  done
  for i in "${!flat_src[@]}"; do
    # Source absente au démarrage (dossier pas encore créé) : on accepte aussi son contenu
    if [[ "$path" == "${flat_src[$i]}" || "$path" == "${flat_src[$i]}/"* ]]; then
      last_event[${flat_owner[$i]}]="$now"
    fi
  done
  return 0
}

watch_tick() {
  local name ev interval
  for name in "${watch_profiles[@]}"; do
    ev="${last_event[$name]:-}"
    if [[ -n "$ev" ]]; then
      # Modifications en cours : on attend le calme avant de comparer
      (( now - ev >= delay_of[$name] )) || continue
      unset 'last_event[$name]'
      watch_detect "$name"
      last_attempt[$name]=0
    fi

    if ! pending_exists "$name"; then
      # Attente effacée ailleurs (push manuel, pull --force) : on oublie l'échec notifié
      unset 'notified[$name]'
      continue
    fi

    interval="${delay_of[$name]}"
    if [[ "${notified[$name]:-}" == "$RC_REMOTE_NEWER" ]] && (( interval < WATCH_REMOTE_NEWER_RETRY )); then
      interval=$WATCH_REMOTE_NEWER_RETRY
    fi
    (( now - ${last_attempt[$name]:-0} >= interval )) || continue
    watch_attempt "$name"
  done
}

watch_run() {
  # Le service ne doit pas s'arrêter sur une erreur ponctuelle (jq, réseau...)
  set +e
  watch_check_deps || return 1
  mkdir -p "$STATE_PENDING_DIR" "$STATE_SNAPSHOT_DIR"

  local -a watch_profiles=() rec_src=() rec_owner=() flat_src=() flat_owner=()
  local -a rec_dirs=() flat_dirs=("$SCRIPT_DIR/profiles")
  local -A delay_of=() last_event=() last_attempt=() notified=()
  local now=0

  # 1. Profils à surveiller et chemins à passer à inotifywait
  local profile_file name delay rc source parent
  for profile_file in "$SCRIPT_DIR/profiles"/*.json; do
    [[ -f "$profile_file" ]] || continue
    name="$(basename "$profile_file" .json)"
    [[ "$(jq -r '.enabled // false' "$profile_file")" == "true" ]] || continue
    rc=0
    delay="$(profile_auto_push_delay "$profile_file")" || rc=$?
    [[ $rc -eq 1 ]] && continue
    if [[ $rc -eq 2 ]]; then
      log_error "watch : '$name' ignoré, auto_push_delay=$delay invalide (minimum ${AUTO_PUSH_MIN_DELAY}s)."
      continue
    fi

    watch_profiles+=("$name")
    delay_of[$name]="$delay"

    while IFS= read -r source; do
      source="${source/#\~/$HOME}"
      if [[ -d "$source" ]]; then
        # Dossier : surveillance récursive
        rec_src+=("$source"); rec_owner+=("$name"); rec_dirs+=("$source")
      else
        # Fichier seul : on surveille son dossier parent, car les éditeurs enregistrent en écrivant
        # un fichier temporaire puis en le renommant, ce qui ferait perdre une surveillance du fichier lui-même
        parent="$(dirname "$source")"
        if [[ -d "$parent" ]]; then
          flat_src+=("$source"); flat_owner+=("$name"); flat_dirs+=("$parent")
        else
          log_error "watch : '$name', dossier parent absent, source non surveillée : $source"
        fi
      fi
    done < <(jq -r '.sources[]' "$profile_file")
  done

  mapfile -t rec_dirs < <(printf '%s\n' "${rec_dirs[@]}" | sed '/^$/d' | sort -u)
  mapfile -t flat_dirs < <(printf '%s\n' "${flat_dirs[@]}" | sort -u)

  log_info "watch : démarrage, ${#watch_profiles[@]} profil(s) surveillé(s) : ${watch_profiles[*]:-aucun}"

  # 2. Modifications faites pendant que le service était arrêté (aucun contact avec le NAS ici)
  for name in "${watch_profiles[@]}"; do
    watch_detect "$name"
  done

  # 3. Lecture des événements des deux inotifywait (récursif pour les dossiers, simple pour les parents de fichiers)
  local inotify_pid
  exec 3< <(
    if (( ${#rec_dirs[@]} > 0 )); then
      inotifywait -mrq "${WATCH_EVENTS[@]}" --format '%w%f' "${rec_dirs[@]}" &
    fi
    inotifywait -mq "${WATCH_EVENTS[@]}" --format '%w%f' "${flat_dirs[@]}" &
    # Si l'un s'arrête (limite fs.inotify.max_user_watches atteinte...), on arrête tout pour être relancé
    wait -n
    kill $(jobs -p) 2>/dev/null
    echo "$WATCH_EOF_MARK"
  )
  inotify_pid=$!
  trap 'pkill -P '"$inotify_pid"' 2>/dev/null; kill '"$inotify_pid"' 2>/dev/null' EXIT

  local path last_tick=0
  while true; do
    printf -v now '%(%s)T' -1
    if IFS= read -r -t 1 -u 3 path; then
      if [[ "$path" == "$WATCH_EOF_MARK" ]]; then
        log_error "watch : inotifywait s'est arrêté (limite fs.inotify.max_user_watches ?), redémarrage."
        return 1
      fi
      watch_dispatch "$path" || return 0
    else
      rc=$?
      if (( rc < 128 )); then
        log_error "watch : flux inotifywait fermé, redémarrage."
        return 1
      fi
    fi
    printf -v now '%(%s)T' -1
    if (( now != last_tick )); then
      last_tick=$now
      watch_tick
    fi
  done
}
