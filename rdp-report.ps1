# elevated powershell
# irm rdpreport.vcc.net | iex

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required to read Security Logs." -ForegroundColor Red
    Write-Host "Please close, right-click, and 'Run as Administrator'." -ForegroundColor Yellow
    return
}

# Configuration
$DaysBack = 30
$MaxEvents = 2000
$startTime = (Get-Date).AddDays(-$DaysBack)

# Helper function to extract data from Event XML
function Get-EventData {
    param($xml, $fieldNames)
    foreach ($f in $fieldNames) {
        $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $f }
        if ($node) { return $node.'#text' }
    }
    return $null
}

Write-Host "----------------------"
Write-Host "Scanning Security Log for RDP connections (Last $DaysBack days)..." -ForegroundColor Cyan
Write-Host "----------------------"

# Query SECURITY log
$events = Get-WinEvent -FilterHashtable @{
    LogName='Security'
    Id=@(4624,4625)
    StartTime=$startTime
} -MaxEvents $MaxEvents -ErrorAction SilentlyContinue

$results = $events | ForEach-Object {
    # Convert to XML once per event for speed
    $xml = [xml]$_.ToXml()
    
    # Check LogonType (10 = RemoteInteractive/RDP)
    $logonType = Get-EventData $xml @('LogonType')
    if ($logonType -ne '10') { return }

    $ip   = Get-EventData $xml @('IpAddress','Ip','Address')
    $user = Get-EventData $xml @('TargetUserName','SubjectUserName')
    
    # Determine Status
    if ($_.Id -eq 4624) { 
        $status = "Success"
        $color = "Green"
    } else { 
        $status = "Failed" 
        $color = "Red"
    }

    [PSCustomObject]@{
        Time    = $_.TimeCreated.ToString("g")
        User    = if ($user) { $user } else { '(unknown)' }
        IP      = if ($ip) { $ip } else { '-' }
        Status  = $status
        _Color  = $color # Internal use for coloring
    }
}

# Output Table
if ($results) {
    $results | Sort-Object Time -Descending | Format-Table Time, User, IP, Status -AutoSize
} else {
    Write-Host "No RDP connections found in the last $DaysBack days." -ForegroundColor Yellow
}

# Unique IPs Summary
if ($results) {
    Write-Host "----------------------"
    Write-Host "Unique Client IPs:" -ForegroundColor Cyan
    $results | Where-Object { $_.IP -ne '-' } | Select-Object -ExpandProperty IP -Unique | ForEach-Object { 
        Write-Host " - $_" 
    }
    Write-Host "----------------------"
}
