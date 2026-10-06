# 客户端远程诊断日志

设置 → Diagnostics →「同步本机日志到 Core」。默认关闭，开关保存在当前客户端的本地偏好中，不影响其他设备。开启后上传新产生的日志；不会回传此前的本地日志文件。本地日志开关和远程同步开关彼此独立。需要同时更新 Core 与 Flutter 客户端。

## Core API

接口前缀为 `/api/v1`，沿用 Core 的访问方式。

- `GET /diagnostics/clients`：返回有保存日志的客户端 ID（`clients` 数组）。
- `GET /diagnostics/clients/{id}/logs`：返回 `client_id` 和 `events`，默认最近 100 条，按接收顺序排列。
- 可选参数：`limit=1..500`、`level=error`、`after=2026-10-06T00:00:00.000Z`。`after` 按客户端记录的 UTC ISO 时间戳筛选，适合各端时钟已同步时使用。
- `POST /diagnostics/clients/{id}/logs`：客户端批量上传，正文为 `{"events":[...]}`；每条至少有 `timestamp`、`event` 字符串。

例：`GET /api/v1/diagnostics/clients/flutter-android-a306/logs?level=error&limit=100`。实际 ID 应从列表接口获取；日志使用本次客户端安装持久保存的随机 ID，不依赖主机名，避免同名 Android 设备混合日志。开启事件同时记录设备名称和 Renderer ID。

## 性能与容量

客户端每 10 秒最多上传 32 条，单次请求超时 4 秒。待传队列最多 256 条，超过容量丢弃最旧记录；超过 3500 字节的单条记录改为省略提示。上传失败保留待传批次，下次重试；重试可能产生重复记录，可用 timestamp 和 sequence 辨认。关闭开关清空待传队列并停止后续上传，已经发出的请求可能仍完成。日志上传请求自身不再进入待传队列。

Core 在数据目录 `client-logs` 下按客户端保存 JSON Lines 文件，每客户端最多保留当前 2 MiB 和上一份 2 MiB 文件，最多 128 个客户端。关闭客户端开关不会删除 Core 已保存的日志。Core 重启后日志仍可查询。

除原有播放、请求和错误日志外：

- `ui.slow_frames`：超过 100 ms 的慢帧，包含构建、光栅化和总耗时；最多每 10 秒报告一次。
- `ui.track_projection`：大型歌曲列表后台排序、筛选和合并展示耗时。
- `ui.error`：界面错误提示，便于提示自动消退后继续排查。
- `client.log.upload_enabled`：客户端 ID、平台、逻辑屏幕尺寸及像素比。

这些指标用于定位瓶颈，不能替代 A306 上的操作延迟和持续播放实测。上传内容经过现有诊断字段脱敏，不包含音乐或封面文件。
