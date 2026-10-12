# Claudemeter

[日本語](README.ja.md)

A macOS menu bar app that shows your Claude Code (Pro / Max) usage limits in real time.

Menu bar: `Claude 5h 8% · 7d 41%` (5-hour window / weekly window, percent used; the `Claude` prefix is always shown so the app is distinguishable from a Codex meter placed next to it)
Dropdown: a bar per window with time until reset, per-model weekly windows, extra usage spend, last update, refresh interval, launch at login, quit

Source only. No signed binaries are distributed; build it yourself with the steps below.

## How it works

- Uses the OAuth token that Claude Code stores in the Keychain item `Claude Code-credentials` at login to call `GET https://api.anthropic.com/api/oauth/usage` (the same data as `/usage`).
- When it fetches
  - On a timer: every 30 s / 1 min / 5 min (default 1 min)
  - 3 seconds after any `~/.claude/projects/**/*.jsonl` session transcript changes, i.e. right after Claude Code receives a response
  - On wake from sleep, when the dropdown opens, and on demand
  - Never more often than every 15 seconds; on HTTP 429 it waits until `Retry-After`
- If the access token has expired it is refreshed with the refresh token and **written back to the same Keychain item**, so the `claude` CLI keeps working.
- The last successful result is cached in UserDefaults and shown as stale data right after launch or when a fetch fails.

## Requirements

- macOS 14 or later
- **Xcode 26 or later** (the Command Line Tools alone cannot build it: their SDK and compiler versions do not match)

```bash
sudo xcode-select -s <path to Xcode.app>
sudo xcodebuild -license accept
```

- Logged in to Claude Code (`claude`), so the Keychain item exists

## Build and run

```bash
scripts/build-app.sh --install
```

Builds `build/Claudemeter.app`, copies it to `/Applications` (override with `INSTALL_DIR`) and launches it. Without `--install` it only builds.

Keychain access goes through `/usr/bin/security`, the same tool the `claude` CLI uses for this item, so no permission is tied to the app itself and nothing is asked on first launch or after a rebuild.

If a dialog saying "security wants to access key \"Claude Code-credentials\"" with a password field appears, the item has lost `apple-tool:` from its ACL partition list (this happens when another app rewrites the item through Security.framework; see [anthropics/claude-code#62213](https://github.com/anthropics/claude-code/issues/62213)). Enter the login keychain password and choose "Always Allow" once; both the `claude` CLI and Claudemeter then stay silent until something rewrites the item again. Claudemeter never does that: it updates the item only through `security`, which keeps `apple-tool:` in place.

Signing: an `Apple Development` certificate is used if one exists, otherwise the app is ad-hoc signed. Either way the Keychain does not care, because the item is only ever touched by `/usr/bin/security`.

If Xcode is not installed and `swift build` from the Command Line Tools is broken, `scripts/build-app-clt-fallback.sh` compiles with bare `swiftc` against the macOS 15 SDK bundled with the Command Line Tools. It is a workaround; installing Xcode is the real fix.

During development `swift run` also works (no Dock icon; "Launch at login" only works when started from the `.app`).

## Tests

```bash
swift test
```

## Logs

```bash
log stream --predicate 'subsystem == "jp.ymzkmct.Claudemeter"' --level info
```

## Security and data handling

- Only two hosts are contacted: `api.anthropic.com` (usage) and `platform.claude.com` (token refresh). HTTPS, TLS 1.2+, redirects are refused so the bearer token is never sent to another host. No cookies, no disk cache.
- Reads: the Keychain item `Claude Code-credentials` created by Claude Code at login. No other Keychain item is touched.
- All Keychain access runs `/usr/bin/security` as a child process (the tool the `claude` CLI uses for the same item). When writing back, the credential JSON is passed on that short-lived process's command line, so it is visible to other processes of the same user for the few milliseconds the process runs.
- Writes: the token fields of that same item after a refresh. All other keys are preserved. The update is restricted to the item that was read (matched by account).
- `~/.claude/projects` is watched through FSEvents for path changes only. Session transcripts are never read.
- Tokens never appear in logs, the UI, or UserDefaults. UserDefaults only holds the display snapshot (percentages, reset times).
- The OAuth `client_id` in the source is the public client ID Claude Code itself uses (a PKCE public client). It is not a secret.
- The app is not sandboxed, because it needs another app's Keychain item and FSEvents on `~/.claude`.
- No telemetry, nothing is sent anywhere else.

## Limitations

- The usage endpoint is unofficial and may break when Anthropic changes it.
- Not applicable when Claude Code is used with an API key, Bedrock, or Vertex (there is no OAuth Keychain item).
- If the refresh token has expired as well, log in again with `claude` (the dropdown says so).
- The handling of `limits[]` (per-model weekly windows) follows the CodexBar implementation and is still to be confirmed against a real response.

## License

MIT. See [LICENSE](LICENSE).
