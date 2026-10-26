#!/usr/bin/env bash
# Undo setup-pipeline on this workstation: stop and remove the runner (also in GitHub), log out of
# Harbor and GitHub, remove ~/.bootcamp.env. Your repos and NKP project are left alone: delete the
# GitOps source and the project in the NKP dashboard.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=bootcamp.conf
. "$HERE/bootcamp.conf"
[[ $(id -u) != 0 ]] || { echo "run as yourself, not root" >&2; exit 1; }

RUNNER_DIR=$HOME/actions-runner
if [[ -f $RUNNER_DIR/.runner ]]; then
  url=$(jq -r .gitHubUrl "$RUNNER_DIR/.runner")
  repo=${url#https://github.com/}
  (cd "$RUNNER_DIR" && { sudo ./svc.sh stop >/dev/null 2>&1 || true; sudo ./svc.sh uninstall >/dev/null 2>&1 || true; })
  if tok=$(gh api -X POST "repos/$repo/actions/runners/remove-token" --jq .token 2>/dev/null); then
    (cd "$RUNNER_DIR" && ./config.sh remove --token "$tok" >/dev/null) && echo "  done  runner removed from $repo"
  else
    echo "  todo  remove runner $(hostname) by hand: https://github.com/$repo/settings/actions/runners"
  fi
  rm -rf "$RUNNER_DIR"
fi
docker logout "$HARBOR" >/dev/null 2>&1 && echo "  done  logged out of $HARBOR"
gh auth logout --hostname github.com >/dev/null 2>&1 && echo "  done  logged out of GitHub"
rm -f "$HOME/.bootcamp.env"
echo "  done  ~/.bootcamp.env removed"
