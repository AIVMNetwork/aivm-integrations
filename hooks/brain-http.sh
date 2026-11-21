#!/usr/bin/env bash
# Shared by the hooks (sourced, never run). Two rules for every call that carries the agent key:
#   1. The URL is HTTPS, or plain HTTP only to a canonical loopback host (local dev).
#   2. The key and any request body stay out of curl's argv, where other local accounts can
#      read them through the process table. The header comes from a process-substitution fd
#      (printf is a builtin, so it never appears in argv) and the body comes from stdin.

brain_url_ok() {
  case "$1" in
    https://*) return 0 ;;
    http://*) [[ "${1#http://}" =~ ^(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?(/.*)?$ ]] ;;
    *) return 1 ;;
  esac
}

# brain_curl <curl args...> — adds the Authorization header without putting the key in argv.
brain_curl() {
  curl -H @<(printf 'Authorization: Bearer %s\n' "$AGENT_KEY") "$@"
}
