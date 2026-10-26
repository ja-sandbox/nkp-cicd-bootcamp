# NKP CI/CD bootcamp

Scripts and files for the "CI/CD on Nutanix Kubernetes Platform" lab: Pac-Man built by a
self-hosted GitHub Actions runner on each student's VM, pushed to the lab Harbor, and deployed by
an NKP project's GitOps source (Flux).

Each student `##` gets two repos in this GitHub account, prepared by the instructor:

| Repo | What it holds |
|---|---|
| `pacman-user##` | The app (from [saintdle/pacman](https://github.com/saintdle/pacman)) and the pipeline `.github/workflows/build-and-promote.yml` |
| `pacman-for-k8s-user##` | The Kubernetes manifests (from [saintdle/pacman-for-k8s](https://github.com/saintdle/pacman-for-k8s)) and the NKP overlay `nkp/kustomization.yaml` |

## Files

| Path | Used by | Purpose |
|---|---|---|
| `files/build-and-promote.yml` | `prep-lab.sh` | The pipeline: lint and test, build, push to Harbor, commit the new tag to the manifests repo |
| `files/kustomization.yaml` | `prep-lab.sh` | The NKP overlay: project namespace and image |
| `files/harbor-ca.crt` | student VMs | The lab Harbor's CA certificate (public) |
| `instructor/prepare-devbox.sh` | instructor | Readies the instructor machine (JA-Devbox): `gh`, Harbor CA |
| `instructor/prep-lab.sh` | instructor | Readies a class: cluster read access, Harbor robot, the repos, deploy keys |

## Instructor

On JA-Devbox, in `/lab/nkp-cicd-bootcamp`:

```bash
instructor/prepare-devbox.sh
gh auth login --hostname github.com --git-protocol https --web --insecure-storage
instructor/prep-lab.sh --students 15
```

`prep-lab.sh` asks for the Harbor admin password the first time (to create the robot account) and
writes the class card to `instructor/class/card.md`, which stays out of git.

## Licences

Pac-Man is GPL-3.0 ([saintdle/pacman](https://github.com/saintdle/pacman)); the manifests are
Apache-2.0 ([saintdle/pacman-for-k8s](https://github.com/saintdle/pacman-for-k8s)). The student
repos are unmodified copies apart from the pipeline, the overlay and removed upstream workflows,
and keep their licence files.
