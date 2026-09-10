# GitHub Secrets Setup

Add secrets at: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

---

## 1. Developer ID Certificate (Code Signing)

Required secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`

### Create a new certificate (if you don't have one)

1. **Keychain Access** → Certificate Assistant → **Request a Certificate From a Certificate Authority**
   - User Email: your Apple ID email
   - Common Name: your name
   - Request: **Saved to disk**

2. [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates) → **+** → **Developer ID Application**
   - Upload the `.certSigningRequest` file → Download the `.cer`

3. Double-click the `.cer` to install into Keychain

### Export as .p12

1. Keychain Access → **My Certificates** → find `Developer ID Application: Your Name (TEAMID)`
   - Must show a **▶** triangle with a private key underneath
2. **File → Export Items** → format: **Personal Information Exchange (.p12)**
3. Set a strong password → remember it for `APPLE_CERTIFICATE_PASSWORD`

### Encode and add to GitHub

```bash
# Encode and copy to clipboard
base64 -i /path/to/certificate.p12 | tr -d '\n' | pbcopy

# Verify it's valid first
./scripts/verify-p12.sh /path/to/certificate.p12
```

Expected verify output:
```
PASS: P12 file is valid
PASS: Found 1 certificate(s)
PASS: Found 1 private key(s)
PASS: Certificate is 'Developer ID Application' type
PASS: Certificate is valid for XXX more days
```

Add secrets:
- `APPLE_CERTIFICATE_P12` — paste the base64 output
- `APPLE_CERTIFICATE_PASSWORD` — the .p12 password

---

## 2. App Store Connect API Key (Notarization)

Required secrets: `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`

1. [appstoreconnect.apple.com/access/api](https://appstoreconnect.apple.com/access/api) → **Keys** → **+**
   - Name: `GitHub Actions`
   - Role: `Developer`
   - Click **Generate**

2. **Download the .p8 file** — you can only download it ONCE
3. Note the **Key ID** (e.g. `6X3CMK22CY`) and **Issuer ID** (UUID at the top of the page)

```bash
# Encode and copy
base64 -i /path/to/AuthKey_XXXXXX.p8 | tr -d '\n' | pbcopy

# Verify it looks right
head -1 /path/to/AuthKey_XXXXXX.p8  # → -----BEGIN PRIVATE KEY-----
```

Add secrets:
- `APP_STORE_CONNECT_API_KEY_P8` — base64-encoded .p8
- `APP_STORE_CONNECT_KEY_ID` — the Key ID string
- `APP_STORE_CONNECT_ISSUER_ID` — the Issuer UUID

---

## 3. Sparkle EdDSA Key (In-App Auto-Updates)

Required secret: `SPARKLE_EDDSA_PRIVATE_KEY`

The EdDSA key signs the appcast so Sparkle can verify updates are authentic.

```bash
# Find sign_update in your Tuist build (after tuist install)
find Tuist/.build -name "sign_update" | head -1

# Generate a new key pair (first time only)
./Tuist/.build/.../sign_update --generate-key

# This outputs:
# Private EdDSA key (keep secret): <base64-key>
# Public EdDSA key (add to Info.plist): <base64-key>
```

If you already have the key pair:
- Add the **private key** as secret `SPARKLE_EDDSA_PRIVATE_KEY`
- The **public key** should already be in `Sources/App/Info.plist` under `SUPublicEDKey`

> If you lose the private key, generate a new pair and update `SUPublicEDKey` in Info.plist — existing users will need to manually update once.

---

## 4. Codecov Token (Coverage Upload)

Required secret: `CODECOV_TOKEN`

1. Sign in at [codecov.io](https://codecov.io) with your GitHub account
2. Add the `siyanliu1/TouchQuota` repository
3. Copy the **Repository Upload Token**
4. Add secret: `CODECOV_TOKEN`

---

## 5. Optional: Signing Identity Override

Optional secret: `APP_IDENTITY`

If auto-detection of the signing identity fails (e.g. you have multiple Developer ID certs), set this to the exact identity string:

```
Developer ID Application: Your Name (TEAMID)
```

Leave unset to use auto-detection.

---

## Full Secrets Checklist

| Secret | Status |
|--------|--------|
| `APPLE_CERTIFICATE_P12` | required for signing |
| `APPLE_CERTIFICATE_PASSWORD` | required for signing |
| `APP_STORE_CONNECT_API_KEY_P8` | required for notarization |
| `APP_STORE_CONNECT_KEY_ID` | required for notarization |
| `APP_STORE_CONNECT_ISSUER_ID` | required for notarization |
| `SPARKLE_EDDSA_PRIVATE_KEY` | required for appcast signing |
| `CODECOV_TOKEN` | optional (coverage upload) |
| `APP_IDENTITY` | optional (signing override) |
