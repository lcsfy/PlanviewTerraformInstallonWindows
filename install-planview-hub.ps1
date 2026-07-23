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

# 1. Enforce TLS 1.2 and bypass cert validation for internal calls throughout this script
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
Log "TLS configured"

# 2. Download Hub MSI
$MsiUrl  = "https://download.uipath.com/TestManager/testmanagerconnect/uipath-test-manager-integrator-hub-25.3.2.20250817-b28-windows.msi"
$MsiPath = "C:\planview-hub.msi"
Log "Downloading Hub MSI..."
Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
Log "Download complete"

# 3. Silent MSI install - Hub bundles JRE, Keycloak, and embedded Derby database
$InstallLog = "C:\planview-hub-install.log"
Log "Running MSI silent install (this takes several minutes)..."
$msiArgs = @("/i", $MsiPath, "/quiet", "/norestart", "/log", $InstallLog)
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Log "ERROR: msiexec exited with code $($proc.ExitCode) - see $InstallLog"
    exit $proc.ExitCode
}
Log "MSI install complete"

# 4. Generate a self-signed certificate with correct SAN.
#    The MSI ships an insecureKeystore with no Subject Alternative Names, which causes
#    hostname verification failures in kcadm, PowerShell REST calls, and browsers.
#    We replace it with a new cert that includes the VM public IP and localhost.
Log "Detecting public IP..."
$publicIP = (Invoke-WebRequest -Uri "http://checkip.amazonaws.com/" -UseBasicParsing).Content.Trim()
Log "Public IP: $publicIP"

$keystorePath = "C:\Program Files\Tasktop\insecureKeystore"
$keytool      = "C:\Program Files\Tasktop\jre\bin\keytool.exe"

Remove-Item -Path $keystorePath -Force -ErrorAction SilentlyContinue

$keytoolArgs = @(
    "-genkeypair",
    "-alias",    "tasktop",
    "-keyalg",   "RSA",
    "-keysize",  "2048",
    "-validity", "1825",
    "-keystore", $keystorePath,
    "-storetype","JKS",
    "-storepass","changeit",
    "-keypass",  "changeit",
    "-dname",    "CN=planview-hub,O=UiPath,C=US",
    "-ext",      "SAN=IP:127.0.0.1,IP:$publicIP,DNS:localhost"
)
& $keytool @keytoolArgs 2>&1 | Out-Null
Log "Certificate generated with SAN: localhost, 127.0.0.1, $publicIP"

# Export the cert in DER format so it can be downloaded and added to trusted certs on client machines
$certExportPath = "C:\planview-hub.cer"
& $keytool -exportcert -alias tasktop -keystore $keystorePath -storepass changeit -file $certExportPath 2>&1 | Out-Null
Log "Certificate exported to $certExportPath - download via RDP and add to trusted certs on your machine to use HTTPS without warnings"

# 5. Windows Firewall rules (Azure NSG rules for the same ports are in Terraform)
Log "Adding Windows Firewall rules..."
New-NetFirewallRule -DisplayName "Planview Hub HTTP"  -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Planview Hub HTTPS" -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -Profile Any | Out-Null
Log "Firewall rules created"

# 6. Start both services - MSI registers them but does NOT start them automatically
Log "Starting Tasktop service..."
Start-Service -Name "Tasktop"
Log "Starting Keycloak service..."
Start-Service -Name "Keycloak"

# 7. Wait for Keycloak to be ready on its HTTPS port (8444)
Log "Waiting for Keycloak on https://localhost:8444/auth ..."
$MaxWait = 180
$Elapsed = 0
$KcReady = $false

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Seconds 10
    $Elapsed += 10
    try {
        $r = Invoke-RestMethod -Uri "https://localhost:8444/auth/realms/master" -TimeoutSec 5
        if ($r.realm -eq "master") { $KcReady = $true; break }
    } catch {
        Log "  ...waiting for Keycloak - $($Elapsed)s elapsed"
    }
}

if (-not $KcReady) {
    Log "ERROR: Keycloak did not become ready within $MaxWait s."
    exit 1
}
Log "Keycloak is ready"

# 8. Disable SSL requirements on master and Tasktop realms.
#    Fresh install default credentials are root / Tasktop123.
#    This allows Hub login to work on both HTTP and HTTPS without the browser SSL loop.
Log "Configuring Keycloak SSL requirements..."
$tokenBody = "grant_type=password&client_id=admin-cli&username=root&password=Tasktop123"
$token = (Invoke-RestMethod `
    -Uri "https://localhost:8444/auth/realms/master/protocol/openid-connect/token" `
    -Method Post `
    -Body $tokenBody `
    -ContentType "application/x-www-form-urlencoded").access_token

$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
Invoke-RestMethod -Uri "https://localhost:8444/auth/admin/realms/master"  -Method Put -Headers $headers -Body '{"sslRequired":"NONE"}' | Out-Null
Invoke-RestMethod -Uri "https://localhost:8444/auth/admin/realms/Tasktop" -Method Put -Headers $headers -Body '{"sslRequired":"NONE"}' | Out-Null
Log "SSL requirements disabled on master and Tasktop realms"

# 9. Wait for Hub to respond on port 8080
Log "Waiting for Hub on http://localhost:8080 ..."
$Elapsed  = 0
$HubReady = $false

while ($Elapsed -lt 120) {
    Start-Sleep -Seconds 10
    $Elapsed += 10
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -lt 500) { $HubReady = $true; break }
    } catch {
        Log "  ...waiting for Hub - $($Elapsed)s elapsed"
    }
}

if ($HubReady) {
    Log "Hub is up and accessible."
    Log "HTTP:  http://$publicIP:8080"
    Log "HTTPS: https://$publicIP:8443  (trust C:\planview-hub.cer on your client to avoid browser warnings)"
    Log "Default credentials: root / Tasktop123 (change after first login)"
} else {
    Log "WARNING: Hub did not respond on port 8080 within 120s. Check C:\ProgramData\Tasktop\logs\"
}

Log "=== install-planview-hub.ps1 finished ==="
