#!/usr/bin/env bash
# Turn a VM from _TEMPLATE_UBUNTU2404 into a bootcamp workstation. Run as root by cloud-init at
# first boot (see cloud-init.yaml); safe to run again by hand: sudo ./setup-workstation.sh
# Log: /var/log/bootcamp-setup.log   Done marker: /var/lib/bootcamp/workstation-ready
#
# Installs Docker (with buildx), git, jq, gh, kubectl; trusts the lab Harbor's CA; adds the
# desktop user to the docker group; pre-pulls the CI image; downloads the pinned GitHub Actions
# runner and its system packages; puts setup-pipeline and cleanup-pipeline on the PATH.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bootcamp.conf
. "$HERE/bootcamp.conf"
export DEBIAN_FRONTEND=noninteractive

[[ $(id -u) == 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
STUDENT=$(getent passwd 1000 | cut -d: -f1)   # the template's desktop user (localadmin)
[[ -n $STUDENT ]] || { echo "no user with uid 1000" >&2; exit 1; }
step() { printf '%s  %s\n' "$(date +%T)" "$*"; }

step "apt sources: GitHub CLI, Kubernetes $KUBECTL_MINOR"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

step "packages"
apt-get update -qq
apt-get install -y -qq docker.io docker-buildx git jq curl gh kubectl >/dev/null

step "Harbor CA, Docker"
install -m 0644 "$HERE/files/harbor-ca.crt" /usr/local/share/ca-certificates/jaregistry-ca.crt
update-ca-certificates >/dev/null 2>&1
systemctl enable --now docker >/dev/null 2>&1
systemctl restart docker   # Docker reads the system trust store at start
usermod -aG docker "$STUDENT"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$HARBOR/v2/" || true)
[[ $code == 401 || $code == 200 ]] || { echo "https://$HARBOR answers $code (000 = TLS or network)" >&2; exit 1; }

step "pre-pull $CI_IMAGE"
docker pull -q "$CI_IMAGE" >/dev/null

step "GitHub Actions runner $RUNNER_VERSION"
mkdir -p /opt/bootcamp
tarball=/opt/bootcamp/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
if ! echo "$RUNNER_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
  curl -fsSL -o "$tarball" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  echo "$RUNNER_SHA256  $tarball" | sha256sum -c --quiet
fi
# The runner's own system packages (its installdependencies.sh needs an unpacked runner)
tmp=$(mktemp -d)
tar -xzf "$tarball" -C "$tmp" ./bin/installdependencies.sh
"$tmp/bin/installdependencies.sh" >/dev/null 2>&1 || true
rm -rf "$tmp"

step "commands"
ln -sf "$HERE/setup-pipeline.sh" /usr/local/bin/setup-pipeline
ln -sf "$HERE/cleanup-pipeline.sh" /usr/local/bin/cleanup-pipeline
cat > /etc/profile.d/bootcamp.sh <<'EOF'
# NKP CI/CD bootcamp: NS, USER_NO, the repo folders, written by setup-pipeline
[ -r "$HOME/.bootcamp.env" ] && . "$HOME/.bootcamp.env"
EOF
# shellcheck disable=SC2016  # written literally, expanded at login
grep -q bootcamp.env "/home/$STUDENT/.bashrc" 2>/dev/null \
  || echo '[ -r "$HOME/.bootcamp.env" ] && . "$HOME/.bootcamp.env"   # NKP CI/CD bootcamp' >> "/home/$STUDENT/.bashrc"
cat > /etc/motd <<EOF

  NKP CI/CD bootcamp workstation. Tools are ready.
  Next: create your NKP project, then run  setup-pipeline

EOF

mkdir -p /var/lib/bootcamp
date -Is > /var/lib/bootcamp/workstation-ready
step "workstation ready"
