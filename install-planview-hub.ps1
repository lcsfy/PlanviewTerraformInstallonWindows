# install-planview-hub.ps1
# Installs UiPath Test Manager Integrator Hub (Planview Hub) v25.3.2 on Windows Server 2022.
# Invoked via Azure CustomScriptExtension from Terraform.

$ErrorActionPreference = "Stop"
$LogFile = "C:\install-planview-hub.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== Planview Hub install started ==="

# 1. Enforce TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Log "TLS 1.2 enforced"

# 2. Download Hub MSI
$MsiUrl  = "https://download.uipath.com/TestManager/testmanagerconnect/uipath-test-manager-integrator-hub-25.3.2.20250817-b28-windows.msi"
$MsiPath = "C:\planview-hub.msi"
Log "Downloading Hub MSI..."
Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
Log "Download complete: $MsiPath"

# 3. Silent install — Hub bundles JRE, Keycloak, and embedded PostgreSQL
$InstallLog = "C:\planview-hub-install.log"
Log "Running MSI silent install (takes a few minutes)..."
$args = @("/i", $MsiPath, "/quiet", "/norestart", "/log", $InstallLog)
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Log "ERROR: msiexec exited with code $($proc.ExitCode). See $InstallLog"
    exit $proc.ExitCode
}
Log "MSI install complete"

# 4. Windows Firewall rules (Azure NSG is handled in Terraform)
Log "Adding firewall rules for ports 8080 and 8443"
New-NetFirewallRule -DisplayName "Planview Hub HTTP"  -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Planview Hub HTTPS" -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -Profile Any | Out-Null
Log "Firewall rules created"

# 5. Start Tasktop Hub service
$ServiceName = "Tasktop Hub"
Log "Starting service: $ServiceName"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Log "WARNING: Service '$ServiceName' not found — check MSI install log"
} else {
    Start-Service -Name $ServiceName
    Log "Service started"
}

# 6. Wait for Hub to respond on port 8080
Log "Waiting for Hub on http://localhost:8080 ..."
$MaxWait  = 120
$Interval = 10
$Elapsed  = 0
$Ready    = $false

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -lt 500) {
            $Ready = $true
            break
        }
    } catch {
        Log "  ...not up yet - $($Elapsed)s elapsed"
    }
}

if ($Ready) {
    Log "Hub is responding on port 8080 — install complete."
} else {
    Log "WARNING: Hub did not respond within $MaxWait s. Check C:\Tasktop\logs."
}

# Default credentials: root / Tasktop123
# HTTP:  http://<public-ip>:8080
# HTTPS: https://<public-ip>:8443  (self-signed cert — expect browser warning)

Log "=== install-planview-hub.ps1 finished ==="
