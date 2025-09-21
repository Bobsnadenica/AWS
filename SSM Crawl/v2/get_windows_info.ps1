# This script gathers Windows info and outputs it as a single JSON object.

# Uptime calculation
$uptime_span = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$uptime_string = "{0:dd} days, {0:hh} hrs, {0:mm} mins" -f $uptime_span

# Falcon Service Status
$falcon_svc = Get-Service -Name 'CSFalconService' -ErrorAction SilentlyContinue
if ($null -eq $falcon_svc) {
    $falcon_status = 'Not Installed'
} elseif ($falcon_svc.Status -eq 'Running') {
    $falcon_status = 'Running'
} else {
    $falcon_status = 'Not Running'
}

# Pending Windows Updates
$updates_list = @()
$update_status = "OK"
try {
    $session = New-Object -ComObject "Microsoft.Update.Session"
    $searcher = $session.CreateUpdateSearcher()
    $results = $searcher.Search("IsInstalled=0 and Type='Software'").Updates
    if ($results.Count -gt 0) {
        # Limit to the top 3 for brevity in the report
        $limit = [System.Math]::Min($results.Count, 3)
        for ($i = 0; $i -lt $limit; $i++) {
            $updates_list += $results.Item($i).Title
        }
    } else {
        $updates_list += "None"
    }
} catch {
    $update_status = "Update service unavailable"
    $updates_list += "Error checking for updates"
}


# Create a single object with all the data and convert it to JSON
[PSCustomObject]@{
    Uptime         = $uptime_string
    FalconService  = $falcon_status
    UpdateCheck    = $update_status
    PendingUpdates = $updates_list
} | ConvertTo-Json -Compress