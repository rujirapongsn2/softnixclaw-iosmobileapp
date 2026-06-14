# Softnix Mobile for iOS

Native SwiftUI chat client for the Softnix `softnix_app` channel. The main chat experience is fully native; `WKWebView` is used only for OAuth sign-in.

## Requirements

- Xcode 26 or newer
- iOS 17 or newer
- A reachable Softnix Admin API with `channels.softnix_app.enabled`
- HTTPS for production deployments
- An APNs-enabled App ID and provisioning profile for push notifications

## Run

1. Open `SoftnixMobile.xcodeproj`.
2. Set the signing team and bundle identifier if required.
3. Select `SoftnixMobile` and an iOS device or Simulator.
4. Build and run.
5. Pair from Admin Console > Channels > Softnix App.

The Simulator cannot scan a camera QR code. Paste the pairing URL or JSON into the fallback field. No API host, instance ID, token, or credential is compiled into the app.

## Backend configuration

The QR code must contain `instance_id`, a single-use pairing token, and optionally `api_base_url`. If no API URL is embedded, the URL hosting `/mobile` is used. Pairing tokens expire after ten minutes, and pairing a new device revokes the previous registered mobile device for that instance.

The backend must expose:

- `/admin/mobile/register`
- `/admin/mobile/bootstrap`
- `/admin/mobile/events` and `/admin/mobile/events/stream`
- `/admin/mobile/message`
- `/admin/mobile/media`
- `/admin/mobile/transcribe`
- `/admin/mobile/workflow-intents/*`
- `/admin/mobile/workflows/*`
- `/admin/mobile/push/subscribe` and `/admin/mobile/push/unsubscribe`

ATS permits local-network development endpoints, but arbitrary public HTTP loads are disabled. Public deployments must use HTTPS.

## Push notifications

Enable the Push Notifications and Background Modes capabilities in the Apple Developer profile. The app sends the APNs device token to Softnix with provider `apns`. Notification payloads are used only to select a session and trigger a server sync; payload text is never inserted into local chat history.

## Tests

```sh
xcodebuild test \
  -project SoftnixMobile.xcodeproj \
  -scheme SoftnixMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Tests cover reducer replay/deduplication, ordering, multiple sessions, processing grouping, optimistic failure/retry identity, attachment limits, workflow models, reconnect backoff, authenticated downloads, transcription errors, revoked credentials, and push deep links.

See [ARCHITECTURE.md](ARCHITECTURE.md) and [API_CONTRACT.md](API_CONTRACT.md).
