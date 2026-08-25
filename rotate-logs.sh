#!/usr/bin/env bash
# Daily rotation for server.log.
#
#   ./rotate-logs.sh              rotate now, if there is anything to rotate
#   ./rotate-logs.sh --install    install the launchd agent that runs it daily
#   ./rotate-logs.sh --uninstall  remove the agent
#   ./rotate-logs.sh --status     is the agent loaded, and what is on disk
#
# Rotation is copy-then-truncate, not rename. The server holds server.log open,
# so a rename would leave it writing to the moved inode and no new server.log
# would appear until a restart. start.sh opens the log with >>, which is O_APPEND,
# so truncating in place is safe: the next write lands at the new end of file.
# The cost is a small window between copy and truncate where a line can be lost.
# For a server log that is an acceptable trade; for anything billable it is not.
#
# launchd rather than newsyslog because a user agent needs no root and keeps the
# whole thing inside this directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$ROOT/server.log}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
KEEP_DAYS="${KEEP_DAYS:-14}"
LABEL="com.local-llm-stack.logrotate"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

rotate() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "no log at $LOG_FILE, nothing to do"; return 0
  fi
  if [ ! -s "$LOG_FILE" ]; then
    echo "log is empty, nothing to do"; return 0
  fi

  mkdir -p "$LOG_DIR"
  stamp="$(date +%Y-%m-%d)"
  target="$LOG_DIR/server-${stamp}.log"
  # A second rotation on the same day gets a time suffix rather than clobbering.
  [ -e "$target.gz" ] && target="$LOG_DIR/server-${stamp}-$(date +%H%M%S).log"

  size_before="$(wc -c < "$LOG_FILE" | tr -d ' ')"
  cp "$LOG_FILE" "$target"
  : > "$LOG_FILE"
  gzip -9 "$target"
  echo "rotated ${size_before} bytes into ${target}.gz"

  # Prune by mtime. -mtime +N is "older than N days".
  pruned="$(find "$LOG_DIR" -name 'server-*.log.gz' -type f -mtime +"$KEEP_DAYS" -print -delete 2>/dev/null | wc -l | tr -d ' ')"
  [ "$pruned" -gt 0 ] && echo "pruned $pruned archive(s) older than $KEEP_DAYS days"
  return 0
}

install_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  # Written here rather than committed, because the paths are machine specific.
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ROOT}/rotate-logs.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>0</integer>
    <key>Minute</key><integer>5</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${LOG_DIR}/rotate.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/rotate.log</string>
</dict>
</plist>
PLIST_EOF

  # bootout first so a re-install picks up a changed plist. Ignore the error when
  # nothing is loaded yet.
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "installed $PLIST"
  echo "runs daily at 00:05, keeps ${KEEP_DAYS} days in $LOG_DIR"
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $PLIST (archives in $LOG_DIR were left alone)"
}

status() {
  if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
    echo "agent: loaded"
  else
    echo "agent: not loaded ( ./rotate-logs.sh --install )"
  fi
  [ -f "$LOG_FILE" ] && echo "current: $(wc -c < "$LOG_FILE" | tr -d ' ') bytes"
  if [ -d "$LOG_DIR" ]; then
    n="$(find "$LOG_DIR" -name 'server-*.log.gz' -type f | wc -l | tr -d ' ')"
    echo "archives: $n in $LOG_DIR"
  fi
}

case "${1:-}" in
  --install)   install_agent ;;
  --uninstall) uninstall_agent ;;
  --status)    status ;;
  "")          rotate ;;
  *)           echo "usage: $0 [--install|--uninstall|--status]"; exit 2 ;;
esac
