# AGENTS.md

Quick reference for OpenCode sessions working in `iam-deploy/`. This is a deployment/CI repository — no application source code lives here. It contains only the Docker Compose stack and the GitHub Actions workflows that build & push the `iam-server` and `iam-web` images.

---

## Layout

```
iam-deploy/
├── .env / .env.example / .env.production  # compose env (image tags, ports, secrets)
├── docker-compose.yml                       # production stack (uses prebuilt images)
├── deploy.sh                                # legacy SSH-based deploy script
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

- **`.env` controls image tags, not source builds.** `IAM_SERVER_IMAGE` and `IAM_WEB_IMAGE` in `.env` must point to GHCR tags like `ghcr.io/yi-nology/iam-server:nightly`. If you change code in `iam-server/`, that image is **not** rebuilt by anything in this repo — you must trigger `.github/workflows/build-iam.yml` first.
- **`GITCODE_TOKEN` secret is required** for the workflows to clone `iam-server` and `iam-web` from GitCode. It's referenced as `${{ secrets.GITCODE_TOKEN }}` in the workflow files. Without it, builds fail with auth errors.
- **GHCR auth uses `GITHUB_TOKEN`** — no extra secret config needed. Do not add a `GHCR_TOKEN`; it will be ignored.
- **`deploy.sh` is a legacy SSH script** that hardcodes `root@10.x.x.x` servers. Don't run it locally — it expects a real multi-host setup. The Docker Compose stack is the supported path.
- **`nightly.yml` only builds when there are new commits** (it diffs GitCode refs). It does not push on every run — check the workflow's `commit_changed` job output to confirm a build was triggered.
- **`build-iam.yml` parameters**: `iam_server_ref` and `iam_web_ref` default to `main`; set them to a branch/tag to build from. `push_images=true` is required to publish to GHCR.
