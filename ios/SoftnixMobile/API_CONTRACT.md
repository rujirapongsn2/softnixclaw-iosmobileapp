# Mobile API Contract

Every authenticated mobile request sends `X-Mobile-Token`. SSE additionally sends `mobile_token` because this is required by the current event-stream endpoint.

## Pairing

`POST /admin/mobile/register`

```json
{
  "instance_id": "instance",
  "device_id": "mob-uuid",
  "pairing_token": "pair-token",
  "label": "iPhone",
  "platform": "ios",
  "app_version": "1.0"
}
```

The response contains `device_token`.

## Synchronization

`GET /admin/mobile/bootstrap?instance_id=&sender_id=&active_session_id=`

`GET /admin/mobile/events?instance_id=&sender_id=&after_event_id=`

`GET /admin/mobile/events/stream?instance_id=&sender_id=&after_event_id=&mobile_token=`

SSE event name is `chat`, event ID is `event_id`, and data is a `ChatEvent`. The backend can replay workflow/card events before the cursor.

## Message

`POST /admin/mobile/message`

```json
{
  "instance_id": "instance",
  "sender_id": "mob-uuid",
  "text": "Hello",
  "message_id": "mobu-uuid",
  "session_id": "mobile-mob-uuid",
  "reply_to": null,
  "thread_root_id": null,
  "attachments": [],
  "metadata": {}
}
```

Retries reuse `message_id`.

## Attachment

Request attachment objects use `name`, `type`, `size`, and `data_base64`. Maximum size is 15 MB before base64 encoding. Server attachment responses may use `file_name`, `mime_type`, `kind`, `url`, `sender_id`, `source_url`, and `duration`.

Media is downloaded from `/admin/mobile/media` using the token header and a native temporary-file download.

## Voice

`POST /admin/mobile/transcribe` accepts the common attachment shape under `audio`. A successful response contains `transcript`. `error_code=groq_key_missing` means transcription is not configured.

## Workflow

Preflight:

- `POST /admin/mobile/workflow-intents/{intent_id}/approve`
- `POST /admin/mobile/workflow-intents/{intent_id}/reject`

Run approval:

- `POST /admin/mobile/workflows/{run_id}/approve`
- `POST /admin/mobile/workflows/{run_id}/reject`

The body contains `instance_id`, `sender_id`, and `session_id`.

## Push

`POST /admin/mobile/push/subscribe` sends `instance_id`, `device_id`, `push_token`, and `push_provider=apns`.

`POST /admin/mobile/push/unsubscribe` sends `instance_id` and `device_id`.
