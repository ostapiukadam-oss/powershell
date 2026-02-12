#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$TargetDir = 'C:\HyperV_Diag',
    [int]$ClusterLogTimeSpanMinutes = 60
)

# Konfiguracja ścieżki
$exportPath = Join-Path $TargetDir "Logs_$(Get-Date -Format 'yyyyMMdd_HHmm')"

# Sprawdzanie i tworzenie folderu (jeśli nie istnieje)
if (-not (Test-Path -Path $exportPath)) {
    try {
        # -Force utworzy całą strukturę drzewa katalogów, jeśli to konieczne
        New-Item -Path $exportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Utworzono katalog: $exportPath" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Nie można utworzyć folderu! Komunikat: $_"
        exit 1
    }
}

Write-Host 'Rozpoczynam zbieranie danych diagnostycznych...' -ForegroundColor Cyan

# --- Sekcja eksportu ---

# 1. Hyper-V Worker
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-Worker-Admin' -ErrorAction SilentlyContinue |
    Out-File -FilePath (Join-Path $exportPath 'hv-worker.txt') -Encoding utf8

# 2. VMMS
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-VMMS-Admin' -ErrorAction SilentlyContinue |
    Out-File -FilePath (Join-Path $exportPath 'vmms.txt') -Encoding utf8

# 3. Cluster Log (generuje plik bezpośrednio w folderze)
if (Get-Command Get-ClusterLog -ErrorAction SilentlyContinue) {
    Get-ClusterLog -Destination $exportPath -TimeSpan $ClusterLogTimeSpanMinutes -ErrorAction SilentlyContinue
}

# 4. System Errors
Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -eq 'Error' } |
    Format-Table TimeCreated, Id, Message -AutoSize |
    Out-File -FilePath (Join-Path $exportPath 'system-errors.txt') -Encoding utf8

Write-Host "Eksport zakończony sukcesem w: $exportPath" -ForegroundColor Green
