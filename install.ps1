#requires -Version 5.1
<#
.SYNOPSIS
    Installer for monetarium-node + monetarium-wallet + monetarium-ctl (Windows).

.DESCRIPTION
    1. Detects CPU architecture and downloads the matching Windows binaries.
    2. Prompts for the wallet's private passphrase (hidden input).
    3. Writes that passphrase into the wallet's config file so it can
       auto-unlock on start (needed for unattended ticket buying / voting).
    4. Registers Scheduled Tasks (Windows' equivalent of systemd/launchd
       here, since these binaries don't speak the Windows Service Control
       Manager protocol) that start node + wallet at boot.
    5. Prints a large, hard-to-miss warning about what this implies.

    Functions are split out and the "Main" entry point only runs when this
    file is executed directly -- dot-sourcing it (as the Pester tests do)
    loads the functions without running the installer.

.NOTES
    Must be run from an elevated ("Run as Administrator") PowerShell.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
[CmdletBinding()]
param(
    # Used by tests to be extra explicit that Main should not auto-run.
    [switch]$NoExec
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
$Script:GitHubOrg  = 'monetarium'
$Script:InstallDir = Join-Path $env:ProgramFiles 'Monetarium'

# ProgramData is a hidden system folder. Fall back to LOCALAPPDATA if absent.
$baseData = if (Test-Path $env:ProgramData) { $env:ProgramData } else { $env:LOCALAPPDATA }
$Script:DataDir    = Join-Path $baseData 'Monetarium'
$Script:WalletConf = Join-Path $Script:DataDir 'monetarium-wallet.conf'
$Script:NodeConf   = Join-Path $Script:DataDir 'monetarium.conf'

# ctl config - written to ctl's own appdata dir so "monetarium-ctl" works
# without --configfile on every invocation.
$Script:CtlDir   = Join-Path $env:LOCALAPPDATA 'Monetarium-ctl'
$Script:CtlConf  = Join-Path $Script:CtlDir 'monetarium-ctl.conf'

# Install manifest - lists every file this script creates.
$Script:Manifest = Join-Path $Script:DataDir 'install.manifest'

# Startup folder for auto-start scripts (overridable in tests).
$Script:StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

# Mining & ticket buyer settings (set by prompts)
$Script:MiningEnabled  = $false
$Script:MiningCores    = $null
$Script:TicketsEnabled = $false
$Script:TicketLimit    = $null
$Script:TicketBalance  = $null
$Script:VotingEnabled  = $false

# Wallet addresses (populated after RPC)
$Script:MiningAddr        = $null
$Script:ConsolidationAddr = $null

# RPC credentials (generated in Main, used by Write-Config and Write-CtlConfig)
$Script:RpcUser   = $null
$Script:RpcSecret = $null

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Host "[install] $Message" -ForegroundColor Cyan
}

function Write-ErrAndThrow {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    throw $Message
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --------------------------------------------------------------------------
# 1. Detect platform
# --------------------------------------------------------------------------
function Get-Platform {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64'  { 'arm64' }
        'AMD64'  { 'amd64' }
        default  { 'amd64' }
    }
    return "windows-$arch"
}

# --------------------------------------------------------------------------
# 2. Download binaries
# --------------------------------------------------------------------------
function Get-LatestReleaseAssetUrl {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Platform
    )

    $api = "https://api.github.com/repos/$($Script:GitHubOrg)/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'monetarium-installer' }

    $asset = $release.assets | Where-Object { $_.name -like "*$Platform*" } | Select-Object -First 1
    if (-not $asset) {
        Write-ErrAndThrow "Could not find a release asset for '$Repo' matching platform '$Platform'. Check https://github.com/$($Script:GitHubOrg)/$Repo/releases manually."
    }
    return $asset.browser_download_url
}

function Install-Binary {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$BinaryName,
        [Parameter(Mandatory)][string]$Platform
    )

    if (-not (Test-Path $Script:InstallDir)) {
        New-Item -ItemType Directory -Path $Script:InstallDir -Force | Out-Null
    }

    $destination = Join-Path $Script:InstallDir "$BinaryName.exe"
    if (Test-Path $destination) {
        Write-Info "Skipping $BinaryName - already installed at $destination"
        return
    }

    Write-Info "Fetching latest release info for $Repo..."
    $url = Get-LatestReleaseAssetUrl -Repo $Repo -Platform $Platform

    $tmpDir = Join-Path $env:TEMP ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $archivePath = Join-Path $tmpDir (Split-Path $url -Leaf)

    Write-Info "Downloading $BinaryName from: $url"
    Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing

    if ($archivePath -like '*.zip') {
        Expand-Archive -Path $archivePath -DestinationPath $tmpDir -Force
    } else {
        # Raw binary (not archived) - rename to the expected name
        $destName = Join-Path $tmpDir "$BinaryName.exe"
        Move-Item -Path $archivePath -Destination $destName -Force
    }

    $found = Get-ChildItem -Path $tmpDir -Recurse -Filter "$BinaryName.exe" | Select-Object -First 1
    if (-not $found) {
        $found = Get-ChildItem -Path $tmpDir -Recurse -Filter "$BinaryName-*.exe" | Select-Object -First 1
    }
    if (-not $found) {
        Write-ErrAndThrow "Could not locate '$BinaryName.exe' inside the downloaded archive."
    }

    Copy-Item -Path $found.FullName -Destination $destination -Force
    Remove-Item -Path $tmpDir -Recurse -Force

    Write-Info "Installed $BinaryName -> $destination"
}

function Add-InstallDirToPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$($Script:InstallDir)*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$($Script:InstallDir)", 'Machine')
        Write-Info "Added $($Script:InstallDir) to the system PATH (open a new shell to pick it up)."
    }
    if ($env:Path -notlike "*$($Script:InstallDir)*") {
        $env:Path = "$env:Path;$($Script:InstallDir)"
    }
}

# --------------------------------------------------------------------------
# 3. Prompt for passphrase (hidden)
# --------------------------------------------------------------------------
function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-WalletPassphrase {
    while ($true) {
        $secure1 = Read-Host -Prompt 'Enter wallet private passphrase' -AsSecureString
        $secure2 = Read-Host -Prompt 'Confirm passphrase' -AsSecureString

        $plain1 = ConvertFrom-SecureStringToPlainText -SecureString $secure1
        $plain2 = ConvertFrom-SecureStringToPlainText -SecureString $secure2

        if ([string]::IsNullOrEmpty($plain1)) {
            Write-Host 'Passphrase cannot be empty. Try again.' -ForegroundColor Red
            continue
        }
        if ($plain1 -ne $plain2) {
            Write-Host 'Passphrases did not match. Try again.' -ForegroundColor Red
            continue
        }
        return $plain1
    }
}

function Get-RandomToken {
    param([int]$Length = 32)
    # Over-allocate raw bytes since stripping non-alphanumeric base64
    # characters (+, /, =) shortens the string unpredictably.
    $bytes = New-Object byte[] ($Length * 3)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $alnum = [Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', ''
    if ($alnum.Length -lt $Length) {
        Write-ErrAndThrow 'Failed to generate a sufficiently long random token.'
    }
    return $alnum.Substring(0, $Length)
}

# --------------------------------------------------------------------------
# 4. Write config files
# --------------------------------------------------------------------------
function Protect-ConfigFile {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop inherited rules

    foreach ($identity in @($env:USERNAME, 'SYSTEM', 'Administrators')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'Allow'
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Write-Config {
    param(
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][string]$RpcUser,
        [Parameter(Mandatory)][string]$RpcSecret
    )

    New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')

    @"
; monetarium.conf - generated by install.ps1 on $timestamp
rpcuser=$RpcUser
rpcpass=$RpcSecret
"@ | Set-Content -Path $Script:NodeConf -Encoding ASCII

    $tbEnabled = 0;   if ($Script:TicketsEnabled) { $tbEnabled = 1 }
    $voteEnabled = 0; if ($Script:VotingEnabled)  { $voteEnabled = 1 }
    $tktLimit   = if ($Script:TicketLimit -ne $null)   { $Script:TicketLimit }   else { 1 }
    $tktBalance = if ($Script:TicketBalance -ne $null) { $Script:TicketBalance } else { 1 }

    @"
; monetarium-wallet.conf - generated by install.ps1 on $timestamp
; WARNING: 'pass' below stores the wallet unlock passphrase in plaintext
; so the scheduled task can auto-unlock the wallet at startup for
; unattended ticket buying / voting. See the warning printed by install.ps1.
username=$RpcUser
password=$RpcSecret
pass=$Passphrase
enablevoting=$voteEnabled
enableticketbuyer=$tbEnabled
ticketbuyer.limit=$tktLimit
ticketbuyer.balancetomaintainabsolute=$tktBalance
; Gap limit for address discovery
gaplimit=20
accountgaplimit=10
"@ | Set-Content -Path $Script:WalletConf -Encoding ASCII

    Protect-ConfigFile -Path $Script:NodeConf
    Protect-ConfigFile -Path $Script:WalletConf

    Write-Info "Config files written to $($Script:DataDir)."
    Write-Info "  (ProgramData is a hidden system folder - type the path directly into File Explorer or enable 'Show hidden files'.)"
    Write-Info "Access restricted to the current user, SYSTEM, and Administrators."
}

function Write-CtlConfig {
    New-Item -ItemType Directory -Path $Script:CtlDir -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')

    @"
; monetarium-ctl.conf - generated by install.ps1 on $timestamp
; RPC credentials matching the node config.
rpcuser=$($Script:RpcUser)
rpcpass=$($Script:RpcSecret)
"@ | Set-Content -Path $Script:CtlConf -Encoding ASCII

    Protect-ConfigFile -Path $Script:CtlConf
    Write-Info "ctl config written to $($Script:CtlConf)"
}

# --------------------------------------------------------------------------
# 5. Create wallet
# --------------------------------------------------------------------------
function Get-WalletDataDir {
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:APPDATA }
    return Join-Path $localAppData 'Monetarium-wallet'
}

function Create-Wallet {
    $walletDb = Join-Path (Get-WalletDataDir) 'mainnet\wallet.db'

    if (Test-Path $walletDb) {
        Write-Info "Wallet database already exists at $walletDb - skipping creation."
        return
    }

    $walletExe = Join-Path $Script:InstallDir 'monetarium-wallet.exe'

    Write-Info "Creating wallet. Follow the interactive prompts."
    Write-Info "When asked, type 'yes' to use the passphrase you just entered."

    & $walletExe --create --configfile "$Script:WalletConf" 2>&1

    if (-not (Test-Path $walletDb)) {
        Write-ErrAndThrow "Wallet creation failed - database not found at $walletDb"
    }

    Write-Info 'Wallet created successfully.'
}

# --------------------------------------------------------------------------
# 6. Startup scripts (Windows Startup folder — no Task Scheduler needed)
# --------------------------------------------------------------------------
function Install-StartupScripts {
    $nodeExe   = Join-Path $Script:InstallDir 'monetarium-node.exe'
    $walletExe = Join-Path $Script:InstallDir 'monetarium-wallet.exe'

    if (-not (Test-Path $Script:StartupDir)) {
        New-Item -ItemType Directory -Path $Script:StartupDir -Force | Out-Null
    }

    # VBS launcher — runs the binary with ZERO window visibility.
    @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "$($nodeExe) --configfile=`"$($Script:NodeConf)`"", 0, False
"@ | Set-Content -Path (Join-Path $Script:StartupDir 'MonetariumNode.vbs') -Encoding ASCII

    @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c timeout /t 15 /nobreak >nul && ""$walletExe"" --configfile=""$($Script:WalletConf)""", 0, False
"@ | Set-Content -Path (Join-Path $Script:StartupDir 'MonetariumWallet.vbs') -Encoding ASCII

    Write-Info "Startup scripts written to $Script:StartupDir"
    Write-Info "  MonetariumNode.vbs, MonetariumWallet.vbs"

    # Start both processes now.
    Start-Process -WindowStyle Hidden -FilePath $nodeExe `
        -ArgumentList "--configfile=`"$($Script:NodeConf)`""
    Write-Info 'Started monetarium-node.'

    Start-Sleep -Seconds 2
    Start-Process -WindowStyle Hidden -FilePath $walletExe `
        -ArgumentList "--configfile=`"$($Script:WalletConf)`""
    Write-Info 'Started monetarium-wallet.'
}

# --------------------------------------------------------------------------
# 7. Prompt for CPU mining
# --------------------------------------------------------------------------
function Read-MiningPrompt {
    $answer = Read-Host -Prompt 'Enable CPU mining? (y/N)'
    switch -Regex ($answer) {
        '^[yY]([eE][sS])?$' { $Script:MiningEnabled = $true }
    }

    if (-not $Script:MiningEnabled) { return }

    $cpuCount = [Environment]::ProcessorCount
    $recommended = [Math]::Max(1, [Math]::Floor($cpuCount / 2))

    $answer = Read-Host -Prompt "You have ${cpuCount} CPU core(s). How many cores to use for mining? (recommended: ${recommended})"
    $Script:MiningCores = if ($answer -ne '') { $answer } else { $recommended }
    while ($true) {
        if ($Script:MiningCores -match '^\d+$') { break }
        $answer = Read-Host -Prompt 'Please enter a valid number'
        $Script:MiningCores = if ($answer -ne '') { $answer } else { $recommended }
    }
}

# --------------------------------------------------------------------------
# 8. Prompt for ticket buyer
# --------------------------------------------------------------------------
function Read-TicketBuyerPrompt {
    $answer = Read-Host -Prompt 'Enable automatic ticket purchase for staking? (y/N)'
    switch -Regex ($answer) {
        '^[yY]([eE][sS])?$' { $Script:TicketsEnabled = $true }
    }

    if ($Script:TicketsEnabled) {
        $answer = Read-Host -Prompt 'Maximum number of tickets per purchase (ticketbuyer.limit)'
        $Script:TicketLimit = if ($answer -ne '') { $answer } else { 5 }
        while ($true) {
            if ($Script:TicketLimit -match '^\d+$') { break }
            $answer = Read-Host -Prompt 'Please enter a valid number'
            $Script:TicketLimit = $answer
        }

        $answer = Read-Host -Prompt 'Minimum VAR balance to keep in wallet (ticketbuyer.balancetomaintainabsolute)'
        $Script:TicketBalance = if ($answer -ne '') { $answer } else { 0 }
        while ($true) {
            if ($Script:TicketBalance -match '^\d+(\.\d+)?$') { break }
            $answer = Read-Host -Prompt 'Please enter a valid number'
            $Script:TicketBalance = $answer
        }
    }

    $answer = Read-Host -Prompt 'Enable voting? (y/N)'
    switch -Regex ($answer) {
        '^[yY]([eE][sS])?$' { $Script:VotingEnabled = $true }
    }
}

# --------------------------------------------------------------------------
# 9. Post-install: configure mining & ticket buyer via RPC
# --------------------------------------------------------------------------
function Invoke-ConfigureMiningAndVoting {
    $genValue = if ($Script:MiningEnabled) { 'true' } else { 'false' }
    @"

; Mining configuration - added post-install by install.ps1
generate=${genValue}
"@ | Add-Content -Path $Script:NodeConf -Encoding ASCII

    if (-not $Script:MiningEnabled -and -not $Script:TicketsEnabled) { return }

    $ctlExe = Join-Path $Script:InstallDir 'monetarium-ctl.exe'
    $walletExe = Join-Path $Script:InstallDir 'monetarium-wallet.exe'
    $rpcCert = Join-Path (Get-WalletDataDir) 'rpc.cert'
    $configChanged = $false
    $proc = $null
    $rpcReady = $false

    # Check if wallet is already running (previous install re-run).
    try {
        $null = & $ctlExe --wallet getinfo 2>$null
        $rpcReady = $true
        Write-Info 'Wallet already running.'
    } catch {
        Write-Info 'Starting wallet for RPC configuration...'
        try {
            $proc = Start-Process -FilePath $walletExe `
                -ArgumentList "--configfile=`"$($Script:WalletConf)`"" `
                -PassThru -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Write-Info 'Failed to start wallet process. Configure addresses manually.'
            return
        }
        if (-not $proc) { return }
    }

    if (-not $rpcReady) {
        Write-Info 'Waiting for wallet RPC to become available...'
        for ($i = 0; $i -lt 60; $i++) {
            if ($proc.HasExited) { break }
            try {
                $null = & $ctlExe --wallet getinfo 2>$null
                $rpcReady = $true
                break
            } catch { }
            Start-Sleep -Seconds 2
        }
    }

    if (-not $rpcReady) {
        Write-Info 'Wallet RPC not ready after 60 seconds.'
        Write-Info 'Configure mining/ticket addresses manually after the node syncs:'
        if ($Script:MiningEnabled) {
            Write-Info "  Edit $($Script:NodeConf): add generate=true and miningaddr=<address>"
        }
        if ($Script:TicketsEnabled) {
            Write-Info "  After startup: $ctlExe --wallet setvotefeeconsolidationaddress default <address>"
        }
        if ($proc -and -not $proc.HasExited) { $proc.Kill() }
        return
    }

    Write-Host 'Wallet RPC ready.' -ForegroundColor Green

    if ($Script:MiningEnabled) {
        $miningAddr = & $ctlExe --wallet getnewaddress 2>$null
        if ($miningAddr) {
            $Script:MiningAddr = $miningAddr
            "miningaddr=${miningAddr}" | Add-Content -Path $Script:NodeConf -Encoding ASCII
            $configChanged = $true
        }
    } else {
        $Script:MiningAddr = & $ctlExe --wallet getnewaddress 2>$null
        if ($Script:MiningAddr) {
            "miningaddr=$($Script:MiningAddr)" | Add-Content -Path $Script:NodeConf -Encoding ASCII
        }
    }

    # Generate consolidation address always and set it on the wallet.
    $consolidationAddr = & $ctlExe --wallet getnewaddress 2>$null
    if ($consolidationAddr) {
        $Script:ConsolidationAddr = $consolidationAddr
        & $ctlExe --wallet setvotefeeconsolidationaddress "default" $consolidationAddr 2>$null | Out-Null
    }

    if ($proc) {
        Write-Info 'Stopping wallet...'
        & $ctlExe --wallet stop *>$null
        Start-Sleep -Seconds 3
        if (-not $proc.HasExited) { $proc.Kill() }
    }

    Show-ConfigurationSummary
}

# --------------------------------------------------------------------------
# 9b. Configuration Summary display
# --------------------------------------------------------------------------
function Show-ConfigurationSummary {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Green
    Write-Host '  Configuration Summary' -ForegroundColor Green
    Write-Host '=============================================' -ForegroundColor Green
    if ($Script:MiningAddr) {
        Write-Host "Mining address:              $($Script:MiningAddr)"
    }
    if ($Script:MiningCores) {
        Write-Host "CPU cores for mining:        $($Script:MiningCores)"
    }
    if ($Script:TicketsEnabled) {
        Write-Host "Ticket buyer limit:          $($Script:TicketLimit)"
        Write-Host "Balance to maintain:         $($Script:TicketBalance)"
    }
    if ($Script:ConsolidationAddr) {
        Write-Host "Fee consolidation address:   $($Script:ConsolidationAddr)"
    }
    if ($Script:VotingEnabled) {
        Write-Host "Auto voting:                 enabled"
    } else {
        Write-Host "Auto voting:                 disabled"
    }
    Write-Host ''
}

# --------------------------------------------------------------------------
# 10. Install manifest
# --------------------------------------------------------------------------
function Write-Manifest {
    $walletDb = Join-Path (Get-WalletDataDir) 'mainnet\wallet.db'
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')

    @"
# Install manifest - files created by install.ps1
# Run date: $timestamp
#
# To uninstall, stop the processes first:
#   taskkill /f /im monetarium-node.exe
#   taskkill /f /im monetarium-wallet.exe
# Then remove %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Monetarium*.cmd
#
# Then remove the files listed below.
# Backup and remove the wallet database FIRST if it holds funds!
# The wallet seed was shown during installation - without it the
# wallet.db is unrecoverable.

binaries:
  $(Join-Path $Script:InstallDir 'monetarium-node.exe')
  $(Join-Path $Script:InstallDir 'monetarium-wallet.exe')
  $(Join-Path $Script:InstallDir 'monetarium-ctl.exe')

configs:
  $($Script:NodeConf)
  $($Script:WalletConf)
  $($Script:CtlConf)

wallet database (back up seed before removing):
  ${walletDb}

data directories:
  $($Script:DataDir)
  $($Script:CtlDir)

"@ | Set-Content -Path $Script:Manifest -Encoding ASCII

    if ($Script:MiningEnabled -and $Script:MiningAddr) {
        @"

mining:
  enabled:   true
  cores:     $($Script:MiningCores)
  address:   $($Script:MiningAddr)

"@ | Add-Content -Path $Script:Manifest -Encoding ASCII
    }

    if ($Script:TicketsEnabled) {
        @"

ticket buyer:
  enabled:                  true
  limit:                    $($Script:TicketLimit)
  balance to maintain:      $($Script:TicketBalance)

"@ | Add-Content -Path $Script:Manifest -Encoding ASCII
        if ($Script:ConsolidationAddr) {
            "  fee consolidation addr:   $($Script:ConsolidationAddr)" | Add-Content -Path $Script:Manifest -Encoding ASCII
        }
        "" | Add-Content -Path $Script:Manifest -Encoding ASCII
    }

    @"

scheduled tasks:
  MonetariumNode
  MonetariumWallet

This manifest: $($Script:Manifest)
"@ | Add-Content -Path $Script:Manifest -Encoding ASCII

    Write-Info "Install manifest written to $($Script:Manifest)"
}

# --------------------------------------------------------------------------
# 11. Big warning
# --------------------------------------------------------------------------
function Show-BigWarning {
    $bar = '=' * 70
    Write-Host ''
    Write-Host $bar -ForegroundColor Red
    Write-Host '                       !!!  WARNING  !!!' -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
    Write-Host " This script has written your wallet's PRIVATE PASSPHRASE in" -ForegroundColor Red
    Write-Host ' PLAINTEXT to:' -ForegroundColor Red
    Write-Host "     $($Script:WalletConf)" -ForegroundColor Red
    Write-Host ''
    Write-Host ' This is required so the wallet can auto-unlock and buy' -ForegroundColor Red
    Write-Host ' tickets / vote WITHOUT any further action from you. It also' -ForegroundColor Red
    Write-Host ' means:' -ForegroundColor Red
    Write-Host '   - Anyone who can read that file (an admin account, a backup,' -ForegroundColor Red
    Write-Host '     a compromised process, malware running as your user) can' -ForegroundColor Red
    Write-Host '     unlock your wallet and move your funds.' -ForegroundColor Red
    Write-Host '   - This machine is now effectively a HOT WALLET that stays' -ForegroundColor Red
    Write-Host '     unlocked 24/7. There is no PIN, 2FA, or manual approval' -ForegroundColor Red
    Write-Host '     step standing between an attacker and your coins.' -ForegroundColor Red
    Write-Host '   - If this machine is compromised, funds can be drained' -ForegroundColor Red
    Write-Host '     automatically, with no prompt and no warning.' -ForegroundColor Red
    Write-Host ''
    Write-Host ' Recommended precautions:' -ForegroundColor Red
    Write-Host '   - Only put funds on this wallet that you can afford to' -ForegroundColor Red
    Write-Host '     lose, sized for ticket-buying/voting purposes only.' -ForegroundColor Red
    Write-Host '   - Keep the bulk of your holdings in a separate, offline' -ForegroundColor Red
    Write-Host '     or hardware-secured wallet, not this one.' -ForegroundColor Red
    Write-Host '   - Keep Windows Update, antivirus, and firewall active and' -ForegroundColor Red
    Write-Host '     restrict who has admin/RDP access to this machine.' -ForegroundColor Red
    Write-Host '   - Rotate the passphrase and re-run this script if you' -ForegroundColor Red
    Write-Host '     ever suspect the machine has been compromised.' -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
function Main {
    if (-not (Test-IsAdministrator)) {
        Write-ErrAndThrow 'This script must be run from an elevated PowerShell (Run as Administrator).'
    }

    $platform = Get-Platform
    Write-Info "Detected platform: $platform"

    Install-Binary -Repo 'monetarium-node'   -BinaryName 'monetarium-node'   -Platform $platform
    Install-Binary -Repo 'monetarium-wallet' -BinaryName 'monetarium-wallet' -Platform $platform
    Install-Binary -Repo 'monetarium-ctl'    -BinaryName 'monetarium-ctl'    -Platform $platform

    Add-InstallDirToPath

    $passphrase = Read-WalletPassphrase
    $Script:RpcUser = 'monetarium'
    $Script:RpcSecret = Get-RandomToken -Length 32

    Read-TicketBuyerPrompt

    Write-Config -Passphrase $passphrase -RpcUser $Script:RpcUser -RpcSecret $Script:RpcSecret
    Remove-Variable -Name passphrase -ErrorAction SilentlyContinue

    Write-CtlConfig
    Create-Wallet

    Read-MiningPrompt

    Invoke-ConfigureMiningAndVoting
    Install-StartupScripts
    Write-Manifest

    Write-Host ''
    Write-Host 'Installation complete.' -ForegroundColor Green
    Show-BigWarning
}

# Only auto-run when this file is executed directly.
# Dot-sourcing (". .\install.ps1") -- as the Pester tests do -- loads the
# functions above without invoking the installer.
if ($MyInvocation.InvocationName -ne '.' -and -not $NoExec) {
    Main
}
