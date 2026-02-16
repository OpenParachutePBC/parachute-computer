# Releasing Parachute

This document describes how to create releases for Parachute.

## Quick Start

To create a new release:

```bash
# 1. Update version in pubspec.yaml
# version: 0.2.0+1

# 2. Commit the version bump
git add pubspec.yaml
git commit -m "Bump version to 0.2.0"

# 3. Create and push a tag
git tag v0.2.0
git push origin main
git push origin v0.2.0
```

This triggers the GitHub Actions release workflow, which:
1. Builds the macOS DMG
2. Generates SHA256 checksums
3. Creates a draft GitHub Release

## Version Format

Parachute uses semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes or major new features
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

The `pubspec.yaml` format is `version: X.Y.Z+BUILD`:
- `X.Y.Z` = Semantic version (shown to users)
- `BUILD` = Build number (incremented for each build)

## Local Building

To build the DMG locally:

```bash
cd app
./scripts/build_computer_dmg.sh
```

Output: `dist/ParachuteComputer-X.Y.Z.dmg`

### Developer Mode

For development builds that mount a local base path:

```bash
./scripts/build_computer_dmg.sh --dev-base-path ~/path/to/base
```

## Code Signing & Notarization

For production releases, macOS apps need to be:
1. **Code signed** with a Developer ID certificate
2. **Notarized** by Apple

### Setting Up Code Signing

1. **Get an Apple Developer account** ($99/year)
   - https://developer.apple.com/programs/

2. **Create a Developer ID Application certificate**
   - Open Keychain Access
   - Request a certificate from Apple
   - Export as .p12 file

3. **Add GitHub Secrets**
   Go to repository Settings > Secrets and variables > Actions:

   | Secret | Description |
   |--------|-------------|
   | `MACOS_CERTIFICATE` | Base64-encoded .p12 certificate |
   | `MACOS_CERTIFICATE_PASSWORD` | Password for the .p12 file |
   | `APPLE_ID` | Your Apple ID email |
   | `APPLE_APP_PASSWORD` | App-specific password (not your Apple ID password) |
   | `APPLE_TEAM_ID` | Your Apple Developer Team ID |

### Creating an App-Specific Password

1. Go to https://appleid.apple.com/
2. Sign in and go to Security > App-Specific Passwords
3. Generate a new password for "Parachute Notarization"

### Encoding the Certificate

```bash
base64 -i developer_id.p12 | pbcopy
# Paste into MACOS_CERTIFICATE secret
```

## Release Artifacts

Each release includes:

| File | Description |
|------|-------------|
| `ParachuteComputer-X.Y.Z.dmg` | macOS app with bundled Lima config and Parachute Computer |
| `checksums-sha256.txt` | SHA256 checksums for verification |

## Verification

Users can verify downloads:

```bash
# Check the checksum
shasum -a 256 -c checksums-sha256.txt
```

## Manual Release (Without Workflow)

If you need to create a release manually:

```bash
# Build locally
cd app
./scripts/build_computer_dmg.sh

# Generate checksum
cd dist
shasum -a 256 *.dmg > checksums-sha256.txt

# Upload to GitHub Releases manually
```

## Future Improvements

- [ ] iOS App Store deployment workflow
- [ ] Android Play Store deployment workflow
- [ ] Auto-update mechanism in the app
- [ ] Changelog generation from commit messages
- [ ] Linux AppImage/deb builds
