#!/usr/bin/env bash
# Wire your workstation into the bootcamp pipeline. Run it as yourself (not root) after you have
# created your NKP project pacman-user## in the NKP dashboard:
#
#   setup-pipeline
#
# It asks for your user number and the class code (from the instructor; hidden while you paste).
# Then, skipping whatever is already done:
#   1. logs kubectl (read-only), gh, git and Docker in to the lab
#   2. finds your project namespace (pacman-user##-xxxxx)
#   3. clones your two repos to ~/pacman-user## and ~/pacman-for-k8s-user##
#   4. puts your namespace into nkp/kustomization.yaml and pushes it
#   5. names this VM user##-ws, registers it as the self-hosted runner of pacman-user## and
#      starts the runner as a service
#   6. writes ~/.bootcamp.env (USER_NO, NS, APP_DIR, K8S_DIR), loaded by every new terminal
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=bootcamp.conf
. "$HERE/bootcamp.conf"

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }
[[ $(id -u) != 0 ]] || { echo "run as yourself, not root (it uses sudo where it must)" >&2; exit 1; }
[[ -f /var/lib/bootcamp/workstation-ready ]] \
  || { echo "the workstation setup has not finished yet: see /var/log/bootcamp-setup.log" >&2; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "this session can't use Docker yet: log out and back in (the docker group was added at first boot)" >&2; exit 1; }

ok()   { printf '  ok    %s\n' "$*"; }
did()  { printf '  done  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
fail() { printf '\n  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- who
guess=$(hostname | sed -n 's/^user\([0-9][0-9]\)-ws$/\1/p')
if [[ -r $HOME/.bootcamp.env ]]; then
  # shellcheck source=/dev/null
  guess=$(. "$HOME/.bootcamp.env" && echo "${USER_NO:-$guess}")
fi
read -rp "Your user number${guess:+ [$guess]}: " no
no=${no:-$guess}
[[ $no =~ ^[0-9]{1,2}$ ]] || fail "a user number is one or two digits, like 07"
no=$(printf %02d "$((10#$no))")
APP=pacman-user$no K8S=pacman-for-k8s-user$no WS=user$no-ws
APP_DIR=$HOME/$APP K8S_DIR=$HOME/$K8S

# ---------------------------------------------------------------- 1. logins
step "1. Logins"
kube_ok()   { kubectl get ns >/dev/null 2>&1; }
gh_ok()     { gh api "repos/$OWNER/$APP" --jq .permissions.admin 2>/dev/null | grep -qx true; }
docker_ok() { jq -e --arg h "$HARBOR" '.auths[$h]' "$HOME/.docker/config.json" >/dev/null 2>&1; }
if kube_ok && gh_ok && docker_ok; then
  ok "kubectl, GitHub and Harbor already logged in"
else
  read -rsp "Class code: " code; echo
  code=${code//[[:space:]]/}
  [[ $code == NKPCICD1:* ]] || fail "that is not a class code (it starts with NKPCICD1:)"
  json=$(printf '%s' "${code#NKPCICD1:}" | base64 -d 2>/dev/null) || fail "the class code is damaged: paste it again"
  unset code

  kubectl config set-cluster "$(jq -r .name "$HERE/files/cluster.json")" --server "$(jq -r .server "$HERE/files/cluster.json")" >/dev/null
  kubectl config set "clusters.$(jq -r .name "$HERE/files/cluster.json").certificate-authority-data" \
    "$(jq -r .certificateAuthorityData "$HERE/files/cluster.json")" >/dev/null
  kubectl config set-credentials bootcamp-student --token "$(jq -r .kube <<< "$json")" >/dev/null
  kubectl config set-context bootcamp --cluster "$(jq -r .name "$HERE/files/cluster.json")" --user bootcamp-student >/dev/null
  kubectl config use-context bootcamp >/dev/null
  chmod 600 "$HOME/.kube/config"
  kube_ok || fail "the cluster refused the class login: ask the instructor for the current class code"
  did "kubectl (read-only class login to $(jq -r .name "$HERE/files/cluster.json"))"

  jq -r .github <<< "$json" | gh auth login --hostname github.com --git-protocol https --with-token --insecure-storage
  gh_ok || fail "the class GitHub token can't manage $OWNER/$APP: is $APP on the class card?"
  did "GitHub ($(gh api user --jq .login))"

  jq -r .harbor <<< "$json" | docker login "$HARBOR" -u "$HARBOR_ROBOT" --password-stdin >/dev/null 2>&1 \
    || fail "Harbor refused $HARBOR_ROBOT: ask the instructor for the current class code"
  did "Harbor ($HARBOR_ROBOT)"
  unset json
fi
gh auth setup-git --hostname github.com
git config --global user.name >/dev/null || git config --global user.name "user$no"
git config --global user.email >/dev/null || git config --global user.email "user$no@bootcamp.lab"

# ---------------------------------------------------------------- 2. project
step "2. NKP project"
NS=$(kubectl get ns -o name | sed -n "s#^namespace/\(pacman-user$no-[a-z0-9]\{5\}\)\$#\1#p")
case $(printf '%s' "$NS" | grep -c .) in
  1) ok "project namespace $NS" ;;
  0) fail "no namespace pacman-user$no-xxxxx yet: create the project pacman-user$no (cluster poc237-wl01) in the NKP dashboard, then run setup-pipeline again" ;;
  *) fail "several namespaces match pacman-user$no-xxxxx: $(echo "$NS" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------- 3. repos
step "3. Your repos"
for pair in "$APP:$APP_DIR" "$K8S:$K8S_DIR"; do
  repo=${pair%%:*} dir=${pair#*:}
  if [[ -d $dir/.git ]]; then
    git -C "$dir" pull -q --ff-only && ok "$dir"
  else
    git clone -q "https://github.com/$OWNER/$repo.git" "$dir" && did "$dir"
  fi
done

# ---------------------------------------------------------------- 4. overlay
step "4. NKP overlay"
overlay=$K8S_DIR/nkp/kustomization.yaml
if grep -qx "namespace: $NS" "$overlay"; then
  ok "nkp/kustomization.yaml says namespace: $NS"
else
  sed -i "s/^namespace: .*/namespace: $NS/" "$overlay"
  git -C "$K8S_DIR" commit -q -am "Point the NKP overlay at namespace $NS"
  git -C "$K8S_DIR" push -q
  did "nkp/kustomization.yaml: namespace: $NS (pushed)"
fi
n=$(kubectl kustomize --load-restrictor LoadRestrictionsNone "$K8S_DIR/nkp" | grep -c '^kind:')
ok "overlay renders $n objects"

# ---------------------------------------------------------------- 5. runner
step "5. This VM as your runner"
if [[ $(hostname) != "$WS" ]]; then
  old=$(hostname)
  sudo hostnamectl set-hostname "$WS"
  sudo sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts && echo "127.0.1.1 $WS" | sudo tee -a /etc/hosts >/dev/null
  did "hostname $WS (was $old)"
else
  ok "hostname $WS"
fi
RUNNER_DIR=$HOME/actions-runner
svc=actions.runner.$OWNER-$APP.$WS
runner_online() {
  [[ $(gh api "repos/$OWNER/$APP/actions/runners" --jq "[.runners[] | select(.name == \"$WS\" and .status == \"online\")] | length") == 1 ]]
}
if runner_online && systemctl is-active --quiet "$svc"; then
  ok "runner $WS online"
else
  if [[ -f $RUNNER_DIR/.runner ]]; then   # registered before (another name or repo): start over
    (cd "$RUNNER_DIR" && sudo ./svc.sh stop >/dev/null 2>&1; sudo ./svc.sh uninstall >/dev/null 2>&1) || true
  fi
  rm -rf "$RUNNER_DIR" && mkdir -p "$RUNNER_DIR"
  tar -xzf "/opt/bootcamp/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" -C "$RUNNER_DIR"
  reg=$(gh api -X POST "repos/$OWNER/$APP/actions/runners/registration-token" --jq .token)
  (cd "$RUNNER_DIR" && ./config.sh --unattended --replace --url "https://github.com/$OWNER/$APP" \
    --token "$reg" --name "$WS" >/dev/null)
  (cd "$RUNNER_DIR" && sudo ./svc.sh install "$(id -un)" >/dev/null 2>&1 && sudo ./svc.sh start >/dev/null)
  for _ in $(seq 1 20); do runner_online && break; sleep 3; done
  systemctl is-active --quiet "$svc" || fail "runner service $svc is not running: sudo journalctl -u $svc"
  did "runner $WS registered to $OWNER/$APP, running as a service"
fi

# ---------------------------------------------------------------- 6. env
cat > "$HOME/.bootcamp.env" <<EOF
# NKP CI/CD bootcamp (written by setup-pipeline)
export USER_NO=$no NS=$NS
export APP_DIR=$APP_DIR K8S_DIR=$K8S_DIR
EOF

cat <<EOF

Ready. Open a new terminal so \$NS, \$APP_DIR and \$K8S_DIR are set.

Next, in the NKP dashboard: Projects > pacman-user$no > Continuous Deployment (CD) > Add GitOps Source
  ID              pacman
  Repository URL  https://github.com/$OWNER/$K8S
  Branch          main
  Path            ./nkp

Then run  pacman-status  to see it deploy and to get the game's address.
EOF
