# Client/Core resilience architecture (v1.2)

## Goal

IntMusic must remain responsive and deterministic when a connection is fast,
slow, reconnecting, or absent. A network transition must not replace the
catalog, reset the queue, change playback order, or block navigation.

## Non-negotiable invariants

1. The Client SQLite projection is the only read source for foreground UI.
   Core responses update that projection; widgets never wait for Core to render
   an already-known album, playlist, artist, track, or queue.
2. One playback output has one durable session. The renderer that owns the
   output is the playback authority and persists its queue, current item,
   position checkpoint, mode, shuffle seed, epoch, and revision.
3. Core coordinates sessions and library truth, but renderer playback does not
   depend on a WebSocket round trip at track completion.
4. Commands are idempotent. `command_id` identifies an intent, `epoch` rejects
   commands from an obsolete owner, and `expected_revision` detects conflicts.
5. Events are resumable by cursor. Reconnection requests missing events and a
   snapshot instead of assuming an in-memory WebSocket stream is complete.
6. Online and offline playback use the same queue state machine. Network state
   only changes which media copy and synchronization route are available.
7. Cached metadata is never replaced by filename-derived placeholder metadata
   merely because Core is unavailable.

## State ownership

| State | Authority | Client behavior |
| --- | --- | --- |
| Library identity and edits | Core | Read local projection; enqueue offline edits |
| Artwork, biographies, playlists | Core | Read cached normalized rows immediately |
| Output playback session | Renderer Playback Agent | Apply locally, checkpoint, then synchronize |
| Remote control intent | Originating Client until ACK | Persist outbox and retry with same command ID |
| Queue order and mode | Session owner | Replicate snapshot/events to Core and controllers |
| Favorites, history, ratings | Core after merge | Record locally with mutation ID while disconnected |
| Media availability | Each device | Publish copy manifests; choose a playable copy locally |

## Session protocol

The v3 contract lives in `crates/protocol/src/playback_session_v3.rs`.

- A session is addressed by `(session_id, epoch)`.
- Every mutation compares `expected_revision` and increments `revision` once.
- Replaying a completed `command_id` returns `duplicate` with its original
  applied revision.
- Session events have a monotonic `cursor`; clients resume from `after_cursor`.
- Queue entries have stable UUIDs because the same recording can occur more
  than once.
- Shuffle and repeat are independent. The shuffle order is derived from stable
  item IDs plus a persisted seed.

## Transport quality policy

Connection quality is an internal transport signal, not an application mode.
Widgets, catalog queries, queue transitions, and playback controls must never
branch into a separate "degraded" data model. The transport scheduler observes
RTT, timeouts, socket stability, and in-flight work, then adjusts concurrency,
deadlines, retries, polling, and media-copy preference.

| Transport observation | Foreground reads | Scheduling policy | Media choice |
| --- | --- | --- | --- |
| Stable | Local projection | Normal background budget | Best eligible copy |
| Constrained | Local projection | Reduce opportunistic work | Prefer local copy |
| Reconnecting | Local projection | Durable outbox and exponential backoff | Continue current local session |
| Unreachable | Local projection | Durable outbox; probe independently | Local copies only |
| Resynchronizing | Local projection | Merge ACKs/events in background | Do not interrupt playback |

These labels may appear in diagnostics, but they do not own business state. No
transport transition clears UI collections, constructs a second catalog,
changes queue order, or replaces canonical IDs. Missing uncached data is
represented as unavailable detail, not as an empty authoritative result.

## Data and transport planes

- **Catalog plane:** revisioned pull/delta sync into normalized Client SQLite.
- **Control plane:** idempotent request/ACK commands with deadlines.
- **Event plane:** durable cursor-based session and library events.
- **Media plane:** local path or ranged HTTP stream, selected independently of
  catalog/control health and capable of buffered continuation.

## Migration sequence

1. **Transport isolation (implemented):** separate playback control,
   connection health, inventory, and Client manifest traffic. A timeout retires
   its connection generation without immediately cancelling unrelated work.
   Manual manifest synchronization suppresses opportunistic catalog warmup,
   history, artwork, and distribution polling. Renderer registration is
   single-flight and WebSocket reconnects use bounded exponential backoff.
2. **Resumable Client manifests (implemented):** serialize folder scans, use
   adaptive batches and stable `batch_id` values, retry transient failures, and
   let Core deduplicate committed batches after a lost response.
3. **Normalized Client projection (implemented foundation):** albums, artists,
   tracks, playlists, details, artwork references, playback checkpoints, and
   queue checkpoints are read from individually keyed SQLite projection rows.
   Search and detail navigation use the same projection and refresh it in the
   background. Relationship tables, artwork byte inventory, and the durable
   mutation outbox are the remaining normalized-cache work.
4. **Playback Agent (implemented foundation):** each Client output owns one
   deterministic queue cursor restored from a persisted checkpoint. Completion
   and manual next/previous share traversal for sequential, single, repeat-one,
   repeat-all, and stable-seed shuffle modes. The agent now restores the Core
   v3 session identity, epoch, revision, event cursor, stable queue-item IDs,
   and independent playback modes. Pause, resume, stop, seek, next, previous,
   direct-track start, collection start, queue replacement/editing, and mode
   changes now prefer revisioned v3 commands. Collection start uses one atomic
   `replace_queue_and_play` intent, while legacy routes remain only as a
   compatibility fallback for an older Core.
5. **Resumable control and events (implemented foundation):** Core assigns
   emitted events a monotonic cursor, persists one ordered event journal before
   WebSocket delivery, retains a bounded replay window, and replays from the
   Client's `after_cursor` after reconnect or subscriber lag. Client SQLite
   stores the acknowledged cursor and ignores replay duplicates; a retention
   gap requests authoritative catalog, queue, and playback snapshots without
   replacing the foreground projection. Core persists v3 playback sessions and
   queue item UUIDs, rejects obsolete epochs and conflicting revisions, and
   stores command ACKs so a retry cannot execute the mutation twice. Clients
   negotiate the session, resume from their last cursor, apply typed ACKs, and
   rebase a revision conflict once against the returned snapshot. Commands are
   written to a short-lived Client SQLite outbox before transmission. An
   ambiguous timeout remains `pending` instead of being reported as success or
   translated to a legacy command; session recovery retries the original
   `command_id` for ACK/duplicate reconciliation and expires stale intents
   after 30 seconds.
6. **Remove legacy mode switching (in progress):** transport failure no longer
   rewrites catalog lists, status identity, or detail metadata, and synthetic
   offline album/artist/track summaries have been removed. Device and zone
   projections are also retained: remote outputs become unreachable while
   local output state is overlaid in place, rather than replacing the UI with a
   one-device offline list. The remaining local playback fallback flag is
   limited to command routing while the duplicated queue algorithms move into
   the Playback Agent. A development build rebuilds the Client projection
   instead of preserving obsolete local cache formats.

Core canonical metadata and physical-file relationships remain migratable.
Client caches are disposable during development: bump their schema identity
and rebuild them rather than extending the lifetime of legacy state branches.

## Implemented v3 HTTP surface

| Endpoint | Purpose |
| --- | --- |
| `GET /api/v1/playback-v3/zones/{zone_id}/session` | Load or create the authoritative durable session snapshot. |
| `POST /api/v1/playback-v3/zones/{zone_id}/commands` | Apply one idempotent, epoch- and revision-guarded command. |
| `POST /api/v1/playback-v3/zones/{zone_id}/resume` | Return the current snapshot plus retained session events after a cursor. |

Every command carries a UUID `command_id`, `session_id`, `epoch`, and
`expected_revision`. Successful application advances the revision exactly
once and emits `playback.session_v3.changed`. A repeated command returns the
stored result; it is never translated into a second legacy command after an
ambiguous timeout.
