#!/usr/bin/env bash
# Prepare JA-Devbox (Ubuntu 24.04) as the NKP CI/CD bootcamp's instructor machine.
#
#   ./prepare-devbox.sh            install what is missing, then check
#   ./prepare-devbox.sh --check    check only (use after a reboot); exit 1 if anything is missing
#
# Installs, all persistent across reboots:
#   - GitHub CLI `gh` from GitHub's apt repository (signed keyring in /etc/apt/keyrings)
#   - the lab Harbor CA in the system trust store (/usr/local/share/ca-certificates)
# The CA is copied from nai-boot, which already trusts it, and is only installed after it
# verifies Harbor's certificate. Override the source with CA_FILE=/path/to/ca.crt.
#
# The GitHub login itself is left to the instructor (it is their password):
#   gh auth login --hostname github.com --git-protocol https --web --insecure-storage
# --insecure-storage keeps the token in ~/.config/gh/hosts.yml instead of the desktop
# keyring, so scripts over SSH can use it and it survives a reboot without unlocking KWallet.
set -euo pipefail

HARBOR=jaregistry.ntnxlab.local
NAI_BOOT=nutanix@10.38.237.103
NAI_BOOT_CA=/etc/pki/ca-trust/source/anchors/lab-registry-ca.crt
CA_DEST=/usr/local/share/ca-certificates/jaregistry-ca.crt

ok()   { printf '  ok    %s\n' "$*"; }
miss() { printf '  MISS  %s\n' "$*"; missing=1; }

check() {
  missing=0
  echo "Checks"
  if command -v gh >/dev/null; then ok "gh $(gh --version | head -1 | awk '{print $3}')"; else miss "gh not installed"; fi
  if [[ -f /etc/apt/sources.list.d/github-cli.list ]]; then ok "gh apt source (updates with apt)"; else miss "gh apt source"; fi
  if [[ -f $CA_DEST ]]; then ok "Harbor CA in $CA_DEST"; else miss "Harbor CA file"; fi
  if curl -s -o /dev/null --max-time 10 "https://$HARBOR/v2/"; then ok "TLS to $HARBOR trusted"; else miss "TLS to $HARBOR not trusted"; fi
  for t in git jq kubectl python3; do
    if command -v "$t" >/dev/null; then ok "$t"; else miss "$t not installed"; fi
  done
  if [[ -f ~/.kube/poc237-wl01.conf ]]; then ok "kubeconfig poc237-wl01"; else miss "$HOME/.kube/poc237-wl01.conf missing"; fi
  if timeout 8 bash -c '</dev/tcp/github.com/22' 2>/dev/null; then ok "github.com:22 reachable"; else miss "github.com:22 unreachable"; fi
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "gh logged in as $(gh api user --jq .login 2>/dev/null)"
  else
    echo "  todo  gh not logged in yet: gh auth login --hostname github.com --git-protocol https --web --insecure-storage"
  fi
  return $missing
}

install_gh() {
  if command -v gh >/dev/null && [[ -f /etc/apt/sources.list.d/github-cli.list ]]; then return; fi
  echo "Installing gh"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh git jq >/dev/null
}

install_ca() {
  if [[ -f $CA_DEST ]] && curl -s -o /dev/null --max-time 10 "https://$HARBOR/v2/"; then return; fi
  echo "Installing the Harbor CA"
  local tmp; tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  if [[ -n ${CA_FILE:-} ]]; then
    cp "$CA_FILE" "$tmp"
  else
    ssh -o BatchMode=yes "$NAI_BOOT" "sudo cat $NAI_BOOT_CA" > "$tmp"
  fi
  openssl x509 -in "$tmp" -noout -subject -enddate | sed 's/^/        /'
  # Only trust it if it really is the CA that signed Harbor's certificate.
  curl -s -o /dev/null --max-time 10 --cacert "$tmp" "https://$HARBOR/v2/" \
    || { echo "  that file does not verify https://$HARBOR; not installing it" >&2; exit 1; }
  sudo install -m 0644 "$tmp" "$CA_DEST"
  sudo update-ca-certificates >/dev/null
}

if [[ ${1:-} == --check ]]; then
  check
  exit $?
fi

install_gh
install_ca
check
