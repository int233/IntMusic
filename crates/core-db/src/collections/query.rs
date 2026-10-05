use super::*;

pub(super) struct Catalog {
    pub entities: HashMap<EntityType, Vec<Candidate>>,
    pub tracks: HashMap<i64, Candidate>,
}
#[derive(Clone)]
pub(super) struct Candidate {
    pub id: i64,
    pub entity: CollectionEntity,
    pub fields: serde_json::Map<String, Value>,
    pub related: HashMap<String, Vec<i64>>,
}
impl Candidate {
    fn track(&self) -> Option<&TrackSummary> {
        if let CollectionEntity::Track(t) = &self.entity {
            Some(t)
        } else {
            None
        }
    }
    fn related(&self, role: ArtistTrackRole) -> &[i64] {
        let key = if matches!(self.entity, CollectionEntity::Artist(_)) {
            match role {
                ArtistTrackRole::Performer => "performer",
                ArtistTrackRole::AlbumArtist => "album_artist",
                ArtistTrackRole::Composer => "composer",
                ArtistTrackRole::Lyricist => "lyricist",
            }
        } else {
            "tracks"
        };
        self.related.get(key).map(Vec::as_slice).unwrap_or(&[])
    }
}
fn object(v: Value) -> serde_json::Map<String, Value> {
    v.as_object().unwrap().clone()
}

pub(super) async fn load_catalog(pool: &DbPool, max_rating: bool) -> Result<Catalog> {
    // All joins are batched. A release identity has exactly one visible song,
    // regardless of how many devices or codecs hold it.
    let rows = sqlx::query(&track_select_sql(
        "WHERE t.id IN (SELECT track_id FROM visible_catalog_tracks) GROUP BY t.id",
    ))
    .fetch_all(pool)
    .await?;
    let ages: HashMap<i64,String> = sqlx::query_as("SELECT COALESCE(l.release_identity_id,l.release_track_id),MIN(f.created_at) FROM track_catalog_links l JOIN tracks t ON t.id=l.track_id JOIN files f ON f.id=t.file_id GROUP BY COALESCE(l.release_identity_id,l.release_track_id)").fetch_all(pool).await?.into_iter().collect();
    let albums = list_albums(pool, u32::MAX, 0).await?;
    let covers: HashMap<i64, i64> = albums
        .iter()
        .filter_map(|a| a.cover_asset_id.map(|c| (a.id, c)))
        .collect();
    let mut tracks = HashMap::new();
    let mut raw_to_release = HashMap::new();
    for row in rows {
        let mut t = row_to_track(row)?;
        let id = t
            .release_identity_id
            .ok_or_else(|| anyhow::anyhow!("visible song has no release identity"))?;
        if let Some(age) = ages.get(&id) {
            t.added_at = parse_datetime(age.clone())?;
        }
        if t.cover_asset_id.is_none() {
            t.cover_asset_id = t.album_id.and_then(|i| covers.get(&i).copied());
        }
        if max_rating
            && t.tag_rating
                .zip(t.tag_rating_scale)
                .is_some_and(|(r, s)| s > 0 && r >= s)
        {
            t.is_favorite = true;
        }
        raw_to_release.insert(t.id, id);
        tracks.insert(id, Candidate { id, fields: object(json!({"name":t.title,"artist":t.artist_display,"album":t.album_title,"year":t.year,"genres":t.genres,"favorite":t.is_favorite,"rating":t.effective_rating,"duration_ms":t.duration_ms,"added_at":t.added_at,"play_count":0,"plays_30_days":0,"available":t.is_available,"display_mode":t.display_mode,"source_ids":[],"performer_ids":[]})), entity:CollectionEntity::Track(Box::new(t)), related:HashMap::new() });
    }
    // Include history and sources from every replica of the same release.
    for (raw, id) in sqlx::query_as::<_, (i64, i64)>(
        "SELECT track_id,COALESCE(release_identity_id,release_track_id) FROM track_catalog_links",
    )
    .fetch_all(pool)
    .await?
    {
        raw_to_release.insert(raw, id);
    }
    let history=sqlx::query_as::<_,(i64,i64,i64)>("SELECT track_id,COUNT(*),SUM(CASE WHEN datetime(started_at)>=datetime('now','-30 days') THEN 1 ELSE 0 END) FROM playback_sessions WHERE track_id IS NOT NULL GROUP BY track_id").fetch_all(pool).await?;
    for (raw, count, recent) in history {
        if let Some(t) = raw_to_release.get(&raw).and_then(|id| tracks.get_mut(id)) {
            for (key, value) in [("play_count", count), ("plays_30_days", recent)] {
                t.fields.insert(
                    key.into(),
                    json!(t.fields[key].as_i64().unwrap_or(0) + value),
                );
            }
        }
    }
    let sources=sqlx::query_as::<_,(i64,i64)>("SELECT t.id,r.id FROM tracks t JOIN files f ON f.id=t.file_id JOIN library_roots r ON r.id=f.library_root_id LEFT JOIN devices d ON d.id=r.owner_device_id WHERE f.deleted_at IS NULL AND r.enabled=1 AND r.retired_at IS NULL AND r.removed_at IS NULL AND (d.id IS NULL OR d.removed_at IS NULL)").fetch_all(pool).await?;
    for (raw, source) in sources {
        if let Some(t) = raw_to_release.get(&raw).and_then(|id| tracks.get_mut(id)) {
            let arr = t
                .fields
                .get_mut("source_ids")
                .unwrap()
                .as_array_mut()
                .unwrap();
            if !arr.contains(&json!(source)) {
                arr.push(json!(source));
            }
        }
    }
    let mut relations: HashMap<i64, HashMap<String, Vec<i64>>> = HashMap::new();
    let credits = sqlx::query_as::<_, (i64, i64, String)>(
        "SELECT track_id,artist_id,role FROM track_artists",
    )
    .fetch_all(pool)
    .await?;
    for (raw, artist, role) in credits {
        if let Some(id) = raw_to_release
            .get(&raw)
            .filter(|id| tracks.contains_key(id))
        {
            let role = match role.as_str() {
                "primary" | "featured" => "performer",
                "composer" => "composer",
                "lyricist" => "lyricist",
                _ => continue,
            };
            let related = relations
                .entry(artist)
                .or_default()
                .entry(role.into())
                .or_default();
            if !related.contains(id) {
                related.push(*id);
            }
            if role == "performer" {
                let list = tracks
                    .get_mut(id)
                    .unwrap()
                    .fields
                    .get_mut("performer_ids")
                    .unwrap()
                    .as_array_mut()
                    .unwrap();
                if !list.contains(&json!(artist)) {
                    list.push(json!(artist));
                }
            }
        }
    }
    for (album,artist) in sqlx::query_as::<_,(i64,i64)>("SELECT DISTINCT COALESCE(i.canonical_album_id,a.album_id),a.artist_id FROM album_artists a LEFT JOIN album_identity_members i ON i.album_id=a.album_id").fetch_all(pool).await? {
        let related=relations.entry(artist).or_default().entry("album_artist".into()).or_default();
        related.extend(tracks.values().filter(|t|t.track().unwrap().album_id==Some(album)).map(|t|t.id)); related.sort(); related.dedup();
    }
    for candidate in tracks.values_mut() {
        let count = candidate.fields["play_count"].as_i64().unwrap_or(0);
        if let CollectionEntity::Track(t) = &mut candidate.entity {
            t.play_count = count;
        }
    }
    let mut entities = HashMap::new();
    entities.insert(EntityType::Track, tracks.values().cloned().collect());
    let album_profiles: HashMap<i64, (Value, Option<String>, Option<String>)> = sqlx::query(
        "SELECT album_id,genres_json,release_type,country FROM album_metadata_profiles",
    )
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|r| {
        Ok((
            r.try_get("album_id")?,
            (
                serde_json::from_str(&r.try_get::<String, _>("genres_json")?)?,
                r.try_get("release_type")?,
                r.try_get("country")?,
            ),
        ))
    })
    .collect::<Result<_>>()?;
    let mut album_items = Vec::new();
    for mut a in albums {
        let ids: Vec<i64> = tracks
            .values()
            .filter(|c| c.track().unwrap().album_id == Some(a.id))
            .map(|c| c.id)
            .collect();
        if ids.is_empty() {
            continue;
        }
        a.track_count = ids.len() as i64;
        let profile = album_profiles.get(&a.id);
        let fields = object(
            json!({"name":a.title,"artist":a.album_artist_display,"year":a.year,"genres":profile.map(|p|&p.0),"release_type":profile.and_then(|p|p.1.as_ref()),"country":profile.and_then(|p|p.2.as_ref())}),
        );
        album_items.push(Candidate {
            id: a.id,
            entity: CollectionEntity::Album(a),
            fields,
            related: HashMap::from([("tracks".into(), ids)]),
        });
    }
    entities.insert(EntityType::Album, album_items);
    let artist_profiles: HashMap<i64, (Value, Option<String>, Option<String>)> =
        sqlx::query("SELECT artist_id,genres_json,country,artist_type FROM artist_profiles")
            .fetch_all(pool)
            .await?
            .into_iter()
            .map(|r| {
                Ok((
                    r.try_get("artist_id")?,
                    (
                        serde_json::from_str(&r.try_get::<String, _>("genres_json")?)?,
                        r.try_get("country")?,
                        r.try_get("artist_type")?,
                    ),
                ))
            })
            .collect::<Result<_>>()?;
    let mut artist_items = Vec::new();
    for mut a in list_artists(pool, u32::MAX, 0).await? {
        let related = relations.remove(&a.id).unwrap_or_default();
        if related.values().all(Vec::is_empty) {
            continue;
        }
        let ids = related.get("performer").cloned().unwrap_or_default();
        a.track_count = ids.len() as i64;
        a.album_count = ids
            .iter()
            .filter_map(|id| tracks[id].track().unwrap().album_id)
            .collect::<HashSet<_>>()
            .len() as i64;
        let p = artist_profiles.get(&a.id);
        let fields = object(
            json!({"name":a.name,"genres":p.map(|p|&p.0),"country":p.and_then(|p|p.1.as_ref()),"artist_type":p.and_then(|p|p.2.as_ref())}),
        );
        artist_items.push(Candidate {
            id: a.id,
            entity: CollectionEntity::Artist(a),
            fields,
            related,
        });
    }
    entities.insert(EntityType::Artist, artist_items);
    let mut genre_items = Vec::new();
    for (id, name) in sqlx::query_as::<_, (i64, String)>("SELECT id,name FROM genres")
        .fetch_all(pool)
        .await?
    {
        let ids: Vec<i64> = tracks
            .values()
            .filter(|c| c.track().unwrap().genres.contains(&name))
            .map(|c| c.id)
            .collect();
        if ids.is_empty() {
            continue;
        }
        let albums = ids
            .iter()
            .filter_map(|id| tracks[id].track().unwrap().album_id)
            .collect::<HashSet<_>>();
        let artists = ids
            .iter()
            .flat_map(|id| tracks[id].fields["performer_ids"].as_array().unwrap())
            .filter_map(Value::as_i64)
            .collect::<HashSet<_>>();
        genre_items.push(Candidate {
            id,
            fields: object(json!({"name":name,"artist_count":artists.len()})),
            entity: CollectionEntity::Genre(GenreSummary {
                id,
                name,
                track_count: ids.len() as u64,
                album_count: albums.len() as u64,
                artist_count: artists.len() as u64,
            }),
            related: HashMap::from([("tracks".into(), ids)]),
        });
    }
    entities.insert(EntityType::Genre, genre_items);
    for (kind, items) in &mut entities {
        if *kind == EntityType::Track {
            continue;
        }
        for item in items {
            let related: Vec<&Candidate> = item
                .related(ArtistTrackRole::Performer)
                .iter()
                .filter_map(|i| tracks.get(i))
                .collect();
            let count = related.len();
            let available = related
                .iter()
                .filter(|t| t.track().unwrap().is_available)
                .count();
            item.fields.extend(object(json!({"track_count":count,"album_count":related.iter().filter_map(|t|t.track().unwrap().album_id).collect::<HashSet<_>>().len(),"play_count":related.iter().map(|t|t.fields["play_count"].as_i64().unwrap_or(0)).sum::<i64>(),"plays_30_days":related.iter().map(|t|t.fields["plays_30_days"].as_i64().unwrap_or(0)).sum::<i64>(),"favorite_count":related.iter().filter(|t|t.track().unwrap().is_favorite).count(),"available":available>0,"all_available":count>0 && available==count,"added_at":related.iter().map(|t|t.track().unwrap().added_at).max()})));
        }
    }
    Ok(Catalog { entities, tracks })
}

pub(super) fn field_specs(kind: EntityType) -> Vec<(&'static str, &'static str, &'static str)> {
    let mut fields = vec![
        ("name", "名称", "text"),
        ("play_count", "累计播放次数", "number"),
        ("plays_30_days", "近 30 天播放次数", "number"),
        ("available", "至少有可用歌曲", "bool"),
        ("added_at", "入库时间", "date"),
    ];
    if kind == EntityType::Track {
        fields.extend([
            ("artist", "演唱艺术家", "text"),
            ("album", "专辑", "text"),
            ("year", "歌曲年份", "number"),
            ("genres", "歌曲流派", "tags"),
            ("favorite", "已收藏", "bool"),
            ("rating", "评分", "number"),
            ("duration_ms", "时长（毫秒）", "number"),
            ("display_mode", "展示属性", "mode"),
            ("source_ids", "音乐来源", "ids"),
        ]);
    } else {
        fields.extend([
            ("track_count", "歌曲数量", "number"),
            ("album_count", "专辑数量", "number"),
            ("favorite_count", "收藏歌曲数量", "number"),
            ("all_available", "全部歌曲可用", "bool"),
        ]);
    }
    if kind == EntityType::Album {
        fields.extend([
            ("artist", "专辑艺术家", "text"),
            ("year", "发行年份", "number"),
            ("genres", "专辑自身流派", "tags"),
            ("release_type", "发行类型", "text"),
            ("country", "发行地区", "text"),
        ]);
    }
    if kind == EntityType::Artist {
        fields.extend([
            ("genres", "艺术家自身流派", "tags"),
            ("country", "国家或地区", "text"),
            ("artist_type", "艺术家类型", "text"),
        ]);
    }
    if kind == EntityType::Genre {
        fields.push(("artist_count", "艺术家数量", "number"));
    }
    fields
}
pub(super) fn operators(kind: &str) -> Vec<&'static str> {
    match kind {
        "number" => vec!["eq", "gte", "lte", "is_empty"],
        "bool" => vec!["eq"],
        "date" => vec!["within_days", "is_empty"],
        "ids" => vec!["in", "all_in", "not_in"],
        "mode" => vec!["eq"],
        _ => vec!["eq", "contains", "not_eq", "is_empty"],
    }
}
pub fn collection_rule_schema() -> Value {
    json!({"entity_types":["track","album","artist","genre"],"types":([EntityType::Track,EntityType::Album,EntityType::Artist,EntityType::Genre]).into_iter().map(|kind|json!({"entity_type":kind,"fields":field_specs(kind).into_iter().map(|(key,label,t)|json!({"field":key,"label":label,"type":t,"operators":operators(t)})).collect::<Vec<_>>()})).collect::<Vec<_>>(),"max_depth":6,"max_conditions":100,"max_members":10000,"max_result":10000,"timezone":"UTC"})
}
pub(super) fn validate_predicate(
    p: &CollectionPredicate,
    kind: EntityType,
    depth: usize,
    budget: &mut usize,
) -> Result<()> {
    *budget += 1;
    if depth > 6 || *budget > 100 {
        return Err(fail("collection_invalid", "筛选条件过多或嵌套过深"));
    }
    match p {
        CollectionPredicate::All { conditions } | CollectionPredicate::Any { conditions } => {
            for p in conditions {
                validate_predicate(p, kind, depth + 1, budget)?;
            }
        }
        CollectionPredicate::Tracks {
            quantifier,
            value,
            role: _,
            condition,
        } => {
            if kind == EntityType::Track
                || (*quantifier == TrackQuantifier::Percent && !(1..=100).contains(value))
                || (*quantifier == TrackQuantifier::AtLeast && !(1..=1000000).contains(value))
            {
                return Err(fail("collection_invalid", "关联歌曲条件无效"));
            }
            validate_predicate(condition, EntityType::Track, depth + 1, budget)?;
        }
        CollectionPredicate::Field { field, op, value } => {
            let spec = field_specs(kind)
                .into_iter()
                .find(|s| s.0 == field)
                .ok_or_else(|| fail("collection_invalid", format!("不支持的字段：{field}")))?;
            if !operators(spec.2).contains(&op.as_str()) {
                return Err(fail("collection_invalid", "字段运算符无效"));
            }
            let valid = if op == "is_empty" {
                value.is_boolean()
            } else {
                match spec.2 {
                    "number" => value.as_f64().is_some_and(f64::is_finite),
                    "bool" => value.is_boolean(),
                    "date" => value.as_u64().is_some_and(|v| (1..=36500).contains(&v)),
                    "ids" => value.as_array().is_some_and(|v| {
                        !v.is_empty()
                            && v.len() <= 100
                            && v.iter().all(|i| i.as_i64().is_some_and(|v| v > 0))
                    }),
                    "mode" => value
                        .as_str()
                        .is_some_and(|s| ["inherit", "merged", "independent"].contains(&s)),
                    _ => value
                        .as_str()
                        .is_some_and(|s| !s.trim().is_empty() && s.len() <= 500),
                }
            };
            if !valid {
                return Err(fail("collection_invalid", format!("字段值无效：{field}")));
            }
        }
    }
    Ok(())
}
fn equals(a: &Value, b: &Value) -> bool {
    if let (Some(a), Some(b)) = (a.as_str(), b.as_str()) {
        a.to_lowercase() == b.to_lowercase()
    } else {
        a == b
    }
}
pub(super) fn matches(
    p: &CollectionPredicate,
    item: &Candidate,
    catalog: &Catalog,
    now: DateTime<Utc>,
) -> bool {
    match p {
        CollectionPredicate::All { conditions } => {
            conditions.iter().all(|p| matches(p, item, catalog, now))
        }
        CollectionPredicate::Any { conditions } => {
            conditions.iter().any(|p| matches(p, item, catalog, now))
        }
        CollectionPredicate::Tracks {
            quantifier,
            value,
            role,
            condition,
        } => {
            let ids = item.related(*role);
            let total = ids.len();
            let count = ids
                .iter()
                .filter_map(|id| catalog.tracks.get(id))
                .filter(|t| matches(condition, t, catalog, now))
                .count();
            match quantifier {
                TrackQuantifier::Any => count > 0,
                TrackQuantifier::All => total > 0 && count == total,
                TrackQuantifier::AtLeast => count >= *value as usize,
                TrackQuantifier::Percent => total > 0 && count * 100 >= total * (*value as usize),
            }
        }
        CollectionPredicate::Field { field, op, value } => {
            let actual = item.fields.get(field).unwrap_or(&Value::Null);
            if op == "is_empty" {
                return (actual.is_null()
                    || actual.as_array().is_some_and(Vec::is_empty)
                    || actual.as_str() == Some(""))
                    == value.as_bool().unwrap_or(true);
            }
            if actual.is_null() {
                return false;
            }
            let one = |v: &Value| {
                if op == "contains" {
                    v.as_str()
                        .zip(value.as_str())
                        .is_some_and(|(a, b)| a.to_lowercase().contains(&b.to_lowercase()))
                } else {
                    equals(v, value)
                }
            };
            match op.as_str() {
                "eq" | "contains" => actual
                    .as_array()
                    .map(|a| a.iter().any(one))
                    .unwrap_or_else(|| one(actual)),
                "not_eq" => !actual
                    .as_array()
                    .map(|a| a.iter().any(one))
                    .unwrap_or_else(|| one(actual)),
                "gte" => actual
                    .as_f64()
                    .zip(value.as_f64())
                    .is_some_and(|(a, b)| a >= b),
                "lte" => actual
                    .as_f64()
                    .zip(value.as_f64())
                    .is_some_and(|(a, b)| a <= b),
                "within_days" => actual
                    .as_str()
                    .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                    .is_some_and(|t| {
                        t <= now && t >= now - chrono::Duration::days(value.as_i64().unwrap_or(0))
                    }),
                "in" | "all_in" | "not_in" => {
                    let a = actual.as_array().cloned().unwrap_or_default();
                    let v = value.as_array().cloned().unwrap_or_default();
                    if op == "all_in" {
                        v.iter().all(|x| a.contains(x))
                    } else {
                        v.iter().any(|x| a.contains(x)) != (op == "not_in")
                    }
                }
                _ => false,
            }
        }
    }
}

pub(super) struct Generated {
    pub items: Vec<(CollectionItem, Vec<i64>)>,
    pub matched: usize,
    pub missing: Vec<i64>,
}
pub(super) fn generate(
    def: &CollectionDefinition,
    catalog: &Catalog,
    seed: &str,
    previous: &HashSet<i64>,
    now: DateTime<Utc>,
) -> Generated {
    let items = catalog
        .entities
        .get(&def.entity_type)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let index: HashMap<i64, &Candidate> = items.iter().map(|c| (c.id, c)).collect();
    let excluded: HashSet<i64> = def.excluded.iter().copied().collect();
    let fixed: HashSet<i64> = def.included.iter().copied().collect();
    let mut dynamic: Vec<&Candidate> = items
        .iter()
        .filter(|c| {
            def.automatic
                .as_ref()
                .is_some_and(|p| matches(p, c, catalog, now))
                && !excluded.contains(&c.id)
        })
        .collect();
    let matched = dynamic.len();
    dynamic.retain(|c| !fixed.contains(&c.id));
    dynamic.sort_by(|a, b| {
        for sort in &def.sort {
            let order = if sort.field == "random" {
                let hash = |id: i64| {
                    let mut h = Sha384::new();
                    h.update(seed.as_bytes());
                    h.update(id.to_le_bytes());
                    h.finalize().to_vec()
                };
                previous
                    .contains(&a.id)
                    .cmp(&previous.contains(&b.id))
                    .then_with(|| hash(a.id).cmp(&hash(b.id)))
            } else {
                let av = a.fields.get(&sort.field).unwrap_or(&Value::Null);
                let bv = b.fields.get(&sort.field).unwrap_or(&Value::Null);
                // Unknown values always sort last, in either direction.
                if av.is_null() != bv.is_null() {
                    return av.is_null().cmp(&bv.is_null());
                }
                let cmp = if let (Some(a), Some(b)) = (av.as_f64(), bv.as_f64()) {
                    a.total_cmp(&b)
                } else {
                    av.to_string()
                        .to_lowercase()
                        .cmp(&bv.to_string().to_lowercase())
                };
                if sort.descending {
                    cmp.reverse()
                } else {
                    cmp
                }
            };
            if !order.is_eq() {
                return order;
            }
        }
        a.id.cmp(&b.id)
    });
    let missing = def
        .included
        .iter()
        .filter(|id| !index.contains_key(id))
        .copied()
        .collect();
    let mut selected: Vec<(&Candidate, &str)> = def
        .included
        .iter()
        .filter(|id| !excluded.contains(id))
        .filter_map(|id| index.get(id).map(|c| (*c, "specified")))
        .collect();
    let mut artist_counts = HashMap::<i64, u32>::new();
    let mut album_counts = HashMap::<i64, u32>::new();
    for c in dynamic {
        if def
            .limit
            .is_some_and(|limit| selected.len() >= limit as usize)
        {
            break;
        }
        if let Some(t) = c.track() {
            let artists: Vec<i64> = c.fields["performer_ids"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(Value::as_i64)
                .collect();
            if def.max_per_artist.is_some_and(|max| {
                artists
                    .iter()
                    .any(|a| artist_counts.get(a).copied().unwrap_or(0) >= max)
            }) || def.max_per_album.is_some_and(|max| {
                t.album_id
                    .is_some_and(|id| album_counts.get(&id).copied().unwrap_or(0) >= max)
            }) {
                continue;
            }
            for a in artists {
                *artist_counts.entry(a).or_default() += 1;
            }
            if let Some(a) = t.album_id {
                *album_counts.entry(a).or_default() += 1;
            }
        }
        selected.push((c, "rule"));
    }
    let items = selected
        .into_iter()
        .map(|(c, reason)| {
            let mut tracks: Vec<&Candidate> = if def.entity_type == EntityType::Track {
                vec![c]
            } else {
                c.related(def.playback.artist_role)
                    .iter()
                    .filter_map(|id| catalog.tracks.get(id))
                    .filter(|t| {
                        def.playback
                            .filter
                            .as_ref()
                            .is_none_or(|p| matches(p, t, catalog, now))
                    })
                    .collect()
            };
            tracks.sort_by(|a, b| {
                let at = a.track().unwrap();
                let bt = b.track().unwrap();
                match def.playback.order.as_str() {
                    "name" => at
                        .title
                        .to_lowercase()
                        .cmp(&bt.title.to_lowercase())
                        .then(a.id.cmp(&b.id)),
                    "random" => {
                        let hash = |id: i64| {
                            let mut h = Sha384::new();
                            h.update(seed.as_bytes());
                            h.update(id.to_le_bytes());
                            h.finalize().to_vec()
                        };
                        hash(a.id).cmp(&hash(b.id))
                    }
                    _ => at
                        .album_title
                        .cmp(&bt.album_title)
                        .then(at.album_id.cmp(&bt.album_id))
                        .then(at.disc_number.cmp(&bt.disc_number))
                        .then(at.track_number.cmp(&bt.track_number))
                        .then(a.id.cmp(&b.id)),
                }
            });
            (
                CollectionItem {
                    entity_id: c.id,
                    entity: c.entity.clone(),
                    reason: reason.into(),
                },
                tracks.iter().map(|t| t.id).collect(),
            )
        })
        .collect();
    Generated {
        items,
        matched,
        missing,
    }
}

pub async fn collection_genre_detail(pool: &DbPool, id: i64, max_rating: bool) -> Result<Value> {
    let catalog = load_catalog(pool, max_rating).await?;
    let genre = catalog
        .entities
        .get(&EntityType::Genre)
        .into_iter()
        .flatten()
        .find(|g| g.id == id)
        .ok_or_else(|| fail("collection_not_found", "流派不存在"))?;
    let CollectionEntity::Genre(summary) = &genre.entity else {
        unreachable!()
    };
    let mut tracks: Vec<TrackSummary> = genre
        .related(ArtistTrackRole::Performer)
        .iter()
        .filter_map(|id| catalog.tracks.get(id)?.track().cloned())
        .collect();
    tracks.sort_by(|a, b| {
        a.title
            .to_lowercase()
            .cmp(&b.title.to_lowercase())
            .then(a.id.cmp(&b.id))
    });
    Ok(json!({"genre":summary,"tracks":tracks}))
}
