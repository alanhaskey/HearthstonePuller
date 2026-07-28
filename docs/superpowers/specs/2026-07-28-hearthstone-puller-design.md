# macOS Hearthstone Puller Design

Date: 2026-07-28

## 1. Purpose

Build a personal-use macOS utility that displays an always-visible floating button and temporarily interrupts Hearthstone's network connections for exactly 1.5 seconds. Hearthstone is expected to reconnect by itself. The utility must avoid disrupting unrelated applications as far as macOS Packet Filter (PF) permits.

The first version does not use Network Extension because that capability requires a paid Apple Developer Program team on a normally secured Mac. It uses a narrowly scoped privileged helper and PF instead. This provides best-effort Hearthstone isolation, not the absolute per-process isolation available through Network Extension.

## 2. Scope

### Included

- macOS 13 Ventura and later.
- Universal Apple silicon and Intel builds.
- An always-visible, draggable, square floating button.
- Detection of a running Hearthstone process and its active TCP/UDP sockets.
- A fixed 1.5-second interruption window.
- A root launch daemon installed once with explicit administrator approval.
- Dedicated PF anchor management without replacing the system PF configuration.
- Automatic, independent, and manual recovery paths.
- Local ad-hoc signing where needed for development and personal execution.

### Excluded

- Global keyboard shortcuts.
- Configurable interruption duration.
- Network Extension or System Extension integration.
- Mac App Store or public distribution.
- Developer ID signing, notarization, automatic updates, and a polished installer.
- Parsing, decrypting, recording, or modifying Hearthstone packet payloads.
- Support for macOS 12 or earlier.
- A guarantee that no unrelated connection to the same remote address can ever be affected.

## 3. User Experience

The application has no conventional main window. Its primary interface is an 88 by 88 point `NSPanel` containing a square button. The panel is non-activating, joins all Spaces, can appear alongside full-screen applications, and remains above normal application windows. Clicking it must not steal Hearthstone's keyboard focus.

The panel supports two pointer gestures:

- A short press and release triggers the interruption.
- Movement beyond a drag threshold moves the panel without triggering the interruption.

The last position is persisted. On display topology or resolution changes, the application clamps the panel to the visible portion of an active display.

### Button states

| State | Label | Enabled | Meaning |
| --- | --- | --- | --- |
| Helper unavailable | `需要安装` | Yes | Opens the one-time helper installation instructions. |
| Hearthstone absent | `未检测到炉石` | No | No verified Hearthstone process or socket is available. |
| Ready | `一键拔线` | Yes | At least one verified Hearthstone network connection exists. |
| Cutting | `断线中 1.5s` | No | PF rules are active and the deadline has not passed. |
| Waiting for reconnect | `等待重连` | No | Rules are clear; the app is waiting for a new verified Hearthstone flow. |
| Helper error | `服务异常` | Yes | Clicking requests recovery and refreshes status. |

The countdown may update at 100-millisecond visual intervals, but the helper's monotonic deadline is authoritative.

### Context menu

Right-clicking the panel shows:

```text
Helper: running / unavailable
Hearthstone: connected / absent
------------------------------
重新检测
恢复网络
安装或卸载 Helper
退出
```

`恢复网络` always requests an immediate flush of this tool's PF anchor. Exiting first requests recovery and then closes the UI. Recovery does not depend on the UI remaining alive.

## 4. Architecture

The system consists of three executables with narrow local protocols.

### Floating application

Responsibilities:

- Render and position the `NSPanel`.
- Interpret click, drag, and context-menu interactions.
- Display state reported by the helper.
- Send only `status`, `cut`, and `restore` requests.
- Guide the user through helper installation or removal.

The application never runs as root, never constructs PF rules, and never accepts arbitrary shell commands.

### Privileged helper

The helper is a launch daemon running as root. It is installed manually once through a reviewed installation script and launchd property list.

Responsibilities:

- Authenticate requests from the configured local user.
- Find and verify the Hearthstone process itself.
- Enumerate Hearthstone TCP/UDP sockets through structured `libproc` APIs.
- Maintain the dedicated PF anchor and PF enable reference.
- Execute the interruption state machine.
- Arm the independent recovery daemon before installing block rules.
- Report connection count, helper state, deadline, and errors.
- Clear stale rules at every launch and before shutdown.

### Recovery daemon

A second, deliberately small launch daemon runs independently of the privileged helper. It accepts only an `arm(deadline)` request from the root-owned helper socket and owns no process-discovery logic. When armed, it acknowledges that the deadline is durably held in memory, waits until that absolute deadline, and flushes only `com.apple/hearthstone-puller`.

The helper is forbidden from loading block rules until it receives the recovery daemon's armed acknowledgement. If the recovery daemon is unavailable, a cut request fails open. Because launchd manages the recovery daemon separately, UI or helper termination cannot cancel the recovery deadline.

### Local protocol

The UI connects through a Unix domain socket owned by root and accessible only to the configured console user's UID. Requests and responses use length-delimited Codable messages rather than shell text.

Allowed requests:

```text
status
cut
restore
```

`cut` has no caller-provided duration, PID, address, port, path, or rule. The helper always applies the fixed internal duration and discovers all targets itself.

## 5. Hearthstone Identification

The helper must not trust a process name or a PID supplied by the UI.

For each candidate process it:

1. Obtains the executable path with `proc_pidpath`.
2. Resolves symlinks and verifies that the executable belongs to the installed Hearthstone app bundle.
3. Uses Security.framework to inspect the running code and its designated requirement.
4. Matches the Hearthstone bundle/signing identity learned from the locally installed Hearthstone bundle.
5. Explicitly rejects the Battle.net launcher and unrelated Blizzard executables.
6. Records the process start identity so PID reuse cannot silently retarget a later operation.

If code-signature or path verification fails, the candidate is ignored and networking remains allowed. The helper never falls back to name-only matching.

Signing identifiers are discovered dynamically from the locally installed Hearthstone bundle rather than hard-coded. An observation phase on the target Mac validates which in-bundle executable creates the game connection. Only identities whose running code satisfies a designated requirement derived from that verified local bundle may be admitted.

## 6. Socket Discovery

The helper uses `proc_pidinfo`, `PROC_PIDLISTFDS`, and socket descriptor information to enumerate the verified Hearthstone process's sockets. It collects only metadata required for filtering:

- Process identity and start identity.
- Address family: IPv4 or IPv6.
- Protocol: TCP or UDP.
- Local address and port.
- Remote address and port.
- TCP connection state where available.

Payload data is neither read nor stored.

The initial implementation must support established TCP connections and connected UDP sockets. During an active cut window it polls quickly enough to observe reconnect attempts and add newly observed remote endpoints. Polling is bounded to the 1.5-second window and stops immediately afterward.

## 7. PF Rule Strategy

The helper owns only the nested anchor:

```text
com.apple/hearthstone-puller
```

The default macOS PF configuration exposes the `com.apple/*` anchor point. The helper verifies this before activation. It does not edit or reload `/etc/pf.conf`, flush the root ruleset, disable PF globally, or modify another anchor.

For each verified Hearthstone connection, the helper builds IPv4 or IPv6 `block drop quick` rules covering both directions. Rules constrain the remote address, protocol, and remote port. The initial local tuple may also be included for diagnostics, but the active 1.5-second rule must continue to match an immediate reconnect that uses a new local ephemeral port.

PF state lookup can allow an already-established connection to bypass newly loaded rules. The helper therefore removes state entries between the local host and the verified remote address after installing the block rule. macOS PF cannot delete state by PID, so an unrelated application connected to the same remote address may also lose that connection. This is an explicit limitation of this architecture.

During the cut window, the helper repeats socket discovery. If Hearthstone attempts a new endpoint, the helper atomically refreshes its anchor rules and clears the corresponding endpoint state. No network range or historical Blizzard endpoint list is used.

## 8. Interruption State Machine

The helper owns the authoritative state:

```text
ABSENT -> READY -> CUTTING -> WAITING_RECONNECT -> READY
                      |              |
                      +-----> ABSENT-+
```

### Transitions

- `ABSENT -> READY`: a verified Hearthstone socket appears.
- `READY -> CUTTING`: a valid `cut` request arrives.
- `CUTTING -> WAITING_RECONNECT`: the 1.5-second monotonic deadline expires and the anchor is flushed.
- `WAITING_RECONNECT -> READY`: a new verified Hearthstone connection appears.
- Any state to `ABSENT`: the verified process exits and no qualifying socket remains.
- Any failure during `CUTTING`: immediately flush the anchor, report an error, and fail open.

Additional `cut` requests during `CUTTING` are rejected and never extend the deadline. A `restore` request from any state flushes the anchor and transitions to the appropriate non-cutting state.

## 9. PF Lifecycle and Recovery

PF may already be enabled by macOS or another product. The helper uses PF's reference-counted enable mechanism and retains its own enable token. It never assumes ownership of global PF state and never disables a reference it did not acquire.

Before installing any block rule, the helper arms the independent recovery daemon with an absolute deadline. The daemon's root-only protocol has no caller-controlled command, path, anchor, or PF arguments. Its only privileged action is to flush the hard-coded `com.apple/hearthstone-puller` anchor approximately two seconds after activation.

Normal timing:

```text
T+0.0  Recovery daemon armed and acknowledgement received
T+0.0  Dedicated anchor rules installed
T+0.0  Matching endpoint states removed
T+1.5  Helper flushes dedicated anchor
T+2.0  Recovery daemon flushes the same anchor again
```

The recovery daemon must survive UI and helper termination. Both root daemons begin startup by flushing the anchor before accepting requests. Sleep/wake handling compares an absolute deadline and flushes immediately if the deadline has passed.

Manual emergency recovery is documented as:

```bash
sudo pfctl -a com.apple/hearthstone-puller -F all
```

## 10. Installation and Removal

The project supplies a readable installation script that:

1. Verifies explicit source and destination paths.
2. Copies the helper and recovery daemon to fixed root-owned locations.
3. Sets root ownership and non-writable executable permissions.
4. Installs narrowly configured launch daemon property lists for both root processes.
5. Records the installing console user's UID for socket authorization.
6. Bootstraps both daemons with launchctl, starting recovery before the helper.
7. Verifies that the recovery daemon can be armed, that the helper clears its anchor, and that `status` responds.

The script must not disable SIP, alter `/etc/pf.conf`, install a kernel extension, or download executable content.

Removal first invokes `restore`, unloads both daemons, flushes the dedicated anchor again, and removes only files installed by this project. Because this is a personal, unsigned build, sharing it with other users is outside first-version scope.

## 11. Security Boundaries

- The UI remains unprivileged.
- The helper protocol exposes no arbitrary command execution.
- The helper independently discovers and verifies Hearthstone.
- The socket is restricted to one local UID and rejects malformed or oversized messages.
- PF input is generated from validated numeric addresses, protocols, and ports using structured models.
- Rule files are written to root-owned temporary files with exclusive creation and restrictive permissions, or passed through a controlled standard-input channel.
- Diagnostic logs exclude packet payloads, authentication material, and unrelated application endpoints.
- Every error path during a cut attempts an immediate fail-open flush.

## 12. Testing

### Unit tests

- State-machine transitions and repeated-click rejection.
- Fixed 1.5-second deadline behavior with an injected clock.
- Process start identity and PID reuse handling.
- Code-signature and bundle-path verification.
- Socket metadata conversion for IPv4, IPv6, TCP, and UDP.
- PF rule generation and input validation.
- Protocol authentication, framing, malformed input, and size limits.
- Recovery behavior on every failure branch.

### Integration tests

Use two local signed test clients and local TCP/UDP servers:

- Target client A is selected by the same identity abstraction used for Hearthstone.
- Control client B remains unrelated.
- Cutting A interrupts its established connection and immediate reconnect attempts.
- B continues transferring data throughout the cut.
- Killing the UI during a cut does not extend the rule lifetime.
- Killing the helper during a cut leaves the separately managed recovery daemon to clear the anchor.
- Sleep/wake and display/network changes do not leave stale rules.
- Existing third-party PF anchors remain byte-for-byte unchanged.

### Hearthstone observation and manual tests

- Identify the actual Hearthstone executable and any in-bundle networking helper.
- Confirm that Battle.net launcher traffic is not selected.
- Measure whether 1.5 seconds reliably triggers Hearthstone reconnect behavior.
- Verify browser downloads, music, chat, and voice traffic remain connected.
- Exercise Wi-Fi, Ethernet, hotspot, common VPN, IPv4, and IPv6 paths.
- Repeat cuts and game restarts without stale state or UI desynchronization.
- Record any remote-address sharing that causes observable collateral reconnects.

## 13. Acceptance Criteria

- The floating square remains visible across Spaces and full-screen Hearthstone without stealing focus.
- The button is disabled unless the helper reports at least one verified Hearthstone socket.
- One click performs exactly one non-extendable 1.5-second cut.
- PF rules exist only in `com.apple/hearthstone-puller` and are absent after the deadline.
- The root PF configuration and unrelated anchors are never reloaded, flushed, or edited.
- Only endpoints currently observed from a verified Hearthstone process are targeted.
- Under integration testing, an unrelated control client continues uninterrupted unless it deliberately shares an endpoint whose PF state must be removed; that limitation is surfaced rather than hidden.
- UI, helper, IPC, sleep, and timing failures recover to a clear PF anchor within approximately two seconds.
- The implementation requires no paid Apple Developer account, Network Extension entitlement, disabled SIP, or persistent root GUI process.

## 14. Deferred Upgrade Path

If PF endpoint/state limitations cause unacceptable collateral disruption, the supported upgrade is a signed Network Extension content filter under a paid Apple Developer Program team. The floating UI and most state-machine concepts can remain, but process-flow identification and interruption move from PF into `NEFilterDataProvider`.

A BPF/TCP-RST implementation may be explored as a personal research alternative, but it is not part of this version because it is TCP-specific, significantly more complex, and less stable across macOS network configurations.
