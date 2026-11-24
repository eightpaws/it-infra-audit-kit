<#
.SYNOPSIS
    Аудит домена Active Directory: только чтение, ничего не меняет.
.DESCRIPTION
    Проверяет состояние каталога, репликацию, привилегированные группы, гигиену
    учётных записей и групповые политики. Пишет JSONL: одна строка - одна находка.
    Запуск с рабочей станции с RSAT, права администратора домена не обязательны,
    но без них часть проверок вернёт пустоту.
.EXAMPLE
    .\Invoke-AdAudit.ps1 -OutFile out\ad-audit.jsonl
#>
[CmdletBinding()]
param(
    [string]$OutFile = "out\ad-audit.jsonl",
    [int]$InactiveDays = 90,
    [string]$Server
)

$ErrorActionPreference = "Continue"
try { Import-Module ActiveDirectory -ErrorAction Stop } catch {
    Write-Error "Нет модуля ActiveDirectory: нужен RSAT-AD-PowerShell"
    exit 2
}

$script:rows = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Check, $Value, [string]$Severity = "info", [string]$Note = "")
    $script:rows.Add([pscustomobject]@{ check = $Check; value = $Value; severity = $Severity; note = $Note })
}
$splat = @{}
if ($Server) { $splat["Server"] = $Server; $splat["Credential"] = $null; $splat.Remove("Credential") }

# --- контекст каталога
try {
    $dom = Get-ADDomain @splat
    Add-Finding "domain.name" $dom.DNSRoot "info" ""
    Add-Finding "domain.forestMode" ([string](Get-ADForest @splat).ForestMode) "info" "Смена режима - операция с бэкапом и окном"
    Add-Finding "domain.pdcEmulator" $dom.PDCEmulator "info" "Проверять netdom query fsmo, а не по памяти"
} catch { Add-Finding "domain.context" "ошибка: $($_.Exception.Message)" "high" "Без доступа к домену остальные проверки бессмысленны" }

try {
    $dcs = Get-ADDomainController -Filter * @splat
    Add-Finding "dc.count" $dcs.Count "info" ($dcs.HostName -join ", ")
    Add-Finding "dc.globalCatalog" (@($dcs | Where-Object IsGlobalCatalog).Count) "info" ""
} catch { Add-Finding "dc.list" "ошибка: $($_.Exception.Message)" "medium" "" }

# --- FSMO
$fsmo = (netdom query fsmo 2>$null) -join " "
if ($fsmo) { Add-Finding "fsmo.owners" $fsmo.Trim() "info" "Источник: netdom query fsmo" }
else { Add-Finding "fsmo.owners" "не получено" "medium" "netdom нет или нет прав: роли проверить вручную" }

# --- репликация
$repl = (repadmin /replsummary 2>$null) -join "`n"
if ($repl -match "(\d+)\s*/\s*(\d+)\s*$" ) { Add-Finding "replication.summary" $repl.Trim() "info" "Читать строку с ошибками" }
if ($repl -match "([1-9]\d*)\s+error") { Add-Finding "replication.errors" "есть ошибки" "critical" "Разбирать repadmin /showrepl по каждому контроллеру" }
elseif ($repl) { Add-Finding "replication.errors" "нет" "info" "" }

# --- привилегированные группы
foreach ($g in @("Domain Admins", "Enterprise Admins", "Schema Admins")) {
    try {
        $m = @(Get-ADGroupMember $g -Recursive @splat)
        $sev = if ($g -eq "Domain Admins" -and $m.Count -gt 7) { "medium" } else { "info" }
        Add-Finding "groups.$g" $m.Count $sev (($m | Select-Object -First 12 | ForEach-Object { $_.SamAccountName }) -join ", ")
    } catch { Add-Finding "groups.$g" "ошибка чтения" "medium" "" }
}

try {
    $pu = @(Get-ADGroupMember "Protected Users" -Recursive @splat)
    $sev = if ($pu.Count -eq 0) { "high" } else { "info" }
    Add-Finding "groups.ProtectedUsers" $pu.Count $sev "0 участников значит: ключевые админы не защищены от кражи Kerberos-тикетов"
} catch { Add-Finding "groups.ProtectedUsers" "группа не читается" "medium" "" }

# --- гигиена учётных записей
try {
    $adminCount = @(Get-ADUser -LDAPFilter '(adminCount=1)' -Properties adminCount @splat)
    Add-Finding "accounts.adminCount" $adminCount.Count "medium" "Остаточные права после вывода из групп: проверить ACL"
} catch { }

try {
    $noExp = @(Get-ADUser -Filter 'PasswordNeverExpires -eq $true' -Properties PasswordNeverExpires, PasswordLastSet @splat)
    Add-Finding "accounts.passwordNeverExpires" $noExp.Count "medium" "Делить на сервисные (gMSA, длинный случайный пароль) и забытые"
} catch { }

$cut = (Get-Date).AddDays(-$InactiveDays)
try {
    $inactU = @(Get-ADUser -Filter { LastLogonDate -lt $cut -and Enabled -eq $true } -Properties LastLogonDate @splat)
    Add-Finding "accounts.inactiveUsers" $inactU.Count "medium" "Решение об отключении за владельцем, не массовое удаление"
} catch { Add-Finding "accounts.inactiveUsers" "фильтр не отработал" "low" "LastLogonDate может быть пустым: нужна репликация атрибута" }

try {
    $inactC = @(Get-ADComputer -Filter { LastLogonDate -lt $cut -and Enabled -eq $true } -Properties LastLogonDate @splat)
    Add-Finding "computers.inactive" $inactC.Count "low" "Сверять с парком, а не удалять по счётчику"
} catch { }

try {
    $laps = @(Get-ADComputer -Filter * -Properties ms-Mcs-AdmPwdExpirationTime @splat)
    $withLaps = @($laps | Where-Object { $_.'ms-Mcs-AdmPwdExpirationTime' }).Count
    $pct = if ($laps.Count -gt 0) { [math]::Round(100 * $withLaps / $laps.Count, 1) } else { 0 }
    $sev = if ($pct -lt 90) { "medium" } else { "info" }
    Add-Finding "computers.lapsCoverage" "$withLaps из $($laps.Count) ($pct%)" $sev "Остаток добрать: локальный админ без LAPS - общий пароль на парк"
} catch { Add-Finding "computers.lapsCoverage" "не читается" "low" "Нет схемы LAPS в домене или нет прав" }

# --- krbtgt
try {
    $krb = Get-ADUser krbtgt -Properties PasswordLastSet @splat
    $age = [int]((Get-Date) - $krb.PasswordLastSet).TotalDays
    $sev = if ($age -gt 365) { "high" } else { "info" }
    Add-Finding "krbtgt.passwordAgeDays" $age $sev "Пароль krbtgt меняется по регламенту, дважды с паузой для репликации"
} catch { }

# --- GPO
try {
    $gpos = @(Get-GPO -All @splat)
    Add-Finding "gpo.total" $gpos.Count "info" ""
    $recent = @($gpos | Sort-Object ModificationTime -Descending | Select-Object -First 5)
    Add-Finding "gpo.recentChanges" (($recent | ForEach-Object { "$($_.DisplayName) $($_.ModificationTime.ToString('yyyy-MM-dd'))" }) -join "; ") "info" ""
    $disabled = @($gpos | Where-Object { $_.GpoStatus -ne "AllEnabled" })
    $sev = if ($disabled.Count -gt 0) { "medium" } else { "info" }
    Add-Finding "gpo.partiallyDisabled" $disabled.Count $sev "Отключённые половины политики дают эффект, которого никто не ждёт"
} catch { }

# --- прочее
try {
    $q = (Get-ADDomain @splat).MachineAccountQuota
    Add-Finding "domain.machineAccountQuota" "$($q)" "medium" "Больше 0: любая учётка может завести компьютерный объект"
} catch { }

try {
    $zones = @(Get-DnsServerZone @splat -ErrorAction Stop)
    Add-Finding "dns.zones" $zones.Count "info" "Без -ComputerName запрос уходит на рабочую станцию и молча возвращает пустоту"
} catch { Add-Finding "dns.zones" "не читается" "low" "Нужен модуль DnsServer и доступ к контроллеру" }

$json = @($script:rows | ForEach-Object { $_ | ConvertTo-Json -Compress })
[System.IO.File]::WriteAllLines([System.IO.Path]::GetFullPath($OutFile), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "записано: $($script:rows.Count) находок в $OutFile"
$crit = @($script:rows | Where-Object severity -eq "critical").Count
if ($crit -gt 0) { exit 1 } else { exit 0 }
