# Tennis AI

Tennis AI 是一个面向网球训练场景的视频分析项目，当前仓库包含 iOS 端本地分析、后端接入与离线高精度分析流水线。

## 项目组成

- `Tennis AI/`：SwiftUI iOS 应用（视频导入、端侧推理、回放导出、会话对比、遥测）
- `ai/backend/`：FastAPI + Supabase 侧的接入与运维脚本
- `ai/phase1/`：离线 Python 分析管线（rally/shot/bounce/score 等结构化结果）
- `docs/`：架构与联调文档

## 目录结构

```text
.
├── Tennis AI/                 # iOS app + Core ML assets
├── ai/
│   ├── backend/               # API / telemetry / smoke helpers
│   └── phase1/                # Offline analytics pipeline
└── docs/
    ├── architecture.md
    ├── architecture-overview.md
    └── integration-playbook.md
```

## 快速开始

### 1) iOS 端构建

```bash
xcodebuild -project "Tennis AI/Tennis AI.xcodeproj" \
  -scheme "Tennis AI" \
  -destination "generic/platform=iOS Simulator" \
  build
```

### 2) 后端 smoke 脚本

```bash
python3 ai/backend/smoke_api_check.py --help
```

### 3) 联调入口

- 架构导航：`docs/architecture.md`
- 架构总览：`docs/architecture-overview.md`
- 联调手册：`docs/integration-playbook.md`

## GitHub Actions 手动 Smoke

仓库内置 `ci` 工作流，可手动触发后端最小链路验证。

- 推荐在仓库 Secrets 中配置：
  - `SMOKE_BASE_URL`
  - `SMOKE_ACTOR_KEY`
  - `SMOKE_VIDEO_URL`（可选）
- 手动输入会覆盖 Secrets；留空时自动回退到 Secrets
- 不提供 `video_url` 时，工作流会走 `--skip-analysis-upload`，仅验证 health 与 telemetry
- 产物：`smoke-summary`（`smoke_summary.json`）

## 数据边界

- iOS (`ios.ondevice.v1`) 负责端侧推理与会话摘要同步
- Python Phase1 负责高保真结构化分析（rally/shot/bounce/score）
- 后端负责接入、存储、监控与运维可观测性
