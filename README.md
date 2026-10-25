# ResetBar

A small macOS menu bar app for Codex usage and reset alerts. The menu bar shows three items:

```text
61% · R 21h08m · 🔔
```

The values above are an example. The app currently uses Chinese menu labels.

- **Remaining quota:** reads the current Codex account through the separately installed [CodexBar](https://github.com/steipete/CodexBar) CLI, preferring the weekly window. `—%` means unavailable; `?` marks a cached value after a failed or stale read.
- **Time since your account recovered:** records a restoration after two fresh quota observations. `R` means direct restoration, `B` requires evidence of a banked reset being consumed, and `↻` means the type is unknown. A website announcement, a banked grant, or a future window boundary alone does not start this timer. The first launch shows `↻ —` until a restoration is observed or you use **校准上次恢复时间…** to enter a time and type you have confirmed. Automatic observations have polling precision and cannot reconstruct resets missed while the app was offline.
- **Reset alerts:** uses the public [codex-reset.com](https://codex-reset.com/) forecast and timeline endpoints for active announcements, confirmed resets, and new banked grants. A badged bell means unread; a crossed bell means the alert data is unavailable or stale. Open the menu to read the source or mark an alert as read. Old completed events are not replayed on first launch.

Native menu bar text and template symbols follow the menu bar's light or dark appearance. Quota and website data refresh every 60 seconds; the local elapsed-time display refreshes every 15 seconds. System notifications and launch at login are optional menu settings. Email subscriptions and website accounts are not required.

## Requirements

- macOS 13 or later.
- Apple Xcode Command Line Tools with Swift 6.2 or later, `python3`, and `codesign`. The scripts compile in Swift 5 language compatibility mode.
- [CodexBar](https://github.com/steipete/CodexBar) installed in `/Applications`, with a working Codex OAuth sign-in. Compatibility has been tested with CodexBar **0.81.0**.

ResetBar invokes this fixed helper path:

```text
/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI
```

Keep CodexBar.app installed; its menu bar UI does not need to run alongside ResetBar. CodexBar is a third-party project, and its executable or source is not bundled here. ResetBar is independent of OpenAI, CodexBar, and codex-reset.com. Helper output and website endpoints are external dependencies that may change.

## Build, test, and install

From the repository directory:

```sh
zsh test.sh
zsh build.sh
mkdir -p "$HOME/Applications"
cp -R dist/ResetBar.app "$HOME/Applications/"
open "$HOME/Applications/ResetBar.app"
```

The build produces `dist/ResetBar.app` with an **ad-hoc signature**. It is not Developer ID signed or notarized. The unit tests use synthetic fixtures and make no network requests. CI runs the same unit tests and app build on macOS.

## Local data and privacy

ResetBar does not send personal quota data to codex-reset.com. Website requests use an ephemeral session without stored cookies or a website login. Account usage is obtained by invoking CodexBar's CLI; CodexBar handles its own authentication and provider requests.

Local files live in `~/Library/Application Support/ResetBar/`:

- `state.json` stores normalized quota samples, public website events, personal reset timestamps and pending observations, alert read/seen history, notification preferences, and a deterministic SHA-256 account-scope hash used to keep accounts and quota windows separate. Raw account email addresses, account identifiers, cookies, and tokens are not saved by ResetBar.
- Opening the preview exports `status-item.png`, `status-item-dark.png`, `status-item-light.png`, and `status-item-check.json` for local visual checks. These contain the displayed quota and personal reset status. They capture ResetBar's own control, not other apps or the screen, and remain local.

Build outputs, visual evidence, local state, and live probe results are excluded from this source repository. `Tests/LiveProbe.swift` is an optional diagnostic that reads real account usage and website data; it is not part of `test.sh` or CI.
