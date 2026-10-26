# NKP CI/CD bootcamp

Scripts and files for the "CI/CD on Nutanix Kubernetes Platform" lab: Pac-Man built by a
self-hosted GitHub Actions runner on each student's VM, pushed to the lab Harbor, and deployed by
an NKP project's GitOps source (Flux).

## Student path

1. In Prism Central, deploy a VM `user##-ws` from `_TEMPLATE_UBUNTU2404` and paste
   [`cloud-init.yaml`](cloud-init.yaml) unchanged into **Guest Customization**. The tools are
   installed within a couple of minutes of first boot.
2. In the NKP dashboard, create the project `pacman-user##` on `poc237-wl01`.
3. On the VM (RDP or SSH as `localadmin`), run `setup-pipeline` and give it your user number and
   the class code.
4. In the NKP dashboard, add the GitOps source it prints. `pacman-status` shows the deploy and the
   game's address.
5. Change the game in `~/pacman-user##`, commit and push: the pipeline builds it and Flux deploys
   it. Roll back with `git revert` of the "Deploy pacman" commit in `~/pacman-for-k8s-user##`.

Each student `##` has two repos in this GitHub account, made by the instructor:

| Repo | What it holds |
|---|---|
| `pacman-user##` | The app (from [saintdle/pacman](https://github.com/saintdle/pacman)) and the pipeline `.github/workflows/build-and-promote.yml` |
| `pacman-for-k8s-user##` | The Kubernetes manifests (from [saintdle/pacman-for-k8s](https://github.com/saintdle/pacman-for-k8s)) and the NKP overlay `nkp/kustomization.yaml` |

## Files

| Path | Run by | Purpose |
|---|---|---|
| `cloud-init.yaml` | Prism guest customization | Runs `setup-workstation.sh` from a fixed commit of this repo |
| `setup-workstation.sh` | cloud-init (root) | Docker, git, gh, kubectl, Harbor CA, the CI image, the runner download; log `/var/log/bootcamp-setup.log` |
| `setup-pipeline.sh` | student (`setup-pipeline`) | Hostname, the class logins, the repo clones, the overlay's namespace, the self-hosted runner |
| `pacman-status.sh` | student (`pacman-status`) | GitOps source, pods, game address and version, last CI runs, with the commands it runs |
| `bootcamp.conf` | all scripts | Lab settings: GitHub owner, Harbor, versions |
| `files/build-and-promote.yml` | `prep-lab.sh` | The pipeline: lint and test, build, push to Harbor, commit the new tag to the manifests repo |
| `files/kustomization.yaml` | `prep-lab.sh` | The NKP overlay: project namespace and image |
| `files/harbor-ca.crt`, `files/cluster.json` | student VMs | The lab Harbor's CA; the workload cluster's API address and CA (all public) |
| `instructor/prepare-devbox.sh` | instructor | Readies the instructor machine (JA-Devbox): `gh`, Harbor CA |
| `instructor/prep-lab.sh` | instructor | Readies a class: cluster rules and class login, Harbor robot, the repos, deploy keys, class code |
| `instructor/end-class.sh` | instructor | Removes the class: repos, NKP projects, cluster rules, Harbor robot and images, class files |

## Instructor

On JA-Devbox, in `/lab/nkp-cicd-bootcamp`:

1. Once per machine: `instructor/prepare-devbox.sh`, then
   `gh auth login --hostname github.com --git-protocol https --web --insecure-storage` as the lab
   GitHub account.
2. Once per class, the class GitHub token. As the lab account: **Settings** > **Developer
   settings** > **Personal access tokens** > **Fine-grained tokens** > **Generate new token**;
   resource owner the lab account, an expiry after the class, **All repositories**, and
   **Read and write** on **Contents**, **Actions** and **Administration**. Save it without
   showing it:

   ```bash
   read -rsp "token: " t && printf '%s\n' "$t" > instructor/class/github-token && chmod 600 instructor/class/github-token && unset t
   ```

3. `instructor/prep-lab.sh --students 15` from a terminal. The first run asks for the Harbor
   admin password. It ends with the class card, `instructor/class/card.md`: the class code and
   each student's repos. `instructor/class/` stays out of git.
4. After the class: `instructor/end-class.sh` (dry run), then `instructor/end-class.sh --yes`.

## Licences

Pac-Man is GPL-3.0 ([saintdle/pacman](https://github.com/saintdle/pacman)); the manifests are
Apache-2.0 ([saintdle/pacman-for-k8s](https://github.com/saintdle/pacman-for-k8s)). The student
repos are unmodified copies apart from the pipeline, the overlay and removed upstream workflows,
and keep their licence files.
