# AGENTS.md

Quick reference for OpenCode sessions working in `iam-deploy/`. This is a deployment/CI repository — no application source code lives here. It contains only the Docker Compose stack and the GitHub Actions workflows that build & push the `iam-server` and `iam-web` images.

---

## Layout

```
iam-deploy/
├── .env / .env.example / .env.production  # compose runtime config and secrets
├── docker-compose.yml                       # production stack (uses prebuilt images)
├── .minimax/skills/deploy-iam/               # local image-transfer deployment skill (LEGACY)
├── .github/workflows/
│   ├── build-iam.yml                        # manual image build/push to GHCR
│   ├── nightly.yml                          # daily auto-rebuild
│   └── deploy-iam.yml                       # manual deploy to 215 via self-hosted runner
└── README.md
```

There are now three workflow stages:

1. **build-iam.yml** (GitHub-hosted runner) — clones iam-server/iam-web from GitCode, builds `linux/amd64` images, pushes to GHCR.
2. **nightly.yml** (GitHub-hosted runner) — same builder, scheduled daily at 03:00 UTC, only builds when GitCode HEAD changes.
3. **deploy-iam.yml** (self-hosted runner on 215) — pulls the published images, switches `/opt/iam/.iam-images.env` + `/opt/iam/.iam-deploy-images.yml`, restarts iam-server + iam-web, runs health checks, and auto-rolls back on failure.

The stack pulls **prebuilt images** from GHCR — it does not build `iam-server` or `iam-web` from source. To deploy, trigger `build-iam.yml` first, then `deploy-iam.yml` with the resulting `release_tag`.

---

## Essential commands

```bash
# Bring up the production stack using images referenced in .env
docker compose up -d

# Force a rebuild from current image tags in .env (won't build from source)
docker compose pull && docker compose up -d

# Tail logs for a service
docker compose logs -f iam-server

# Tear down
docker compose down
```

---

## Hard-won gotchas

- **`.env` holds runtime configuration, not source builds.** The base Compose file defaults to `main`; both deploy paths use an isolated `.iam-images.env` overlay with immutable image tags. If you change `iam-server/` or `iam-web/`, trigger `.github/workflows/build-iam.yml` first.
- **`GITCODE_TOKEN` secret is required** for the workflows to clone `iam-server` and `iam-web` from GitCode. It's referenced as `${{ secrets.GITCODE_TOKEN }}` in the workflow files. Without it, builds fail with auth errors.
- **`GHCR_TOKEN` and `GHCR_USERNAME` secrets are required by `deploy-iam.yml`.** `GHCR_TOKEN` is a GitHub PAT (or fine-grained token) with `read:packages` scope; `GHCR_USERNAME` is the GitHub login that owns it. `GITHUB_TOKEN` cannot be relied on for cross-package `read:packages` on a self-hosted runner, so we use a dedicated secret. Tokens are written to an ephemeral `DOCKER_CONFIG` and removed at the end of the job.
- **Deploy to 215 with `.github/workflows/deploy-iam.yml`.** It runs on the self-hosted runner registered against this repo on 215 (user `zhangyi`). The runner is **not** in the `docker` group, so every `docker` and `/opt/iam` write goes through `sudo -n`; do not strip the `sudo` prefix.
- **The `deploy-iam.yml` job refuses to start** if there is no currently-healthy iam-server or iam-web container, because it needs a rollback target. If 215 has never been deployed before, seed it once with `.minimax/skills/deploy-iam/scripts/deploy-from-local.sh` (or by hand) to create a baseline overlay under `/opt/iam/.deploy-history/`.
- **Deploy never touches MySQL, Redis, `/opt/iam/docker-compose.yml`, or `/opt/iam/.env`.** It only writes the `.iam-images.env` and `.iam-deploy-images.yml` overlay files and restarts iam-server + iam-web.
- **Health check is mandatory** by default and auto-rolls back on failure. If you must skip it (debugging only), pass `skip_health_check=true`; in that case the job is responsible for cleaning up.
- **`.minimax/skills/deploy-iam/scripts/deploy-from-local.sh` is LEGACY** — kept for the rare case where you need to deploy from a workstation that cannot register as a self-hosted runner. New deploys should use the workflow.
- **`nightly.yml` only builds when there are new commits** (it diffs GitCode refs). It does not push on every run — check the workflow's `commit_changed` job output to confirm a build was triggered.
- **`build-iam.yml` parameters**: `iam_server_ref` and `iam_web_ref` default to `main`; set them to a branch/tag to build from. `push_images=true` is required to publish to GHCR. The `release_tag` printed in the run title is the value you pass to `deploy-iam.yml`.
