#!/usr/bin/env bash
# Prepare a class of the NKP CI/CD bootcamp. Run on JA-Devbox (see prepare-devbox.sh), with gh
# logged in as the lab GitHub account. Safe to re-run: every step skips what already exists, so
# it also adds students to a class that grows.
#
#   ./prep-lab.sh --students 15          users 01..15
#   ./prep-lab.sh --users 03,07          only these
#   ./prep-lab.sh --students 2 --skip-harbor --skip-cluster
#
# Lab (once per HPOC):
#   cluster  On poc237-wl01, two read-only lab shortcuts: every service account may read pods and
#            nodes (bootcamp-pacman-reader), so each student's Pac-Man can show its cloud and zone
#            without a binding per namespace; and the class kubectl login, service account
#            bootcamp-system/bootcamp-student with read-only bootcamp-student-view.
#   harbor   project robot "bootcamp" (push + pull on apps). Asks for the Harbor admin password
#            when it has to create or refresh the robot, so run it from a terminal.
#   lb       warns when the MetalLB pool has fewer free addresses than students.
# Per student ##, in the lab GitHub account:
#   pacman-user##          copy of saintdle/pacman at APP_SHA, upstream workflows and Dependabot
#                          removed, files/build-and-promote.yml added
#   pacman-for-k8s-user##  copy of saintdle/pacman-for-k8s at K8S_SHA, workflows removed,
#                          files/kustomization.yaml as nkp/kustomization.yaml, Actions off
#   deploy key "pacman-pipeline" (write) on the manifests repo, its private half as secret
#   MANIFESTS_DEPLOY_KEY on the app repo
# Class code: the class GitHub token (class/github-token, made by hand, see README), the Harbor
# robot secret and the class kubectl token in one string, class/class-code.txt, which students
# paste into setup-pipeline. class/card.md lists it with the dashboard and the repos.
# class/ holds secrets and is not in git.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
CLASS_DIR=${CLASS_DIR:-$HERE/class}
WL_KUBECONFIG=${WL_KUBECONFIG:-$HOME/.kube/poc237-wl01.conf}
DASHBOARD=https://10.38.237.15/dkp/kommander/dashboard
HARBOR=jaregistry.ntnxlab.local
HARBOR_PROJECT=apps
ROBOT=bootcamp
ROBOT_DAYS=${ROBOT_DAYS:-30}
APP_UPSTREAM=saintdle/pacman
APP_SHA=13f04d6e6aea62f1d32d57d90e4eff786083c02e
K8S_UPSTREAM=saintdle/pacman-for-k8s
K8S_SHA=74ec63c92623a17a960ca52a4a3fed53fe6965b3
KEY_TITLE=pacman-pipeline

users=() skip_harbor=0 skip_cluster=0
while (($#)); do
  case $1 in
    --students) for ((i = 1; i <= $2; i++)); do users+=("$(printf %02d "$i")"); done; shift 2 ;;
    --users) IFS=, read -ra list <<< "$2"; for u in "${list[@]}"; do users+=("$(printf %02d "$((10#$u))")"); done; shift 2 ;;
    --skip-harbor) skip_harbor=1; shift ;;
    --skip-cluster) skip_cluster=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
((${#users[@]})) || { echo "say which students: --students N or --users 01,02 (see --help)" >&2; exit 2; }

ok()   { printf '  ok    %s\n' "$*"; }
did()  { printf '  made  %s\n' "$*"; }
todo() { printf '  todo  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

gh auth status --hostname github.com >/dev/null 2>&1 || { echo "gh is not logged in (see prepare-devbox.sh)" >&2; exit 1; }
OWNER=$(gh api user --jq .login)
mkdir -p "$CLASS_DIR/cache" && chmod 700 "$CLASS_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git_push() {  # dir, repo: push the dir's main branch with gh's login
  git -C "$1" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push -q "https://github.com/$OWNER/$2.git" main
}
kwl() { kubectl --kubeconfig "$WL_KUBECONFIG" "$@"; }

# ---------------------------------------------------------------- lab
lab_cluster() {
  step "Cluster: read access to pods and nodes for every service account"
  kwl apply -f - >/dev/null <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bootcamp-pacman-reader
  labels: {app.kubernetes.io/part-of: nkp-cicd-bootcamp}
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bootcamp-pacman-reader
  labels: {app.kubernetes.io/part-of: nkp-cicd-bootcamp}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: bootcamp-pacman-reader}
subjects:
  - {apiGroup: rbac.authorization.k8s.io, kind: Group, name: "system:serviceaccounts"}
EOF
  ok "clusterrole + clusterrolebinding bootcamp-pacman-reader"

  step "Cluster: read-only class login for the students' kubectl"
  kwl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: bootcamp-system
  labels: {app.kubernetes.io/part-of: nkp-cicd-bootcamp}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: bootcamp-student, namespace: bootcamp-system}
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: bootcamp-student-token
  namespace: bootcamp-system
  annotations: {kubernetes.io/service-account.name: bootcamp-student}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bootcamp-student-view
  labels: {app.kubernetes.io/part-of: nkp-cicd-bootcamp}
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "pods/log", "services", "endpoints", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["source.toolkit.fluxcd.io"]
    resources: ["gitrepositories"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: ["kustomizations"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bootcamp-student-view
  labels: {app.kubernetes.io/part-of: nkp-cicd-bootcamp}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: bootcamp-student-view}
subjects:
  - {kind: ServiceAccount, name: bootcamp-student, namespace: bootcamp-system}
EOF
  for _ in $(seq 1 20); do
    [[ -n $(kwl -n bootcamp-system get secret bootcamp-student-token -o jsonpath='{.data.token}') ]] && break
    sleep 2
  done
  ok "service account bootcamp-system/bootcamp-student, clusterrole bootcamp-student-view (read-only)"
}

lab_lb() {
  step "Load balancer addresses"
  local free
  free=$(kwl -n metallb-system get ipaddresspools.metallb.io -o jsonpath='{range .items[*]}{.status.availableIPv4}{"\n"}{end}' | awk '{s+=$1} END {print s+0}')
  if ((free >= ${#users[@]})); then ok "$free free for ${#users[@]} students"
  else todo "only $free free addresses for ${#users[@]} students: grow the MetalLB pool"; fi
}

robot_file=$CLASS_DIR/harbor-robot.json
robot_works() {
  [[ -s $robot_file ]] || return 1
  local name secret
  name=$(jq -r .name "$robot_file"); secret=$(jq -r .secret "$robot_file")
  curl -sf -o /dev/null -u "$name:$secret" \
    "https://$HARBOR/service/token?service=harbor-registry&scope=repository:$HARBOR_PROJECT/pacman-user01:push,pull"
}
lab_harbor() {
  step "Harbor: push robot for project $HARBOR_PROJECT"
  if robot_works; then ok "$(jq -r .name "$robot_file") works (secret in $robot_file)"; return; fi
  if [[ ! -t 0 ]]; then todo "run from a terminal to create the robot: $0 --users ${users[0]} (asks the Harbor admin password)"; return; fi
  local au pw api existing id body
  read -rp "  Harbor admin user [admin]: " au; au=${au:-admin}
  read -rsp "  Harbor admin password: " pw; echo
  api=(curl -sf -u "$au:$pw" -H 'Content-Type: application/json')
  existing=$("${api[@]}" "https://$HARBOR/api/v2.0/robots?q=name%3D~$ROBOT&page_size=100" \
    | jq -c --arg p "$HARBOR_PROJECT" --arg r "$ROBOT" '[.[] | select(.name | endswith($p + "+" + $r))][0] // empty')
  if [[ -n $existing ]]; then
    id=$(jq -r .id <<< "$existing")
    "${api[@]}" -X PATCH "https://$HARBOR/api/v2.0/robots/$id" -d '{}' \
      | jq --argjson r "$existing" '{name: $r.name, secret: .secret, expires_at: $r.expires_at}' > "$robot_file"
    did "new secret for $(jq -r .name "$robot_file")"
  else
    body=$(jq -n --arg n "$ROBOT" --arg p "$HARBOR_PROJECT" --argjson d "$ROBOT_DAYS" '{
      name: $n, description: "NKP CI/CD bootcamp pipelines", level: "project", duration: $d, disable: false,
      permissions: [{kind: "project", namespace: $p, access: [
        {resource: "repository", action: "push"}, {resource: "repository", action: "pull"}]}]}')
    "${api[@]}" -X POST "https://$HARBOR/api/v2.0/robots" -d "$body" \
      | jq '{name, secret, expires_at}' > "$robot_file"
    did "$(jq -r .name "$robot_file"), expires in $ROBOT_DAYS days"
  fi
  chmod 600 "$robot_file"
  robot_works || { echo "  the robot login does not work; check Harbor" >&2; exit 1; }
}

# ---------------------------------------------------------------- per student
upstream() {  # repo sha -> directory with that commit's files
  local dir=$CLASS_DIR/cache/${1//\//_}-${2::7}
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir.tmp"
    gh api "repos/$1/tarball/$2" | tar -xz -C "$dir.tmp" --strip-components=1
    mv "$dir.tmp" "$dir"
  fi
  printf '%s' "$dir"
}

new_repo() {  # name description source_dir -> creates the repo and pushes one commit
  local name=$1 desc=$2 src=$3 dir=$WORK/$1
  rm -rf "$dir" && cp -a "$src" "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" -c user.name="NKP CI/CD bootcamp" -c user.email="$OWNER@users.noreply.github.com" \
    commit -q -m "$desc [skip ci]"
  gh repo create "$OWNER/$name" --public --description "$desc" >/dev/null
  git_push "$dir" "$name"
}

app_repo() {
  local name=pacman-user$1 src
  if gh api "repos/$OWNER/$name/contents/.github/workflows/build-and-promote.yml" >/dev/null 2>&1; then
    ok "$name"; return
  fi
  gh repo view "$OWNER/$name" >/dev/null 2>&1 && { echo "  $name exists but is not prepared; delete it or fix it by hand" >&2; exit 1; }
  src=$WORK/src-app && rm -rf "$src" && cp -a "$(upstream "$APP_UPSTREAM" "$APP_SHA")" "$src"
  rm -rf "$src/.github/workflows" "$src/.github/dependabot.yml"
  mkdir -p "$src/.github/workflows" && cp "$ROOT/files/build-and-promote.yml" "$src/.github/workflows/"
  new_repo "$name" "Pac-Man for the NKP CI/CD bootcamp (user$1), from $APP_UPSTREAM@${APP_SHA::7}" "$src"
  did "$name"
}

manifests_repo() {
  local name=pacman-for-k8s-user$1 src
  if gh api "repos/$OWNER/$name/contents/nkp/kustomization.yaml" >/dev/null 2>&1; then
    ok "$name"
  else
    gh repo view "$OWNER/$name" >/dev/null 2>&1 && { echo "  $name exists but is not prepared; delete it or fix it by hand" >&2; exit 1; }
    src=$WORK/src-k8s && rm -rf "$src" && cp -a "$(upstream "$K8S_UPSTREAM" "$K8S_SHA")" "$src"
    rm -rf "$src/.github/workflows" "$src/.github/dependabot.yml"
    mkdir -p "$src/nkp" && cp "$ROOT/files/kustomization.yaml" "$src/nkp/kustomization.yaml"
    new_repo "$name" "Pac-Man manifests for the NKP CI/CD bootcamp (user$1), from $K8S_UPSTREAM@${K8S_SHA::7}" "$src"
    did "$name"
  fi
  # The pipeline commits here; nothing should run on GitHub-hosted runners.
  if [[ $(gh api "repos/$OWNER/$name/actions/permissions" --jq .enabled) == true ]]; then
    gh api -X PUT "repos/$OWNER/$name/actions/permissions" -F enabled=false >/dev/null
    did "$name: Actions off"
  fi
}

deploy_key() {
  local app=pacman-user$1 k8s=pacman-for-k8s-user$1 key=$WORK/key-$1 have_key have_secret id
  have_key=$(gh api "repos/$OWNER/$k8s/keys" --jq "[.[] | select(.title == \"$KEY_TITLE\" and .read_only == false)] | length")
  have_secret=$(gh api "repos/$OWNER/$app/actions/secrets" --jq '[.secrets[] | select(.name == "MANIFESTS_DEPLOY_KEY")] | length')
  if ((have_key == 1 && have_secret == 1)); then ok "deploy key + secret"; return; fi
  for id in $(gh api "repos/$OWNER/$k8s/keys" --jq ".[] | select(.title == \"$KEY_TITLE\") | .id"); do
    gh api -X DELETE "repos/$OWNER/$k8s/keys/$id"
  done
  ssh-keygen -q -t ed25519 -N "" -C "$KEY_TITLE-user$1" -f "$key"
  gh repo deploy-key add "$key.pub" -R "$OWNER/$k8s" --allow-write -t "$KEY_TITLE" >/dev/null
  gh secret set MANIFESTS_DEPLOY_KEY -R "$OWNER/$app" < "$key"
  rm -f "$key" "$key.pub"
  did "deploy key on $k8s, secret on $app"
}

# ---------------------------------------------------------------- run
echo "Lab GitHub account: $OWNER; students: ${users[*]}"
((skip_cluster)) || { lab_cluster; lab_lb; }
((skip_harbor)) || lab_harbor
for u in "${users[@]}"; do
  step "user$u"
  app_repo "$u"
  manifests_repo "$u"
  deploy_key "$u"
done

# The class code: the three class logins in one string students paste into setup-pipeline.
step "Class code"
token_file=$CLASS_DIR/github-token code_file=$CLASS_DIR/class-code.txt
kube_token=$(kwl -n bootcamp-system get secret bootcamp-student-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [[ -s $token_file && -s $robot_file && -n $kube_token ]]; then
  printf 'NKPCICD1:%s\n' "$(jq -cn --arg g "$(tr -d '\r\n' < "$token_file")" --arg h "$(jq -r .secret "$robot_file")" \
    --arg k "$kube_token" '{github: $g, harbor: $h, kube: $k}' | base64 -w0)" > "$code_file"
  chmod 600 "$code_file"
  ok "$code_file"
else
  rm -f "$code_file"
  [[ -s $token_file ]] || todo "save the class GitHub token in $token_file (see README), then run this again"
  [[ -s $robot_file ]] || todo "Harbor robot missing: run this again from a terminal"
  [[ -n $kube_token ]] || todo "class kubectl login missing: run this again without --skip-cluster"
fi

card=$CLASS_DIR/card.md
{
  echo "# NKP CI/CD bootcamp: class card ($(date +%F))"
  echo
  echo "- NKP dashboard: $DASHBOARD"
  echo "- Bootcamp repo: https://github.com/$OWNER/nkp-cicd-bootcamp (cloud-init.yaml)"
  if [[ -s $code_file ]]; then
    echo "- Class code (paste into setup-pipeline): \`$(cat "$code_file")\`"
  else
    echo "- Class code: not ready (see the todo lines of prep-lab.sh)"
  fi
  [[ -s $robot_file ]] && echo "- Harbor robot \`$(jq -r .name "$robot_file")\` expires $(date -d "@$(jq -r .expires_at "$robot_file")" +%F)"
  echo
  echo "| Student | App repo | Manifests repo |"
  echo "|---|---|---|"
  # Every student prepared so far, not only this run's.
  for u in $(gh repo list "$OWNER" --limit 500 --json name --jq '.[].name' | sed -n 's/^pacman-user\([0-9][0-9]\)$/\1/p' | sort); do
    echo "| user$u | https://github.com/$OWNER/pacman-user$u | https://github.com/$OWNER/pacman-for-k8s-user$u |"
  done
} > "$card"
chmod 600 "$card"
step "Class card: $card"
