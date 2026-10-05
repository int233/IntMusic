# 统一集合与可配置首页

实现版本：Core 1.6.0、Flutter 1.6.0+11。此文说明当前实现，替代旧普通歌单、智能歌单和隐藏系统歌单的三套设计。

## 使用方式

- 导航中的“集合”可以创建歌曲、专辑、艺术家或流派集合。选择类型后，使用同一个编辑器设置名称、描述、封面、指定内容、排除内容、自动筛选、排序、数量与刷新策略。
- 手动歌单就是关闭自动筛选、只指定歌曲的集合。指定内容可拖动排序；自动内容排列在其后。排除优先于自动筛选；编辑器不允许同一对象同时指定和排除。
- “设置 → 系统集合 → 允许管理系统集合”控制系统集合的编辑入口。开启后共用集合编辑器，关闭不停止首页供给、播放或“换一批”。系统集合不能删除或变为其他内容类型。
- 首页右上角“编辑首页”支持添加已有集合、创建集合并关联、添加内置区块、调整顺序、标题、宽度、首屏数量、歌曲字段和隐藏状态。
- 歌曲集合可显示卡片、列表或横向卡片；专辑和艺术家还支持网格；流派还支持标签。首页与完整集合共用结果组件和缓存，两个区块引用同一集合不会各自选曲。
- “今日随听”和“新近入库”始终保留为系统集合。首页对应区块可移除；重启不自动补回。编辑首页提供恢复默认区块的明确操作。
- 点击标题或“查看全部”仅打开集合，点击“播放全部”或歌曲播放按钮才改变队列。首页预览数量不限制完整播放数量。
- 全局歌曲合并、展示属性筛选与排序仍在设置中；单曲展示覆盖值立即投影到当前列表。作品/录音关联不消除专辑发行身份；流派等标签映射沿用用户自行指定的输入、1–5 个输出及适用字段。

## 成员和筛选语义

`collection.entity_type` 只能是 `track / album / artist / genre`。歌曲成员使用 `release_identity_id`，物理文件与设备副本不会增加成员数量；其他成员使用对应实体 ID。`CollectionItem.entity_id` 用于筛选、指定、排除和选中播放；`item.data.id` 是详情与播放端使用的当前实体 ID。歌曲这两个 ID 不应混用。

集合结果 = 指定成员（指定顺序）+ 自动命中成员（规则顺序）− 排除成员，再应用总数限制。关闭自动筛选且指定为空时结果为空；启用空的 `all` 条件表示全库。随机、每位艺术家上限和每张专辑上限仅作用于自动加入部分，手工指定优先。

规则为类型化树：

- `all` / `any` 包含子条件。
- `field` 只读取当前对象自身字段。专辑自身流派不会偷偷继承曲目流派。
- `tracks` 在专辑、艺术家或流派关联的歌曲内判断，支持至少一首、全部、至少 N 首、至少 N%。`all` 要求关联歌曲非空。
- 一个 `tracks.condition` 中的条件绑定到同一首歌曲。例如“粤语且已收藏”不能用一首粤语歌曲和另一首收藏歌曲拼凑满足。
- 艺术家关联明确选择演唱、专辑艺术家、作曲或作词角色。演唱包括主唱与合作演唱；不自动混入作曲作品。
- 未知字段、操作符、错误值类型、超过 6 层或 100 个条件会拒绝。未知年份和评分不等于 0，使用“为空”判断。相同排序值以实体 ID 稳定打破平局。
- 音乐来源筛选表示现有库存归属；设备暂时离线不移除库存成员。可用性是另一项筛选，最终播放仍通过实时音源解析。

非歌曲集合另有“播放范围”：默认展开其关联歌曲，也可额外过滤歌曲和选择展开顺序。选择了某张专辑，不代表只播放使它入选的那首歌；必须明确设置播放过滤才缩小范围。多个实体展开后按发行身份去重。

## 系统默认值与结果生命周期

今日随听：默认 30 首、每日随机、允许手动换一批。新近入库：默认 100 首、发行身份下最早文件入库时间倒序、实时更新。增加副本、重扫或修改一般元数据不会把已有发行重新当成新歌。

Core 使用 UTC 日期统一每日边界，返回 `generated_at` 和 `next_refresh_at`。每日集合保持当日批次，手动集合保持上次生成批次，实时集合响应曲库、收藏、可用性和播放统计变化。编辑规则立即生成并发布对应批次。预览使用独立计算，不保存或改变播放。

结果包含规则快照、生成版本和有序成员，并冻结各成员展开后的发行 ID。分页固定 `result_version`，每页最多 200 项；没有 1,000 首截断。当前结果持续保留，非当前结果与播放计划在清理时保留至少 7 天。

播放通过结果版本创建完整播放计划，按当前目录将冻结的发行 ID 解析成歌曲摘要；已移除内容计入 `missing_count`。每个计划有 `plan_id`，队列接收时校验计划与歌曲归属。生成、换批、编辑规则、删除集合均不会替换正在播放的队列。

## 多端一致性

- 所有响应携带 `server_id`、`catalog_epoch`；写请求必须带 `x-intmusic-server-id`、`x-intmusic-catalog-epoch`。
- 集合、首页布局和管理开关分别使用修订号。编辑携带预期修订号，过期编辑返回 409，保留草稿供用户重新处理。
- 保存时校验输入、计算结果，再在同一写事务中发布定义与完整结果。计算期间曲库变化则返回可重试错误，不发布半套内容。
- 刷新请求使用 `request_id` 与 `expected_result_version`。同一请求重复提交返回同一批次；换用相同 ID 提交不同请求会拒绝。
- `collections.changed` 通知客户端刷新集合状态，不要求下载整份曲库。漏事件后由连接快照及 30 秒重读收敛。
- Flutter 在保存确认后先更新共享状态。晚到的旧读请求不能覆盖已确认修改；切换 Core 或 epoch 会清空请求、内存和订阅身份。持久缓存按连接地址、Core ID、epoch 隔离。
- 离线可浏览已缓存内容；只有已缓存完整成员的歌曲集合可以交给现有离线播放路径。未完整缓存或需要远端展开的集合明确提示连接 Core。

## 接口

均位于 `/api/v1`，能力标记为 `collections_v1`。精确类型定义见 `crates/protocol/src/collections.rs`。

| 方法与路径 | 用途 |
| --- | --- |
| GET /collections | 所有集合摘要；系统集合带 system_key 和能力字段 |
| POST /collections | 创建 `{expected_revision:null, definition}` |
| GET /collections/{id} | `result_version? / offset? / limit?`；offset > 0 必须指定版本 |
| PATCH /collections/{id} | `{expected_revision, definition}` |
| DELETE /collections/{id}?expected_revision=N | 删除用户集合，并原子移除首页引用 |
| GET /collections/rule-schema | 各实体可用字段、类型、操作符和限制 |
| POST /collections/preview | 请求为完整 definition；返回最多 50 项预览及两个总数 |
| GET /collections/entities/{kind} | 搜索或按 ids 查找可选成员，支持分页 |
| POST /collections/{id}/refresh | `{request_id, expected_result_version}` |
| POST /collections/{id}/reset | `{expected_revision}`；恢复系统默认规则 |
| POST /collections/{id}/play | `{result_version, entity_ids:null或选中ID列表}`；返回完整计划 |
| GET、PATCH /settings/collections | `{management_enabled, revision}`；写入使用 expected_revision |
| GET、PATCH /home-layout | `{revision, sections}`；写入使用 expected_revision |
| GET /genres/{id} | 流派与关联歌曲详情 |

集合定义示例：

```json
{
  "name": "收藏的粤语专辑", "description": "至少有一首已收藏的粤语歌曲",
  "entity_type": "album", "cover_album_id": null,
  "included": [], "excluded": [],
  "automatic": {
    "kind": "tracks", "quantifier": "any", "value": 1, "role": "performer",
    "condition": {"kind": "all", "conditions": [
      {"kind": "field", "field": "genres", "op": "eq", "value": "粤语"},
      {"kind": "field", "field": "favorite", "op": "eq", "value": true}
    ]}
  },
  "sort": [{"field": "year", "descending": true}], "limit": 30,
  "refresh": "live", "max_per_artist": null, "max_per_album": null,
  "playback": {"filter": null, "artist_role": "performer", "order": "album"}
}
```

稳定错误码：`collection_invalid`（422）、`collection_not_found`（404）、`collection_conflict` / `collection_retry`（409）、`collection_protected` / `collection_management_disabled`（403）、`collection_result_expired`（410）、`collection_empty`（422）。

## 测试版升级边界

迁移 0035 删除旧普通/智能/系统歌单定义、成员与旧系统结果表，创建统一集合，重建默认集合和首页，并更换 catalog epoch。旧播放队列的歌单来源标签清空。音乐文件不读写或删除，目录、收藏和曲目元数据保留；不提供旧 `/playlists` 或 `/system-playlists` 接口兼容。

Core 和客户端需要共同升级。此改动不代表其他机器上运行的 Core 或客户端已部署；旧客户端必须更新后使用新集合接口。鸿蒙客户端有独立工作，未在本改动中移植新集合页面。

回归覆盖：系统保护与管理开关、规则严格校验、同曲条件绑定、艺术家角色、来源库存与在线状态分离、空值语义、指定/排除、CAS 冲突、固定批次、播放范围、6,000 首分页与完整播放、首页引用删除、跨资料库缓存隔离、晚到响应、手机/桌面布局、单曲展示立即更新。

## 本次验证

- `flutter analyze`：无问题；`flutter test`：98 项通过。
- Rust 全工作区测试通过；最终集合回归 14 项通过，包含 6,000 首固定版本分页、完整播放计划、并发相同刷新请求、每日/手动结果冻结、系统自动模式保护。
- Core Release 构建通过（1.6.0）；macOS Release 构建通过，客户端版本 1.6.0+11。实际组件已在 390 与 1200 像素宽度渲染检查。
- OpenAPI YAML 解析通过：107 个路径、9 个集合请求 schema；路由和事件契约测试通过。
- Android 构建因本机缺少 Android SDK 未完成；Windows 和跨设备音频输出未在本机实机验收。此处的构建与测试不代表已部署到现有设备。
