# Decision: ad-hoc signing stays, and so does one of its two prompts

## Context

The macOS build is signed ad-hoc (`codesign --sign -`), with `TeamIdentifier=not set`. Developer ID
and notarisation are deliberately out of reach — see the README. An unstable code identity has two
visible consequences, and a user reported both after an update:

1. **"Weto added items that can run in the background"** appears again after every successful
   update, even though the permission was granted once.
2. **The keychain password dialog** appears again after every update, even though "Always Allow"
   was clicked before.

They look like one bug and are not. Background Task Management ties a granted permission to a
*record*, and a record to a *file* in `LaunchAgents` / `LaunchDaemons`. The keychain ties an item's
ACL to the *code signature* of the app that reads it.

## Decision

Fix the first, leave the second.

**Fixed.** The installer stopped recreating the files. `preinstall` still unloads the job — without
that, launchd with `KeepAlive` raises a copy of the app in the middle of replacing the bundle — but
it no longer deletes the plist. `postinstall` writes both plists only when the content actually
differs, which for an update it never does: the program path does not depend on the version. The
daemon's `LaunchDaemon` left the package payload for the same reason — `installer` overwrites
payload files on every install, past any check of ours. Pinned by
`macos/scripts/tests/install-idempotency-contract.sh`: a second run changes neither the inode nor
the mtime of either file, while a changed bundle path still rewrites the agent.

**Not fixed.** The keychain prompt. Every build has a different cdhash, so the ACL written by
"Always Allow" stops matching at the next update. The two ways out without Developer ID were both
rejected by the owner:

- open the item's ACL to all applications — the same weakness as a plain file, but less obvious;
- move the token to a `0600` file, as Linux already does — readable by any process of the user.

The token stays in the keychain and the password keeps being asked once per update. This is a
known, accepted cost, not an oversight.

## Consequences

- A Developer ID would fix both at once and make the installer's write-only-if-changed logic
  redundant. Until then it is load-bearing.
- The daemon's binary changes on every update regardless. If BTM keys its record on the ad-hoc
  cdhash rather than the file, the background-items notification may still appear for
  `com.weto.helper`. That can only be observed on a real update cycle; CI cannot see it.
- Files written by `postinstall` are not in the package receipt, so `pkgutil --forget` knows
  nothing about them. `Resources/uninstall-weto.sh` removes them explicitly, and
  `launch-agent-contract.sh` checks that it does.
