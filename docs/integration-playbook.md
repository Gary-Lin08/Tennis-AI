# Tennis AI 联调手册（测试/联调向）

## 1. 目标

本手册用于最小化联调验证：

- 后端是否可用（health）
- 上传分析任务是否可创建
- 任务状态是否推进到终态
- 会话列表与详情是否可回查
- 埋点是否可写入

## 2. 前置条件

- Backend 已启动（`ai/backend/app/main.py`）
- 已配置必要环境变量（至少 Supabase 相关）
- 本地可访问接口地址（默认 `http://127.0.0.1:8000`）
- 准备一个可上传的视频文件（建议短视频）

## 3. 自动化 smoke 脚本

使用仓库内脚本：

- `ai/backend/smoke_api_check.py`

### 3.1 仅接口可用性（不跑上传）

```bash
cd "/Users/kaijunlin/Desktop/Tennis AI Mar19/Tennis AI"
python ai/backend/smoke_api_check.py \
  --base-url "http://127.0.0.1:8000" \
  --actor-key "ios:smoke:player_001" \
  --skip-analysis-upload
```

### 3.2 完整最小链路（推荐）

```bash
cd "/Users/kaijunlin/Desktop/Tennis AI Mar19/Tennis AI"
python ai/backend/smoke_api_check.py \
  --base-url "http://127.0.0.1:8000" \
  --actor-key "ios:smoke:player_001" \
  --video-path "/absolute/path/to/test.mp4" \
  --strict-stage-order \
  --poll-timeout-sec 900 \
  --poll-interval-sec 2
```

### 3.3 输出结果落盘（便于 CI 留档）

```bash
cd "/Users/kaijunlin/Desktop/Tennis AI Mar19/Tennis AI"
python ai/backend/smoke_api_check.py \
  --base-url "http://127.0.0.1:8000" \
  --actor-key "ios:smoke:player_001" \
  --video-path "/absolute/path/to/test.mp4" \
  --summary-out "ai/backend/smoke_summary.json"
```

### 3.4 严格阶段顺序校验（建议在 CI 开启）

添加 `--strict-stage-order` 后，脚本会检查轮询到的 `stage` 是否按预期单调推进：

- `queued -> upload_received -> court_detection -> tracknet -> shot_association -> rally_segmentation -> score_timeline -> export_contract -> db_ingest -> asset_publish -> completed`

如果出现未知 stage 或顺序回退，脚本会直接失败退出。

## 4. 状态推进期望

上传后，`analysis_jobs` 典型阶段推进如下：

- `queued`
- `upload_received`
- `court_detection`
- `tracknet`
- `shot_association`
- `rally_segmentation`
- `score_timeline`
- `export_contract`
- `db_ingest`
- `asset_publish`
- `completed`（最终）

允许的最终状态：

- `completed`
- `partial_failed`（发生降级但有可用结果）
- `failed`（视为 smoke 失败）

## 5. 审查清单（勾选）

- [ ] `GET /healthz` 返回 `status=ok`
- [ ] `POST /telemetry/events` 成功（默认脚本会发 1 条 tap）
- [ ] `POST /analysis/videos` 返回 `job_id`
- [ ] `GET /analysis/jobs/{job_id}` 能轮询到终态
- [ ] 若终态为 `completed/partial_failed`，`GET /sessions?actor_key=...` 有数据
- [ ] `GET /sessions/{session_ref}/detail?actor_key=...` 返回 rallies/shots/bounces/score_timeline

## 6. 常见失败定位

- 上传即失败：检查 `video_path` 是否可读、`/analysis/videos` 路由是否可达
- 长时间不推进：检查后台 worker 或 `process_analysis_job` 是否执行
- 卡在 Phase1：检查 Python 依赖、模型和脚本路径、超时参数
- 列表有会话但详情失败：重点看 `session_ref` 与 `actor_key` 是否一致
- telemetry 失败：检查 endpoint、请求体和后端日志
