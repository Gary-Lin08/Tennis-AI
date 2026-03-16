# Models Folder

把你的 Core ML 模型放在这个目录，并确保勾选 `Tennis AI` target。

推荐文件名（按优先顺序）：

1. `TrackNet.mlmodel`
2. `TrackNetTennis.mlmodel`
3. `TennisTrackNet.mlmodel`

说明：

- Xcode 会在构建时自动把 `.mlmodel` 编译为 `.mlmodelc` 并打包进 App。
- App 启动时会从 Bundle 自动加载模型；如果未找到，会在界面显示错误状态并阻止新任务运行。

当前目录已放置：`TrackNet.mlmodel`（由 `TrackNetV2/tf2torch/track.pt` 转换）。
