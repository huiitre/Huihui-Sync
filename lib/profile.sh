#!/bin/bash

profile_list() {
  local verbose="${1:-false}"

  local profiles_dir="$SCRIPT_DIR/profiles"
  local green='\033[0;32m'
  local red='\033[0;31m'
  local dim='\033[2m'
  local bold='\033[1m'
  local reset='\033[0m'
  local cyan='\033[0;36m'

  local total=0
  local active=0

  echo ""
  printf "${bold}huihuisync${reset}  ${dim}$(whoami)@$(hostname)${reset}\n"
  echo ""

  for profile_file in "$profiles_dir"/*.json; do
    [[ -f "$profile_file" ]] || continue

    local name enabled remote_base backup
    name="$(basename "$profile_file" .json)"
    enabled="$(jq -r '.enabled // false' "$profile_file")"
    remote_base="$(jq -r '.remote_base // "-"' "$profile_file")"
    backup="$(jq -r '.backup // false' "$profile_file")"

    (( total++ )) || true

    if [[ "$enabled" == "true" ]]; then
      (( active++ )) || true
      printf "  ${green}●${reset} %-20s ${dim}%s${reset}" "$name" "$remote_base"
    else
      printf "  ${red}●${reset} %-20s ${dim}%s${reset}" "$name" "$remote_base"
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

  echo ""
  local disabled=$(( total - active ))
  printf "${dim}%d profils — %d actifs · %d désactivé(s)${reset}\n" "$total" "$active" "$disabled"
  echo ""
}