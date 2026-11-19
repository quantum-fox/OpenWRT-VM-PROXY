#!/usr/bin/env python3
"""Собирает главы учебника для новичков (docs/beginner/NN-*.md) в один файл docs/beginner-guide.md.
  python docs/beginner/build.py
Что делает: берёт файлы вида 01-*.md, 02-*.md ... по порядку номеров; строит оглавление (главы и разделы), между главами вставляет
разрыв страницы для печати. Ссылки внутри файла делаются по заголовкам (так, как их понимают GitHub, VS Code и большинство просмотрщиков
Markdown): ссылка на определение термина `(#term-ip)` автоматически заменяется на ссылку на раздел, где стоит это определение.
Результат НЕ править вручную: правьте главы и запускайте сборку заново. Файлы README.md и beginner-guide.md в сборку не входят."""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'beginner-guide.md')
PAGE_BREAK = '\n<div style="page-break-after: always;"></div>\n'


def chapters():
    return sorted(f for f in os.listdir(HERE) if re.match(r'^\d\d-.*\.md$', f))


def slugify(text, used):
    """Якорь заголовка так, как его строит GitHub: строчные буквы, без знаков препинания, пробелы -> дефисы, повтор -> -1, -2."""
    t = re.sub(r'`', '', text).strip().lower()
    t = re.sub(r'[^\w\- ]', '', t, flags=re.UNICODE).replace(' ', '-')
    base, n = t, 0
    while t in used:
        n += 1
        t = '%s-%d' % (base, n)
    used.add(t)
    return t


def main():
    used = set()
    toc = []
    body = []
    idmap = {}                      # явный якорь (term-ip, ch03-s02 ...) -> якорь ближайшего заголовка
    for ci, name in enumerate(chapters(), 1):
        text = open(os.path.join(HERE, name), encoding='utf-8').read().replace('\r\n', '\n')
        in_code = False
        si = 0
        cur = None
        out_lines = []
        for line in text.split('\n'):
            if line.startswith('```'):
                in_code = not in_code
            if not in_code and line.startswith('# '):
                cur = slugify(line[2:], used)
                idmap['ch%02d' % ci] = cur
                toc.append('- **[%s](#%s)**' % (line[2:].strip(), cur))
            elif not in_code and line.startswith('## '):
                si += 1
                cur = slugify(line[3:], used)
                idmap['ch%02d-s%02d' % (ci, si)] = cur
                toc.append('  - [%s](#%s)' % (line[3:].strip(), cur))
            if not in_code:
                for m in re.finditer(r'<a id="([^"]+)"></a>', line):
                    idmap[m.group(1)] = cur
            out_lines.append(line)
        body.append('\n'.join(out_lines).rstrip() + '\n')

    def fix(m):
        key = m.group(1)
        return '](#%s)' % idmap[key] if idmap.get(key) else m.group(0)
    body = [re.sub(r'\]\(#([^)]+)\)', fix, b) for b in body]
    # явные якоря больше не нужны для ссылок, но безвредны; убираем, чтобы просмотрщики не показывали их как текст
    body = [re.sub(r'<a id="[^"]+"></a>\n?', '', b) for b in body]
    head = ('<!-- Файл создан скриптом docs/beginner/build.py из глав docs/beginner/NN-*.md. Не правьте его вручную. -->\n\n'
            '# Учебник для новичков: роутер OpenWrt + PassWall2\n\n'
            '## Оглавление\n\n' + '\n'.join(toc) + '\n')
    open(OUT, 'w', encoding='utf-8', newline='\n').write(head + PAGE_BREAK + PAGE_BREAK.join(body))
    words = sum(len(b.split()) for b in body)
    broken = sorted(set(re.findall(r'\]\(#((?:term|ch)[^)]*)\)', ''.join(body))))
    print('собрано глав: %d, слов: %d, примерно страниц A4 (400 слов): %d -> %s' % (len(body), words, words // 400, os.path.abspath(OUT)))
    if broken:
        print('ВНИМАНИЕ: не найдены якоря для ссылок:', ', '.join(broken))


if __name__ == '__main__':
    sys.exit(main())
