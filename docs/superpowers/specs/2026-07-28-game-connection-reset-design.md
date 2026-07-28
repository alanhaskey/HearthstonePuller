# Hearthstone Game Connection Reset Design

Date: 2026-07-28

## 1. Purpose

Change the pull action from a fixed-duration network block into a one-shot reset of the Hearthstone game connection that exists when the user clicks. The tool must let Hearthstone's replacement connection pass immediately.

The normal path has no configured disconnection duration. A two-second deadline remains only as an independent fail-open bound if the helper crashes, stalls, or cannot confirm that the original connection disappeared.

## 2. Target Selection

The first supported game-flow signature is an observed, non-loopback TCP connection owned by the verified Hearthstone process with remote port `3724`.

The helper must not target Hearthstone connections on ports `443` or `1119`. Those connections serve login, content, or other background functions and are not evidence that an active game connection is available.

The floating button is ready only while at least one qualifying TCP `3724` connection exists. If Hearthstone is running without such a connection, the button displays `未检测到对局` and cannot issue a reset.

This is deliberately evidence-based and narrow. Additional game-flow signatures require a separate observed trace and test update; they must not be inferred from the executable name alone.

## 3. Reset Sequence

On one accepted click, the helper performs this sequence:

1. Locate and revalidate the Hearthstone process.
2. Capture the exact qualifying TCP `3724` socket tuples currently owned by that process.
3. Arm the independent recovery daemon for an absolute deadline two seconds in the future.
4. Load dedicated PF `block return` rules for only those captured tuples.
5. Delete matching PF states so the next packet is evaluated by the new rules.
6. Poll the verified Hearthstone process for the captured tuples to disappear.
7. As soon as every captured tuple has disappeared, flush the dedicated anchor and disarm the recovery daemon.
8. Wait for a new qualifying TCP `3724` tuple and then return to ready.

The helper must never add a socket discovered after step 2 to the active rules. A replacement connection normally uses a new local ephemeral port and must be allowed even while cleanup of the old tuple is still pending.

Repeated clicks while a reset is in progress remain rejected and cannot change the captured targets or recovery deadline.

## 4. PF Rules

Each outbound rule constrains:

- Address family.
- TCP protocol.
- Local address and local ephemeral port.
- Remote address and remote port `3724`.

Each inbound rule applies the exact reverse tuple. For example:

```pf
block return out quick inet proto tcp from 192.0.2.10 port = 50123 to 198.51.100.20 port = 3724
block return in quick inet proto tcp from 198.51.100.20 port = 3724 to 192.0.2.10 port = 50123
```

The dedicated anchor remains `com.apple/hearthstone-puller`. The helper does not edit `/etc/pf.conf`, reload the root ruleset, flush unrelated anchors, or disable PF globally.

macOS `pfctl -k` cannot delete state by PID or exact socket descriptor. State removal therefore retains the existing limitation that an unrelated flow to the same address pair can be forced to re-establish. The active block rule itself is exact to the captured Hearthstone tuple.

## 5. State And Timing

The state flow remains:

```text
ABSENT -> READY -> CUTTING -> WAITING_RECONNECT -> READY
```

State meanings change as follows:

- `READY`: at least one verified TCP `3724` game connection exists.
- `CUTTING`: the one-shot reset has been accepted and at least one captured original tuple still exists.
- `WAITING_RECONNECT`: all captured tuples disappeared and the dedicated anchor was cleared.
- `ERROR`: setup, polling, or cleanup failed, or the helper could not confirm tuple disappearance before the two-second safety deadline.

`CUTTING` has no user-visible countdown and displays `拔线中`. Snapshots report zero remaining milliseconds because there is no normal cut duration.

Normal completion is event-driven:

```text
T+0       Capture original TCP 3724 tuples and arm recovery
T+0       Load exact-tuple rules and delete their PF states
T+event   Original tuples disappear; helper immediately flushes the anchor
T+event   A replacement TCP 3724 tuple is allowed and observed
T+2.0     Independent recovery flushes only if still armed
```

The two-second boundary is not a promise to keep the connection blocked. It is the maximum time stale rules may survive and the point at which an unconfirmed reset is reported as a failure.

## 6. Failure Handling

- Failure before recovery acknowledgement must not load PF rules.
- Failure after recovery acknowledgement must attempt an immediate anchor flush and recovery disarm.
- Process identity change or process exit must immediately clear the anchor and end the attempt.
- Reaching the two-second safety deadline without observing all captured tuples disappear must clear the anchor and report failure instead of claiming a successful reset.
- The recovery daemon independently flushes the same anchor at its armed deadline if the helper or UI dies.
- App polling must use only authoritative helper snapshots; it must not infer success from elapsed wall time.

## 7. Testing

Unit and integration fixtures must prove:

- Only verified TCP connections with remote port `3724` are selected.
- TCP `443`, TCP `1119`, UDP `3724`, and unrelated sockets do not make the button ready.
- PF rules include both local and remote ports in both directions.
- A newly observed replacement tuple is never added to PF rules and never has its state killed.
- Original tuple disappearance causes an immediate anchor flush without waiting for a fixed duration.
- A second click cannot extend or replace an active reset.
- The two-second deadline clears the anchor and reports an unconfirmed reset.
- Setup, polling, process-change, and cleanup failures remain fail-open.
- Existing fake-root installer, dry-run network integration, universal build, and code-signature checks continue to pass.

The final live check must be performed in a non-ranked Hearthstone context. It must capture the original and replacement TCP `3724` tuples, confirm that the replacement uses a different local port, and confirm that ports `443` and `1119` remain untouched by active PF rules.

## 8. Alternatives Considered

### Reset every Hearthstone socket

Rejected because unrelated HTTPS and login connections can remain idle or reconnect independently. Treating them as game-session signals causes false readiness and can delay or destabilize recovery.

### Keep a fixed PF window

Rejected because a quiet socket may send no packet during the window, while a replacement socket can be repeatedly reset if rules are broadened or refreshed. Elapsed time does not indicate whether the intended connection was reset.

### Inject a TCP RST directly

Rejected for this version because macOS has no supported `tcpdrop` utility or public API for closing another process's socket. Raw reset injection would require packet capture, valid TCP sequence tracking, and substantially broader privileges and risk.
