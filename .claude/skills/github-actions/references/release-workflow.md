# Release Workflow Reference

## CHANGELOG.md Format

Release notes are auto-extracted from `CHANGELOG.md`. Use [Keep a Changelog](https://keepachangelog.com) format:

```markdown
## [Unreleased]

## [1.2.0] - 2025-06-15

### Added
- New provider support for XYZ

### Changed
- Improved quota refresh performance

### Fixed
- Memory leak when switching providers
```

Preview extraction before releasing:

```bash
./scripts/extract-changelog.sh 1.2.0
```

Notes flow: `CHANGELOG.md` → GitHub Release "What's New" + `appcast.xml` Sparkle description

---

## Release Cheat Sheet

```bash
# 1. Update CHANGELOG.md, then:
git add CHANGELOG.md
git commit -m "docs: add release notes for v1.2.0"
git push origin main

# Stable release
git tag v1.2.0 && git push origin v1.2.0

# Beta release
git tag v1.2.0-beta.1 && git push origin v1.2.0-beta.1

# Check Actions tab for progress
```

---

## Version Formats

| Format | Example | GitHub Release | Sparkle channel |
|--------|---------|---------------|----------------|
| `X.Y.Z` | `1.2.0` | Latest | stable (no channel tag) |
| `X.Y.Z-beta` | `1.2.0-beta` | Pre-release | `beta` |
| `X.Y.Z-beta.N` | `1.2.0-beta.3` | Pre-release | `beta` |
| `X.Y.Z-alpha.N` | `2.0.0-alpha.1` | Pre-release | `beta` |
| `X.Y.Z-rc.N` | `2.0.0-rc.1` | Pre-release | `beta` |

---

## Beta Channel Matrix

| User's Version | Appcast Contains | Beta Setting | Sparkle Offers |
|---------------|-----------------|--------------|----------------|
| 1.0.0 | 1.0.1-beta + 1.0.0 | ON | 1.0.1-beta |
| 1.0.0 | 1.0.1-beta + 1.0.0 | OFF | Nothing |
| 1.0.1-beta | 1.0.1 + 1.0.1-beta | Either | 1.0.1 (higher build #) |
| 1.0.0 | 1.0.2-beta + 1.0.1 | ON | 1.0.2-beta |
| 1.0.0 | 1.0.2-beta + 1.0.1 | OFF | 1.0.1 |

**Key rule**: Stable version always has a higher build number than its corresponding beta. `github.run_number` is the build number — it always increments, guaranteeing this.

---

## What Gets Published

Each release produces:
- `TouchQuota-X.Y.Z.zip` — notarized + stapled app (for Sparkle)
- `TouchQuota-X.Y.Z.zip.sha256` — checksum
- `TouchQuota-X.Y.Z.dmg` — signed DMG (for manual download)
- `TouchQuota-X.Y.Z.dmg.sha256` — checksum
- `docs/appcast.xml` — Sparkle feed (deployed to GitHub Pages)

TouchQuota has no Homebrew cask yet; users install from the DMG or ZIP attached to the GitHub release.

---

## Troubleshooting

### "0 valid identities found"

The Developer ID cert chain is broken in the runner keychain.

- Enable `debug: true` in manual dispatch to inspect
- Ensure .p12 contains both cert AND private key: `./scripts/verify-p12.sh cert.p12`
- Cert must be type **Developer ID Application** (not Mac Developer)

### "invalidPrivateKeyContents" during notarization

The .p8 API key is incorrectly encoded.

```bash
# Re-encode from the original file
base64 -i AuthKey_XXXX.p8 | tr -d '\n' | pbcopy
# Update APP_STORE_CONNECT_API_KEY_P8 secret
```

### "Invalid issuer" during notarization

- `APP_STORE_CONNECT_ISSUER_ID` is the **UUID** at the top of the API Keys page — not the Key ID
- `APP_STORE_CONNECT_KEY_ID` is the short alphanumeric ID next to the key name

### Appcast not updating

- Check `SPARKLE_EDDSA_PRIVATE_KEY` is set
- The `sign_update` binary must exist at `Tuist/.build/.../Sparkle/bin/sign_update` (present after `tuist install`)
- GitHub Pages must be enabled: **Settings → Pages → Source: GitHub Actions**

### Cert and key are separate in Keychain

```bash
# Combine them into a single .p12
./scripts/combine-cert-key.sh cert.cer key.p12 combined.p12
```

### Build fails with macro validation error

The `-skipMacroValidation` flag is already included in `xcodebuild archive`. If it reappears, check `PROJECT_SWIFT` — Mockable requires this flag on CI.