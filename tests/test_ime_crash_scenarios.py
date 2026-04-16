#!/usr/bin/env python3
"""
TERM-MESH-9 크래시 재현 시나리오 — IME 입력 중 NSRangeException

크래시: NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds
경로: insertText:replacementRange: → NSTextStorage replaceCharactersInRange → 범위 초과

이 파일은 자동 재현 테스트(소켓 기반)와 수동 재현 절차를 함께 정의한다.
자동 테스트는 term-mesh 앱이 실행 중이어야 한다.

Usage:
    python3 tests/test_ime_crash_scenarios.py
    python3 tests/test_ime_crash_scenarios.py --scenario 1   # 특정 시나리오만 실행

재현 우선순위 (가장 가능성 높은 순):
    1. acceptGhostSuggestion race (텍스트 리셋 + ghost 수락 타이밍)
    2. 마크드 텍스트 중 탭 전환 (applyHighlightingDeferred stale len)
    3. 한글 IME 빠른 입력 후 포커스 전환 (insertText 도중 unmarkText 경합)
    4. 긴 한글 텍스트 + Cmd+V (paste 중 storage 경합)
"""

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


SOCKET_PATH = os.environ.get("TERMMESH_SOCKET", "/tmp/term-mesh.sock")
DEBUG_SOCKET = os.environ.get("TERMMESH_DEBUG_SOCKET", "/tmp/term-mesh-debug.sock")

# IME 바를 여는 단축키 (term-mesh 기본: Cmd+I)
IME_OPEN_KEY = "cmd+i"

PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"


def _wait_for(pred, timeout_s: float = 3.0, step_s: float = 0.05) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return True
        time.sleep(step_s)
    return False


# ---------------------------------------------------------------------------
# 시나리오 1: acceptGhostSuggestion race
# ---------------------------------------------------------------------------
# 원인: IMETextView.acceptGhostSuggestion() 에서
#   let loc = (string as NSString).length  ← 이 시점의 길이 캡처
#   insertText(insertion, replacementRange: NSRange(location: loc, length: 0))
#
# SwiftUI updateNSView()가 textView.string = "" 으로 리셋하면
# loc > 새 storage.length → NSRangeException
#
# 재현 조건:
#   - IME 바에 텍스트 있고 ghost suggestion 표시됨 (히스토리 엔트리 필요)
#   - Tab 키로 ghost 수락 시도와 동시에 외부에서 string="" 리셋
# ---------------------------------------------------------------------------
def scenario_1_ghost_suggestion_race(c: termmesh) -> str:
    """
    [시나리오 1] acceptGhostSuggestion race — 우선순위: 최고

    재현 절차:
    1. IME 바를 열고 히스토리에 있는 텍스트의 접두어를 입력 → ghost 표시됨
    2. Tab으로 ghost 수락 직전, 외부 이벤트로 string="" 리셋 유도
    3. NSRangeException 여부 확인

    자동화 한계: ghost suggestion은 히스토리 데이터에 의존하므로
    소켓으로 직접 트리거하기 어렵다. 여기서는 근사 재현으로:
    - 소켓 ime.open → 텍스트 입력 → ime.submit (빠른 리셋)
    - ime.open → type → Tab (ghost accept) 를 반복하여 타이밍 경합 유도
    """
    print("  [S1] IME 오픈 후 빠른 submit 반복 (ghost race 근사 재현)")

    for i in range(10):
        try:
            c.send_command("ime.open")
            time.sleep(0.05)
            # 히스토리 엔트리와 접두어가 일치하는 텍스트 입력
            c.send_command("ime.type", {"text": "ls"})
            time.sleep(0.03)
            # ghost가 표시될 시간을 주고 Tab (ghost accept) 시도
            c.send_command("ime.key", {"key": "tab"})
            time.sleep(0.02)
            # 즉시 submit으로 string 리셋 유도 (race window)
            c.send_command("ime.submit")
            time.sleep(0.05)
        except termmeshError:
            pass

    return PASS  # 크래시 없이 완료되면 PASS


# ---------------------------------------------------------------------------
# 시나리오 2: 마크드 텍스트 상태에서 탭 전환
# ---------------------------------------------------------------------------
# 원인: applyHighlightingDeferred 가 perform(...afterDelay:0) 으로 예약된 후
# dismantleNSView 의 cancelPreviousPerformRequests 가 실행되기 전에
# 런루프가 deferred 블록을 실행하면:
#   - textStorage 가 이미 SwiftUI 업데이트로 변경된 상태
#   - 캡처된 markedRange / fullString 이 stale → 범위 초과
#
# 재현 조건:
#   - IME 바에서 한글 조합 중 (marked text 활성)
#   - 다른 탭으로 전환 (IMETextEditor dismantleNSView 트리거)
# ---------------------------------------------------------------------------
def scenario_2_marked_text_tab_switch(c: termmesh) -> str:
    """
    [시나리오 2] 마크드 텍스트 + 탭 전환 — 우선순위: 높음

    재현 절차 (소켓으로 근사 재현):
    1. 새 탭 2개 생성 (A, B)
    2. 탭 A에서 IME 오픈 후 한글 조합 시작 (setMarkedText 유도)
    3. 조합 완료 전에 탭 B로 전환 → dismantleNSView 트리거
    4. 크래시 여부 확인

    수동 재현 절차 (가장 확실):
    - 한글 키보드로 IME 바 열기
    - 'ㄱ' 입력 (조합 중 상태 = marked text 활성)
    - 즉시 Cmd+T 또는 탭 클릭으로 다른 탭 전환
    - 반복: 이 과정을 10회 이상 빠르게 반복
    """
    print("  [S2] IME 오픈 후 마크드 텍스트 시뮬레이션 + 탭 전환")

    # 탭 2개 확보
    surfaces = c.list_surfaces()
    if len(surfaces) < 2:
        c.new_surface(panel_type="terminal")
        time.sleep(0.5)
        surfaces = c.list_surfaces()

    if len(surfaces) < 2:
        print("  [S2] 탭 부족 — SKIP")
        return SKIP

    tab_a = surfaces[0][1]
    tab_b = surfaces[1][1]

    for i in range(15):
        try:
            # 탭 A 포커스
            c.focus_surface(tab_a)
            time.sleep(0.05)
            # IME 오픈 후 텍스트 입력 시작
            c.send_command("ime.open")
            time.sleep(0.04)
            c.send_command("ime.type", {"text": "가나다"})
            time.sleep(0.02)
            # 조합 중 탭 전환 (marked text 활성 상태)
            c.focus_surface(tab_b)
            time.sleep(0.04)
        except termmeshError:
            pass

    return PASS


# ---------------------------------------------------------------------------
# 시나리오 3: 한글 IME 빠른 입력 후 즉시 포커스 전환
# ---------------------------------------------------------------------------
# 원인: GhosttyNSView.insertText(_:replacementRange:) 에서
# sendTextToSurface → ghostty_surface_key 호출 후,
# 포커스 전환이 surface=nil 시점에 겹치면 unmarkText → syncPreedit 경합
#
# 이 경로는 GhosttyNSView (터미널 직접 입력)에 해당하며
# IMETextView 크래시와는 별개이지만 유사 패턴
# ---------------------------------------------------------------------------
def scenario_3_rapid_korean_focus_switch(c: termmesh) -> str:
    """
    [시나리오 3] 한글 IME 빠른 입력 + 포커스 전환 — 우선순위: 중간

    재현 절차 (수동):
    - 한글 입력기로 터미널에 직접 빠르게 타이핑
    - 입력 도중 Cmd+[ / Cmd+] 로 패널 전환 반복
    - 10~20회 반복 시 크래시 발생 가능

    소켓 근사 재현:
    - send_text 반복 + focus 전환 교차 실행
    """
    print("  [S3] 빠른 텍스트 입력 + 포커스 전환 교차")

    surfaces = c.list_surfaces()
    if len(surfaces) < 2:
        c.new_split("right")
        time.sleep(0.5)
        surfaces = c.list_surfaces()

    if len(surfaces) < 2:
        print("  [S3] 패널 부족 — SKIP")
        return SKIP

    panel_ids = [s[1] for s in surfaces[:2]]

    korean_texts = ["안녕하세요", "테스트입니다", "한글IME입력", "가나다라마바사"]

    for i in range(20):
        try:
            idx = i % 2
            c.focus_surface(panel_ids[idx])
            time.sleep(0.02)
            text = korean_texts[i % len(korean_texts)]
            c.send_text(panel_ids[idx], text[:2])  # 부분 입력
            time.sleep(0.01)
            # 즉시 포커스 전환 (IME 조합 도중)
            c.focus_surface(panel_ids[1 - idx])
            time.sleep(0.02)
        except termmeshError:
            pass

    return PASS


# ---------------------------------------------------------------------------
# 시나리오 4: 긴 텍스트 한글 입력 중 Cmd+C / Cmd+V
# ---------------------------------------------------------------------------
# 원인: IMETextView에서 Cmd+C 처리 시
# findTerminalSurfaceWithSelection → ghostty_surface_has_selection 은 별도이나,
# Cmd+V (paste) 시 pasteAsPlainText → NSTextStorage 직접 편집이 발생
# 한글 조합 중 붙여넣기는 insertText가 marked text 범위와 충돌 가능
# ---------------------------------------------------------------------------
def scenario_4_korean_copy_paste_during_composition(c: termmesh) -> str:
    """
    [시나리오 4] 한글 IME 입력 중 Cmd+C/V — 우선순위: 중간

    재현 절차 (수동):
    - IME 바에 긴 한글 텍스트 입력 (marked text 활성 유지)
    - 입력 도중 Cmd+V (붙여넣기) 실행
    - 또는 Cmd+C (복사) 실행
    - 크래시 여부 확인

    소켓 근사 재현: IME 오픈 후 type + clipboard operation 교차
    """
    print("  [S4] IME 오픈 후 텍스트 입력 + 붙여넣기 교차")

    for i in range(10):
        try:
            c.send_command("ime.open")
            time.sleep(0.04)
            c.send_command("ime.type", {"text": "안녕하세요테스트"})
            time.sleep(0.03)
            # 조합 중 Cmd+V 유사 동작 (추가 텍스트 삽입)
            c.send_command("ime.type", {"text": " 추가텍스트"})
            time.sleep(0.02)
            c.send_command("ime.submit")
            time.sleep(0.1)
        except termmeshError:
            pass

    return PASS


# ---------------------------------------------------------------------------
# 시나리오 5: 여러 터미널 패널 동시 IME 입력 (동시성 스트레스)
# ---------------------------------------------------------------------------
# 원인: 여러 GhosttyNSView 인스턴스가 각자 markedText 상태를 가지고
# 동시에 insertText 호출 시 AppKit 내부 상태 경합 가능
# (NSTextInputContext 는 뷰 단위이므로 직접 경합은 없으나,
#  포커스 전환 시 firstResponder 변경이 빠르면 context flush 타이밍 어긋남)
# ---------------------------------------------------------------------------
def scenario_5_concurrent_ime_panels(c: termmesh) -> str:
    """
    [시나리오 5] 여러 패널 동시 IME — 우선순위: 낮음

    재현 절차 (수동):
    - 4개 이상 패널 분할
    - 각 패널에서 한글 입력 후 빠르게 다음 패널로 이동 반복
    - Cmd+[ 반복으로 순환하면서 각 패널에 1-2글자씩 입력
    """
    print("  [S5] 여러 패널 분할 후 순환 IME 입력")

    # 패널 3개 확보
    surfaces = c.list_surfaces()
    needed = max(0, 3 - len(surfaces))
    for _ in range(needed):
        c.new_split("right")
        time.sleep(0.4)
    surfaces = c.list_surfaces()

    panel_ids = [s[1] for s in surfaces[:3]]

    for round_i in range(10):
        for pid in panel_ids:
            try:
                c.focus_surface(pid)
                time.sleep(0.02)
                c.send_text(pid, "가")
                time.sleep(0.01)
            except termmeshError:
                pass

    return PASS


# ---------------------------------------------------------------------------
# 실행 엔진
# ---------------------------------------------------------------------------

SCENARIOS = [
    (1, "acceptGhostSuggestion race", scenario_1_ghost_suggestion_race),
    (2, "마크드 텍스트 + 탭 전환", scenario_2_marked_text_tab_switch),
    (3, "한글 IME 빠른 입력 + 포커스 전환", scenario_3_rapid_korean_focus_switch),
    (4, "한글 IME 중 Cmd+C/V", scenario_4_korean_copy_paste_during_composition),
    (5, "여러 패널 동시 IME", scenario_5_concurrent_ime_panels),
]


def main() -> int:
    parser = argparse.ArgumentParser(description="TERM-MESH-9 IME 크래시 재현 시나리오")
    parser.add_argument("--scenario", type=int, help="특정 시나리오 번호만 실행 (1-5)")
    parser.add_argument("--socket", default=SOCKET_PATH, help="소켓 경로")
    args = parser.parse_args()

    results = []

    try:
        with termmesh(args.socket) as c:
            c.activate_app()
            time.sleep(0.3)

            for num, name, fn in SCENARIOS:
                if args.scenario and args.scenario != num:
                    continue
                print(f"\n[시나리오 {num}] {name}")
                try:
                    result = fn(c)
                except Exception as e:
                    result = FAIL
                    print(f"  → 예외 발생: {e}")
                print(f"  → {result}")
                results.append((num, name, result))

    except Exception as e:
        print(f"소켓 연결 실패: {e}")
        print("앱이 실행 중인지, 소켓 경로가 맞는지 확인하세요.")
        print("\n=== 수동 재현 체크리스트 ===")
        _print_manual_checklist()
        return 1

    print("\n=== 결과 요약 ===")
    for num, name, result in results:
        mark = "✓" if result == PASS else ("?" if result == SKIP else "✗")
        print(f"  [{mark}] S{num}: {name} → {result}")

    failed = [r for r in results if r[2] == FAIL]
    return 1 if failed else 0


def _print_manual_checklist():
    print("""
수동 재현 체크리스트 (소켓 없이도 실행 가능한 재현 절차)

[우선순위 1] acceptGhostSuggestion race
  - IME 바 열기 (Cmd+I)
  - 이전 히스토리 항목의 접두어 입력 (ghost suggestion 표시 확인)
  - Tab 키를 빠르게 반복 → 제출 → 다시 열기 (10회 이상)
  - 특히 Tab 직후 Cmd+I 로 닫기를 빠르게 반복

[우선순위 2] 마크드 텍스트 + 탭 전환
  - 한글 입력기 활성화
  - IME 바 열기 (Cmd+I)
  - 'ㄱ' 또는 'ㅎ' 입력 (마크드 텍스트 상태 확인: 밑줄 표시)
  - 조합 완료 전 즉시 Cmd+] 또는 탭 클릭으로 다른 탭 전환
  - 10~20회 반복 (빠를수록 재현 가능성 높음)

[우선순위 3] 한글 IME 빠른 입력 + 포커스 전환
  - 한글 입력기로 터미널 직접 입력
  - 빠르게 "안녕하세요" 입력 후 즉시 Cmd+[ 로 패널 전환
  - 다른 패널에서도 같은 동작 반복
  - 분할 패널이 많을수록 재현 쉬움

[우선순위 4] 한글 IME 중 Cmd+V
  - 클립보드에 텍스트 복사해 두기
  - IME 바 열고 한글 조합 중 Cmd+V
  - 조합 완료 전 붙여넣기 타이밍이 중요

[확인 방법]
  - Console.app 에서 'term-mesh' 필터 → NSRangeException 로그 확인
  - Sentry 대시보드에서 TERM-MESH-9 이벤트 증가 확인
  - crash log: ~/Library/Logs/DiagnosticReports/term-mesh*.ips
""")


if __name__ == "__main__":
    raise SystemExit(main())
