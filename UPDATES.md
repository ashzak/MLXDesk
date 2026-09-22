# Signed Updates

Sparkle 2.9.5 is integrated but remains dormant in preview builds. To activate it:

1. Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` and protect the private key it creates in Keychain.
2. Set `UPDATE_FEED_URL` to an HTTPS appcast URL and `UPDATE_PUBLIC_KEY` to the generated public EdDSA key when packaging.
3. Sign with a Developer ID identity, notarize the archive, and generate the appcast with Sparkle's `generate_appcast` tool.
4. Publish the DMG/zip and appcast at stable HTTPS URLs, then test an update from the previous signed release on a clean Mac account.

Example:

```sh
SIGNING_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="mlx-desk-notary" \
UPDATE_FEED_URL="https://downloads.example.com/mlx-desk/appcast.xml" \
UPDATE_PUBLIC_KEY="…" \
./Scripts/release-preview.sh
```

The application checks that both settings are real before starting Sparkle. Placeholder or missing values cannot initiate network update checks.
