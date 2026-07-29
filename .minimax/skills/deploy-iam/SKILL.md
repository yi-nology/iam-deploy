---
name: deploy-iam
description: Build iam-server and iam-web through the iam-deploy GitHub Actions workflow, pull the published linux/amd64 images to the current machine, transfer them to the 215 environment, and deploy them with Docker Compose. Use for requests to deploy IAM to 215, trigger an IAM build and deployment, transfer IAM images locally, redeploy an IAM release, or roll forward IAM without letting 215 pull from GHCR.
---

# Deploy IAM

Use `scripts/deploy-from-local.sh` for an end-to-end deployment. The script owns the release tag, waits for the matching GitHub Actions run, and transfers the exact two images that were built.

## Required State

- Run from a machine with `gh`, Docker, SSH, SCP, and a Docker daemon.
- Authenticate `gh` to `yi-nology/iam-deploy` with permission to dispatch and read Actions runs.
- Set `GHCR_TOKEN` to a token that can read the two GHCR packages. Set `GHCR_USERNAME` only when the token's GitHub owner cannot be inferred.
- Configure the 215 SSH host key in `~/.ssh/known_hosts`. Pass the deploy key with `--ssh-key` when it is not available through the SSH agent.
- Keep `/opt/iam/.env` and the primary `/opt/iam/docker-compose.yml` on 215 in place. The deployment writes only `.iam-images.env`, `.iam-deploy-images.yml`, and history files under `/opt/iam`.

## Deploy

Run the script from this repository. Use explicit refs when deploying a branch or tag.

```bash
GHCR_TOKEN="$GHCR_TOKEN" \
  .minimax/skills/deploy-iam/scripts/deploy-from-local.sh \
  --server-ref main \
  --web-ref main \
  --ssh-key ~/.ssh/id_ed25519
```

Use `--tag` only to choose the immutable release tag before triggering the build. Do not use a mutable tag such as `main` or `latest`.

## Execution Contract

1. Dispatch `build-iam.yml` with `push_images=true` and a unique `release_tag`.
2. Wait for the GitHub Actions run whose name contains that tag.
3. Pull `ghcr.io/yi-nology/iam-server:<tag>` and `iam-web:<tag>` as `linux/amd64` on the current machine.
4. Export both images in one archive, calculate SHA-256, and upload both files to 215 over SSH.
5. Verify the checksum and load the archive on 215. Do not run `docker login`, `docker pull`, or `docker compose pull` on 215.
6. Run only `iam-server` and `iam-web` with the generated Compose overlay, wait for backend and frontend health checks, and restore the previous image references if the deployment fails.

## Constraints

- Never replace `/opt/iam/docker-compose.yml` or `/opt/iam/.env`; 215 may have environment-specific ports and secrets.
- Never run `docker compose down`, remove Docker volumes, or restart MySQL or Redis as part of this skill.
- Keep the imported image tags immutable. Do not prune images during or immediately after deployment because they are the rollback source.
- Stop before deployment when the GitHub run, local image architecture check, SSH verification, checksum verification, or remote preflight fails.

## Read-Only Checks

To inspect the deployed version without changing state, run:

```bash
ssh root@10.44.129.215 \
  "cat /opt/iam/.iam-images.env && docker compose -f /opt/iam/docker-compose.yml ps"
```
