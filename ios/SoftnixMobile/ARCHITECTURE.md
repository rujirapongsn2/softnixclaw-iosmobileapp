# Architecture

## Layers

`Domain`

- Backend contract models with loss-tolerant metadata decoding.
- `ChatEventReducer`, the only component allowed to transform incoming or optimistic events into chat state.
- Timeline grouping for progress/tool events.

`Data`

- `APIClient` owns URL construction, encoding, authentication headers, HTTP error classification, SSE parsing, media downloads, and endpoint models.
- `ChatPersistence` uses a versioned SwiftData schema for messages, conversations, cursor state, and workflow decisions.
- Keychain stores the complete credential record, including API base URL, instance ID, device ID, and mobile token.

`Application`

- `SessionStore` coordinates handlers and exposes observable UI state.
- Explicit handlers cover pairing, auth interception, bootstrap, SSE, polling, send, attachments, media, voice, transcription, workflows, push, lifecycle sync, and network recovery.

`Presentation`

- Native SwiftUI authentication, conversation list, timeline, composer, workflow cards, attachment preview, audio controls, and voice recording.
- OAuth is the only flow that uses a web view.

## Event flow

All sources call the same reducer:

```text
bootstrap ─┐
SSE ───────┤
polling ───┼─> ChatEventReducer ─> ChatState ─> SwiftData ─> SwiftUI
push sync ─┤
optimistic ┘
```

`event_id` is the cursor and event deduplication key. `message_id` is the message upsert key. Events are sorted by timestamp and then message ID. Server replay is expected, including actionable workflow cards that precede the current cursor.

## Security

- Mobile credentials use Keychain accessibility `AfterFirstUnlockThisDeviceOnly`.
- Authenticated API calls use `X-Mobile-Token`; SSE also uses the query token required by the current backend.
- 401/403 responses clear local credentials and return to pairing.
- Attachment base64 and microphone buffers are never persisted.
- Tokenized media URLs are removed before persistence.
- Downloads validate status and reject JSON/HTML responses as media.
- Push content is treated as a sync hint, not authoritative history.

## Persistence and migration

`SoftnixSchemaV1` is the first versioned SwiftData schema. Add future schemas to `SoftnixMigrationPlan` and define lightweight or custom migration stages. The server remains authoritative; local storage is an offline cache plus optimistic delivery state.

## Realtime behavior

SSE reconnects after normal 120-second server expiration or network errors using 1, 2, 4, 8, 16, and 30-second delays. Polling runs every two seconds as a fallback. Both use the latest reducer cursor and can safely receive replayed events.
