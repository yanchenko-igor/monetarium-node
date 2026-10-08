#requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for install.ps1 (Windows).

.DESCRIPTION
    Dot-sources install.ps1 (which, thanks to the InvocationName guard at
    the bottom of that file, only loads its functions and does not run
    Main). Network calls (Invoke-RestMethod / Invoke-WebRequest) and the
    Windows-elevation check are mocked so the test never touches the real
    monetarium GitHub releases or launches real processes. Everything else
    (file writes, ACLs, zip extraction, config content) runs for real
    against a throwaway temp directory.
#>

BeforeAll {
    $Script:InstallScript = Join-Path $PSScriptRoot '..' 'install.ps1'
    . $Script:InstallScript -NoExec
}

Describe 'install.ps1' {

    BeforeEach {
        $Script:TestRoot = Join-Path $env:TEMP ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null

        # Redirect install/data/startup dirs into the throwaway root.
        $Script:InstallDir  = Join-Path $Script:TestRoot 'bin'
        $Script:DataDir     = Join-Path $Script:TestRoot 'data'
        $Script:WalletConf  = Join-Path $Script:DataDir 'monetarium-wallet.conf'
        $Script:NodeConf    = Join-Path $Script:DataDir 'monetarium.conf'
        $Script:CtlDir      = Join-Path $Script:TestRoot 'ctl'
        $Script:CtlConf     = Join-Path $Script:CtlDir 'monetarium-ctl.conf'
        $Script:Manifest    = Join-Path $Script:DataDir 'install.manifest'
        $Script:StartupDir  = Join-Path $Script:TestRoot 'startup'

        Mock Test-IsAdministrator { return $true }

        # Fake "latest release" API response.
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -notmatch '/repos/[^/]+/([^/]+)/releases/latest') {
                throw "Unexpected Invoke-RestMethod call: $Uri"
            }
            $repo = $Matches[1]
            [PSCustomObject]@{
                assets = @(
                    [PSCustomObject]@{
                        name                = "${repo}-windows-amd64.zip"
                        browser_download_url = "https://fixtures.test/${repo}-windows-amd64.zip"
                    }
                )
            }
        }

        # Fake download: build a small real zip containing a stub .exe.
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            if ($Uri -notmatch '/([a-zA-Z0-9_-]+)-windows-amd64\.zip$') {
                throw "Unexpected Invoke-WebRequest call: $Uri"
            }
            $binName = $Matches[1]
            $tmp = Join-Path $env:TEMP ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $tmp | Out-Null
            Set-Content -Path (Join-Path $tmp "$binName.exe") -Value "mock exe for $binName"
            Compress-Archive -Path (Join-Path $tmp "$binName.exe") -DestinationPath $OutFile -Force
            Remove-Item -Path $tmp -Recurse -Force
        }

        # Don't launch real processes.
        Mock Start-Process { }

        # Wallet --create is tested end-to-end via Linux E2E; in Pester
        # the stub .exe isn't a real binary, so mock it as a no-op.
        Mock Create-Wallet { }
    }

    AfterEach {
        Remove-Item -Path $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'normal flow' {
        BeforeEach {
            Mock Read-Host {
                ConvertTo-SecureString -String 'test-passphrase-123' -AsPlainText -Force
            }
        }

        It 'refuses to run when not elevated' {
            Mock Test-IsAdministrator { return $false }
            { Main } | Should -Throw '*elevated*'
        }

        It 'downloads and installs all three binaries' {
            Main
            Test-Path (Join-Path $Script:InstallDir 'monetarium-node.exe')   | Should -BeTrue
            Test-Path (Join-Path $Script:InstallDir 'monetarium-wallet.exe') | Should -BeTrue
            Test-Path (Join-Path $Script:InstallDir 'monetarium-ctl.exe')    | Should -BeTrue
        }

        It 'writes a wallet config containing the passphrase and staking flags' {
            Main
            $content = Get-Content -Path $Script:WalletConf -Raw
            $content | Should -Match 'pass=test-passphrase-123'
            $content | Should -Match 'enablevoting=0'
            $content | Should -Match 'enableticketbuyer=0'
            $content | Should -Match 'ticketbuyer\.limit=1'
            $content | Should -Match 'ticketbuyer\.balancetomaintainabsolute=1'
            $content | Should -Match 'gaplimit=20'
            $content | Should -Match 'accountgaplimit=10'
        }

        It 'writes a node config with rpc credentials and mining flag, and no hardcoded peers' {
            Main
            $content = Get-Content -Path $Script:NodeConf -Raw
            $content | Should -Match 'rpcuser=monetarium'
            $content | Should -Match 'rpcpass='
            # Peer discovery is handled by the HTTPS seeders compiled into
            # chaincfg, so no peers may be pinned in the generated config.
            $content | Should -Not -Match '(?m)^addpeer='
            $content | Should -Match 'generate=false'
        }

        It 'does not leave the passphrase visible in Main''s own console output' {
            $output = Main 6>&1 5>&1 3>&1 | Out-String
            $output | Should -Not -Match 'test-passphrase-123'
        }

        It 'locks down the wallet config ACL so only current user/SYSTEM/Administrators have access' {
            Main
            $acl = Get-Acl -Path $Script:WalletConf
            $identities = $acl.Access | ForEach-Object { $_.IdentityReference.Value }
            ($identities -join ';') | Should -Match 'SYSTEM'
            ($identities -join ';') | Should -Match 'Administrators'
        }

        It 'writes a ctl config with matching rpc credentials' {
            Main
            $content = Get-Content -Path $Script:CtlConf -Raw
            $content | Should -Match 'rpcuser=monetarium'
            $content | Should -Match 'rpcpass='
        }

        It 'writes the install manifest' {
            Main
            Test-Path $Script:Manifest | Should -BeTrue
            $content = Get-Content -Path $Script:Manifest -Raw
            $content | Should -Match 'monetarium-node.exe'
            $content | Should -Match 'monetarium-wallet.exe'
            $content | Should -Match 'monetarium-ctl.exe'
            $content | Should -Match 'MonetariumNode'
            $content | Should -Match 'MonetariumWallet'
        }

        It 'creates startup scripts for node and wallet' {
            Main
            $nodeScript = Join-Path $Script:StartupDir 'MonetariumNode.vbs'
            $walletScript = Join-Path $Script:StartupDir 'MonetariumWallet.vbs'
            Test-Path $nodeScript   | Should -BeTrue
            Test-Path $walletScript | Should -BeTrue
            $nodeContent   = Get-Content -Path $nodeScript -Raw
            $walletContent = Get-Content -Path $walletScript -Raw
            $nodeContent   | Should -Match 'monetarium-node'
            $walletContent | Should -Match 'monetarium-wallet'
            $walletContent | Should -Match 'timeout'
        }

        It 'starts both processes during installation' {
            Main
            Should -Invoke Start-Process -Times 2 -Exactly
        }

        It 'prints the big warning banner' {
            $output = Main 6>&1 | Out-String
            $output | Should -Match 'WARNING'
            $output | Should -Match 'PLAINTEXT'
        }
    }
}

Describe 'Show-ConfigurationSummary' {

    BeforeEach {
        $script:SummaryLines = @()
        Mock Write-Host { $script:SummaryLines += $Object }
    }

    It 'shows Auto voting enabled when VotingEnabled is true' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $true

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Match 'Auto voting:\s+enabled'
    }

    It 'shows Auto voting disabled when VotingEnabled is false' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Match 'Auto voting:\s+disabled'
    }

    It 'shows fee consolidation address when ConsolidationAddr is set' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = 'TcTestAddr123'
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Match 'Fee consolidation address:\s+TcTestAddr123'
    }

    It 'omits fee consolidation address when ConsolidationAddr is null' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Not -Match 'Fee consolidation'
    }

    It 'shows mining address when both MiningEnabled and MiningAddr are set' {
        $Script:MiningEnabled = $true; $Script:MiningAddr = 'TMiningAddr'
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Match 'Mining address:\s+TMiningAddr'
    }

    It 'omits mining address when MiningAddr is null' {
        $Script:MiningEnabled = $true; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Not -Match 'Mining address'
    }

    It 'shows ticket buyer lines when TicketsEnabled and ConsolidationAddr set' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $true; $Script:ConsolidationAddr = 'TcAddr'
        $Script:TicketLimit = 3; $Script:TicketBalance = 10
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Match 'Ticket buyer limit:\s+3'
        $combined | Should -Match 'Balance to maintain:\s+10'
    }

    It 'omits ticket buyer lines when TicketsEnabled is false' {
        $Script:MiningEnabled = $false; $Script:MiningAddr = $null
        $Script:TicketsEnabled = $false; $Script:ConsolidationAddr = $null
        $Script:VotingEnabled = $false

        Show-ConfigurationSummary

        $combined = $script:SummaryLines -join "`n"
        $combined | Should -Not -Match 'Ticket buyer'
        $combined | Should -Not -Match 'Balance to maintain'
    }
}

Describe 'Get-Platform' {
    It 'maps AMD64 to windows-amd64' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Get-Platform | Should -Be 'windows-amd64'
    }

    It 'maps ARM64 to windows-arm64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        Get-Platform | Should -Be 'windows-arm64'
    }
}

Describe 'ConvertFrom-SecureStringToPlainText' {
    It 'round-trips a plaintext value through a SecureString' {
        $secure = ConvertTo-SecureString -String 'hello world' -AsPlainText -Force
        ConvertFrom-SecureStringToPlainText -SecureString $secure | Should -Be 'hello world'
    }
}
