# Reset Attempt And Reconnect Timeout Design

Date: 2026-07-28

## 1. Problem

The existing one-shot reset gives a captured Hearthstone TCP `3724` connection only two seconds to emit a packet. PF `block return` is packet-driven: deleting PF state does not close the socket in the Hearthstone process. If the socket is quiet for those two seconds, no reset packet is generated, the exact-tuple rules are cleared, and the helper reports a technical failure even though the helper, PF, and IPC all worked correctly.

This produces two misleading user experiences:

- Several clicks may be needed before one attempt overlaps game traffic.
- A normal "no packet arrived" outcome is displayed as `服务异常`.

After a reset does trigger, the current `等待重连` state also has no deadline. A match may have ended, so a replacement TCP `3724` connection may never appear.

## 2. Decision

Keep the existing packet-driven, exact-tuple reset design and add two independent monotonic deadlines:

1. Wait at most 10 seconds for traffic on the captured original connection to trigger its reset.
2. After the captured connection disappears and PF has been cleared, wait at most 15 seconds for a replacement game connection.

Neither deadline is a fixed disconnection duration. The anchor is cleared immediately when every captured original tuple disappears. Connections created after the click are never added to the block rules.

## 3. State Model

The user-visible flow is:

```text
一键拔线
    |
    v
等待连接活动 -- original tuple disappears --> 等待重连
    |                                      |
    | 10 seconds, original still present   | replacement TCP 3724 appears
    v                                      v
未触发 (clickable)                         一键拔线
                                           |
                                           | 15 seconds, no replacement
                                           v
                                      未检测到对局
```

The exact state meanings are:

| Internal state | Button label | Actionable | Meaning |
| --- | --- | --- | --- |
| `ready` | `一键拔线` | Yes | At least one verified Hearthstone-owned TCP `3724` game tuple exists. |
| `cutting` | `等待连接活动` | No | Exact PF rules are active for the tuples captured by this attempt. |
| `notTriggered` | `未触发` | Yes | The captured tuples did not emit traffic and did not disappear within 10 seconds; PF is clear. |
| `waitingForReconnect` | `等待重连` | No | The original tuples disappeared and PF is clear; the helper is observing for a replacement. |
| `absent` | `未检测到对局` | No | No verified TCP `3724` game tuple is currently observable. |
| `error` | `服务异常` | Yes | A real helper, PF, recovery, IPC, or socket-observation operation failed. |

`helperUnavailable` remains `需要安装` and is outside this change.

## 4. Reset Attempt

On an accepted click, the helper retains the existing sequence:

1. Revalidate the Hearthstone process.
2. Capture its current qualifying TCP `3724` tuples.
3. Arm the independent recovery daemon.
4. Load exact local-and-remote tuple `block return` rules.
5. Delete matching PF state.
6. Poll for every captured tuple to disappear.

The reset-attempt and recovery deadlines both become 10 seconds. The recovery daemon remains an independent fail-open guard: if the helper stalls or dies, it clears only the dedicated anchor at the deadline.

If all captured tuples disappear before the deadline, the helper immediately clears the anchor, disarms recovery, enters `waitingForReconnect`, and starts the 15-second reconnect deadline. It does not wait out the remainder of the 10 seconds.

If any captured tuple remains at the 10-second deadline, the helper clears the anchor, disarms recovery, and enters `notTriggered`. This is a normal, retryable outcome, not an error.

While `notTriggered` is displayed, a click starts a completely new attempt: the helper revalidates the process, captures the currently qualifying tuples, creates fresh exact rules, and arms a fresh non-extendable deadline. A click does not reuse stale target data.

## 5. Observation Semantics

The helper remembers the captured tuple set that produced `notTriggered`. Background polling must not immediately replace `notTriggered` with `ready` merely because those same tuples are still present. Otherwise the outcome would disappear before the user could understand or retry it.

The state is released when observation shows that none of those timed-out captured tuples remain:

- If a different qualifying TCP `3724` tuple is present, transition to `ready`.
- If no qualifying TCP `3724` tuple is present, transition to `absent`.

This compares tuple identity, not only connection count. A same-count replacement must therefore be recognized as a new connection.

During `waitingForReconnect`, the first observed qualifying TCP `3724` tuple transitions immediately to `ready`. If none appears within 15 monotonic seconds, transition to `absent`. The helper reports only the observable fact; it must not claim that the player died or the match ended.

## 6. Failure Semantics

The following are outcomes, not failures:

- No captured connection activity within 10 seconds: `notTriggered` / `未触发`.
- No replacement connection within 15 seconds after a confirmed reset: `absent` / `未检测到对局`.
- Hearthstone exits or its verified process identity changes: fail open and report `absent`.

The following remain technical failures and report `error` / `服务异常`:

- PF rule load, state deletion, or anchor cleanup fails.
- Recovery daemon arm or disarm fails.
- Process or socket observation throws an operational error.
- Helper IPC fails.

All paths that loaded or may have loaded PF rules must attempt fail-open cleanup. A timeout must never leave the dedicated anchor armed.

## 7. Timing And Ownership

The helper owns both behavior deadlines and evaluates them using its monotonic time source:

```text
T+0                 capture original tuples, arm recovery, load rules
T+event (<10s)      originals disappear; clear PF immediately
T+event to +15s     observe for replacement tuple
T+10s               if originals remain: clear PF and show 未触发
T+event+15s         if no replacement: show 未检测到对局
```

The recovery daemon continues to translate an accepted wall-clock deadline into its own monotonic timer and must accept the helper's 10-second request. It must not extend an already armed earlier deadline.

The existing two-second app/helper socket I/O timeout is unrelated to connection-reset timing and remains unchanged.

## 8. Testing

Tests must prove:

- A captured tuple disappearing before 10 seconds immediately clears PF and enters `waitingForReconnect`.
- A captured tuple remaining for 10 seconds clears PF and enters `notTriggered`, not `error`.
- Recovery is armed for the 10-second reset-attempt bound and independently clears stale rules.
- `notTriggered` is actionable and a click starts a fresh attempt with freshly captured tuples.
- Background polling preserves `notTriggered` while any timed-out captured tuple remains.
- Once timed-out captured tuples disappear, a different tuple produces `ready` and no tuple produces `absent`.
- A replacement TCP `3724` tuple before the 15-second reconnect deadline produces `ready`.
- No replacement by the 15-second reconnect deadline produces `absent`.
- PF, recovery, IPC, and observation failures still produce `error` and attempt fail-open cleanup.
- Exact button labels and enabled states match the state table.
- TCP `443`, TCP `1119`, UDP, loopback, and unrelated process sockets remain excluded.

The full Swift test suite, fake-root helper lifecycle, network dry run, universal release build, signature checks, and macOS PF syntax validation must continue to pass.

## 9. Scope

This change does not add packet injection, packet capture, a fixed cut duration, automatic retries, global shortcuts, new target ports, or game-outcome detection. Automatic retry is deliberately excluded because repeated resets without an explicit click could affect a later connection the user did not intend to reset.
