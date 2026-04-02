# Problem

tm-op 에이전트 팀 오케스트레이션의 안정성 확보를 위한 개선. 방금 수정한 wait 버그(completed 에이전트가 카운트에서 사라지는 문제, stale 태스크가 total을 부풀리는 문제) 외에도 추가적인 안정성 이슈가 있을 수 있음. tm-agent의 delegate→reply→wait 전체 통신 파이프라인, tm-op 커맨드의 전략 실행 로직, 에러 핸들링, edge case 등을 종합적으로 분석하여 개선 방안을 도출해야 함.
