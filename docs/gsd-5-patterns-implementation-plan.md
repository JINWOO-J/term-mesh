# GSD 5가지 핵심 패턴의 term-mesh (tm-agent) 통합 구현 계획

GSD(Get Shit Done)의 강력한 자율성 제어 및 스케줄링 패턴을 term-mesh의 고성능 소켓/데몬 아키텍처에 결합하여 최고의 에이전트 시스템을 구축합니다.

## 1. Wave 기반 병렬 오케스트레이션 (18개 전문 에이전트)
- **GSD 패턴**: 다양한 전문 에이전트를 Wave(단계)별로 그룹화하여 병렬 실행.
- **term-mesh 구현 계획**: 기존 Rust 데몬이 관리하는 지속적 에이전트 풀에 'Wave' 개념을 도입. `tm-agent` 오케스트레이터가 특정 단계에서 필요한 여러 에이전트(예: Researcher, Planner)에게 소켓 RPC를 통해 병렬로 작업을 할당하고, 모든 응답을 수집한 뒤 다음 Wave로 넘어가는 스케줄러(Scheduler) 모듈을 추가합니다.

## 2. 파일 기반 간접 통신 (.planning/)과 하이브리드 상태 관리
- **GSD 패턴**: `.planning/` 디렉토리를 통한 파일 기반 상태 관리 및 에이전트 간 비동기 소통.
- **term-mesh 구현 계획**: term-mesh는 소켓 통신을 통해 실시간 반응성이 매우 우수하므로, 상태 지속성(Persistence)과 복구(Fault-tolerance)를 위해 이 패턴을 차용합니다. `.omc/state/` 또는 `.planning/`과 유사한 전용 디렉토리에 각 Wave의 결과와 마스터 플랜을 JSON/Markdown 형태로 저장하여, 데몬 재시작 시에도 끊김 없이 워크플로우를 재개할 수 있도록 하이브리드 통신망을 구축합니다.

## 3. 6단계 파이프라인
- **GSD 패턴**: 명확하게 정의된 6단계 파이프라인.
- **term-mesh 구현 계획**: `tm-agent`의 작업 생명주기를 6단계(예: 1. 분석 -> 2. 계획 -> 3. 컨텍스트 수집 -> 4. 병렬 실행 -> 5. 검증 -> 6. 정리)의 유한 상태 기계(State Machine)로 엄격하게 정의합니다. CLI 레벨에서 각 단계의 진척도를 시각적으로 표시합니다.

## 4. Context Monitor Hook (35%/25% 임계치)
- **GSD 패턴**: 컨텍스트 윈도우 한계를 추적하여 임계치 도달 시 알림.
- **term-mesh 구현 계획**: Rust 데몬 내에 Token/Context 추적 훅(Hook)을 구현하여 에이전트와 주고받는 메시지 크기를 실시간으로 계산합니다. 남은 컨텍스트가 35%, 25%에 도달할 때 `tm-agent` 프로세스에 경고 이벤트를 발송하여, 에이전트가 불필요한 과거 기억을 요약하거나 컨텍스트를 압축(Context Consolidation)하도록 강제합니다.

## 5. 4-Rule Auto-Fix Protocol & Analysis Paralysis Guard
- **GSD 패턴**: 3회 수정 제한 및 5회 연속 읽기 방지 등의 무한 루프 가드.
- **term-mesh 구현 계획**: `tm-agent` 실행 루프 내에 '행동 패턴 감지기(Action Pattern Detector)' 모듈을 탑재합니다.
  - **Analysis Paralysis Guard**: 동일한 파일 읽기나 의미 없는 탐색 명령이 5회 연속 발생하면 작업을 일시 정지(Block)하고 상위 에이전트 또는 사용자에게 개입을 요청합니다.
  - **Auto-Fix Protocol**: 테스트 실패나 컴파일 에러에 대한 자동 수정 시도를 3회로 제한하고, 이를 초과할 경우 기존 방식을 폐기하고 새로운 전략 수립(Re-planning) 단계로 강제 전환합니다.
