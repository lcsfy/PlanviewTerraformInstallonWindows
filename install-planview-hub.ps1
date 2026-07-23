# install-planview-hub.ps1
# Installs UiPath Test Manager Integrator Hub (Planview Hub) v25.3.2 on Windows Server 2022.
# Invoked via Azure CustomScriptExtension from Terraform.
# Push this file to: https://github.com/lcsfy/TerraformingWithRajesh

$ErrorActionPreference = "Stop"
$LogFile = "C:\install-planview-hub.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== Planview Hub install started ==="

# ---------------------------------------------------------------------------
# 1. Enforce TLS 1.2 for all web requests in this session
# ---------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Log "TLS 1.2 enforced"

# ---------------------------------------------------------------------------
# 2. Download the Hub MSI
# ---------------------------------------------------------------------------
$MsiUrl  = "https://download.uipath.com/TestManager/testmanagerconnect/uipath-test-manager-integrator-hub-25.3.2.20250817-b28-windows.msi"
$MsiPath = "C:\planview-hub.msi"

Log "Downloading Hub MSI from $MsiUrl"
Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
Log "Download complete: $MsiPath"

# ---------------------------------------------------------------------------
# 3. Install Hub silently
#    Hub bundles its own JRE, Keycloak, and embedded PostgreSQL — no separate
#    prerequisites needed. The installer writes to C:\Tasktop by default.
# ---------------------------------------------------------------------------
$InstallLog = "C:\planview-hub-install.log"
Log "Running MSI silent install (this takes a few minutes)..."
$proc = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList "/i `"$MsiPath`" /quiet /norestart /log `"$InstallLog`"" `
    -Wait -PassThru

if ($proc.ExitCode -ne 0) {
    Log "ERROR: msiexec exited with code $($proc.ExitCode). Check $InstallLog for details."
    exit $proc.ExitCode
}
Log "MSI install completed successfully"

# ---------------------------------------------------------------------------
# 4. Open Windows Firewall for Hub ports
#    Port 8080 = Hub HTTP   (default web UI)
#    Port 8443 = Hub HTTPS  (TLS web UI, self-signed cert bundled by default)
#    Azure NSG rules are handled in Terraform; these rules cover the OS firewall.
# ---------------------------------------------------------------------------
Log "Adding Windows Firewall rules for Hub ports 8080 and 8443"

New-NetFirewallRule -DisplayName "Planview Hub HTTP"  -Direction Inbound `
    -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any | Out-Null

New-NetFirewallRule -DisplayName "Planview Hub HTTPS" -Direction Inbound `
    -Protocol TCP -LocalPort 8443 -Action Allow -Profile Any | Out-Null

Log "Firewall rules created"

# ---------------------------------------------------------------------------
# 5. Start the Tasktop Hub service (installed by the MSI as "Tasktop Hub")
# ---------------------------------------------------------------------------
$ServiceName = "Tasktop Hub"
Log "Starting service: $ServiceName"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Log "WARNING: Service '$ServiceName' not found. Check MSI install log."
} else {
    Start-Service -Name $ServiceName
    Log "Service started"
}

# ---------------------------------------------------------------------------
# 6. Wait for Hub to become reachable on port 8080
# ---------------------------------------------------------------------------
Log "Waiting for Hub to respond on http://localhost:8080 ..."
$MaxWait  = 120   # seconds
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
        # not up yet, keep waiting
    }
    Log "  ...still waiting ($Elapsed s elapsed)"
}

if ($Ready) {
    Log "Hub is responding on port 8080 — installation complete."
} else {
    Log "WARNING: Hub did not respond within $MaxWait seconds. It may still be starting up."
    Log "Check service status and C:\Tasktop\logs for details."
}

# ---------------------------------------------------------------------------
# Notes for first login
# ---------------------------------------------------------------------------
# Default credentials:  root / Tasktop123
# Change the root password immediately after first login.
# HTTP UI:   http://<public-ip>:8080
# HTTPS UI:  https://<public-ip>:8443  (self-signed cert — expect browser warning)
#
# The embedded PostgreSQL database is used by default.
# For production use, point Hub at an external PostgreSQL instance via
# the Hub admin UI under Settings > Database.
#
# To replace the self-signed SSL certificate, drop your PEM files into
# C:\Tasktop\conf and update the keystore reference in server.xml,
# then restart the Tasktop Hub service.
# ---------------------------------------------------------------------------

Log "=== install-planview-hub.ps1 finished ==="
