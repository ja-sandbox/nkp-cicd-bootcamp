#!/usr/bin/env bash
# Wire your workstation into the bootcamp pipeline. Run it as yourself (not root), after you have
# created your NKP project pacman-user## and saved its kubeconfig:
#
#   setup-pipeline                         asks for what it needs
#   setup-pipeline --kubeconfig FILE       use this kubeconfig (copied to ~/.kube/config)
#
# Asks for: your user number, the class GitHub token and the Harbor robot secret (both on the
# class card; neither is shown or stored in your shell history).
# Then, skipping whatever is already done:
#   1. checks kubectl reaches the cluster and finds your project namespace (pacman-user##-xxxxx)
#   2. logs gh and git in to GitHub with the class token, and Docker in to Harbor
#   3. clones your two repos to ~/pacman-user## and ~/pacman-for-k8s-user##
#   4. puts your namespace into nkp/kustomization.yaml and pushes it
#   5. registers this VM as the self-hosted runner of pacman-user## and starts it as a service
#   6. writes ~/.bootcamp.env (NS, USER_NO, APP_DIR, K8S_DIR), loaded by every new terminal
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=bootcamp.conf
. "$HERE/bootcamp.conf"

[[ $(id -u) != 0 ]] || { echo "run as yourself, not root (it uses sudo where it must)" >&2; exit 1; }
[[ -f /var/lib/bootcamp/workstation-ready ]] \
  || { echo "the workstation setup has not finished yet: see /var/log/bootcamp-setup.log" >&2; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "this session can't use Docker yet: log out and back in (the docker group was added at first boot)" >&2; exit 1; }

kubeconfig=
while (($#)); do
  case $1 in
    --kubeconfig) kubeconfig=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

ok()   { printf '  ok    %s\n' "$*"; }
did()  { printf '  done  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
fail() { printf '\n  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- who
guess=$(hostname | sed -n 's/^user\([0-9][0-9]\).*/\1/p')
# shellcheck source=/dev/null
[[ -r $HOME/.bootcamp.env ]] && guess=$(. "$HOME/.bootcamp.env" && echo "${USER_NO:-$guess}")
read -rp "Your user number [${guess:-01}]: " no
no=$(printf %02d "$((10#${no:-${guess:-01}}))")
APP=pacman-user$no K8S=pacman-for-k8s-user$no
APP_DIR=$HOME/$APP K8S_DIR=$HOME/$K8S

# ---------------------------------------------------------------- 1. cluster
step "1. Cluster"
if [[ -n $kubeconfig ]]; then
  mkdir -p "$HOME/.kube" && install -m 600 "$kubeconfig" "$HOME/.kube/config"
  did "kubeconfig saved as ~/.kube/config"
fi
kubectl get ns >/dev/null 2>&1 \
  || fail "kubectl can't reach the cluster. Save your kubeconfig from the NKP dashboard, then: setup-pipeline --kubeconfig FILE"
NS=$(kubectl get ns -o name | sed -n "s#^namespace/\(pacman-user$no-[a-z0-9]\{5\}\)\$#\1#p")
case $(printf '%s' "$NS" | grep -c .) in
  1) ok "project namespace $NS" ;;
  0) fail "no namespace pacman-user$no-xxxxx: create the NKP project pacman-user$no on poc237-wl01 first" ;;
  *) fail "several namespaces match pacman-user$no-xxxxx: $(echo "$NS" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------- 2. logins
step "2. Logins"
if gh auth status --hostname github.com >/dev/null 2>&1 && gh api "repos/$OWNER/$APP" --jq .permissions.admin 2>/dev/null | grep -q true; then
  ok "GitHub ($(gh api user --jq .login))"
else
  read -rsp "Class GitHub token: " token; echo
  printf '%s\n' "$token" | gh auth login --hostname github.com --git-protocol https --with-token --insecure-storage 2>/dev/null \
    || printf '%s\n' "$token" | gh auth login --hostname github.com --git-protocol https --with-token
  unset token
  gh api "repos/$OWNER/$APP" --jq .permissions.admin 2>/dev/null | grep -q true \
    || fail "that token can't manage $OWNER/$APP: check it against the class card"
  did "GitHub ($(gh api user --jq .login))"
fi
gh auth setup-git --hostname github.com
git config --global user.name >/dev/null || git config --global user.name "user$no"
git config --global user.email >/dev/null || git config --global user.email "user$no@bootcamp.lab"

if jq -e --arg h "$HARBOR" '.auths[$h]' "$HOME/.docker/config.json" >/dev/null 2>&1; then
  ok "Harbor ($HARBOR)"
else
  read -rsp "Harbor robot secret: " secret; echo
  printf '%s' "$secret" | docker login "$HARBOR" -u "$HARBOR_ROBOT" --password-stdin >/dev/null 2>&1 \
    || fail "Harbor refused $HARBOR_ROBOT with that secret: check it against the class card"
  unset secret
  did "Harbor ($HARBOR_ROBOT)"
fi

# ---------------------------------------------------------------- 3. repos
step "3. Repos"
for pair in "$APP:$APP_DIR" "$K8S:$K8S_DIR"; do
  repo=${pair%%:*} dir=${pair#*:}
  if [[ -d $dir/.git ]]; then
    git -C "$dir" pull -q --ff-only && ok "$dir (pulled)"
  else
    git clone -q "https://github.com/$OWNER/$repo.git" "$dir" && did "$dir"
  fi
done

# ---------------------------------------------------------------- 4. overlay
step "4. NKP overlay"
overlay=$K8S_DIR/nkp/kustomization.yaml
if grep -qx "namespace: $NS" "$overlay"; then
  ok "nkp/kustomization.yaml already says namespace: $NS"
else
  sed -i "s/^namespace: .*/namespace: $NS/" "$overlay"
  git -C "$K8S_DIR" commit -q -am "Point the NKP overlay at namespace $NS"
  git -C "$K8S_DIR" push -q
  did "nkp/kustomization.yaml: namespace: $NS (pushed)"
fi
kubectl kustomize --load-restrictor LoadRestrictionsNone "$K8S_DIR/nkp" >/dev/null \
  && ok "overlay renders ($(kubectl kustomize --load-restrictor LoadRestrictionsNone "$K8S_DIR/nkp" | grep -c '^kind:') objects)"

# ---------------------------------------------------------------- 5. runner
step "5. Runner"
RUNNER_DIR=$HOME/actions-runner
svc=actions.runner.$OWNER-$APP.$(hostname)
online=$(gh api "repos/$OWNER/$APP/actions/runners" --jq "[.runners[] | select(.name == \"$(hostname)\" and .status == \"online\")] | length")
if [[ $online == 1 ]] && systemctl is-active --quiet "$svc"; then
  ok "runner $(hostname) online"
else
  if [[ -f $RUNNER_DIR/.runner ]]; then   # registered before: start over cleanly
    (cd "$RUNNER_DIR" && sudo ./svc.sh stop >/dev/null 2>&1; sudo ./svc.sh uninstall >/dev/null 2>&1) || true
  fi
  rm -rf "$RUNNER_DIR" && mkdir -p "$RUNNER_DIR"
  tar -xzf "/opt/bootcamp/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" -C "$RUNNER_DIR"
  reg=$(gh api -X POST "repos/$OWNER/$APP/actions/runners/registration-token" --jq .token)
  (cd "$RUNNER_DIR" && ./config.sh --unattended --replace --url "https://github.com/$OWNER/$APP" \
    --token "$reg" --name "$(hostname)" --labels "user$no" >/dev/null)
  (cd "$RUNNER_DIR" && sudo ./svc.sh install "$(id -un)" >/dev/null && sudo ./svc.sh start >/dev/null)
  for _ in $(seq 1 20); do
    [[ $(gh api "repos/$OWNER/$APP/actions/runners" --jq "[.runners[] | select(.name == \"$(hostname)\" and .status == \"online\")] | length") == 1 ]] && break
    sleep 3
  done
  systemctl is-active --quiet "$svc" || fail "runner service $svc is not running: sudo journalctl -u $svc"
  did "runner $(hostname) registered to $OWNER/$APP and running as a service"
fi

# ---------------------------------------------------------------- 6. env
cat > "$HOME/.bootcamp.env" <<EOF
# NKP CI/CD bootcamp (written by setup-pipeline)
export USER_NO=$no NS=$NS
export APP_DIR=$APP_DIR K8S_DIR=$K8S_DIR
EOF

cat <<EOF

Done. Open a new terminal (or run: . ~/.bootcamp.env) so \$NS and friends are set.

  Your app repo       https://github.com/$OWNER/$APP
  Your manifests repo https://github.com/$OWNER/$K8S
  The overlay         https://github.com/$OWNER/$K8S/blob/main/nkp/kustomization.yaml
  The pipeline        https://github.com/$OWNER/$APP/blob/main/.github/workflows/build-and-promote.yml
  Your runner         $(hostname), service $svc

Next: add the GitOps source in the NKP dashboard (Projects > pacman-user$no > Continuous Deployment).
EOF
