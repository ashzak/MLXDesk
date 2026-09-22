# Distribution Checklist

The build script creates a conventional macOS app bundle. Without a Developer ID identity it applies an ad-hoc signature and labels the result as a development preview.

For public distribution:

1. Join the Apple Developer Program and install a `Developer ID Application` certificate.
2. Run `SIGNING_IDENTITY="Developer ID Application: …" ./Scripts/package-app.sh`.
3. Submit the resulting zip with `xcrun notarytool`, staple the accepted ticket, and run Gatekeeper verification on a clean Mac user account.
4. Host signed releases and configure a signed updater feed before enabling automatic updates. No updater is silently enabled in the current build because there is no release URL or update-signing key.
5. Test at least one 8 GB, 16 GB, and 32+ GB Apple-silicon Mac, plus offline launch, interrupted download, sleep/wake, and low-disk behavior.

The legacy Python server can be selected with `MLX_DESK_USE_LEGACY_SERVER=1`; it is a compatibility escape hatch, not the distribution default.

