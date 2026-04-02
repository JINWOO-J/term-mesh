# Problem

에이전트에게 전달된 Enter 키가 씹히는(무시되는) 현상 — tm-agent delegate/send로 에이전트에 텍스트+Enter를 전송할 때 Enter가 터미널에 도달하지 않는 버그. sendIMEText, ghostty_surface_text, ghostty_surface_key 경로에서 Enter 유실 발생.
