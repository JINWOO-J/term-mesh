# Enter 씹힘(Key Drop) 버그 컨텍스트

## 개요

에이전트 팀 운영 중 Enter 키가 전달되지 않아 명령어가 실행되지 않는 버그.
**에이전트→에이전트(broadcast/delegate)** 경로는 수정 완료되었으나,
**리더←에이전트(reply/msg send)** 경로는 미수정 상태.

---

## 이전 수정 이력 (시간순)

### 1단계 — 초기 접근: 딜레이 튜닝 (2026-03 초반)

**커밋 범위:** `e00958a`, `4fcfe88`, `05b150b`, `745f1a5`, `37a519d`, `23be82c`, `9f0c9fa`, `ff2a689`, `b553ebb`, `d7f497b`

- 방식: `sendTextToPanel`에 `enterDelay` 값을 조정하거나 GCD `asyncAfter`로 Enter 타이밍을 늦춤
- 문제: 딜레이 값(10ms → 20ms → 절반 → 두 배)을 반복 조정해도 재현 가능한 안정성 없음
- dual-timer 방식(`Merge fix/IME-hang-approach-D`)도 시도했으나 본질적인 race condition은 미해결

### 2단계 — atomic sendIMEText로 전환 (2026-03-23 초반)

**커밋:** `7d3584b`, `c774239`, `4ecd23c`, `92592d2`

- 방식: `sendInputText + asyncAfter Enter` → `sendIMEText` (atomic press/release pair)로 교체
- 효과: 단일 에이전트 케이스에서 안정성 향상
- 한계: 10명 이상 동시 전송 시 GCD main queue saturation 문제 여전히 존재

### 3단계 — surface-nil 감지 + 재시도 (2026-03-23 중반)

**커밋:** `7346382`, `77c4668`

- 방식: `sendIMEText`가 `Bool`을 반환하도록 변경, surface nil 시 재시도 로직 추가
- 효과: surface가 아직 준비되지 않은 케이스(빠른 split 직후) 처리 가능

### 4단계 — GCD saturation 해결 (2026-03-23, v0.84.1)

**커밋:** `c8aa3ef` — `fix(enter): prevent Enter key drops in agent command delivery`

**근본 원인:** 10명+ 에이전트가 동시에 text를 수신할 때 GCD main queue가 포화되어 Enter 이벤트가 묵살됨.

**수정 내용:**
- `sendIMEText` / `sendTextToPanel`에 지수 백오프 4회 재시도 (50 → 150 → 400 → 800ms)
- `team.send` / `team.delegate` dispatch를 ≥100ms 간격으로 stagger
- `v2MainExec` timeout 2s → 5s 상향
- timed-out Task 취소로 stale Enter 전달 방지
- `sendReturnKey`가 `Bool` 반환 + 미처리 key event 로그
- 21개 케이스 테스트 스위트 추가 (`tests/test_enter_comprehensive.py`)

### 5단계 — 전달 방식 재설계 (2026-03-24, v0.85.0)

**커밋:** `1ca67c0` — `fix(enter): rewrite agent text delivery to prevent Enter key drops`

**수정 내용:**
- 텍스트 전달: async paste → `ghostty_surface_text` (C API 직접 호출)
- Return 키: `asyncAfter` GCD → RunLoop 기반 딜레이 (`usleep` 대신)
- 재시도 로직을 `sendIMEText` 내부로 이동, retry delay 150ms로 증가
- 파일 변경: `GhosttyTerminalView.swift`, `TeamOrchestrator.swift`, `TerminalController.swift`

---

## CHANGELOG 기록된 엔트리

| 버전 | 엔트리 |
|------|--------|
| v0.74.0 | Agent Enter key delivery made reliable with atomic IME-style press/release pairs |
| v0.69.0 | IME composition no longer strips trailing newline on Enter submit |
| v0.84.1 | (fix) Enter key drops when 10+ agents receive text simultaneously — GCD saturation |
| v0.85.0 | (fix) Rewrite agent text delivery — ghostty_surface_text + RunLoop Return key |

---

## 현재 문제 상황

### 수정된 경로: 에이전트→에이전트 (leader → agent)

```
tm-agent send/delegate/broadcast
  → daemon: message.post RPC
  → TerminalController: v2TeamSend / v2Broadcast
  → TeamOrchestrator.sendToAgent / broadcast
  → sendTextToPanel (with 4-attempt exponential backoff)
  → TerminalSurface.sendIMEText (ghostty_surface_text + RunLoop Return)
```

단계 3~5의 수정이 이 경로를 커버. 안정성 확보됨.

### 미수정 경로: 리더←에이전트 (agent → leader)

```
tm-agent reply / tm-agent msg send (to leader)
  → daemon: message.post RPC (type=report)
  → TerminalController: v2TeamLeaderSend
  → v2MainSync { sendToLeader(...) }        ← 여기서 차이 발생
  → TeamOrchestrator.sendToLeader
  → sendTextToPanel → sendIMEText
```

**문제 포인트:**

1. **동시 보고 집중:** 여러 에이전트가 동시에 `tm-agent reply`를 호출하면, 각각의 `message.post` RPC가 소켓에서 순차 처리되지만, 모두 main thread를 요구하는 `v2MainSync` 를 경쟁적으로 점유 → Enter 유실 가능성
2. **adopted 모드 교차 워크스페이스:** 리더가 다른 워크스페이스에 있을 때 (`leaderWorkspaceId` 설정), `locateSurface` 실패 시 text 자체가 전달되지 않음 (Enter 유실이 아닌 전달 실패)
3. **stagger 미적용:** 에이전트→에이전트 경로는 dispatch를 100ms 간격으로 stagger하지만, 에이전트→리더 보고는 daemon 소켓 수신 순서 그대로 연속 처리됨

### 100ms 딜레이 방식의 한계

단계 4에서 도입된 100ms stagger는 에이전트→에이전트 broadcast에만 적용:

```swift
// TeamOrchestrator.swift — broadcast 시 stagger
DispatchQueue.main.asyncAfter(deadline: .now() + staggerOffset) { ... }
// staggerOffset = index * 0.1  (100ms 간격)
```

**한계:**
- 에이전트 수가 늘어날수록 마지막 에이전트 전달까지 걸리는 총 시간이 선형 증가 (10명 → 최대 1s 지연)
- 리더←에이전트 방향에는 stagger 자체가 없음 — 에이전트들이 거의 동시에 작업을 완료하면 reply가 burst로 도착
- 100ms라는 값은 실험적으로 도출된 것으로, 부하 조건이 달라지면 여전히 부족할 수 있음
- `v2MainExec` timeout(5s)이 있지만, 이는 RPC 실패 감지용이지 Enter 전달을 보장하지 않음

---

## 관련 파일

| 파일 | 역할 |
|------|------|
| `Sources/GhosttyTerminalView.swift` | `TerminalSurface.sendIMEText` — 실제 ghostty 키 이벤트 전달 (line ~996, ~1850) |
| `Sources/TeamOrchestrator.swift` | `sendTextToPanel`, `sendToLeader`, `sendToAgent`, `broadcast` |
| `Sources/TerminalController.swift` | `v2TeamLeaderSend`, `v2TeamSend` — 소켓 RPC → Swift 브릿지 |
| `daemon/term-meshd/src/socket.rs` | `message.post` 소켓 핸들러 |
| `tests/test_enter_comprehensive.py` | 21개 Enter 전달 케이스 테스트 |
