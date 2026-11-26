#!/bin/bash

# État de synchronisation d'un profil : index du NAS, index local, modifications en attente, empreinte locale.
#
# Fichiers locaux (dans .watch/, ignoré par git) :
#   .watch/pending/<profil>         existe = des modifications locales attendent d'être poussées
#   .watch/snapshots/<profil>.list  empreinte des fichiers synchronisés au dernier push/pull réussi
#
# L'empreinte est la liste des fichiers que rsync enverrait (exclusions comprises), avec taille et date.
# Comparer l'empreinte actuelle à celle du dernier push/pull dit si un fichier réellement synchronisé
# a changé, sans contacter le NAS. Un fichier exclu (ex. Cache/) qui change ne modifie donc pas l'empreinte.

STATE_DIR="$SCRIPT_DIR/.watch"
STATE_PENDING_DIR="$STATE_DIR/pending"
STATE_SNAPSHOT_DIR="$STATE_DIR/snapshots"
STATE_LOCAL_FILE="$SCRIPT_DIR/profiles/.sync_state.json"

AUTO_PUSH_MIN_DELAY=5
AUTO_PUSH_DEFAULT_DELAY=10

# Délai d'auto-push d'un profil, affiché sur stdout.
# Codes retour : 0 auto-push actif, 1 auto-push absent ou false, 2 délai invalide (< 5 s ou non entier).
# Usage: profile_auto_push_delay <profile_file>
profile_auto_push_delay() {
  local profile_file="$1"
  local auto delay
  auto="$(jq -r '.auto_push // false' "$profile_file")"
  [[ "$auto" == "true" ]] || return 1
  delay="$(jq -r ".auto_push_delay // $AUTO_PUSH_DEFAULT_DELAY" "$profile_file")"
  echo "$delay"
  # Sécurité : un délai trop court ferait un push à chaque frappe, le profil est alors ignoré
  if [[ ! "$delay" =~ ^[0-9]+$ ]] || (( delay < AUTO_PUSH_MIN_DELAY )); then
    return 2
  fi
  return 0
}

# Timestamp du dernier push/pull de ce profil vu par cette machine (0 si jamais).
# Usage: local_state_ts <profile>
local_state_ts() {
  local profile="$1"
  [[ -f "$STATE_LOCAL_FILE" ]] || { echo 0; return 0; }
  jq -r --arg p "$profile" '.[$p] // 0' "$STATE_LOCAL_FILE"
}

# Indique si le NAS a une version plus récente que la dernière vue par cette machine,
# c'est-à-dire qu'une autre machine a poussé depuis notre dernier push/pull.
# Affiche la machine auteur du dernier push sur stdout.
# Codes retour : 0 NAS plus récent, 1 pas plus récent, 2 NAS injoignable.
# Usage: remote_is_newer <remote_host> <remote_port> <remote_base> <profile>
remote_is_newer() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local profile="$4"
  local remote_state_file
  remote_state_file="$(dirname "$remote_base")/.huihuisync_state.json"

  local remote_json
  if ! remote_json="$(ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "cat '$remote_state_file' 2>/dev/null || echo '{}'")"; then
    return 2
  fi
  [[ -z "$remote_json" ]] && remote_json="{}"

  local remote_ts remote_machine local_ts
  remote_ts="$(echo "$remote_json" | jq -r --arg p "$profile" '.[$p].timestamp // 0' 2>/dev/null || echo 0)"
  remote_machine="$(echo "$remote_json" | jq -r --arg p "$profile" '.[$p].machine // "inconnue"' 2>/dev/null || echo inconnue)"
  local_ts="$(local_state_ts "$profile")"

  echo "$remote_machine"
  (( remote_ts > local_ts )) && return 0
  return 1
}

# --- Modifications en attente ---

pending_mark() {
  mkdir -p "$STATE_PENDING_DIR"
  [[ -f "$STATE_PENDING_DIR/$1" ]] || date +%s > "$STATE_PENDING_DIR/$1"
}

pending_clear() {
  rm -f "$STATE_PENDING_DIR/$1"
}

pending_exists() {
  [[ -f "$STATE_PENDING_DIR/$1" ]]
}

# --- Empreinte locale ---

# Écrit sur stdout l'empreinte des fichiers synchronisés par un profil.
# Usage: snapshot_compute <profile_file>
snapshot_compute() {
  local profile_file="$1"
  local sources excludes exclude_args=()
  mapfile -t sources < <(jq -r '.sources[]' "$profile_file")
  mapfile -t excludes < <(jq -r '.exclude[]? // empty' "$profile_file")
  local ex
  for ex in "${excludes[@]}"; do
    exclude_args+=("--exclude=$ex")
  done

  # rsync --list-only affiche "droits taille date heure nom".
  # Pour les dossiers on ne garde que le nom : leur date change dès qu'un fichier (même exclu)
  # y est créé ou supprimé, ce qui ferait croire à une modification.
  local normalize='{
    line = $0
    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ /, "", line)
    if ($1 ~ /^d/) print "d " line; else print $1, $2, $3, $4, line
  }'

  local source
  for source in "${sources[@]}"; do
    source="${source/#\~/$HOME}"
    if [[ -d "$source" ]]; then
      echo "# $source"
      rsync -a --list-only "${exclude_args[@]}" "$source/" 2>/dev/null | awk "$normalize"
    elif [[ -e "$source" ]]; then
      echo "# $source"
      rsync -a --list-only "${exclude_args[@]}" "$source" 2>/dev/null | awk "$normalize"
    else
      echo "# absent $source"
    fi
  done
}

# Calcule l'empreinte actuelle dans <profil>.next (à valider avec snapshot_commit après un sync réussi).
# Usage: snapshot_prepare <profile> <profile_file>
snapshot_prepare() {
  mkdir -p "$STATE_SNAPSHOT_DIR"
  snapshot_compute "$2" > "$STATE_SNAPSHOT_DIR/$1.next"
}

# Usage: snapshot_commit <profile>
snapshot_commit() {
  [[ -f "$STATE_SNAPSHOT_DIR/$1.next" ]] && mv "$STATE_SNAPSHOT_DIR/$1.next" "$STATE_SNAPSHOT_DIR/$1.list"
  return 0
}

# Usage: snapshot_discard <profile>
snapshot_discard() {
  rm -f "$STATE_SNAPSHOT_DIR/$1.next"
}

# Compare l'empreinte actuelle à celle du dernier push/pull.
# Codes retour : 0 modifié, 1 identique, 2 aucune empreinte enregistrée.
# Usage: snapshot_changed <profile> <profile_file>
snapshot_changed() {
  local saved="$STATE_SNAPSHOT_DIR/$1.list"
  [[ -f "$saved" ]] || return 2
  if snapshot_compute "$2" | cmp -s - "$saved"; then
    return 1
  fi
  return 0
}
