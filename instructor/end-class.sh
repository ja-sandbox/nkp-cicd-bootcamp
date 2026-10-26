#!/usr/bin/env bash
# Remove everything a class of the NKP CI/CD bootcamp made. Run on JA-Devbox.
#
#   ./end-class.sh          list what would be removed (changes nothing)
#   ./end-class.sh --yes    remove it
#
# Removes:
#   GitHub   the student repos pacman-user## and pacman-for-k8s-user## (their runners and deploy
#            keys go with them). Needs gh's delete_repo scope: gh auth refresh -s delete_repo
#   NKP      the students' projects (namespace pacman-user##-xxxxx): their apps, disks and load
#            balancer addresses go with them
#   cluster  bootcamp-pacman-reader, bootcamp-student-view and namespace bootcamp-system
#   Harbor   the robot and the apps/pacman-user## images (asks for the Harbor admin password)
#   class/   the class code, GitHub token file, robot secret and card
# Left to the instructor: deleting the user##-ws VMs in Prism Central and the class GitHub token
# (GitHub > Settings > Developer settings > Fine-grained tokens).
# The bootcamp repo and the instructor's own demo (other names) are not touched.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=bootcamp.conf
. "$ROOT/bootcamp.conf"
CLASS_DIR=${CLASS_DIR:-$HERE/class}
WL_KUBECONFIG=${WL_KUBECONFIG:-$HOME/.kube/poc237-wl01.conf}
MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-$HOME/.kube/nkp.conf}
WORKSPACE_NS=kommander-default-workspace

yes=0
case ${1:-} in
  --yes) yes=1 ;;
  "") ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac
run() { if ((yes)); then "$@"; fi; }
item() { if ((yes)); then printf '  gone  %s\n' "$*"; else printf '  would remove  %s\n' "$*"; fi; }
todo() { printf '  todo  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
kwl() { kubectl --kubeconfig "$WL_KUBECONFIG" "$@"; }
kmg() { kubectl --kubeconfig "$MGMT_KUBECONFIG" "$@"; }

((yes)) || echo "Dry run: nothing is changed. Run with --yes to remove."

step "GitHub ($OWNER)"
repos=$(gh repo list "$OWNER" --limit 500 --json name --jq '.[].name' | grep -E '^pacman-(for-k8s-)?user[0-9]{2}$' | sort || true)
if [[ -z $repos ]]; then
  echo "  none"
elif ((yes)) && ! gh auth status --hostname github.com 2>&1 | grep -q delete_repo; then
  todo "gh can't delete repos yet: gh auth refresh -h github.com -s delete_repo, then run this again"
else
  for r in $repos; do run gh repo delete "$OWNER/$r" --yes >/dev/null; item "$OWNER/$r"; done
fi

step "NKP projects"
projects=$(kmg -n "$WORKSPACE_NS" get projects.workspaces.kommander.mesosphere.io -o json \
  | jq -r '.items[] | select(.spec.namespaceName | test("^pacman-user[0-9]{2}-[a-z0-9]{5}$")) | .metadata.name')
if [[ -z $projects ]]; then echo "  none"; fi
for p in $projects; do
  run kmg -n "$WORKSPACE_NS" delete project "$p" --wait=false >/dev/null
  item "project $p"
done

step "Cluster (poc237-wl01)"
for o in clusterrolebinding/bootcamp-pacman-reader clusterrole/bootcamp-pacman-reader \
         clusterrolebinding/bootcamp-student-view clusterrole/bootcamp-student-view namespace/bootcamp-system; do
  if kwl get "$o" >/dev/null 2>&1; then run kwl delete "$o" --wait=false >/dev/null; item "$o"; fi
done

step "Harbor ($HARBOR)"
if ((yes)); then
  if [[ -t 0 ]]; then
    read -rp "  Harbor admin user [admin]: " au; au=${au:-admin}
    read -rsp "  Harbor admin password: " pw; echo
    api=(curl -sf -u "$au:$pw")
    for r in $("${api[@]}" "https://$HARBOR/api/v2.0/projects/$HARBOR_PROJECT/repositories?page_size=100" \
               | jq -r '.[].name' | sed -n "s#^$HARBOR_PROJECT/\(pacman-user[0-9][0-9]\)\$#\1#p"); do
      "${api[@]}" -X DELETE "https://$HARBOR/api/v2.0/projects/$HARBOR_PROJECT/repositories/$r" >/dev/null && item "image $HARBOR_PROJECT/$r"
    done
    for id in $("${api[@]}" "https://$HARBOR/api/v2.0/robots?q=name%3D~bootcamp&page_size=100" \
                | jq -r --arg n "$HARBOR_ROBOT" '.[] | select(.name == $n) | .id'); do
      "${api[@]}" -X DELETE "https://$HARBOR/api/v2.0/robots/$id" >/dev/null && item "robot $HARBOR_ROBOT"
    done
  else
    todo "run from a terminal to remove the Harbor robot and images (asks the Harbor admin password)"
  fi
else
  item "robot $HARBOR_ROBOT and images $HARBOR_PROJECT/pacman-user## (asks the Harbor admin password)"
fi

step "Class files ($CLASS_DIR)"
for f in class-code.txt github-token harbor-robot.json card.md; do
  if [[ -e $CLASS_DIR/$f ]]; then run rm -f "$CLASS_DIR/$f"; item "$f"; fi
done

step "By hand"
echo "  - Prism Central: delete the students' VMs (user##-ws)"
echo "  - GitHub as $OWNER: delete the class fine-grained token (Settings > Developer settings)"
