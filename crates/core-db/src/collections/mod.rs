use super::*;
use protocol::*;
use serde_json::json;
mod query;
use query::*;
pub use query::{collection_genre_detail, collection_rule_schema};

#[derive(Debug)]
pub struct CollectionError {
    pub code: &'static str,
    pub message: String,
    pub current_revision: Option<u64>,
}
impl std::fmt::Display for CollectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for CollectionError {}
fn fail(code: &'static str, message: impl Into<String>) -> anyhow::Error {
    CollectionError {
        code,
        message: message.into(),
        current_revision: None,
    }
    .into()
}
fn conflict(revision: u64) -> anyhow::Error {
    CollectionError {
        code: "collection_conflict",
        message: "内容已在另一处更新，请重新读取后保存".into(),
        current_revision: Some(revision),
    }
    .into()
}

pub fn empty_collection(kind: EntityType) -> CollectionDefinition {
    CollectionDefinition {
        name: String::new(),
        description: String::new(),
        entity_type: kind,
        cover_album_id: None,
        included: vec![],
        excluded: vec![],
        automatic: None,
        sort: vec![CollectionSort {
            field: "name".into(),
            descending: false,
        }],
        limit: None,
        refresh: CollectionRefreshPolicy::Live,
        max_per_artist: None,
        max_per_album: None,
        playback: CollectionPlayback {
            filter: None,
            artist_role: ArtistTrackRole::Performer,
            order: "album".into(),
        },
    }
}
pub fn default_collection(key: &str) -> Result<CollectionDefinition> {
    let mut def = empty_collection(EntityType::Track);
    def.automatic = Some(CollectionPredicate::All { conditions: vec![] });
    match key {
        "daily_mix" => {
            def.name = "今日随听".into();
            def.description = "每日选取一批歌曲，也可以随时换一批".into();
            def.limit = Some(30);
            def.refresh = CollectionRefreshPolicy::Daily;
            def.sort = vec![CollectionSort {
                field: "random".into(),
                descending: false,
            }];
        }
        "recently_added" => {
            def.name = "新近入库".into();
            def.description = "最近加入资料库的歌曲".into();
            def.limit = Some(100);
            def.sort = vec![CollectionSort {
                field: "added_at".into(),
                descending: true,
            }];
        }
        _ => return Err(fail("collection_not_found", "未知系统集合")),
    }
    Ok(def)
}
pub async fn initialize_collections(pool: &DbPool) -> Result<()> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let now = Utc::now().to_rfc3339();
    for key in ["daily_mix", "recently_added"] {
        let definition = serde_json::to_string(&default_collection(key)?)?;
        sqlx::query("INSERT OR IGNORE INTO collections(system_key,entity_type,definition_json,created_at,updated_at) VALUES(?1,'track',?2,?3,?3)").bind(key).bind(&definition).bind(&now).execute(&mut *tx).await?;
    }
    let ids: Vec<(i64, String)> = sqlx::query_as(
        "SELECT id,system_key FROM collections WHERE system_key IS NOT NULL ORDER BY id",
    )
    .fetch_all(&mut *tx)
    .await?;
    let mut sections: Vec<HomeSection> = ids
        .into_iter()
        .map(|(id, key)| HomeSection {
            id: format!("default-{key}"),
            collection_id: Some(id),
            builtin: None,
            title: None,
            layout: "list".into(),
            preview_count: 6,
            width: "wide".into(),
            hidden: false,
            track_columns: vec![
                "artist".into(),
                "album".into(),
                "duration".into(),
                "availability".into(),
            ],
        })
        .collect();
    for builtin in [
        "now_playing",
        "library",
        "history",
        "devices",
        "stats",
        "core",
    ] {
        sections.push(HomeSection {
            id: format!("default-{builtin}"),
            collection_id: None,
            builtin: Some(builtin.into()),
            title: None,
            layout: "card".into(),
            preview_count: 6,
            width: if ["devices", "stats", "core"].contains(&builtin) {
                "narrow"
            } else {
                "wide"
            }
            .into(),
            hidden: false,
            track_columns: vec![],
        });
    }
    sqlx::query("INSERT OR IGNORE INTO home_layout(id,sections_json) VALUES(1,?1)")
        .bind(serde_json::to_string(&sections)?)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}
pub async fn collection_settings(pool: &DbPool) -> Result<CollectionSettings> {
    let (enabled, revision): (bool, i64) =
        sqlx::query_as("SELECT management_enabled,revision FROM collection_settings WHERE id=1")
            .fetch_one(pool)
            .await?;
    Ok(CollectionSettings {
        management_enabled: enabled,
        revision: revision as u64,
    })
}
pub async fn update_collection_settings(
    pool: &DbPool,
    update: &CollectionSettingsUpdate,
) -> Result<CollectionSettings> {
    let changed=sqlx::query("UPDATE collection_settings SET management_enabled=?1,revision=revision+1 WHERE id=1 AND revision=?2").bind(update.management_enabled).bind(update.expected_revision as i64).execute(pool).await?.rows_affected();
    let settings = collection_settings(pool).await?;
    if changed == 0 {
        return Err(conflict(settings.revision));
    }
    Ok(settings)
}
#[derive(Clone)]
struct Stored {
    id: i64,
    key: Option<String>,
    def: CollectionDefinition,
    revision: u64,
    version: Option<String>,
    updated: DateTime<Utc>,
    error: Option<String>,
}
fn stored(row: sqlx::sqlite::SqliteRow) -> Result<Stored> {
    Ok(Stored {
        id: row.try_get("id")?,
        key: row.try_get("system_key")?,
        def: serde_json::from_str(&row.try_get::<String, _>("definition_json")?)?,
        revision: row.try_get::<i64, _>("revision")? as u64,
        version: row.try_get("result_version")?,
        updated: parse_datetime(row.try_get("updated_at")?)?,
        error: row.try_get("error")?,
    })
}
async fn definition(pool: &DbPool, id: i64) -> Result<Stored> {
    stored(
        sqlx::query("SELECT * FROM collections WHERE id=?1")
            .bind(id)
            .fetch_optional(pool)
            .await?
            .ok_or_else(|| fail("collection_not_found", "集合不存在"))?,
    )
}
fn summary(s: &Stored, total: u64, management: bool) -> CollectionSummary {
    CollectionSummary {
        id: s.id,
        name: s.def.name.clone(),
        description: s.def.description.clone(),
        entity_type: s.def.entity_type,
        cover_album_id: s.def.cover_album_id,
        system_key: s.key.clone(),
        revision: s.revision,
        result_version: s.version.clone(),
        result_total: total,
        can_edit: s.key.is_none() || management,
        can_delete: s.key.is_none(),
        updated_at: s.updated,
    }
}
pub async fn list_collections(pool: &DbPool) -> Result<Vec<CollectionSummary>> {
    let management = collection_settings(pool).await?.management_enabled;
    let rows=sqlx::query("SELECT c.*,COALESCE(r.result_total,0) AS total FROM collections c LEFT JOIN collection_results r ON r.version=c.result_version ORDER BY c.updated_at DESC,c.id").fetch_all(pool).await?;
    rows.into_iter()
        .map(|r| {
            let total = r.try_get::<i64, _>("total")? as u64;
            Ok(summary(&stored(r)?, total, management))
        })
        .collect()
}
fn validate_definition(def: &CollectionDefinition) -> Result<()> {
    if def.name.trim().is_empty() || def.name.len() > 300 || def.description.len() > 4000 {
        return Err(fail(
            "collection_invalid",
            "名称不能为空，或文字长度超出限制",
        ));
    }
    for ids in [&def.included, &def.excluded] {
        if ids.len() > 10000
            || ids.iter().any(|i| *i <= 0)
            || ids.iter().collect::<HashSet<_>>().len() != ids.len()
        {
            return Err(fail("collection_invalid", "指定或排除成员无效、重复或过多"));
        }
    }
    if def.included.iter().any(|id| def.excluded.contains(id)) {
        return Err(fail("collection_invalid", "同一成员不能同时指定和排除"));
    }
    if def
        .limit
        .is_some_and(|v| v == 0 || v > 10000 || def.included.len() > v as usize)
    {
        return Err(fail(
            "collection_invalid",
            "结果上限须为 1 至 10000，且不能少于指定成员数",
        ));
    }
    if def.sort.len() > 5
        || def.sort.iter().any(|s| {
            s.field != "random"
                && !field_specs(def.entity_type).iter().any(|f| {
                    f.0 == s.field && ["text", "number", "date", "bool", "mode"].contains(&f.2)
                })
        })
    {
        return Err(fail("collection_invalid", "排序字段无效"));
    }
    if def.sort.iter().filter(|s| s.field == "random").count() > 0 && def.sort.len() != 1 {
        return Err(fail("collection_invalid", "随机排序不能与其他排序混用"));
    }
    if [def.max_per_artist, def.max_per_album]
        .into_iter()
        .flatten()
        .any(|v| v == 0 || v > 10000)
        || (def.entity_type != EntityType::Track
            && (def.max_per_artist.is_some() || def.max_per_album.is_some()))
    {
        return Err(fail("collection_invalid", "多样性限制仅适用于歌曲"));
    }
    if !["album", "name", "random"].contains(&def.playback.order.as_str()) {
        return Err(fail("collection_invalid", "播放排序无效"));
    }
    if def.entity_type == EntityType::Track && def.playback.filter.is_some() {
        return Err(fail("collection_invalid", "歌曲集合直接播放集合结果"));
    }
    let mut count = 0;
    if let Some(p) = &def.automatic {
        validate_predicate(p, def.entity_type, 0, &mut count)?;
    }
    if let Some(p) = &def.playback.filter {
        validate_predicate(p, EntityType::Track, 0, &mut count)?;
    }
    Ok(())
}
fn validate_system(s: &Stored, def: &CollectionDefinition) -> Result<()> {
    if s.def.entity_type != def.entity_type {
        return Err(fail("collection_invalid", "已有集合不能更改内容类型"));
    }
    if let Some(key) = &s.key {
        if def.name != s.def.name
            || def.automatic.is_none()
            || !def.included.is_empty()
            || !def.excluded.is_empty()
        {
            return Err(fail(
                "collection_protected",
                "系统集合名称和自动成员方式不可更改",
            ));
        }
        if key == "daily_mix"
            && (def.refresh != CollectionRefreshPolicy::Daily
                || def.sort.len() != 1
                || def.sort[0].field != "random")
        {
            return Err(fail("collection_protected", "今日随听按每日随机生成"));
        }
        if key == "recently_added"
            && (def.refresh != CollectionRefreshPolicy::Live
                || def.sort.len() != 1
                || def.sort[0].field != "added_at"
                || !def.sort[0].descending)
        {
            return Err(fail("collection_protected", "新近入库按入库时间倒序更新"));
        }
    }
    Ok(())
}
async fn fingerprint(pool: &DbPool, max_rating: bool) -> Result<String> {
    let mut connection = pool.acquire().await?;
    fingerprint_connection(&mut connection, max_rating).await
}
async fn fingerprint_connection(
    connection: &mut sqlx::SqliteConnection,
    max_rating: bool,
) -> Result<String> {
    let cursor:i64=sqlx::query_scalar("SELECT COALESCE(MAX(cursor),0) FROM client_sync_changes WHERE scope NOT IN ('collections','playlists','home')").fetch_one(&mut *connection).await?;
    let presence: Vec<(String, bool)> = sqlx::query_as(
        "SELECT id,COALESCE(datetime(online_until)>=datetime('now'),0) FROM devices ORDER BY id",
    )
    .fetch_all(&mut *connection)
    .await?;
    let history: (i64, Option<String>) =
        sqlx::query_as("SELECT COUNT(*),MAX(ended_at) FROM playback_sessions")
            .fetch_one(&mut *connection)
            .await?;
    let preferences: (i64, Option<String>) =
        sqlx::query_as("SELECT COUNT(*),MAX(updated_at) FROM user_track_state")
            .fetch_one(&mut *connection)
            .await?;
    Ok(serde_json::to_string(&(
        cursor,
        presence,
        history,
        preferences,
        max_rating,
        Utc::now().date_naive(),
    ))?)
}
fn next_day(now: DateTime<Utc>) -> DateTime<Utc> {
    (now.date_naive() + chrono::Duration::days(1))
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
}
struct Publication<'a> {
    existing: Option<&'a Stored>,
    def: &'a CollectionDefinition,
    g: &'a Generated,
    seed: &'a str,
    fp: &'a str,
    edit: bool,
    receipt: Option<(&'a str, &'a str)>,
    max_rating: bool,
}
async fn publish(pool: &DbPool, publication: Publication<'_>) -> Result<(i64, String)> {
    let Publication {
        existing,
        def,
        g,
        seed,
        fp,
        edit,
        receipt,
        max_rating,
    } = publication;
    let now = Utc::now();
    let version = Uuid::new_v4().to_string();
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let s = if let Some(stored) = existing {
        stored.clone()
    } else {
        let id=sqlx::query("INSERT INTO collections(entity_type,definition_json,created_at,updated_at) VALUES(?1,?2,?3,?3)").bind(def.entity_type.as_str()).bind(serde_json::to_string(def)?).bind(now.to_rfc3339()).execute(&mut *tx).await?.last_insert_rowid();
        Stored {
            id,
            key: None,
            def: def.clone(),
            revision: 1,
            version: None,
            updated: now,
            error: None,
        }
    };
    let current = stored(
        sqlx::query("SELECT * FROM collections WHERE id=?1")
            .bind(s.id)
            .fetch_one(&mut *tx)
            .await?,
    )?;
    if current.revision != s.revision || current.version != s.version {
        return Err(conflict(current.revision));
    }
    if edit && s.key.is_some() {
        let enabled: bool =
            sqlx::query_scalar("SELECT management_enabled FROM collection_settings WHERE id=1")
                .fetch_one(&mut *tx)
                .await?;
        if !enabled {
            return Err(fail(
                "collection_management_disabled",
                "请先在设置中开启系统集合管理",
            ));
        }
    }
    // A catalog write published during generation invalidates the computation.
    if fingerprint_connection(&mut tx, max_rating).await? != fp {
        return Err(fail("collection_retry", "资料库正在更新，请重试"));
    }
    let revision = s.revision + u64::from(edit);
    let serialized = serde_json::to_string(def)?;
    sqlx::query("INSERT INTO collection_results(version,collection_id,definition_json,revision,generated_at,next_refresh_at,fingerprint,seed,matched_total,result_total,missing_json) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)").bind(&version).bind(s.id).bind(&serialized).bind(revision as i64).bind(now.to_rfc3339()).bind(next_day(now).to_rfc3339()).bind(fp).bind(seed).bind(g.matched as i64).bind(g.items.len() as i64).bind(serde_json::to_string(&g.missing)?).execute(&mut *tx).await?;
    for (position, (item, ids)) in g.items.iter().enumerate() {
        sqlx::query("INSERT INTO collection_result_items(version,position,entity_id,item_json,track_ids_json) VALUES(?1,?2,?3,?4,?5)").bind(&version).bind(position as i64).bind(item.entity_id).bind(serde_json::to_string(item)?).bind(serde_json::to_string(ids)?).execute(&mut *tx).await?;
    }
    sqlx::query("UPDATE collections SET definition_json=?1,revision=?2,result_version=?3,error=NULL,updated_at=?4 WHERE id=?5").bind(&serialized).bind(revision as i64).bind(&version).bind(if edit{now}else{s.updated}.to_rfc3339()).bind(s.id).execute(&mut *tx).await?;
    if edit || existing.is_none() {
        sqlx::query("INSERT INTO collection_history(collection_id,revision,definition_json,saved_at) VALUES(?1,?2,?3,?4)").bind(s.id).bind(revision as i64).bind(serialized).bind(now.to_rfc3339()).execute(&mut *tx).await?;
    }
    if let Some((request_id, request_json)) = receipt {
        sqlx::query("INSERT INTO collection_refresh_receipts(collection_id,request_id,request_json,result_version) VALUES(?1,?2,?3,?4)").bind(s.id).bind(request_id).bind(request_json).bind(&version).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok((s.id, version))
}
pub async fn save_collection(
    pool: &DbPool,
    id: Option<i64>,
    write: &CollectionWrite,
    max_rating: bool,
) -> Result<CollectionPage> {
    validate_definition(&write.definition)?;
    if let Some(album) = write.definition.cover_album_id {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM albums WHERE id=?1)")
            .bind(album)
            .fetch_one(pool)
            .await?;
        if album <= 0 || !exists {
            return Err(fail("collection_invalid", "所选封面专辑不存在"));
        }
    }
    let mut def = write.definition.clone();
    def.name = def.name.trim().into();
    let previous = if let Some(id) = id {
        let s = definition(pool, id).await?;
        if Some(s.revision) != write.expected_revision {
            return Err(conflict(s.revision));
        }
        validate_system(&s, &def)?;
        if s.key.is_some() && !collection_settings(pool).await?.management_enabled {
            return Err(fail(
                "collection_management_disabled",
                "请先在设置中开启系统集合管理",
            ));
        }
        Some(s)
    } else {
        if write.expected_revision.is_some() {
            return Err(fail("collection_invalid", "新集合不应包含旧版本"));
        }
        None
    };
    let fp = fingerprint(pool, max_rating).await?;
    let catalog = load_catalog(pool, max_rating).await?;
    let existing: HashSet<i64> = catalog
        .entities
        .get(&def.entity_type)
        .into_iter()
        .flatten()
        .map(|c| c.id)
        .collect();
    if def.included.iter().any(|i| !existing.contains(i)) {
        return Err(fail("collection_invalid", "指定成员已不存在，请移除后重试"));
    }
    let seed = Uuid::new_v4().to_string();
    let generated = generate(&def, &catalog, &seed, &HashSet::new(), Utc::now());
    let (id, version) = publish(
        pool,
        Publication {
            existing: previous.as_ref(),
            def: &def,
            g: &generated,
            seed: &seed,
            fp: &fp,
            edit: id.is_some(),
            receipt: None,
            max_rating,
        },
    )
    .await?;
    collection_page(pool, id, Some(&version), 0, 50).await
}
pub async fn collection_page(
    pool: &DbPool,
    id: i64,
    version: Option<&str>,
    offset: u32,
    limit: u32,
) -> Result<CollectionPage> {
    if offset > 0 && version.is_none() {
        return Err(fail("collection_invalid", "翻页须指定结果版本"));
    }
    let s = definition(pool, id).await?;
    let management = collection_settings(pool).await?.management_enabled;
    let selected = version.map(str::to_owned).or_else(|| s.version.clone());
    let mut page = CollectionPage {
        collection: summary(&s, 0, management),
        definition: s.def.clone(),
        result_version: selected.clone(),
        generated_at: None,
        next_refresh_at: None,
        matched_total: 0,
        result_total: 0,
        missing_members: vec![],
        offset,
        next_offset: None,
        items: vec![],
        error: s.error.clone(),
    };
    let Some(version) = selected else {
        return Ok(page);
    };
    let row = sqlx::query("SELECT * FROM collection_results WHERE version=?1 AND collection_id=?2")
        .bind(&version)
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| fail("collection_result_expired", "此结果批次已失效，请刷新集合"))?;
    page.definition = serde_json::from_str(&row.try_get::<String, _>("definition_json")?)?;
    page.generated_at = Some(parse_datetime(row.try_get("generated_at")?)?);
    page.next_refresh_at = Some(parse_datetime(row.try_get("next_refresh_at")?)?);
    page.matched_total = row.try_get::<i64, _>("matched_total")? as u64;
    page.result_total = row.try_get::<i64, _>("result_total")? as u64;
    page.collection.result_total = page.result_total;
    page.missing_members = serde_json::from_str(&row.try_get::<String, _>("missing_json")?)?;
    let jsons:Vec<String>=sqlx::query_scalar("SELECT item_json FROM collection_result_items WHERE version=?1 ORDER BY position LIMIT ?2 OFFSET ?3").bind(&version).bind(limit.clamp(1,200) as i64).bind(offset as i64).fetch_all(pool).await?;
    page.items = jsons
        .into_iter()
        .map(|s| serde_json::from_str(&s).map_err(Into::into))
        .collect::<Result<_>>()?;
    let next = offset as u64 + page.items.len() as u64;
    if next < page.result_total {
        page.next_offset = Some(next as u32);
    }
    Ok(page)
}
pub async fn preview_collection(
    pool: &DbPool,
    def: &CollectionDefinition,
    max_rating: bool,
) -> Result<Value> {
    validate_definition(def)?;
    let catalog = load_catalog(pool, max_rating).await?;
    let g = generate(def, &catalog, "preview", &HashSet::new(), Utc::now());
    Ok(
        json!({"matched_total":g.matched,"result_total":g.items.len(),"missing_members":g.missing,"items":g.items.into_iter().take(50).map(|i|i.0).collect::<Vec<_>>()}),
    )
}
pub async fn browse_collection_entities(
    pool: &DbPool,
    kind: EntityType,
    q: &str,
    ids: Option<&[i64]>,
    offset: u32,
    limit: u32,
    max_rating: bool,
) -> Result<Value> {
    let mut catalog = load_catalog(pool, max_rating).await?;
    let mut items = catalog.entities.remove(&kind).unwrap_or_default();
    let q = q.trim().to_lowercase();
    items.retain(|c| {
        ids.is_none_or(|ids| ids.contains(&c.id))
            && (q.is_empty()
                || c.fields
                    .values()
                    .any(|v| v.to_string().to_lowercase().contains(&q)))
    });
    items.sort_by(|a, b| {
        a.fields["name"]
            .to_string()
            .to_lowercase()
            .cmp(&b.fields["name"].to_string().to_lowercase())
            .then(a.id.cmp(&b.id))
    });
    let total = items.len();
    let result: Vec<CollectionItem> = items
        .into_iter()
        .skip(offset as usize)
        .take(limit.clamp(1, 200) as usize)
        .map(|c| CollectionItem {
            entity_id: c.id,
            entity: c.entity,
            reason: "browse".into(),
        })
        .collect();
    let next = offset as usize + result.len();
    Ok(json!({"items":result,"total":total,"next_offset":if next<total{Some(next)}else{None}}))
}
pub async fn delete_collection(pool: &DbPool, id: i64, revision: u64) -> Result<()> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let s = stored(
        sqlx::query("SELECT * FROM collections WHERE id=?1")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(|| fail("collection_not_found", "集合不存在"))?,
    )?;
    if s.key.is_some() {
        return Err(fail("collection_protected", "默认系统集合不能删除"));
    }
    if revision != s.revision {
        return Err(conflict(s.revision));
    }
    let raw: String = sqlx::query_scalar("SELECT sections_json FROM home_layout WHERE id=1")
        .fetch_one(&mut *tx)
        .await?;
    let mut sections: Vec<HomeSection> = serde_json::from_str(&raw)?;
    let before = sections.len();
    sections.retain(|s| s.collection_id != Some(id));
    if sections.len() != before {
        sqlx::query("UPDATE home_layout SET revision=revision+1,sections_json=?1 WHERE id=1")
            .bind(serde_json::to_string(&sections)?)
            .execute(&mut *tx)
            .await?;
    }
    sqlx::query("DELETE FROM collections WHERE id=?1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}
async fn refresh_receipt(
    pool: &DbPool,
    id: i64,
    request_id: &str,
    request: &str,
) -> Result<Option<CollectionPage>> {
    let receipt = sqlx::query_as::<_,(String,String)>("SELECT request_json,result_version FROM collection_refresh_receipts WHERE collection_id=?1 AND request_id=?2").bind(id).bind(request_id).fetch_optional(pool).await?;
    let Some((body, version)) = receipt else {
        return Ok(None);
    };
    if body != request {
        return Err(fail("collection_invalid", "刷新标识已用于其他请求"));
    }
    Ok(Some(
        collection_page(pool, id, Some(&version), 0, 50).await?,
    ))
}
pub async fn refresh_collection(
    pool: &DbPool,
    id: i64,
    r: &CollectionRefreshRequest,
    max_rating: bool,
) -> Result<CollectionPage> {
    if r.request_id.is_empty() || r.request_id.len() > 200 {
        return Err(fail("collection_invalid", "刷新请求标识无效"));
    }
    let request = json!({"expected_result_version":r.expected_result_version}).to_string();
    if let Some(page) = refresh_receipt(pool, id, &r.request_id, &request).await? {
        return Ok(page);
    }
    let s = definition(pool, id).await?;
    if s.version != r.expected_result_version {
        if let Some(page) = refresh_receipt(pool, id, &r.request_id, &request).await? {
            return Ok(page);
        }
        return Err(conflict(s.revision));
    }
    let fp = fingerprint(pool, max_rating).await?;
    let catalog = load_catalog(pool, max_rating).await?;
    let seed = Uuid::new_v4().to_string();
    let previous = previous_members(pool, &s).await?;
    let g = generate(&s.def, &catalog, &seed, &previous, Utc::now());
    let result = publish(
        pool,
        Publication {
            existing: Some(&s),
            def: &s.def,
            g: &g,
            seed: &seed,
            fp: &fp,
            edit: false,
            receipt: Some((&r.request_id, &request)),
            max_rating,
        },
    )
    .await;
    match result {
        Ok((_, version)) => collection_page(pool, id, Some(&version), 0, 50).await,
        Err(error) => match refresh_receipt(pool, id, &r.request_id, &request).await? {
            Some(page) => Ok(page),
            None => Err(error),
        },
    }
}
async fn previous_members(pool: &DbPool, s: &Stored) -> Result<HashSet<i64>> {
    Ok(
        sqlx::query_scalar("SELECT entity_id FROM collection_result_items WHERE version=?1")
            .bind(&s.version)
            .fetch_all(pool)
            .await?
            .into_iter()
            .collect(),
    )
}
pub async fn refresh_stale_collections(pool: &DbPool, max_rating: bool) -> Result<Vec<i64>> {
    let fp = fingerprint(pool, max_rating).await?;
    let now = Utc::now();
    let rows=sqlx::query("SELECT c.*,r.fingerprint,r.seed,r.next_refresh_at FROM collections c LEFT JOIN collection_results r ON r.version=c.result_version").fetch_all(pool).await?;
    let mut pending = vec![];
    for row in rows {
        let old_fp: Option<String> = row.try_get("fingerprint")?;
        let seed: Option<String> = row.try_get("seed")?;
        let next: Option<String> = row.try_get("next_refresh_at")?;
        let s = stored(row)?;
        let due = next
            .and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
            .is_some_and(|t| t <= now);
        if s.version.is_none()
            || (s.def.refresh == CollectionRefreshPolicy::Live
                && (old_fp.as_deref() != Some(&fp) || due))
            || (s.def.refresh == CollectionRefreshPolicy::Daily && due)
        {
            pending.push((s, seed, due));
        }
    }
    if pending.is_empty() {
        return Ok(vec![]);
    }
    let catalog = load_catalog(pool, max_rating).await?;
    let mut changed = vec![];
    for (s, old_seed, due) in pending {
        let seed = if due {
            Uuid::new_v4().to_string()
        } else {
            old_seed.unwrap_or_else(|| Uuid::new_v4().to_string())
        };
        let previous = if due {
            previous_members(pool, &s).await?
        } else {
            HashSet::new()
        };
        let g = generate(&s.def, &catalog, &seed, &previous, now);
        match publish(
            pool,
            Publication {
                existing: Some(&s),
                def: &s.def,
                g: &g,
                seed: &seed,
                fp: &fp,
                edit: false,
                receipt: None,
                max_rating,
            },
        )
        .await
        {
            Ok(_) => changed.push(s.id),
            Err(e) => {
                if e.downcast_ref::<CollectionError>().is_none() {
                    sqlx::query("UPDATE collections SET error=?1 WHERE id=?2 AND revision=?3")
                        .bind(e.to_string())
                        .bind(s.id)
                        .bind(s.revision as i64)
                        .execute(pool)
                        .await?;
                    warn!(%e,"collection generation failed");
                }
            }
        }
    }
    sqlx::query("DELETE FROM collection_results WHERE datetime(generated_at)<datetime('now','-7 days') AND version NOT IN (SELECT result_version FROM collections WHERE result_version IS NOT NULL)").execute(pool).await?;
    sqlx::query(
        "DELETE FROM collection_play_plans WHERE datetime(created_at)<datetime('now','-7 days')",
    )
    .execute(pool)
    .await?;
    Ok(changed)
}

pub async fn collection_play_plan(
    pool: &DbPool,
    id: i64,
    r: &CollectionPlayRequest,
    max_rating: bool,
) -> Result<CollectionPlayPlan> {
    let page = collection_page(pool, id, Some(&r.result_version), 0, 1).await?;
    let rows:Vec<(i64,String)>=sqlx::query_as("SELECT entity_id,track_ids_json FROM collection_result_items WHERE version=?1 ORDER BY position").bind(&r.result_version).fetch_all(pool).await?;
    if let Some(ids) = &r.entity_ids {
        if ids.is_empty()
            || ids.iter().collect::<HashSet<_>>().len() != ids.len()
            || ids.iter().any(|id| !rows.iter().any(|(e, _)| e == id))
        {
            return Err(fail("collection_invalid", "播放对象不属于所选结果批次"));
        }
    }
    let mut seen = HashSet::new();
    let mut ids = vec![];
    for (entity, raw) in rows {
        if r.entity_ids
            .as_ref()
            .is_some_and(|selection| !selection.contains(&entity))
        {
            continue;
        }
        for id in serde_json::from_str::<Vec<i64>>(&raw)? {
            if seen.insert(id) {
                ids.push(id);
            }
        }
    }
    let catalog = load_catalog(pool, max_rating).await?;
    let total = ids.len();
    let tracks: Vec<TrackSummary> = ids
        .into_iter()
        .filter_map(|id| catalog.tracks.get(&id))
        .filter_map(|c| {
            if let CollectionEntity::Track(t) = &c.entity {
                Some(t.as_ref().clone())
            } else {
                None
            }
        })
        .collect();
    if tracks.is_empty() {
        return Err(fail("collection_empty", "没有可加入播放队列的歌曲"));
    }
    let source = CollectionQueueSource {
        collection_id: id,
        result_version: r.result_version.clone(),
        plan_id: Uuid::new_v4().to_string(),
        name: page.collection.name,
    };
    sqlx::query("INSERT INTO collection_play_plans(id,source_json,tracks_json,created_at) VALUES(?1,?2,?3,?4)").bind(&source.plan_id).bind(serde_json::to_string(&source)?).bind(serde_json::to_string(&tracks.iter().map(|t|t.id).collect::<Vec<_>>())?).bind(Utc::now().to_rfc3339()).execute(pool).await?;
    Ok(CollectionPlayPlan {
        source,
        missing_count: (total - tracks.len()) as u64,
        tracks,
    })
}
pub async fn validate_collection_queue(
    pool: &DbPool,
    source: &CollectionQueueSource,
    ids: &[i64],
) -> Result<CollectionQueueSource> {
    let (raw, tracks): (String, String) =
        sqlx::query_as("SELECT source_json,tracks_json FROM collection_play_plans WHERE id=?1")
            .bind(&source.plan_id)
            .fetch_optional(pool)
            .await?
            .ok_or_else(|| fail("collection_result_expired", "播放计划已失效"))?;
    let actual: CollectionQueueSource = serde_json::from_str(&raw)?;
    let allowed: HashSet<i64> = serde_json::from_str::<Vec<i64>>(&tracks)?
        .into_iter()
        .collect();
    if actual.collection_id != source.collection_id
        || actual.result_version != source.result_version
        || ids.is_empty()
        || ids.iter().any(|i| !allowed.contains(i))
    {
        return Err(fail("collection_invalid", "播放队列与所选集合结果不一致"));
    }
    Ok(actual)
}
pub async fn home_layout(pool: &DbPool) -> Result<HomeLayout> {
    let (revision, raw): (i64, String) =
        sqlx::query_as("SELECT revision,sections_json FROM home_layout WHERE id=1")
            .fetch_one(pool)
            .await?;
    Ok(HomeLayout {
        revision: revision as u64,
        sections: serde_json::from_str(&raw)?,
    })
}
pub async fn save_home_layout(pool: &DbPool, update: &HomeLayoutUpdate) -> Result<HomeLayout> {
    if update.sections.len() > 40
        || update
            .sections
            .iter()
            .map(|s| &s.id)
            .collect::<HashSet<_>>()
            .len()
            != update.sections.len()
    {
        return Err(fail("collection_invalid", "首页区块数量过多或标识重复"));
    }
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    for section in &update.sections {
        if section.id.is_empty()
            || section.id.len() > 100
            || section.title.as_ref().is_some_and(|s| s.len() > 300)
            || !(1..=100).contains(&section.preview_count)
            || !["wide", "narrow"].contains(&section.width.as_str())
            || section.track_columns.iter().any(|s| {
                ![
                    "artist",
                    "album",
                    "year",
                    "genres",
                    "duration",
                    "availability",
                ]
                .contains(&s.as_str())
            })
        {
            return Err(fail("collection_invalid", "首页区块设置无效"));
        }
        match (section.collection_id, &section.builtin) {
            (Some(id), None) => {
                let kind: String =
                    sqlx::query_scalar("SELECT entity_type FROM collections WHERE id=?1")
                        .bind(id)
                        .fetch_optional(&mut *tx)
                        .await?
                        .ok_or_else(|| fail("collection_not_found", "首页引用的集合已删除"))?;
                let layouts = match kind.as_str() {
                    "track" => vec!["card", "list", "carousel"],
                    "genre" => vec!["card", "list", "chips"],
                    _ => vec!["card", "list", "grid", "carousel"],
                };
                if !layouts.contains(&section.layout.as_str()) {
                    return Err(fail("collection_invalid", "展示方式不适用于该集合"));
                }
            }
            (None, Some(name))
                if [
                    "now_playing",
                    "library",
                    "history",
                    "devices",
                    "stats",
                    "core",
                ]
                .contains(&name.as_str()) => {}
            _ => return Err(fail("collection_invalid", "区块必须引用一个集合或内置内容")),
        }
    }
    let revision: i64 = sqlx::query_scalar("SELECT revision FROM home_layout WHERE id=1")
        .fetch_one(&mut *tx)
        .await?;
    if revision as u64 != update.expected_revision {
        return Err(conflict(revision as u64));
    }
    sqlx::query("UPDATE home_layout SET revision=revision+1,sections_json=?1 WHERE id=1")
        .bind(serde_json::to_string(&update.sections)?)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    home_layout(pool).await
}
