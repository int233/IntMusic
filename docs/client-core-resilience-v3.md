# Client/Core resilience architecture (v1.1)

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

## Connection states

The connection manager uses a quality state rather than a single offline flag:

| State | Foreground reads | Commands | Media choice |
| --- | --- | --- | --- |
| Healthy | Local projection | Send immediately, persist until ACK | Best eligible copy |
| Degraded | Local projection | Optimistic local apply; short bounded send | Prefer local copy |
| Reconnecting | Local projection | Durable outbox | Continue current local session |
| Offline | Local projection | Durable outbox | Local copies only |
| Resyncing | Local projection | Merge ACKs/events in background | Do not interrupt playback |

No state transition clears UI collections or constructs a second offline
catalog. Missing uncached data is represented as unavailable detail, not as an
empty authoritative result.

## Data and transport planes

- **Catalog plane:** revisioned pull/delta sync into normalized Client SQLite.
- **Control plane:** idempotent request/ACK commands with deadlines.
- **Event plane:** durable cursor-based session and library events.
- **Media plane:** local path or ranged HTTP stream, selected independently of
  catalog/control health and capable of buffered continuation.

## Migration sequence

1. **Foundation (current change):** introduce the v3 protocol, a pure Rust
   session queue model, persist/expose legacy shuffle seeds, and use the same
   deterministic transition in Flutter offline playback.
2. Add Client normalized catalog tables, sync cursors, mutation outbox, and
   session checkpoints. Redirect page reads away from live HTTP responses.
3. Run a Playback Agent per output. Move completion/next/previous/mode handling
   out of dashboard widgets into the agent.
4. Add Core session command journal, event cursor storage, ACK replay, and
   snapshot/resume endpoints.
5. Dual-write legacy and v3 session state, compare decisions in diagnostics,
   migrate active sessions, then remove `_offlineMode` catalog rewriting and
   the legacy queue algorithms.

Each step must preserve compatibility with v1 endpoints until telemetry and
contract tests show that all supported Clients have migrated.
