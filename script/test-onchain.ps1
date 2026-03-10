# ReTemp On-Chain Test Suite -- Real Tempo Blockchain (env-driven)
# Usage: set variables in .env (PRIVATE_KEY, RPC_URL, TREASURY_ADDRESS, etc.)
# then run: .\script\test-onchain.ps1

# load environment file if it exists
if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -and $_ -notmatch '^#') {
            $parts = $_ -split '=', 2
            if ($parts.Count -eq 2) {
                Set-Item -Path env:\$($parts[0]) -Value $parts[1]
            }
        }
    }
} else {
    Write-Error ".env file not found; please create one from .env.example and set PRIVATE_KEY, RPC_URL etc."
    exit 1
}

# required variables
if (-not $env:PRIVATE_KEY) { Write-Error "PRIVATE_KEY not set in environment"; exit 1 }
if (-not $env:RPC_URL)     { Write-Error "RPC_URL not set in environment"; exit 1 }
if (-not $env:TREASURY_ADDRESS) { Write-Error "TREASURY_ADDRESS not set in environment"; exit 1 }

# Use existing contracts from contracts.md, no new deploy
Write-Host "Running seed/test script with existing contracts from contracts.md..."
forge script script/Seed.s.sol:Seed `
    --rpc-url $env:RPC_URL `
    --private-key $env:PRIVATE_KEY `
    --broadcast `
    --chain 42431

Write-Host "On-chain tests complete. Check explorer for results."