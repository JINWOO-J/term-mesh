import os
import sys

def check_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    results = []
    
    # 2. delegate 프로퍼티가 strong
    import re
    delegate_pattern = re.compile(r'^\s*(?:private\s+|public\s+|internal\s+)?(?:var|let)\s+[a-zA-Z0-9_]*delegate\b', re.MULTILINE | re.IGNORECASE)
    for match in delegate_pattern.finditer(content):
        line_num = content[:match.start()].count('\n') + 1
        line = match.group(0).strip()
        if 'weak' not in line:
            results.append((line_num, line, 'delegate strong', 'low', 'weak로 선언'))

    # 1. 클로저에서 [self] 강한 캡처 
    # Search for common async/closure keywords and find the `{` block
    keywords = [r'DispatchQueue\.[a-zA-Z0-9_().]+async(?:After)?(?:\([^)]*\))?', 
                r'NotificationCenter\.default\.addObserver(?:\([^)]*\))?',
                r'Timer\.scheduledTimer(?:\([^)]*\))?',
                r'URLSession\.shared\.dataTask(?:\([^)]*\))?',
                r'(?:\w+Completion|\w*handler|\w*Handler)\s*(?::|=|\()']
    
    for kw in keywords:
        pattern = re.compile(kw + r'\s*\{', re.MULTILINE)
        for match in pattern.finditer(content):
            start_idx = match.end() - 1
            # extract block
            depth = 0
            end_idx = start_idx
            for i in range(start_idx, len(content)):
                if content[i] == '{':
                    depth += 1
                elif content[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end_idx = i
                        break
            if depth != 0: continue
            
            block = content[start_idx:end_idx+1]
            if 'self.' in block:
                # check if there's [weak self] or [unowned self]
                if '[weak self]' not in block and '[unowned self]' not in block:
                    # check if the class/struct is actually a struct (can't easily do, but we report)
                    # let's report it
                    line_num = content[:start_idx].count('\n') + 1
                    snippet = match.group(0).strip()
                    results.append((line_num, snippet, f'클로저 strong self 캡처 ({kw.split(".")[0][:10]})', '중/높', '[weak self] 추가'))

    # 4. escaping 클로저에서 self 캡처
    # find functions with @escaping
    escaping_pattern = re.compile(r'@escaping\s*\(?[^)]*\)?\s*->\s*[^,{]*')
    # This is a bit complex. Let's just focus on the above which covers most closures.

    if results:
        print(f"File: {filepath}")
        for r in results:
            print(f"  Line {r[0]}: {r[2]} - {r[1]} - {r[4]}")

def main():
    for root, dirs, files in os.walk('Sources'):
        for file in files:
            if file.endswith('.swift'):
                check_file(os.path.join(root, file))

if __name__ == '__main__':
    main()