#!/bin/bash

profile_list() {
  local filter="${1:-list}"
  local verbose="${2:-false}"
  local sync_check="${3:-false}"

  local profiles_dir="$SCRIPT_DIR/profiles"
  local local_state_file="$SCRIPT_DIR/profiles/.sync_state.json"
  local config_file="$SCRIPT_DIR/config.json"

  local green='\033[0;32m'
  local red='\033[0;31m'
  local orange='\033[0;33m'
  local dim='\033[2m'
  local bold='\033[1m'
  local reset='\033[0m'
  local cyan='\033[0;36m'

  local total=0
  local active=0

  # Lecture config globale
  local global_host global_port
  if [[ -f "$config_file" ]]; then
    global_host="$(jq -r '.remote_host // empty' "$config_file")"
    global_port="$(jq -r '.remote_port // "22"' "$config_file")"
  fi

  # Pré-chargement des états si --sync
  declare -A REMOTE_STATES
  if [[ "$sync_check" == true ]]; then
    # On groupe par hôte pour ne faire qu'un appel SSH par serveur
    local hosts=()
    if [[ -n "$global_host" ]]; then hosts+=("$global_host"); fi
    
    # On scanne les profils pour trouver d'autres hôtes
    for p in "$profiles_dir"/*.json; do
      [[ -f "$p" ]] || continue
      local h=$(jq -r '.remote_host // empty' "$p")
      [[ -n "$h" ]] && hosts+=("$h")
    done
    
    # On dédoublonne les hôtes
    mapfile -t hosts < <(printf "%s\n" "${hosts[@]}" | sort -u)

    for h in "${hosts[@]}"; do
      local port="$global_port"
      # On cherche un profil qui utilise cet hôte pour trouver le remote_base
      local sample_base=""
      for p in "$profiles_dir"/*.json; do
        [[ -f "$p" ]] || continue
        if [[ "$(jq -r '.remote_host // empty' "$p")" == "$h" || ( -z "$(jq -r '.remote_host // empty' "$p")" && "$h" == "$global_host" ) ]]; then
          sample_base=$(jq -r '.remote_base' "$p")
          local p_port=$(jq -r '.remote_port // empty' "$p")
          [[ -n "$p_port" ]] && port="$p_port"
          break
        fi
      done

      if [[ -n "$sample_base" ]]; then
        local remote_state_file="$(dirname "$sample_base")/.huihuisync_state.json"
        log_verbose "Récupération index distant ($h)..."
        REMOTE_STATES["$h"]=$(ssh -p "$port" "$h" "cat '$remote_state_file' 2>/dev/null || echo '{}'")
      fi
    done
  fi

  # Chargement état local
  local local_json="{}"
  [[ -f "$local_state_file" ]] && local_json=$(cat "$local_state_file")

  echo ""
  printf "${bold}huihuisync${reset}  ${dim}$(whoami)@$(hostname)${reset}\n"
  echo ""

  for profile_file in "$profiles_dir"/*.json; do
    [[ -f "$profile_file" ]] || continue

    local name
    name="$(basename "$profile_file" .json)"
    
    # Filtre sur le nom
    if [[ "$filter" != "list" && "$filter" != "$name" ]]; then
      continue
    fi

    local enabled remote_base backup
    enabled="$(jq -r '.enabled // false' "$profile_file")"
    remote_base="$(jq -r '.remote_base // "-"' "$profile_file")"
    backup="$(jq -r '.backup // false' "$profile_file")"

    (( total++ )) || true

    local status_info=""
    local dot_color="$green"
    [[ "$enabled" != "true" ]] && dot_color="$red"

    if [[ "$sync_check" == true && "$enabled" == "true" ]]; then
      local remote_host="$global_host"
      local p_host=$(jq -r '.remote_host // empty' "$profile_file")
      [[ -n "$p_host" ]] && remote_host="$p_host"

      if [[ -n "$remote_host" ]]; then
        local local_sync_ts=$(echo "$local_json" | jq -r ".[\"$name\"] // 0")
        local remote_json_data=${REMOTE_STATES["$remote_host"]:-"{}"}
        
        local remote_ts=$(echo "$remote_json_data" | jq -r ".[\"$name\"].timestamp // 0")
        local remote_machine=$(echo "$remote_json_data" | jq -r ".[\"$name\"].machine // \"unknown\"")

        if [[ "$remote_ts" -gt "$local_sync_ts" ]]; then
          status_info=" ${cyan}(UPDATE AVAILABLE: $remote_machine)${reset}"
          dot_color="$orange"
        elif [[ "$remote_ts" -eq 0 ]]; then
          status_info=" ${dim}(NO REMOTE STATE)${reset}"
        else
          status_info=" ${dim}(UP TO DATE)${reset}"
        fi
      fi
    fi

    if [[ "$enabled" == "true" ]]; then
      (( active++ )) || true
      printf "  ${dot_color}●${reset} %-20s ${dim}%-30s${reset}%b" "$name" "$remote_base" "$status_info"
    else
      printf "  ${dot_color}●${reset} %-20s ${dim}%-30s${reset}" "$name" "$remote_base"
    fi

    if [[ "$verbose" == true ]]; then
      local backup_str=""
      [[ "$backup" == "true" ]] && backup_str=" backup ✓"
      printf "${dim}%s${reset}" "$backup_str"
      echo ""
      while IFS= read -r source; do
        printf "    ${dim}↳ %s${reset}\n" "$source"
      done < <(jq -r '.sources[] // empty' "$profile_file")
    else
      echo ""
    fi
  done

  if [[ "$filter" == "list" ]]; then
    echo ""
    local disabled=$(( total - active ))
    printf "${dim}%d profils — %d actifs · %d désactivé(s)${reset}\n" "$total" "$active" "$disabled"
    echo ""
  fi
}

profile_set_enabled() {
  local name="$1"
  local state="$2" # true ou false
  local profile_file="$SCRIPT_DIR/profiles/${name}.json"

  if [[ ! -f "$profile_file" ]]; then
    log_error "Profil '$name' introuvable."
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp)
  if jq ".enabled = $state" "$profile_file" > "$tmp_file"; then
    mv "$tmp_file" "$profile_file"
    local status="activé"
    [[ "$state" == "false" ]] && status="désactivé"
    log_info "Profil '$name' $status avec succès."
  else
    rm -f "$tmp_file"
    log_error "Erreur lors de la modification du profil '$name'."
    return 1
  fi
}
