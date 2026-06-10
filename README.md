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

## 需要配置的 Secrets

| Secret | 说明 |
|--------|------|
| `GITCODE_TOKEN` | GitCode 个人访问令牌（仓库读取权限） |

GHCR 登录使用 GitHub 内置的 `GITHUB_TOKEN`，无需额外配置。

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
│   ├── build-iam.yml    # 手动构建
│   └── nightly.yml      # 每日自动构建
├── docker-compose.yml   # 本地编排
├── .env.example         # 环境变量模板
└── .gitignore
```
