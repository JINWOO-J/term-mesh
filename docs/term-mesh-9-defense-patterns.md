# TERM-MESH-9 방어 코드 패턴

## 크래시 요약

```
NSRangeException: NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds
경로: insertText:replacementRange: → NSTextStorage replaceCharactersInRange → 범위 초과
위치: IMETextView (IME 바) 또는 GhosttyNSView (터미널 직접 입력)
```

---

## 크래시 경로 분석 (우선순위 순)

### [P1] acceptGhostSuggestion race — 가장 유력

**위치**: `Sources/IME/IMETextView.swift:759-760`

```swift
// 현재 코드 (취약)
func acceptGhostSuggestion() {
    guard !ghostSuggestion.isEmpty else { return }
    let insertion = ghostSuggestion
    clearGhost()
    let loc = (string as NSString).length          // ← 이 시점 길이 캡처
    insertText(insertion, replacementRange: NSRange(location: loc, length: 0))
    // ↑ SwiftUI updateNSView가 textView.string = "" 하면 loc > storage.length → 크래시
}
```

**크래시 타이밍**:
1. 사용자 Tab → `acceptGhostSuggestion()` 호출, `loc = 5` 캡처
2. SwiftUI update 사이클이 동시에 실행되어 `textView.string = ""` (length=0)
3. `insertText(_, replacementRange: NSRange(location: 5, length: 0))` → 5 > 0 → 크래시

**방어 패턴**:
```swift
func acceptGhostSuggestion() {
    guard !ghostSuggestion.isEmpty else { return }
    let insertion = ghostSuggestion
    clearGhost()
    // storage.length를 insertText 직전에 다시 읽고, 범위 유효성 검증
    guard let storage = textStorage else { return }
    let loc = min((string as NSString).length, storage.length)
    guard loc <= storage.length else { return }  // 방어: 리셋 경합 시 skip
    insertText(insertion, replacementRange: NSRange(location: loc, length: 0))
}
```

또는 더 강력한 방어:
```swift
func acceptGhostSuggestion() {
    guard !ghostSuggestion.isEmpty else { return }
    let insertion = ghostSuggestion
    clearGhost()
    // NSRange(location: NSNotFound, length: 0) = 커서 위치에 삽입 (항상 안전)
    insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
}
```

---

### [P2] applyHighlightingDeferred 지연 실행 + 외부 스토리지 변경

**위치**: `Sources/IME/IMETextView.swift:575-579`

**크래시 타이밍**:
1. `didChangeText()` → `perform(applyHighlightingDeferred, afterDelay: 0)` 예약
2. SwiftUI `dismantleNSView` → `cancelPreviousPerformRequests` 실행 (취소)
3. **문제**: 런루프가 이미 deferred 블록 실행을 시작한 경우 `cancel`이 무효
4. `applyRainbowKeywords()` 내에서 `fullString` 은 `beginEditing` 전에 캡처됨
5. `textView.string = ""` 이 그 사이에 실행되면 → `len > storage.length` → 크래시

**현재 코드 (부분적으로 방어됨)**:
```swift
@objc func applyHighlightingDeferred() {
    guard !isApplyingRainbow, !hasMarkedText() else { return }
    applyRainbowKeywords()
    updateGhostSuggestion()
}

func applyRainbowKeywords() {
    guard let storage = textStorage, storage.length > 0 else { return }
    let markedRange = self.markedRange()
    let fullString = storage.string as NSString   // ← beginEditing 전 캡처 (취약)

    isApplyingRainbow = true
    defer { isApplyingRainbow = false }

    storage.beginEditing()
    let len = storage.length  // ← beginEditing 내에서 재캡처 (개선됨)
    guard len > 0 else { storage.endEditing(); return }
    // ...
    // fullString 은 위에서 캡처된 stale 값 — fullString.length != len 가능
```

**추가 방어 패턴**:
```swift
func applyRainbowKeywords() {
    guard !isApplyingRainbow else { return }
    guard let storage = textStorage, storage.length > 0 else { return }

    isApplyingRainbow = true
    defer { isApplyingRainbow = false }

    storage.beginEditing()
    let len = storage.length
    guard len > 0 else { storage.endEditing(); return }

    // fullString을 beginEditing 내에서 캡처 (len과 일관성 보장)
    let fullString = storage.string as NSString
    guard fullString.length == len else { storage.endEditing(); return }  // 일관성 검증

    let markedRange = self.markedRange()
    // ... 이하 동일
```

---

### [P3] insertText 에서 replacementRange 유효성 검증

**위치**: `Sources/IME/IMETextView.swift:495-497`

```swift
// 현재 코드
override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    composingHandler?(false)
}
```

`super.insertText`에 들어가기 전 `replacementRange` 유효성 검증:

```swift
override func insertText(_ string: Any, replacementRange: NSRange) {
    // replacementRange 유효성 검증: NSNotFound 는 NSTextView 가 처리하므로 통과
    if replacementRange.location != NSNotFound,
       let storage = textStorage {
        let storageLen = storage.length
        let rangeEnd = replacementRange.location + replacementRange.length
        guard replacementRange.location <= storageLen,
              rangeEnd <= storageLen else {
            // 범위 초과: 커서 위치에 삽입 (안전한 폴백)
            super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            composingHandler?(false)
            return
        }
    }
    super.insertText(string, replacementRange: replacementRange)
    composingHandler?(false)
}
```

---

### [P4] GhosttyNSView insertText — replacementRange 미사용 (현재 안전)

**위치**: `Sources/GhosttyNSView+TextInput.swift:125-150`

현재 코드는 `replacementRange`를 전혀 사용하지 않고 `sendTextToSurface`만 호출한다.
`NSTextStorage`에 직접 접근하지 않으므로 이 경로는 크래시 위험 낮음.

단, `unmarkText()` → `markedText.mutableString.setString("")` 과
외부 이벤트(포커스 전환)가 경합하는 경우:

```swift
// 현재 코드 (안전)
func unmarkText() {
    if markedText.length > 0 {
        markedText.mutableString.setString("")
        syncPreedit()
    }
}
// markedText 는 NSMutableAttributedString 이고 NSTextStorage 가 아님
// → NSRangeException 위험 없음
```

---

## try-catch로 NSRangeException 방어 가능한가?

**불가능** — Swift에서 Objective-C `NSException`은 `do-catch`로 잡을 수 없다.

```swift
// ❌ 이 코드는 NSRangeException을 잡지 못함
do {
    try super.insertText(string, replacementRange: replacementRange)
} catch {
    // NSException은 Swift Error가 아님 — 여기 도달하지 않음
}
```

**대안**: Objective-C 래퍼 사용 (권장하지 않음, 복잡도 증가):
```objc
// ObjcExceptionBridge.m
BOOL safeInsertText(NSTextView *view, id string, NSRange range) {
    @try {
        [view insertText:string replacementRange:range];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[TERM-MESH] insertText exception caught: %@", e);
        return NO;
    }
}
```

→ **권장 방어 전략은 try-catch가 아닌 사전 유효성 검증**이다.

---

## NSTextStorage 접근 전 length 체크 패턴

```swift
// 패턴 1: beginEditing/endEditing 내에서 일관된 len 사용
storage.beginEditing()
let len = storage.length  // 편집 세션 내에서 권위 있는 값
guard len > 0 else { storage.endEditing(); return }
// len 으로만 모든 NSRange 구성

// 패턴 2: NSRange 생성 시 clamping
extension NSRange {
    static func safe(location: Int, length: Int, within bound: Int) -> NSRange? {
        guard location >= 0, location <= bound else { return nil }
        let clampedLength = min(length, bound - location)
        return NSRange(location: location, length: clampedLength)
    }
}

// 패턴 3: NSString range 검증
let nsStr = storage.string as NSString
let range = NSRange(location: 0, length: min(len, nsStr.length))
// len과 nsStr.length가 일치하는지 검증

// 패턴 4: 복합 guard
guard let range = NSRange.safe(location: loc, length: 0, within: storage.length) else { return }
storage.addAttribute(.foregroundColor, value: color, range: range)
```

---

## 유사 오픈소스 프로젝트 방어 코드 패턴

### iTerm2
- `PTYTextView.m`: `insertText:replacementRange:` 에서 `replacementRange` 무시하고
  마크드 텍스트 상태에서는 자체 버퍼로 관리. `NSTextStorage` 직접 편집 없음.
- IME 조합 완료 전 외부 텍스트 변경 시 `unmarkText` 먼저 호출 후 처리.

### Ghostty (Rust/Zig 코어)
- Swift 레이어에서 `markedText` 를 `NSMutableAttributedString` 으로 독립 관리.
- `NSTextInputClient` 프로토콜 구현이 `NSTextView`를 상속하지 않으므로
  `NSTextStorage` 경합 없음.

### Alacritty (macOS Swift wrapper)
- `NSTextInputClient` 를 `NSView` 에서 직접 구현 (NSTextView 미사용).
- `insertText` 에서 자체 문자열 버퍼에만 쓰고 화면 렌더링은 별도 경로.
- → **NSTextView 상속을 피하면 NSTextStorage 관련 크래시 구조적으로 차단됨**.

### 공통 패턴
1. **IME 조합 중 외부 텍스트 변경 차단**: `hasMarkedText()` 확인 후 변경
2. **deferred 작업 시 weak 캡처 + 유효성 재확인**:
   ```swift
   perform(#selector(applyHighlightingDeferred), with: nil, afterDelay: 0)
   // ↓ 실행 시
   @objc func applyHighlightingDeferred() {
       guard !isApplyingRainbow, !hasMarkedText() else { return }
       guard let storage = textStorage, storage.length > 0 else { return }
       // ...
   }
   ```
3. **NSRange 구성 전 bounds 체크**: `location + length <= storage.length` 항상 검증

---

## 권장 수정 우선순위

| 순위 | 파일 | 수정 내용 | 난이도 |
|------|------|-----------|--------|
| 1 | `IMETextView.swift:760` | `acceptGhostSuggestion` — `NSNotFound` 대체 또는 bounds 검증 | 낮음 |
| 2 | `IMETextView.swift:586` | `applyRainbowKeywords` — `fullString` 을 `beginEditing` 내 캡처 + 일관성 검증 | 낮음 |
| 3 | `IMETextView.swift:495` | `insertText` override — `replacementRange` bounds 사전 검증 | 낮음 |
| 4 | `IMETextEditor.swift:140` | `updateNSView` — `textView.string = text` 전 `!hasMarkedText()` 확인 강화 | 낮음 |
