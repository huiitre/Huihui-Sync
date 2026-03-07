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

  ssh -p "$remote_port" "$remote_host" "mkdir -p '$remote_base/current'"

  for source in "${_sources[@]}"; do
    source="${source/#\~/$HOME}"
    local name
    name="$(basename "$source")"

    log_verbose "rsync push : $source → $remote_host:$remote_base/current/$name"

    if [[ -d "$source" ]]; then
      # Dossier : sync le contenu dans un sous-dossier
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv --delete "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$source/" \
          "$remote_host:$remote_base/current/$name/" 2>&1 | tee -a "$LOG_FILE"
      else
        rsync -az --delete "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$source/" \
          "$remote_host:$remote_base/current/$name/" >> "$LOG_FILE" 2>&1
      fi
    elif [[ -f "$source" ]]; then
      # Fichier : copie directement dans current/
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$source" \
          "$remote_host:$remote_base/current/$name" 2>&1 | tee -a "$LOG_FILE"
      else
        rsync -az "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$source" \
          "$remote_host:$remote_base/current/$name" >> "$LOG_FILE" 2>&1
      fi
    else
      log_error "Source introuvable : $source"
      continue
    fi

    log_info "Push OK : $source → $remote_base/current/$name"
  done
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

  for source in "${_sources[@]}"; do
    source="${source/#\~/$HOME}"
    local name
    name="$(basename "$source")"

    # Détecter si la source remote est un fichier ou un dossier
    local is_dir
    is_dir=$(ssh -p "$remote_port" "$remote_host" "[ -d '$remote_base/current/$name' ] && echo dir || echo file")

    log_verbose "rsync pull : $remote_host:$remote_base/current/$name → $source"

    if [[ "$is_dir" == "dir" ]]; then
      mkdir -p "$source"
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv --delete "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$remote_host:$remote_base/current/$name/" \
          "$source/" 2>&1 | tee -a "$LOG_FILE"
      else
        rsync -az --delete "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$remote_host:$remote_base/current/$name/" \
          "$source/" >> "$LOG_FILE" 2>&1
      fi
    else
      mkdir -p "$(dirname "$source")"
      if [[ "$VERBOSE" == true ]]; then
        rsync -azv "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$remote_host:$remote_base/current/$name" \
          "$source" 2>&1 | tee -a "$LOG_FILE"
      else
        rsync -az "${exclude_args[@]}" \
          -e "ssh -p $remote_port" \
          "$remote_host:$remote_base/current/$name" \
          "$source" >> "$LOG_FILE" 2>&1
      fi
    fi

    log_info "Pull OK : $remote_base/current/$name → $source"
  done
}