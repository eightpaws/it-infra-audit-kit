#!/usr/bin/env python3
"""Собирает находки из JSONL в отчёт Markdown и считает риски.

Вход: один или несколько файлов JSONL вида
    {"check": "accounts.adminCount", "value": 17, "severity": "medium", "note": "..."}
Выход: отчёт с таблицами по разделам и итоговой оценкой.

Код возврата: 1, если есть находки уровня critical, иначе 0.
"""
import argparse
import json
import sys
import datetime
from pathlib import Path

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
SEVERITY_TITLE = {
    "critical": "Критично",
    "high": "Высокий",
    "medium": "Средний",
    "low": "Низкий",
    "info": "Справочно",
}
SECTION_TITLE = {
    "domain": "Домен и контроллеры",
    "dc": "Домен и контроллеры",
    "fsmo": "Домен и контроллеры",
    "replication": "Репликация",
    "groups": "Привилегированные группы",
    "accounts": "Учётные записи",
    "computers": "Компьютеры",
    "krbtgt": "Ключевые секреты",
    "gpo": "Групповые политики",
    "dns": "DNS",
    "wbadmin": "Резервное копирование Windows",
    "vss": "Резервное копирование Windows",
    "dsrm": "Восстановление контроллера",
    "backup": "Резервное копирование",
    "storage": "Хранилища",
    "cluster": "Кластер",
    "replication": "Репликация",
    "config": "Конфигурация",
    "schedule": "Расписание",
    "path": "Каталоги копий",
    "db": "Базы данных",
    "restore": "Проверка восстановления",
    "pve": "Гипервизор",
}


def load(paths):
    rows = []
    for p in paths:
        for line in Path(p).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip().lstrip("\ufeff")
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"пропущена строка в {p}: {line[:60]}", file=sys.stderr)
    return rows


def section_of(check):
    head = check.split(".")[0]
    return SECTION_TITLE.get(head, head)


def main():
    ap = argparse.ArgumentParser(description="Собрать отчёт из JSONL-находок аудита")
    ap.add_argument("inputs", nargs="+", help="файлы JSONL")
    ap.add_argument("-o", "--out", default="out/report.md", help="куда писать отчёт")
    args = ap.parse_args()

    rows = load(args.inputs)
    if not rows:
        print("находок нет: проверьте, что скрипты отработали", file=sys.stderr)
        return 2

    for r in rows:
        r["severity"] = r.get("severity", "info")
        r.setdefault("note", "")
        r.setdefault("value", "")

    counts = {k: 0 for k in SEVERITY_ORDER}
    for r in rows:
        counts[r["severity"]] = counts.get(r["severity"], 0) + 1

    sections = {}
    for r in rows:
        sections.setdefault(section_of(r["check"]), []).append(r)

    out = []
    out.append("# Отчёт аудита ИТ-инфраструктуры")
    out.append("")
    out.append(f"Дата: {datetime.date.today().isoformat()}. Находок: {len(rows)}.")
    out.append("")
    out.append("## Итог")
    out.append("")
    out.append("| Уровень | Сколько |")
    out.append("|---|---|")
    for sev in SEVERITY_ORDER:
        if counts.get(sev):
            out.append(f"| {SEVERITY_TITLE[sev]} | {counts[sev]} |")
    out.append("")

    top = sorted([r for r in rows if r["severity"] in ("critical", "high")],
                 key=lambda r: SEVERITY_ORDER[r["severity"]])
    if top:
        out.append("## Что чинить первым")
        out.append("")
        for r in top:
            out.append(f"- **{r['check']}**: {r['value']}" + (f". {r['note']}" if r["note"] else ""))
        out.append("")
    else:
        out.append("Критичных и высоких находок нет. Это не значит, что всё хорошо: смотрите средние и низкие.")
        out.append("")

    out.append("## Подробно по разделам")
    out.append("")
    for name in sorted(sections, key=lambda s: min(SEVERITY_ORDER[r["severity"]] for r in sections[s])):
        items = sorted(sections[name], key=lambda r: SEVERITY_ORDER[r["severity"]])
        out.append(f"### {name}")
        out.append("")
        out.append("| Проверка | Значение | Уровень | Комментарий |")
        out.append("|---|---|---|---|")
        for r in items:
            value = str(r["value"]).replace("|", "\\|").replace("\n", " ")
            note = str(r["note"]).replace("|", "\\|").replace("\n", " ")
            out.append(f"| `{r['check']}` | {value} | {SEVERITY_TITLE[r['severity']]} | {note} |")
        out.append("")

    out.append("---")
    out.append("")
    out.append("Отчёт собран из находок, которые скрипты сняли только на чтение. "
               "Пустое значение означает, что проверка не смогла получить данные: это не норма, а повод разобраться.")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"отчёт: {args.out} ({len(rows)} находок, критичных: {counts.get('critical', 0)})")
    return 1 if counts.get("critical") else 0


if __name__ == "__main__":
    sys.exit(main())
