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

  ssh -p "$remote_port" "$remote_host" "
    mkdir -p '$remote_base/backups' &&
    if [ -d '$remote_base/current' ]; then
      cd '$remote_base' &&
      tar -czf 'backups/$archive_name' current
    fi
  "

  log_info "Backup créé : $remote_base/backups/$archive_name"
}