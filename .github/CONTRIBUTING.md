# Contributing to OAgents

OAgents is a Flutter Android app that embeds the opencode CLI on-device through a
native Kotlin bridge. You do not need a local Android or Flutter toolchain to
contribute — the CI pipelines build, test, lint and release the app for you.

## Build via CI (no local build required)

Every push and pull request to `main` runs:

- **CI** (`.github/workflows/ci.yml`) — formatting, `flutter analyze`, unit tests.
- **E2E** (`.github/workflows/e2e.yml`) — integration tests against an in-process
  mock opencode server (no external service required).
- **Auto-fix** (`.github/workflows/auto-fix.yml`) — on pushes to `main`, applies
  `dart fix` + `dart format` and commits the result as `oagents-bot`.

To work locally, run the same commands CI runs: `flutter pub get`,
`dart format lib/ test/ integration_test/`, `flutter analyze`, `flutter test`.

## Embedded opencode runtime

The opencode CLI and the NodeJS Mobile runtime are NOT committed to the repo.
They are produced by the **bundle-opencode** workflow
(`.github/workflows/bundle-opencode.yml`), which:

- bundles `sst/opencode` (the `dev` branch) into `opencode.bundle.js`,
- writes `version.txt` (`opencode-<short-sha>`) and `package.json`, and
- stages `libnode.so` per Android ABI under `jniLibs/<abi>/`.

It runs automatically on pushes to `main` (artifact only, never commits back),
can be triggered manually via `workflow_dispatch`, and is also called as a
prerequisite by the release workflow. The resulting `opencode-bundle` artifact is
what the release build embeds into the APK.

## Releases

Cut a release by tagging a commit:

```
git tag v1.0.0
git push origin v1.0.0
```

The **release** workflow (`.github/workflows/release.yml`) then:

1. builds a fresh `opencode-bundle` (via the reusable bundle-opencode workflow),
2. stages it into `android/app/src/main/assets/opencode/` and
   `android/app/src/main/jniLibs/<abi>/`,
3. builds signed, split-per-ABI release APKs (unsigned, with a warning, if no
   keystore secret is set — so the first release can still ship), and
4. publishes them to a GitHub Release with auto-generated notes.

## The `OAGENTS_CI_TOKEN` secret

The **auto-fix** and **release** workflows authenticate commits, pushes and
release uploads with a personal access token stored in the `OAGENTS_CI_TOKEN`
repository secret. The maintainer must create this token in GitHub
**Settings → Secrets and variables → Actions** and grant it `contents: write` for
the repository. No token is ever hardcoded in the workflows — every reference is
`${{ secrets.OAGENTS_CI_TOKEN }}`.

Release signing additionally uses the `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`
secrets; if these are absent the release ships an unsigned APK.
