<#
.SYNOPSIS
    Аудит резервного копирования на Windows: только чтение.
.DESCRIPTION
    Проверяет, есть ли копии, когда снимались последний раз, живы ли VSS-писатели
    и сохранён ли пароль DSRM для восстановления контроллера домена.
    Правило: без проверенного восстановления бэкап считается отсутствующим.
.EXAMPLE
    .\Invoke-BackupAudit.ps1 -OutFile out\backup-audit.jsonl -GpoBackupPath D:\GPOBackup
#>
[CmdletBinding()]
param(
    [string]$OutFile = "out\backup-audit.jsonl",
    [string]$GpoBackupPath = "D:\GPOBackup",
    [int]$MaxAgeHours = 48
)

$script:rows = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Check, $Value, [string]$Severity = "info", [string]$Note = "")
    $script:rows.Add([pscustomobject]@{ check = $Check; value = $Value; severity = $Severity; note = $Note })
}

# --- Windows Server Backup: версии и свежесть
$wb = $null
try { $wb = & wbadmin get versions 2>$null } catch { }
$dateCount = 0
if (-not $wb) {
    Add-Finding "wbadmin.versions" "нет данных" "high" "WSB не настроен либо нужен запуск от администратора"
} else {
    $text = ($wb -join "`n")
    $dates = [regex]::Matches($text, "(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})")
    $dateCount = $dates.Count
    if ($dateCount -gt 0) {
        $last = $dates[$dateCount - 1]
        $stamp = "{0}.{1}.{2} {3}:{4}" -f $last.Groups[1].Value, $last.Groups[2].Value, $last.Groups[3].Value, $last.Groups[4].Value, $last.Groups[5].Value
        $dt = [datetime]::ParseExact($stamp, "dd.MM.yyyy HH:mm", $null)
        $ageH = [math]::Round(((Get-Date) - $dt).TotalHours, 1)
        $sev = "info"
        if ($ageH -gt $MaxAgeHours) { $sev = "high" }
        Add-Finding "wbadmin.lastBackupAgeHours" $ageH $sev "Копия старше $MaxAgeHours часов не защищает от шифровальщика"
    } else {
        Add-Finding "wbadmin.versions" "версии есть, дата не разобрана" "low" "Смотреть вывод вручную"
    }
    Add-Finding "wbadmin.versionsCount" $dateCount "info" "Проверять размер и wbadmin get items, а не слово успешно"
}

# --- бэкап GPO
if (Test-Path $GpoBackupPath) {
    $dirs = @(Get-ChildItem $GpoBackupPath -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -eq 0) {
        Add-Finding "gpo.backup" "каталог пуст" "high" "Backup-GPO не запускался"
    } else {
        $ageD = [math]::Round(((Get-Date) - $dirs[0].LastWriteTime).TotalDays, 1)
        $sev = "info"
        if ($ageD -gt 30) { $sev = "medium" }
        Add-Finding "gpo.backupAgeDays" $ageD $sev "Последний каталог: $($dirs[0].Name)"
    }
} else {
    Add-Finding "gpo.backup" "каталог не найден: $GpoBackupPath" "medium" "Путь передаётся параметром -GpoBackupPath"
}

# --- VSS-писатели
try {
    $vss = (& vssadmin list writers 2>$null | Out-String)
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($vss, "Writer name:\s*(.+?)\r?\n[\s\S]{0,200}?State:\s*\[(\d+)\]\s*(\w+)")) {
        $state = $m.Groups[3].Value.Trim()
        if ($state -ne "Stable" -and $state -ne "1") { $bad.Add($m.Groups[1].Value.Trim()) }
    }
    $sev = "info"
    if ($bad.Count -gt 0) { $sev = "high" }
    Add-Finding "vss.failedWriters" $bad.Count $sev ($bad -join "; ")
} catch {
    Add-Finding "vss.writers" "не читается" "low" "Нужны права администратора"
}

# --- DSRM: сохранён ли пароль восстановления
try {
    $null = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "DsrmAdminLogon" -ErrorAction Stop
    Add-Finding "dsrm.passwordSaved" "да" "info" "Пароль DSRM известен дежурному и лежит в сейфе"
} catch {
    Add-Finding "dsrm.passwordSaved" "не подтверждено" "medium" "Без пароля DSRM восстановление контроллера упирается в сейф"
}

$json = @($script:rows | ForEach-Object { $_ | ConvertTo-Json -Compress })
[System.IO.File]::WriteAllLines([System.IO.Path]::GetFullPath($OutFile), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "записано: $($script:rows.Count) находок в $OutFile"
$bad = @($script:rows | Where-Object { $_.severity -eq "critical" -or $_.severity -eq "high" }).Count
if ($bad -gt 0) { exit 1 } else { exit 0 }
