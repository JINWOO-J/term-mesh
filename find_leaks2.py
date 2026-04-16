import os
import re

sources_dir = 'Sources'
results = []

delegate_regex = re.compile(r'^\s*(?:@objc\s+)?(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(?:lazy\s+)?var\s+\w*(?:[dD]elegate|[dD]ataSource)\s*:\s*[A-Z]', re.MULTILINE)

closure_patterns = [
    (re.compile(r'Timer\.scheduledTimer[^{]*\{'), "Timer Capture", "High"),
    (re.compile(r'NotificationCenter\.default\.addObserver[^{]*\{'), "NotificationCenter Capture", "High"),
    (re.compile(r'DispatchQueue\.[^{]*\.async[^{]*\{'), "DispatchQueue Async Capture", "Low"),
    (re.compile(r'(?<!\.)addObserver[^{]*\{'), "addObserver Capture", "Medium"),
    (re.compile(r'Task\s*\{'), "Task Capture", "Low")
]

def analyze_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return
    
    lines = content.split('\n')
    
    for i, line in enumerate(lines):
        if delegate_regex.search(line):
            if 'weak ' not in line and 'unowned ' not in line:
                # avoid false positives like var delegate: Delegate = ... inside a function
                if "struct " not in content and "class " in content:
                     results.append((filepath, i+1, "Delegate without weak", "High", line.strip()))
    
    for pattern, name, severity in closure_patterns:
        for match in pattern.finditer(content):
            start = match.end() - 1 # position of '{'
            if content[start] != '{':
                continue
                
            brace_count = 0
            end = start
            in_string = False
            for j in range(start, len(content)):
                if content[j] == '"' and (j == 0 or content[j-1] != '\\'):
                    in_string = not in_string
                if not in_string:
                    if content[j] == '{':
                        brace_count += 1
                    elif content[j] == '}':
                        brace_count -= 1
                        if brace_count == 0:
                            end = j + 1
                            break
            
            if brace_count == 0:
                block = content[start:end]
                if re.search(r'\bself\b', block):
                    # Check capture list
                    capture_list_match = re.match(r'^\{\s*\[([^\]]+)\]', block)
                    has_weak_self = False
                    if capture_list_match:
                        caps = capture_list_match.group(1)
                        if 'weak self' in caps or 'unowned self' in caps or 'self' == caps.strip():
                            # [self] is explicit capture, often strong but implies intentional. Still a strong capture.
                            if 'weak' in caps or 'unowned' in caps:
                                has_weak_self = True
                    
                    if not has_weak_self:
                        line_num = content[:start].count('\n') + 1
                        snippet = content.split('\n')[line_num-1].strip()
                        results.append((filepath, line_num, name, severity, snippet))

for root, _, files in os.walk(sources_dir):
    for file in files:
        if file.endswith('.swift'):
            analyze_file(os.path.join(root, file))

# Deduplicate
unique_results = []
seen = set()
for r in results:
    key = (r[0], r[1])
    if key not in seen:
        seen.add(key)
        unique_results.append(r)

print("| 파일명 | 라인번호 | 패턴 종류 | 위험도 | 코드 스니펫 |")
print("|---|---|---|---|---|")
for r in sorted(unique_results, key=lambda x: (x[0], x[1])):
    print(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | `{r[4][:80]}` |")
