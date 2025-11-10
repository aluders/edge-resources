# Show recent RDP connection attempts (success + failure) with client IPs and timestamps
# Uses Security Log only (4624 + 4625 with LogonType 10)
# Run as Administrator
# powershell -ExecutionPolicy Bypass -File "c:\rdp-connections.ps1"

$DaysBack = 30
$MaxEvents = 2000
$startTime = (Get-Date).AddDays(-$DaysBack)

function Parse-EventXml {
    param($evt, $fields)
    $xml = [xml]$evt.ToXml()
    foreach ($f in $fields) {
        $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $f }
        if ($node) { return $node.'#text' }
    }
    return $null
}

# Query SECURITY log only (no TerminalServices, no warnings)
$events = Get-WinEvent -FilterHashtable @{
    LogName='Security'
    Id=@(4624,4625)
    StartTime=$startTime
} -MaxEvents $MaxEvents -ErrorAction SilentlyContinue

$parsed = $events | ForEach-Object {
    $xml = [xml]$_.ToXml()
    $logonType = Parse-EventXml $_ @('LogonType')

    # Only RDP/RemoteInteractive
    if ($logonType -ne '10') { return }

    $ip   = Parse-EventXml $_ @('IpAddress','Ip','Address')
    $user = Parse-EventXml $_ @('TargetUserName','SubjectUserName')

    $status = if ($_.Id -eq 4624) { 'Success' } else { 'Failed' }

    [PSCustomObject]@{
        Time   = $_.TimeCreated
        User   = if ($user) { $user } else { '(unknown)' }
        IP     = if ($ip) { $ip } else { '<no-ip-recorded>' }
        Status = $status
        EventID= $_.Id
    }
}

$parsed |
    Sort-Object Time -Descending |
    Format-Table -AutoSize

''
Write-Output "Unique IPs (excluding '<no-ip-recorded>'):"
$parsed |
    Where-Object { $_.IP -ne '<no-ip-recorded>' } |
    Select-Object -ExpandProperty IP -Unique |
    ForEach-Object { " - $_" }
