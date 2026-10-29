#!/usr/bin/env python3
"""字符级括号/引号配平检查（ObjC 高密度表达式改后必做的机械检查）。
剥掉字符串/字符字面量与行注释后统计三种括号差值，并扫常见残留问题。"""
import sys

BS = chr(92)  # backslash

def strip_strings(s: str) -> str:
    out = []
    i = 0
    n = len(s)
    mode = None
    while i < n:
        c = s[i]
        if mode is None:
            if c == '"':
                mode = 'str'; out.append(' ')
            elif c == "'":
                mode = 'chr'; out.append(' ')
            elif c == '/' and i + 1 < n and s[i + 1] == '/':
                mode = 'line'; out.append(' ')
            elif c == '/' and i + 1 < n and s[i + 1] == '*':
                mode = 'block'; out.append('  '); i += 1
            else:
                out.append(c)
        elif mode in ('str', 'chr'):
            if c == BS:
                i += 2
                continue
            if (mode == 'str' and c == '"') or (mode == 'chr' and c == "'"):
                mode = None
        elif mode == 'line':
            if c == '\n':
                mode = None
                out.append(c)
        elif mode == 'block':
            if c == '*' and i + 1 < n and s[i + 1] == '/':
                mode = None
                out.append(' ')
                i += 1
        i += 1
    return ''.join(out)

def main():
    ok = True
    for path in sys.argv[1:]:
        s = open(path, encoding='utf-8').read()
        t = strip_strings(s)
        b = t.count('{') - t.count('}')
        k = t.count('[') - t.count(']')
        p = t.count('(') - t.count(')')
        name = path.split('/')[-1]
        status = 'OK' if b == k == p == 0 else f'不平衡 braces={b} brackets={k} parens={p}'
        print(f'{name:24s} {status}')
        if b or k or p:
            ok = False
        compact = s.replace(' ', '')
        for bad in ('UIColor.systemFill', 'UIColor.systemRed5', 'p[@"province]', 'p[@"file]', 'p[@"display]', 'p[@"size]'):
            if bad.replace(' ', '') in compact:
                print('  残留:', bad)
                ok = False
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
