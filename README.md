# MLX Desk

A native macOS SwiftUI client for running compatible language models privately with MLX on Apple silicon.

## Download

Grab the latest build from [Releases](https://github.com/ashzak/MLXDesk/releases/latest) (`.dmg` or `.zip`), then drag **MLX Desk.app** into `/Applications`.

The app is ad-hoc signed, not notarized, so Gatekeeper will block a plain double-click on first launch. Instead, right-click (or Control-click) the app and choose **Open**, or allow it under **System Settings → Privacy & Security** after the first blocked attempt. Requires macOS 14+ on Apple silicon.

## Run from source

```sh
swift run
```

The app uses Apple's native Swift MLX stack (`mlx-swift-lm`) by default, detects this Mac's hardware with llmfit, ranks compatible MLX models, validates disk/cache capacity, and streams responses without a localhost server. Set `MLX_DESK_USE_LEGACY_SERVER=1` only when testing the older Python compatibility path.

## Test

```sh
swift test
MLX_DESK_UI_TESTING=1 swift run
./Scripts/package-app.sh
```

Demo mode avoids model downloads and returns a deterministic streamed response for UI testing.

See [IMPROVEMENT_TRACKER.md](IMPROVEMENT_TRACKER.md) for the durable 10-item reliability roadmap and [DISTRIBUTION.md](DISTRIBUTION.md) for public-release prerequisites.

The productized preview also includes first-run onboarding, MLX model storage management, pause/resume recovery, idle/power/thermal unloading, performance history, redacted compatibility reports, localized resources, a DMG builder, generated third-party notices, and dormant signed-update support. See [UPDATES.md](UPDATES.md) for activation instructions.
