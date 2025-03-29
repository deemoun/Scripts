# Path to Android Emulator
#$EmulatorPath = "C:\Users\Deemounus\AppData\Local\Android\Sdk\emulator\emulator.exe"
$EmulatorPath = Join-Path "$env:USERPROFILE\AppData\Local\Android\Sdk\emulator" "emulator.exe"

# Check if emulator exists
if (-not (Test-Path $EmulatorPath)) {
    Write-Error "Android Emulator not found at: $EmulatorPath"
    exit 1
}

# Get list of available AVDs
$avdList = & $EmulatorPath -list-avds | Where-Object { $_ -match '\S' }

# Check if any AVDs are available
if (-not $avdList) {
    Write-Error "No AVDs available."
    exit 1
}

# Display menu of available AVDs
Write-Host "`nAvailable Android Virtual Devices:`n"
for ($i = 0; $i -lt $avdList.Count; $i++) {
    Write-Host "$($i + 1)) $($avdList[$i])"
}

# Prompt for selection
Write-Host "`nSelect an emulator (1-$($avdList.Count)):"
$selection = Read-Host

# Validate input
if (-not ($selection -match '^\d+$')) {
    Write-Error "Invalid input. Please enter a number."
    exit 1
}

$selectedIndex = [int]$selection - 1
if ($selectedIndex -lt 0 -or $selectedIndex -ge $avdList.Count) {
    Write-Error "Selection out of range. Please select a number between 1 and $($avdList.Count)"
    exit 1
}

# Get selected AVD name
$selectedAVD = $avdList[$selectedIndex]

# Launch the selected emulator
Write-Host "`nLaunching emulator: $selectedAVD"
try {
    Start-Process -FilePath $EmulatorPath -ArgumentList "-avd", $selectedAVD
}
catch {
    Write-Error "Failed to launch emulator: $_"
    exit 1
}

