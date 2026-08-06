# IAM Deploy

从 GitCode 拉取 [iam-server](https://gitcode.com/yi-nology/iam-server) 和 [iam-web](https://gitcode.com/yi-nology/iam-web) 并通过 GitHub Actions 构建 Docker 镜像。

## GitHub Actions Workflows

### 手动构建 (`build-iam.yml`)

手动触发，可指定分支/tag，选择是否推送镜像到 Registry。

```bash
# 在 GitHub Actions 页面点击 "Run workflow"
# 参数：
#   - iam_server_ref: iam-server 分支/tag，默认 main
#   - iam_web_ref:    iam-web 分支/tag，默认 main
#   - push_images:    是否推送镜像到 Registry
```

### 每日构建 (`nightly.yml`)

每天凌晨 3:00 自动检测 GitCode 仓库是否有新提交，有变更才触发构建，打 `nightly` 标签。

### 部署到 215 (`deploy-iam.yml`) — 推荐

`deploy-iam.yml` 在 215 的 self-hosted runner（用户 `zhangyi`）上运行，直接从 GHCR 拉取镜像并切换 `/opt/iam` 的 overlay，无需本地中转。

**完整发布流程**：

1. 在 GitHub Actions 页面 → `build-iam.yml` → `Run workflow`，勾选 `push_images=true`（默认就是 true），可选 `iam_server_ref` / `iam_web_ref`。
2. 等 build 完成，在 run 详情里看 `run-name` 里的 `release_tag`（形如 `iam-20260806094500-56e8d5b2`）。
3. 在 GitHub Actions 页面 → `deploy-iam.yml` → `Run workflow`，把刚才的 `release_tag` 填进去。
4. workflow 在 215 跑：预检 → 拉镜像 → 切 overlay → 重启 `iam-server` + `iam-web` → 健康检查（最多 60s）→ 失败自动回滚。
5. 部署结果写入 `Summary` 步骤和 215 的 `/opt/iam/.deploy-history/history.log`。

**deploy 参数**：

| 参数 | 必填 | 默认 | 说明 |
|------|------|------|------|
| `release_tag` | 是 | — | build-iam 产生的 immutable tag |
| `iam_server_ref` | 否 | `main` | 仅记录用，build 时已经定 |
| `iam_web_ref` | 否 | `main` | 仅记录用，build 时已经定 |
| `skip_health_check` | 否 | `false` | 调试用，跳过健康检查和回滚 |

**约束**：不会重启 MySQL / Redis、不会改 `docker-compose.yml` 或 `.env`、不会 `docker compose down`、不会删 volumes。失败会自动切回上一个 overlay。

### 旧式部署 (`deploy-from-local.sh`) — 已不推荐

`.minimax/skills/deploy-iam/scripts/deploy-from-local.sh` 仍保留，用于在没有 self-hosted runner 的环境部署。当前 215 runner 状态良好，所有部署请走 `deploy-iam.yml`。

```bash
# 仅在自托管 runner 不可用时使用
GHCR_TOKEN=<read-packages-token> \
  .minimax/skills/deploy-iam/scripts/deploy-from-local.sh \
  --ssh-key ~/.ssh/id_ed25519
```

本机需要 `gh`、Docker、SSH 和 SCP；GitHub CLI 需要能触发并读取 `yi-nology/iam-deploy` 的 Actions run。215 的 SSH host key 必须预先写入本机 `known_hosts`。

## 需要配置的 Secrets

| Secret | 说明 | 用在 |
|--------|------|------|
| `GITCODE_TOKEN` | GitCode 个人访问令牌（仓库读取权限） | `build-iam.yml` / `nightly.yml` 从 GitCode 克隆源码 |
| `GHCR_TOKEN` | GitHub PAT 或 fine-grained token，**需要 `read:packages` scope** | `deploy-iam.yml` 在 215 拉取 GHCR 镜像 |
| `GHCR_USERNAME` | `GHCR_TOKEN` 对应的 GitHub 用户名 | `deploy-iam.yml` 登录 GHCR |

`GITHUB_TOKEN` 在 self-hosted runner 上没有 `read:packages` 跨包权限，所以 `deploy-iam.yml` 必须用专门的 PAT。token 写入 ephemeral `DOCKER_CONFIG`，job 结束自动清理。

## 本地开发

```bash
cp .env.example .env
# 编辑 .env 配置

# 构建并启动
GITCODE_TOKEN=your-token docker compose up -d --build

# 或直接使用已推送的镜像
docker compose up -d
```

访问 http://localhost 即可。

## 项目结构

```
iam-deploy/
├── .github/workflows/
│   ├── build-iam.yml    # 手动构建并推 GHCR
│   ├── nightly.yml      # 每日自动构建
│   └── deploy-iam.yml   # 手动部署到 215（self-hosted runner）
├── docker-compose.yml   # 本地编排
├── .env.example         # 环境变量模板
├── .minimax/skills/deploy-iam/  # 旧式本地中转部署脚本（已不推荐）
└── .gitignore
```
