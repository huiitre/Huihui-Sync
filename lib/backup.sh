#!/bin/bash

# Crée un backup du dossier remote courant avant écrasement
# Usage: backup_remote <remote_host> <remote_port> <remote_base> <profile_name>
backup_remote() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local profile_name="$4"
  local date
  date="$(date +%Y%m%d_%H%M%S)"
  local archive_name="${date}_$(hostname)_${profile_name}.tar.gz"

  log_verbose "Création backup : $remote_base/backups/$archive_name"

  ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "
    mkdir -p '$remote_base/backups' &&
    if [ -d '$remote_base/current' ]; then
      cd '$remote_base' &&
      tar -czf 'backups/$archive_name' current
    fi
  "

  log_info "Backup créé : $remote_base/backups/$archive_name"
  backup_rotate "$remote_host" "$remote_port" "$remote_base"
}

# Nombre d'archives conservées par profil, toutes machines confondues
BACKUP_KEEP=20

# Supprime les archives les plus anciennes au-delà de BACKUP_KEEP.
# Le nom commence par la date (AAAAMMJJ_HHMMSS_...), donc trier par nom revient à trier par date.
# Seuls les fichiers qui ont ce format sont concernés : un fichier déposé à la main n'est jamais supprimé.
# Usage: backup_rotate <remote_host> <remote_port> <remote_base>
backup_rotate() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local removed

  removed="$(ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "
    cd '$remote_base/backups' 2>/dev/null || exit 0
    ls -1 | grep -E '^[0-9]{8}_[0-9]{6}_.*\.tar\.gz\$' | sort -r | tail -n +$(( BACKUP_KEEP + 1 )) | while read -r f; do
      rm -f -- \"\$f\" && echo \"\$f\"
    done
  ")" || { log_error "Rotation des backups impossible : $remote_base/backups"; return 0; }

  if [[ -n "$removed" ]]; then
    log_info "Rotation backups : $(echo "$removed" | wc -l) ancienne(s) archive(s) supprimée(s), $BACKUP_KEEP conservées."
    log_verbose "Archives supprimées : $(echo "$removed" | tr '\n' ' ')"
  fi
}