#!/bin/bash

# Push toutes les sources vers le remote
# Usage: sync_push <remote_host> <remote_port> <remote_base> <sources_array> <excludes_array>
sync_push() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local -n _sources="$4"
  local -n _excludes="$5"

  local exclude_args=()
  for ex in "${_excludes[@]}"; do
    exclude_args+=("--exclude=$ex")
  done

  ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "mkdir -p '$remote_base/current'"

  # Un échec rsync sur une source fait échouer l'ensemble (sinon le push/pull serait marqué réussi)
  local status=0 failed
  for source in "${_sources[@]}"; do
    failed=false
    source="${source/#\~/$HOME}"
    local name
    name="$(basename "$source")"

    log_verbose "rsync push : $source → $remote_host:$remote_base/current/$name"

    if [[ -d "$source" ]]; then
      # Dossier : sync le contenu dans un sous-dossier
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv --delete "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$source/" \
          "$remote_host:$remote_base/current/$name/" 2>&1 | tee -a "$LOG_FILE" || failed=true
      else
        rsync -az --delete "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$source/" \
          "$remote_host:$remote_base/current/$name/" >> "$LOG_FILE" 2>&1 || failed=true
      fi
    elif [[ -f "$source" ]]; then
      # Fichier : copie directement dans current/
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$source" \
          "$remote_host:$remote_base/current/$name" 2>&1 | tee -a "$LOG_FILE" || failed=true
      else
        rsync -az "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$source" \
          "$remote_host:$remote_base/current/$name" >> "$LOG_FILE" 2>&1 || failed=true
      fi
    else
      log_error "Source introuvable : $source"
      continue
    fi

    if [[ "$failed" == true ]]; then
      log_error "Push ÉCHEC : $source → $remote_base/current/$name (détails dans $LOG_FILE)"
      status=1
      continue
    fi
    log_info "Push OK : $source → $remote_base/current/$name"
  done
  return $status
}

# Pull toutes les sources depuis le remote
# Usage: sync_pull <remote_host> <remote_port> <remote_base> <sources_array> <excludes_array>
sync_pull() {
  local remote_host="$1"
  local remote_port="$2"
  local remote_base="$3"
  local -n _sources="$4"
  local -n _excludes="$5"

  local exclude_args=()
  for ex in "${_excludes[@]}"; do
    exclude_args+=("--exclude=$ex")
  done

  # Un échec rsync sur une source fait échouer l'ensemble (sinon le push/pull serait marqué réussi)
  local status=0 failed
  for source in "${_sources[@]}"; do
    failed=false
    source="${source/#\~/$HOME}"
    local name
    name="$(basename "$source")"

    # Détecter si la source remote est un fichier ou un dossier
    local is_dir
    is_dir=$(ssh "${SSH_OPTS[@]}" -p "$remote_port" "$remote_host" "[ -d '$remote_base/current/$name' ] && echo dir || echo file")

    log_verbose "rsync pull : $remote_host:$remote_base/current/$name → $source"

    if [[ "$is_dir" == "dir" ]]; then
      mkdir -p "$source"
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv --delete "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$remote_host:$remote_base/current/$name/" \
          "$source/" 2>&1 | tee -a "$LOG_FILE" || failed=true
      else
        rsync -az --delete "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$remote_host:$remote_base/current/$name/" \
          "$source/" >> "$LOG_FILE" 2>&1 || failed=true
      fi
    else
      mkdir -p "$(dirname "$source")"
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$remote_host:$remote_base/current/$name" \
          "$source" 2>&1 | tee -a "$LOG_FILE" || failed=true
      else
        rsync -az "${exclude_args[@]}" \
          -e "ssh ${SSH_OPTS[*]} -p $remote_port" \
          "$remote_host:$remote_base/current/$name" \
          "$source" >> "$LOG_FILE" 2>&1 || failed=true
      fi
    fi

    if [[ "$failed" == true ]]; then
      log_error "Pull ÉCHEC : $remote_base/current/$name → $source (détails dans $LOG_FILE)"
      status=1
      continue
    fi
    log_info "Pull OK : $remote_base/current/$name → $source"
  done
  return $status
}