# 系统隐藏智能歌单：1.5.0 对接与验证

此文仅记录 1.5.0 历史实现，已被 1.6.0 的[统一集合与可配置首页](collections.md)替代。旧接口与三套歌单模型已删除，当前对接请使用新文档。

## 使用方式

首页“为你整理”提供“今日随听”和“新近入库”。点击卡片先进入详情，只有点击歌曲或“播放全部”才建立队列。详情先完整读取固定批次，再应用全局同名歌曲展示、筛选和排序设置。后台更新只提示“查看新批次”，不会悄悄换掉当前列表或播放队列。

设置 → 系统智能歌单 → 允许管理系统智能歌单（默认关闭）。开启后可编辑筛选条件、结果数量、最近入库天数；今日随听还可限制每位艺术家和每张专辑数量。支持预览和确认恢复默认。规则编辑器从 Core 能力接口读取可用字段和运算符，音乐来源按设备与文件夹名称选择。

管理开关由 Core 持久保存，多端共享；关闭后仍能浏览、播放和换一批。普通歌单列表、搜索、同步和“添加到歌单”不展示这两张系统歌单。用户自己创建的同名歌单仍独立保留。

## 身份、批次与入库时间

- 能力：`GET /status` 的 `capabilities` 包含 `system_smart_playlists_v1`。
- 稳定系统键：`daily_mix`、`recently_added`。名称固定，数字 `playlist_id` 仅供诊断，不作为客户端查找依据。
- 默认结果分别为 30、100 首，结果上限可设为 1～10000；每页最多 200 首。首页每张歌单只返回 6 首预览，规则预览最多返回 50 首。
- `matched_total` 是满足筛选条件的候选总数；`result_total` 是数量与多样性限制后的总数；`tracks.length` 仅为本次返回条数。
- 批次不可变，成员、顺序及摘要由 Core 保存。生成时间、规则版本和随机种子随批次持久保存。翻页须携带首次读取的 `result_version`。
- 默认日期边界是 UTC 零点，返回 `timezone: "UTC"` 和 `next_refresh_at`；Flutter 转成本地时间显示。后台每 15 秒检查目录变化、日期与可用性条件；普通 GET 不生成或重新抽样。
- 每日更新和显式换一批优先选择上一批未出现的候选，再使用带种子的随机顺序。小曲库返回实际数量，不能保证完全不重复。
- “新近入库”使用同一发行身份下原始文件的最早 `created_at`，按时间倒序、ID 倒序稳定排列。重新扫描、编辑元数据和后来添加副本不改变原始入库时间；撤销合并后各身份恢复其原始文件时间。
- 每次成功发布原子写入规则（如有修改）、完整结果与当前批次指针。生成失败不替换旧规则或旧批次。保留七天内历史结果；显式读取超过七天的批次返回 410。已经建立的队列独立持久化，不受历史批次清理影响。
- 原始音频和标签不因本功能被改写。迁移 0034 新增系统歌单、规则历史、结果快照、管理设置及队列来源字段。重建资料库后重新创建默认系统歌单；恢复完整数据库备份则恢复备份中的规则和批次。

## HTTP 协议

以下路径位于 `/api/v1`。所有返回对象包含 `server_id`、`catalog_epoch`。所有系统歌单写请求必须同时携带 `X-IntMusic-Server-Id` 和 `X-IntMusic-Catalog-Epoch`；不匹配或缺失时写入前拒绝。它们用于隔离资料库，不是认证机制。

| 方法与路径 | 请求 / 响应重点 |
| --- | --- |
| GET `/system-playlists` | `{items: [page, page], server_id, catalog_epoch}`，每项 6 首预览 |
| GET `/system-playlists/rule-schema` | `version`、`fields`、参数上下界、各歌单默认规则与生成方式 |
| GET `/system-playlists/{key}?limit=200` | 当前批次第一页 |
| GET `/system-playlists/{key}?result_version=...&offset=200&limit=200` | 固定批次续页；`next_offset: null` 表示结束 |
| GET `/settings/system-playlists` | `management_enabled`、`revision` |
| PATCH `/settings/system-playlists` | `{management_enabled: true, expected_revision: 1}` |
| PATCH `/system-playlists/{key}` | `{expected_revision: 1, rules: ...}` |
| POST `/system-playlists/{key}/preview` | 请求体直接为规则对象；无持久副作用 |
| POST `/system-playlists/daily_mix/refresh` | `{expected_result_version: "...", request_id: "unique-operation-id"}`；管理关闭仍允许 |
| POST `/system-playlists/{key}/reset-rules` | `{expected_revision: 2, confirm: true}` |

规则示例（仅是对接示例，不会自动应用到用户资料库）：

```json
{
  "match_mode": "all",
  "filters": [
    {"field": "genre", "op": "equals", "value": "流行"},
    {"field": "favorite", "op": "equals", "value": true}
  ],
  "limit": 30,
  "only_available": false,
  "added_within_days": null,
  "max_per_artist": 3,
  "max_per_album": 2
}
```

`match_mode` 是 `all` 或 `any`；最多 50 条筛选条件。文本字段与运算符、布尔收藏字段、整数评分/年份和音乐来源 ID 数组以能力接口为准。所有字段、运算符、数值类型、范围和未知输入字段严格校验，不支持任意 SQL 或排序表达式。

页面响应的重要字段：

```json
{
  "system_key": "daily_mix",
  "playlist_id": 123,
  "name": "今日随听",
  "is_system": true,
  "hidden": true,
  "can_edit_rules": false,
  "can_delete": false,
  "can_edit_tracks": false,
  "rules_revision": 1,
  "defaults_version": 1,
  "result_version": "batch-uuid",
  "generated_at": "2026-10-04T00:00:00Z",
  "next_refresh_at": "2026-10-05T00:00:00Z",
  "timezone": "UTC",
  "status": "ready",
  "stale": false,
  "error": null,
  "matched_total": 6061,
  "result_total": 30,
  "offset": 0,
  "next_offset": 6,
  "tracks": [],
  "rules": {},
  "server_id": "server-uuid",
  "catalog_epoch": "catalog-epoch"
}
```

以上 `tracks` 和 `rules` 省略内容以展示结构；真实 `tracks` 复用 `TrackSummary`，歌曲没有封面时使用专辑封面。`status` 为 `generating`、`ready`、`stale`、`error`，预览为 `preview`。`generating` 没有批次，不应当作已生成的零首结果。快照可用标记是该批次生成时的摘要；播放前 Core 再检查当前可用来源，客户端继续使用已有音源解析。

错误示例：

```json
{"code":"system_playlist_conflict","error":"歌单已由其他操作更新，请重新读取后重试","current_revision":3}
```

| HTTP | code | 客户端处理 |
| --- | --- | --- |
| 403 | `system_playlist_protected` | 不提供删除、改名、转换、手动成员编辑 |
| 403 | `system_playlist_management_disabled` | 停止提交，重读管理开关 |
| 404 | `system_playlist_not_found` | 未知系统键 |
| 409 | `system_playlist_conflict` | 重读规则和当前批次，让用户决定是否再次保存 |
| 409 | `catalog_identity_mismatch` | 重读 Core 身份；丢弃旧资料库待提交内容 |
| 410 | `system_playlist_result_expired` | 提示用户显式读取新批次；不自动替换 |
| 422 | `system_playlist_invalid_rules` / `system_playlist_invalid_request` | 修正规则或分页参数 |

反序列化错误同样返回 422。生成异常为 500，已有批次保持可读。换一批重试必须复用同一 `request_id` 和原始 `expected_result_version`；同请求返回原批次，改变请求内容复用 ID 会被拒绝。旧批次超出保留期限后不承诺继续保存幂等收据。

## 事件、队列和缓存

事件 `system_playlists.changed` 包含 `server_id`、`catalog_epoch`、`system_key`（管理开关变化时为 null）、`rules_revision`、`result_version`。只重读本模块，不触发整份歌曲目录同步。Flutter 在重新连接和 30 秒兜底轮询时读取轻量摘要；Core 不支持该能力则隐藏该入口。

播放沿用 `/playback-v3/zones/{zone_id}/commands` 的 `replace_queue_and_play`，增加可选来源：

```json
{
  "type":"replace_queue_and_play",
  "source":{"system_key":"daily_mix","result_version":"batch-uuid","name":"今日随听"},
  "items":[{"item_id":"occurrence-uuid","track_id":42,"added_by_device_id":"client-id","added_at":"2026-10-04T10:00:00Z"}],
  "start_item_id":"occurrence-uuid",
  "position_ms":0
}
```

客户端必须完整读取同一批次后再建立队列，允许显式展示筛选、合并和排序后的成员投影。Core 检查成员均来自指定批次且不重复，并使用服务端名称，拒绝伪造成员和失效批次。选定歌曲已不可用时在修改队列前拒绝。当前输出设备的最终解码、网络中断与音量仍由现有播放器反馈。

会话快照的 `queue_source` 保存系统键、名称和结果版本；用户编辑队列不回写系统歌单。普通歌曲集替换队列会清除来源。歌单刷新、规则更改和管理关闭均不发起播放命令。

Flutter 缓存按 Core 地址、`server_id`、`catalog_epoch` 哈希隔离。离线仅使用完整缓存批次，显示生成时间，播放依照本机副本能力；不保存离线规则写入。显式失效响应不会回退成缓存成功。切换 Core 后未完成请求的结果被丢弃。

## 验证记录

2026-10-04，macOS Apple M5、16 GiB 内存。使用生产数据库的只读备份复制为独立临时库，再迁移测试；没有在原音乐目录进行任何写操作。

- 6061 首可见歌曲：两张默认歌单首次生成共 750 ms，分别返回 30/100 首，每张首页预览 6 首。
- 100 次连续读取两张摘要：数据库层 P95 0.527 ms，最大 1.609 ms；6 并发客户端共 120 对摘要读取共 31 ms。此数据不含 HTTP、跨设备网络和绘制延迟，也不代表首屏启动耗时。部署后从 Mac 经局域网读取 LabPC 摘要 30 次，HTTP P95 为 14.46 ms。
- Core DB 系统歌单 10 项测试：稳定身份与保护、用户同名歌单隔离、严格规则、并发幂等、重启、预览无副作用、CAS 冲突、发布失败回滚、1205 首稳定分页、跨日、原始入库时间、合并/撤销、可用租期和来源移除。
- Core API：真实 HTTP 路由验证身份、管理开关、普通入口保护、分页和过期错误；队列集成验证完整批次、点选位置、来源记录、后台换批次不影响队列，以及不可用/过期请求保留旧队列。
- Flutter：1205 首固定版本全量分页、完整性检查、离线缓存、资料库切换丢弃迟到响应、PATCH 身份保护，以及手机/桌面设置布局、首页点击不播放、后台新批次不替换已查看列表。
- 已通过完整 Flutter 97 项测试、静态分析；Rust core-api/core-db/protocol/playback 回归及新增边界测试通过。构建和安装状态在 `flutter-library-sync-audit.md` 追加记录。
