# Tennis AI

Tennis AI 是一个网球视频分析项目，当前仓库包含：

- 架构与联调文档（`docs/`）
- 后端最小化 smoke 验证脚本（`ai/backend/smoke_api_check.py`）

## 目录结构

```text
.
├── ai/
│   └── backend/
│       └── smoke_api_check.py
└── docs/
    ├── architecture.md
    ├── architecture-overview.md
    └── integration-playbook.md
```

## 快速开始

1. 进入仓库根目录

```bash
cd Tennis-AI
```

2. 运行 smoke 脚本帮助

```bash
python3 ai/backend/smoke_api_check.py --help
```

3. 按联调手册执行最小链路验证

- 参考：`docs/integration-playbook.md`

## GitHub Actions 手动 smoke

仓库内置 `ci` 工作流，支持手动触发真实后端 smoke：

- 必填输入：`base_url`、`actor_key`
- 可选输入：`video_url`（可公网下载的视频 URL）
- 若不提供 `video_url`，工作流会自动使用 `--skip-analysis-upload`，仅检查 health + telemetry
- 产物：`smoke-summary`（`smoke_summary.json`）

## 文档入口

- 文档导航：`docs/architecture.md`
- 架构总览：`docs/architecture-overview.md`
- 联调手册：`docs/integration-playbook.md`

## 说明

当前仓库优先沉淀架构文档与联调基线。后续如接入完整 App/Backend/Phase1 源码，可在此基础上扩展目录与 CI。
