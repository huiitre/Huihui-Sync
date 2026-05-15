#!/bin/bash

# Vérifie si une mise à jour est disponible sur Git (via ls-remote)
# Intervalle : 1 heure
update_check() {
  local script_dir="$1"
  local state_file="$script_dir/.update_state"
  local check_interval=3600
  local now
  now=$(date +%s)

  # 1. Lire l'état actuel
  local last_check=0
  local remote_hash=""
  if [[ -f "$state_file" ]]; then
    last_check=$(cut -d'|' -f1 "$state_file")
    remote_hash=$(cut -d'|' -f2 "$state_file")
  fi

  # 2. Alerte si mise à jour déjà connue
  local local_hash
  local_hash=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null || echo "unknown")

  if [[ -n "$remote_hash" && "$remote_hash" != "unknown" && "$remote_hash" != "$local_hash" ]]; then
    local yellow='\033[0;33m'
    local reset='\033[0m'
    printf "${yellow}[huihuisync] Mise à jour disponible !${reset}\n"
    printf "${yellow}[huihuisync] Lancez : git -C %s pull${reset}\n\n" "$script_dir"
  fi

  # 3. Check asynchrone si intervalle dépassé
  if (( now - last_check > check_interval )); then
    # Marque immédiatement le check pour éviter les lancements multiples
    echo "$now|$remote_hash" > "$state_file"

    (
      # Récupère le hash de origin/master sans fetch
      local new_hash
      new_hash=$(git -C "$script_dir" ls-remote origin -h refs/heads/master 2>/dev/null | cut -f1)
      if [[ -n "$new_hash" ]]; then
        echo "$now|$new_hash" > "$state_file"
      fi
    ) & disown
  fi
}
