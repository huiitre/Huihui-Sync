#!/bin/bash

# Variables globales de logging
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
LOG_FILE="$LOG_DIR/huihuisync.log"
VERBOSE=false

# Initialise le dossier de logs
log_init() {
  mkdir -p "$LOG_DIR"
}

# Écrit dans le log et affiche dans le terminal
# Usage: log_info <message>
log_info() {
  local msg="[huihuisync] $1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts $msg" >> "$LOG_FILE"
  echo "$msg"
}

# Écrit uniquement si --verbose
# Usage: log_verbose <message>
log_verbose() {
  local msg="[huihuisync][verbose] $1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts $msg" >> "$LOG_FILE"
  if [[ "$VERBOSE" == true ]]; then
    echo "$msg"
  fi
}

# Écrit une erreur dans le log et affiche dans stderr
# Usage: log_error <message>
log_error() {
  local msg="[huihuisync][error] $1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts $msg" >> "$LOG_FILE"
  echo "$msg" >&2
}