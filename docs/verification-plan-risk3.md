# 잔여 위험 3건 수정 후 검증 계획

## 개요

| # | 수정 항목 | 담당 | 영향 파일 |
|---|----------|------|----------|
| 1 | BrowserPanelView layout 재진입 비동기화 | backend | `Sources/Panels/BrowserPanelView.swift` |
| 2 | resignFirstResponder에서 discardMarkedText 추가 | executor | `Sources/GhosttyTerminalView.swift` |
| 3 | DispatchQueue.main.sync 8곳 제거 | ai | `Sources/TerminalController*.swift` (75곳) |

---

## 수정 #1 — BrowserPanelView layout 재진입 비동기화

### 배경
`scheduleGeometryCallback()` 은 `hasScheduledGeometryCallback` 가드로 coalescing 중이나,
`layout()` → `synchronizeForAnchor()` → AppKit 레이아웃 재트리거 경로에서
재진입 루프가 발생할 수 있다 (TERM-MESH-H 원인).

현재 `DispatchQueue.main.async` 지연이 있으나, 일부 직접 콜백 경로가 동기로 남아있는 경우
AppKit 레이아웃 패스 내에서 재귀 진입 가능.

### 검증 방법

**자동 검증 (소켓)**:
```python
# 브라우저 패널 + 분할 생성 → 크기 변경 → 레이아웃 반복 트리거
def verify_browser_layout_no_loop(c: termmesh):
    ws = c.new_workspace()
    c.select_workspace(ws)
    # 브라우저 패널 열기
    c.open_browser("https://example.com")
    time.sleep(0.5)
    # 분할 생성 (레이아웃 재계산 트리거)
    for _ in range(5):
        c.new_split("right")
        time.sleep(0.3)
    # 분할 닫기 (역방향 레이아웃)
    for _ in range(5):
        c.close_surface()
        time.sleep(0.3)
    # 크래시/행 없으면 PASS
```

**수동 체크리스트**:
1. 브라우저 패널 열기 → 터미널 분할 생성(오른쪽) 5회 → 앱 행 없음 확인
2. 브라우저 패널이 있는 상태에서 창 크기를 빠르게 변경 (리사이즈 핸들 드래그) → 무한 루프 없음
3. 브라우저 패널 + Cmd+` 워크스페이스 전환 반복 10회 → 레이아웃 안정성 확인
4. DevTools 열기/닫기 중 분할 크기 변경 → EXC_BAD_ACCESS 없음
5. Console.app 에서 "layout: infinite loop" 또는 "layout recursion" 로그 없음

**측정 기준**:
- `hasScheduledGeometryCallback` 로그(DEBUG 빌드)에서 동시 호출 겹침 없어야 함
- 레이아웃 패스 당 `scheduleGeometryCallback` 호출이 1회로 coalesced 확인

---

## 수정 #2 — resignFirstResponder에서 discardMarkedText 추가

### 배경
`GhosttyTerminalView.resignFirstResponder()` 에서 포커스 해제 시
`markedText`(NSMutableAttributedString)가 비워지지 않으면:
- 다음 포커스 복귀 시 `hasMarkedText()` = true 상태에서 `insertText` 호출
- `applyHighlightingDeferred`가 stale markedRange로 실행 → NSRangeException

수정 예상:
```swift
override func resignFirstResponder() -> Bool {
    // 포커스 해제 전 IME 조합 취소
    if hasMarkedText() {
        markedText.mutableString.setString("")
        syncPreedit(clearIfNeeded: true)
    }
    let result = super.resignFirstResponder()
    // ... 기존 코드
}
```

### 검증 방법

**자동 검증 (소켓)**:
```python
def verify_ime_focus_switch_no_crash(c: termmesh):
    surfaces = c.list_surfaces()
    if len(surfaces) < 2:
        c.new_split("right")
        time.sleep(0.4)
        surfaces = c.list_surfaces()

    panel_a, panel_b = surfaces[0][1], surfaces[1][1]

    # 마크드 텍스트 상태 시뮬레이션 + 포커스 전환
    for _ in range(20):
        c.focus_surface(panel_a)
        time.sleep(0.02)
        # 한글 조합 중 포커스 전환 근사
        c.send_text(panel_a, "가")      # 조합 시작
        time.sleep(0.01)
        c.focus_surface(panel_b)        # 조합 중 포커스 전환
        time.sleep(0.03)
    # 크래시 없으면 PASS
```

**수동 체크리스트** (가장 확실한 재현):
1. **단계 1** — 한글 입력기 활성화
2. **단계 2** — 터미널 A에서 'ㄱ' 입력 (밑줄 표시 = marked text 활성 확인)
3. **단계 3** — 즉시 Cmd+] 또는 다른 패널 클릭으로 포커스 전환
4. **단계 4** — 수정 전: NSRangeException 크래시 / 수정 후: 크래시 없음
5. **단계 5** — 위 1-4를 30회 반복하여 안정성 확인

**IMETextView도 동일 검증**:
- IME 바(Cmd+I) 열고 한글 조합 중 Cmd+I로 닫기 → `dismantleNSView` 경로
- `NSObject.cancelPreviousPerformRequests` + `unmarkText` 순서 확인

**확인 포인트**:
- `GhosttyNSView.markedText.length == 0` 이 `resignFirstResponder` 반환 후 보장되는지
- `syncPreedit` 호출 후 `ghostty_surface_preedit(surface, nil, 0)` 확인 (preedit 클리어)

---

## 수정 #3 — DispatchQueue.main.sync 8곳 제거

### 현재 잔존 위치 (총 75개 v2MainSync 호출)

| 파일 | 개수 | 성격 |
|------|------|------|
| `TerminalController+Workspace.swift` | 13 | 워크스페이스 생성/전환/닫기 |
| `TerminalController+Debug.swift` | 7 | 디버그/윈도우 관리 |
| `TerminalController.swift` | 54 | 소켓 명령 처리 (resolveTabManager 등) |
| `TerminalController+Browser.swift` | 1 | 브라우저 명령 |

> **참고**: 과제 명세의 "8곳"은 고위험 경로(Ghostty C 콜백 경로)를 의미하며,
> 실제 파일 내 총 v2MainSync 호출은 75개임.

### 전환 패턴

```swift
// Before (교착 위험)
let result = v2MainSync { someUIWork() }

// After (timeout 보호)
var result: ReturnType?
let ok = v2MainExec(timeout: 2.0) { result = someUIWork() }
guard ok, let result else { return .err(...) }
```

**주의**: `v2MainExec`는 `body`가 실행되지 않을 수 있으므로
반환값을 사용하는 모든 호출처에서 `nil` 폴백 처리 필요.

### 검증 방법

**빌드 검증** (수정 완료 후):
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh \
  -configuration Debug -destination 'platform=macOS' build \
  2>&1 | tail -20
```

**자동 회귀 테스트** (기존 소켓 테스트 실행):
```bash
# VM에서 실행
ssh term-mesh-vm 'cd /Users/term-mesh/GhosttyTabs && \
  python3 tests/test_ctrl_socket.py && \
  python3 tests/test_multi_workspace_focus.py && \
  python3 tests/test_signals_auto.py && \
  python3 tests/test_notifications.py'
```

**수동 체크리스트**:

1. **워크스페이스 생성**: Cmd+T 5회 빠르게 → 탭이 모두 생성되고 포커스 정확
2. **워크스페이스 전환**: Cmd+[/] 빠르게 반복 → 터미널 응답 정상
3. **소켓 명령 + IME 동시**: IME 바에서 타이핑 중 `termmesh workspace.list` CLI 실행 → 교착 없음
4. **윈도우 닫기/열기**: Cmd+W → Dock에서 재오픈 → 창 정상 생성
5. **팀 에이전트 + 워크스페이스**: `tm-agent create 3` 실행 중 Cmd+T → 행 없음

**행(hang) 감지 방법**:
```bash
# 소켓 명령이 2초 내 응답하는지 확인
timeout 3 termmesh workspace.list || echo "HANG DETECTED"
```

**핵심 검증 케이스** (v2MainSync→v2MainExec 전환에서 가장 위험한 경로):
```bash
# 동시 소켓 명령 + 앱 포커스 변경
for i in {1..10}; do termmesh workspace.list & done
wait
```

---

## 빌드 검증 명령어

```bash
# 1. 클린 빌드 (수정 완료 후 VM에서)
ssh term-mesh-vm 'cd /Users/term-mesh/GhosttyTabs && \
  xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh \
  -configuration Debug -destination "platform=macOS" build \
  2>&1 | tail -30'

# 2. 빌드 성공 확인 후 앱 실행
ssh term-mesh-vm 'pkill -x "term-mesh DEV" || true; \
  APP=$(find /Users/term-mesh/Library/Developer/Xcode/DerivedData \
    -path "*/Build/Products/Debug/term-mesh DEV.app" -print -quit); \
  open "$APP" --env TERMMESH_SOCKET_MODE=allowAll'

# 3. 소켓 준비 대기
ssh term-mesh-vm 'for i in {1..20}; do \
  [ -S /tmp/term-mesh-debug.sock ] && break; sleep 0.5; done; echo ready'

# 4. 기존 자동화 테스트 전체 실행
ssh term-mesh-vm 'cd /Users/term-mesh/GhosttyTabs && \
  python3 tests/test_ctrl_socket.py && \
  python3 tests/test_multi_workspace_focus.py && \
  python3 tests/test_signals_auto.py && \
  python3 tests/test_notifications.py && \
  python3 tests/test_ime_crash_scenarios.py'
```

---

## 코드 리뷰 체크리스트 (수정 완료 후)

### 수정 #1 체크포인트
- [ ] `scheduleGeometryCallback` 재진입 경로 모두 async 처리
- [ ] `hasScheduledGeometryCallback` 초기화 시점 (view 해제 시 reset 여부)
- [ ] `onGeometryChanged?()` 콜백 내에서 레이아웃 재트리거 없는지

### 수정 #2 체크포인트
- [ ] `resignFirstResponder` 내 `markedText.length > 0` 조건 확인 후 clear
- [ ] `syncPreedit(clearIfNeeded: true)` 호출 순서 (`super.resignFirstResponder()` 전/후)
- [ ] `keyTextAccumulator` nil 처리 (조합 중 포커스 전환 시 accumulator 상태)
- [ ] IMETextView의 `viewDidMoveToWindow(window == nil)` 경로와 중복 없는지

### 수정 #3 체크포인트
- [ ] `v2MainExec` 반환 `false` 시 에러 응답 코드 일관성 (`"timeout"` 코드 사용)
- [ ] 반환값을 캡처하는 모든 `v2MainSync` 전환처에서 `optional` 언래핑 처리
- [ ] `TerminalController+Browser.swift:14` — 브라우저 명령 경로, timeout 2s 적절한지
- [ ] `TerminalController+Debug.swift` — 디버그 명령은 사용자 대면이 낮으므로 timeout 5s 고려
- [ ] 전환 후 새로운 `DispatchQueue.main.sync` 미도입 확인
  ```bash
  grep -rn "DispatchQueue.main.sync" Sources/ --include="*.swift"
  ```

---

## 검증 완료 기준 (Definition of Done)

| 항목 | 기준 |
|------|------|
| 빌드 | 에러 0, 경고 증가 없음 |
| 자동 테스트 | 기존 테스트 전부 PASS |
| 수동 #1 (layout) | 브라우저+분할 30회 조작 후 행/크래시 없음 |
| 수동 #2 (IME) | 한글 조합 중 포커스 전환 30회 후 크래시 없음 |
| 수동 #3 (sync) | 소켓 명령 동시 10개 발행 후 교착 없음 |
| Console.app | NSRangeException / EXC_BAD_ACCESS / Hang 로그 없음 |
