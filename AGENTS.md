# AGENTS.md

Quick reference for OpenCode sessions working in `iam-deploy/`. This is a deployment/CI repository — no application source code lives here. It contains only the Docker Compose stack and the GitHub Actions workflows that build & push the `iam-server` and `iam-web` images.

---

## Layout

```
iam-deploy/
├── .env / .env.example / .env.production  # compose runtime config and secrets
├── docker-compose.yml                       # production stack (uses prebuilt images)
├── .minimax/skills/deploy-iam/               # local image-transfer deployment skill
├── .github/workflows/
│   ├── build-iam.yml                        # manual image build/push
│   └── nightly.yml                          # daily auto-rebuild
└── README.md
```

The stack pulls **prebuilt images** from GHCR — it does not build `iam-server` or `iam-web` from source. To build images, you must trigger a workflow run (see below).

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

- **`.env` holds runtime configuration, not source builds.** The base Compose file defaults to `main`; the local-transfer deployment script uses an isolated `.iam-images.env` overlay with immutable image tags. If you change `iam-server/` or `iam-web/`, trigger `.github/workflows/build-iam.yml` first.
- **`GITCODE_TOKEN` secret is required** for the workflows to clone `iam-server` and `iam-web` from GitCode. It's referenced as `${{ secrets.GITCODE_TOKEN }}` in the workflow files. Without it, builds fail with auth errors.
- **GHCR auth uses `GITHUB_TOKEN` inside GitHub Actions.** The local-transfer deployment script additionally requires a local `GHCR_TOKEN` with `read:packages`; it is never sent to 215.
- **Deploy to 215 with `.minimax/skills/deploy-iam/scripts/deploy-from-local.sh`.** It waits for GitHub Actions to publish immutable `linux/amd64` images, pulls them to the current machine, transfers a checked archive to 215, then uses `docker load`. It does not let 215 pull from GHCR.
- **`nightly.yml` only builds when there are new commits** (it diffs GitCode refs). It does not push on every run — check the workflow's `commit_changed` job output to confirm a build was triggered.
- **`build-iam.yml` parameters**: `iam_server_ref` and `iam_web_ref` default to `main`; set them to a branch/tag to build from. `push_images=true` is required to publish to GHCR.
