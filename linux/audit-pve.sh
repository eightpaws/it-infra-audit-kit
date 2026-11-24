#!/usr/bin/env bash
# Аудит гипервизора Proxmox VE. Только чтение, ничего не меняет.
# Пишет JSONL: одна строка - одна находка. Запуск от root на узле кластера.
set -u
OUT="${1:-out/pve-audit.jsonl}"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

add() { # check value severity note
  printf '{"check":"%s","value":"%s","severity":"%s","note":"%s"}\n' "$1" "$2" "$3" "${4:-}" >> "$OUT"
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- версия и узел
if have pveversion; then add "pve.version" "$(pveversion | head -1 | tr -d '\n')" "info" ""; fi
HAVE_CLUSTER=0
if [ -f /etc/pve/corosync.conf ]; then HAVE_CLUSTER=1; fi

# --- кворум
if [ "$HAVE_CLUSTER" = "1" ] && have pvecm; then
  q=$(pvecm status 2>/dev/null | awk -F': *' '/Quorate/{print $2; exit}')
  case "$q" in
    Yes) add "cluster.quorum" "есть" "info" "" ;;
    "")  add "cluster.quorum" "не прочитано" "medium" "pvecm status требует прав" ;;
    *)   add "cluster.quorum" "нет кворума" "critical" "Запись конфигурации заблокирована" ;;
  esac
fi

# --- задачи резервного копирования
if have pvesh; then
  JOBS=$(pvesh get /cluster/backup --output-format json 2>/dev/null)
  if [ -z "$JOBS" ] || [ "$JOBS" = "[]" ]; then
    add "backup.jobs" "нет заданий" "critical" "Виртуальные машины не имеют регулярного бэкапа"
  else
    N=$(printf '%s' "$JOBS" | grep -o '"id"' | wc -l | tr -d ' ')
    DIS=$(printf '%s' "$JOBS" | grep -o '"enabled":[0-9]' | grep -c ':0' || true)
    add "backup.jobs" "$N" "info" "Заданий в планировщике"
    if [ "${DIS:-0}" -gt 0 ]; then add "backup.jobsDisabled" "$DIS" "high" "Отключённое задание выглядит как настроенное"; fi
    if printf '%s' "$JOBS" | grep -q '"mode":"suspend"'; then
      add "backup.mode" "suspend" "high" "Режим suspend останавливает ВМ: окно не согласовано с бизнесом"
    fi
  fi
fi

# --- последние прогоны vzdump
LAST_LOG=$(ls -1t /var/log/vzdump/*.log 2>/dev/null | head -1 || true)
if [ -n "$LAST_LOG" ]; then
  AGE_D=$(( ( $(date +%s) - $(stat -c %Y "$LAST_LOG") ) / 86400 ))
  if grep -q "Finished Backup" "$LAST_LOG"; then
    SEV="info"; [ "$AGE_D" -gt 3 ] && SEV="medium"
    add "backup.lastRunDays" "$AGE_D" "$SEV" "Файл: $(basename "$LAST_LOG")"
  else
    add "backup.lastRun" "без строки Finished Backup" "high" "Смотреть хвост лога: ошибка или обрыв"
  fi
else
  add "backup.lastRun" "логов vzdump нет" "high" "Не было прогонов или логи в другом месте"
fi

# --- хранилища
if have pvesm; then
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | awk '{print $1}')
    use=$(printf '%s' "$line" | awk '{print $6}' | tr -d '%')
    case "$use" in ''|*[!0-9]*) continue ;; esac
    SEV="info"
    [ "$use" -ge 70 ] && SEV="medium"
    [ "$use" -ge 85 ] && SEV="high"
    add "storage.$name" "${use}%" "$SEV" "Занято в хранилище"
  done < <(pvesm status 2>/dev/null | tail -n +2)
fi

# --- репликация
if have pvesh; then
  R=$(pvesh get /cluster/replication --output-format json 2>/dev/null)
  if [ -n "$R" ] && [ "$R" != "[]" ]; then
    add "replication.jobs" "настроена" "info" "Проверять последний статус по каждому заданию"
  fi
fi

# --- конфигурация кластера
if [ -f /var/lib/pve-cluster/config.db ]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y /var/lib/pve-cluster/config.db) ) / 3600 ))
  add "config.lastChangeHours" "$AGE_H" "info" "config.db: копия нужна после каждого изменения"
fi

echo "записано в $OUT"
