Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- USTAWIENIA ---
$Interval = 5
$LogFolder = 'C:\Monitoring\Logs'
$LogFile = Join-Path $LogFolder "FileServer_$(Get-Date -Format 'yyyy-MM-dd').log"

if (-not (Test-Path -Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

function Write-Both {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('White', 'Gray', 'Cyan', 'Yellow', 'Green', 'Red')]
        [string]$Color = 'White',
        [AllowNull()]
        [string]$FullContent = $null
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host $Message -ForegroundColor $Color

    $toLog = if ($null -ne $FullContent -and $FullContent.Length -gt 0) { $FullContent } else { $Message }
    "[$stamp] $toLog" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Get-CounterValue {
    param(
        [Parameter(Mandatory)]
        [string[]]$CounterPaths
    )

    try {
        $counterData = Get-Counter -Counter $CounterPaths -ErrorAction Stop
        return $counterData.CounterSamples
    }
    catch {
        Write-Both "[WARN] Nie udało się pobrać liczników: $($CounterPaths -join ', ')" 'Gray'
        return $null
    }
}

function Format-TimeSpan {
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Span
    )

    '{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds
}

function Get-FSMetrics {
    Clear-Host
    $now = Get-Date
    $currentTime = $now.ToString('yyyy-MM-dd HH:mm:ss')

    $header = "`n--- FILE SERVER MONITORING: $env:COMPUTERNAME ---`nData: $currentTime`n------------------------------------------------------------------"
    Write-Both -Message $header -Color 'Cyan'

    # 1. Monitoring dysków
    $diskSamples = Get-CounterValue -CounterPaths @(
        '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
        '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
        '\PhysicalDisk(_Total)\Disk Transfers/sec'
    )

    if ($diskSamples -and $diskSamples.Count -ge 3) {
        $iops = [math]::Round($diskSamples[2].CookedValue, 0)
        $readLatencyMs = [math]::Round($diskSamples[0].CookedValue * 1000, 2)
        $writeLatencyMs = [math]::Round($diskSamples[1].CookedValue * 1000, 2)
        Write-Both "[ZASOBY] IOPS: $iops | Latency R/W: $readLatencyMs / $writeLatencyMs ms" 'Yellow'
    }

    # 2. SMB utylizacja
    $smbSamples = Get-CounterValue -CounterPaths @(
        '\SMB Server Shares(_Total)\Data Requests/sec',
        '\SMB Server Shares(_Total)\Write Bytes/sec',
        '\SMB Server Shares(_Total)\Read Bytes/sec'
    )

    if ($smbSamples -and $smbSamples.Count -ge 3) {
        $req = [math]::Round($smbSamples[0].CookedValue, 0)
        $write = [math]::Round($smbSamples[1].CookedValue / 1KB, 2)
        $read = [math]::Round($smbSamples[2].CookedValue / 1KB, 2)
        Write-Both "[SMB] Ruch: $req req/s | Zapis: $write KB/s | Odczyt: $read KB/s"
    }

    Write-Both "`n[SMB / UŻYTKOWNICY DOMENOWI]" 'Yellow'

    $hasSmbCmdlets = (Get-Command -Name Get-SmbSession -ErrorAction SilentlyContinue) -and
        (Get-Command -Name Get-SmbOpenFile -ErrorAction SilentlyContinue)

    if (-not $hasSmbCmdlets) {
        Write-Both 'Cmdlety SMB (Get-SmbSession/Get-SmbOpenFile) są niedostępne w tym środowisku.' 'Red'
        return
    }

    try {
        $sessions = @(Get-SmbSession -ErrorAction Stop)
        $openFiles = @(Get-SmbOpenFile -ErrorAction Stop)

        Write-Both "Aktywne sesje: $($sessions.Count) | Otwarte pliki: $($openFiles.Count)"

        if ($sessions.Count -gt 0) {
            $sessionList = $sessions |
                Select-Object UserName, ClientComputerName,
                @{
                    N = 'CzasSesji'
                    E = {
                        if ($_.Created) {
                            Format-TimeSpan -Span (New-TimeSpan -Start $_.Created -End $now)
                        }
                        else {
                            'n/d'
                        }
                    }
                },
                @{
                    N = 'Idle'
                    E = { Format-TimeSpan -Span (New-TimeSpan -Seconds $_.SecondsIdle) }
                } |
                Sort-Object UserName

            Write-Both ($sessionList | Format-Table -AutoSize | Out-String)
        }

        if ($openFiles.Count -gt 0) {
            Write-Both 'TOP użytkownicy (wg liczby otwartych plików):' 'Gray'
            $topUsers = $openFiles |
                Group-Object { if ($_.ClientUserName) { $_.ClientUserName } else { '<nieznany>' } } |
                Select-Object @{ N = 'Uzytkownik'; E = { $_.Name } }, @{ N = 'Pliki'; E = { $_.Count } } |
                Sort-Object Pliki -Descending |
                Select-Object -First 5
            Write-Both ($topUsers | Format-Table -AutoSize | Out-String)

            # Do logu: pełna lista ścieżek
            $fullFilesTable = $openFiles |
                Select-Object @{ N = 'Uzytkownik'; E = { if ($_.ClientUserName) { $_.ClientUserName } else { '<nieznany>' } } }, ClientComputerName, ShareRelativePath |
                Format-Table -AutoSize |
                Out-String -Width 4096

            # Na ekran: TOP 15 z zawijaniem
            $screenFilesTable = $openFiles |
                Select-Object @{ N = 'Uzytkownik'; E = { if ($_.ClientUserName) { $_.ClientUserName } else { '<nieznany>' } } }, ShareRelativePath -First 15 |
                Format-Table -AutoSize -Wrap |
                Out-String

            Write-Both 'Szczegóły ścieżek (Ekran: TOP 15 / Log: wszystkie):' 'Gray' $fullFilesTable
            Write-Host $screenFilesTable
        }
    }
    catch {
        Write-Both "Błąd modułu SMB: $($_.Exception.Message)" 'Red'
    }
}

try {
    Write-Both "Start monitoringu. Interwał: $Interval s | Log: $LogFile" 'Green'
    while ($true) {
        Get-FSMetrics
        Start-Sleep -Seconds $Interval
    }
}
catch {
    Write-Both "`nMonitorowanie zakończone: $($_.Exception.Message)" 'Yellow'
}
