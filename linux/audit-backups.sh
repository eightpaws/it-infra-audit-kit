#!/usr/bin/env bash
# Аудит резервного копирования на Linux: свежесть копий, расписание, проверка восстановления.
set -u
OUT="${1:-out/backup-audit.jsonl}"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

add() { printf '{"check":"%s","value":"%s","severity":"%s","note":"%s"}\n' "$1" "$2" "$3" "${4:-}" >> "$OUT"; }

# --- расписание: systemd-таймеры с явным именем
if command -v systemctl >/dev/null 2>&1; then
  TIMERS=$(systemctl list-timers --all --no-legend 2>/dev/null | grep -Ei 'backup|borg|restic|dump' || true)
  if [ -n "$TIMERS" ]; then
    add "schedule.timers" "$(printf '%s' "$TIMERS" | wc -l | tr -d ' ')" "info" "Таймеры с backup/borg/restic в имени"
  else
    add "schedule.timers" "нет" "medium" "Расписание может жить в cron: проверить crontab -l и /etc/cron.d"
  fi
fi

# --- свежесть каталогов с копиями
check_dir() {
  local d="$1" name="$2"
  [ -d "$d" ] || return 0
  local newest
  newest=$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [ -z "$newest" ]; then add "path.$name" "каталог пуст" "high" "$d"; return 0; fi
  local age_d=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
  local sev="info"
  [ "$age_d" -gt 2 ] && sev="medium"
  [ "$age_d" -gt 7 ] && sev="high"
  add "path.$name" "${age_d} дн" "$sev" "$d"
}
check_dir /var/backups local
check_dir /srv/backup srv
check_dir /mnt/backup mnt

# --- дампы баз
if command -v pg_dump >/dev/null 2>&1; then
  if compgen -G "/var/backups/postgres*" >/dev/null 2>&1 || compgen -G "/srv/backup/pg*" >/dev/null 2>&1; then
    add "db.postgres" "дампы найдены" "info" ""
  else
    add "db.postgres" "дампов не найдено" "medium" "pg_dump установлен, файлов копий не видно"
  fi
fi

# --- проверка восстановления: единственный настоящий тест
if [ -f /var/log/restore-drill.log ]; then
  AGE=$(( ( $(date +%s) - $(stat -c %Y /var/log/restore-drill.log) ) / 86400 ))
  SEV="info"
  [ "$AGE" -gt 180 ] && SEV="high"
  add "restore.lastDrillDays" "$AGE" "$SEV" "Журнал прогонов восстановления"
else
  add "restore.lastDrillDays" "нет журнала" "high" "Копии есть, восстановление не проверялось: считать, что бэкапа нет"
fi

echo "записано в $OUT"
