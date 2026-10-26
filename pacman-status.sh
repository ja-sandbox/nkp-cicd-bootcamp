#!/usr/bin/env bash
# Where is my Pac-Man? Shows each command it runs, so you can run them yourself:
# the GitOps source (Flux), the pods, the game's address and running version, the last CI runs.
set -uo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=bootcamp.conf
. "$HERE/bootcamp.conf"
# shellcheck source=/dev/null
[[ -r $HOME/.bootcamp.env ]] && . "$HOME/.bootcamp.env"
[[ -n ${NS:-} ]] || { echo "run setup-pipeline first" >&2; exit 1; }
show() { printf '\n\033[1m$ %s\033[0m\n' "$*"; "$@"; }

show kubectl -n "$NS" get gitrepository,kustomization pacman \
  || echo "  No GitOps source yet: add it in the NKP dashboard (setup-pipeline printed the values)."
show kubectl -n "$NS" get pods
ip=$(kubectl -n "$NS" get svc pacman-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ -n $ip ]]; then
  show curl -s "http://$ip:8080/version"; echo
  version=$(curl -s --max-time 5 "http://$ip:8080/version" | jq -r .version 2>/dev/null)
  printf '\nGame: http://%s:8080   running version: %s\n' "$ip" "${version:-?}"
else
  printf '\nGame: no address yet (pacman-web has no EXTERNAL-IP).\n'
fi
show gh run list -R "$OWNER/pacman-user$USER_NO" -L 3
