# ReTemp: Verify contracts on Tempo testnet via Sourcify API v2
# Usage: .\script\verify-sourcify.ps1
# Requirements: run from D:\ReTemp directory

$VERIFIER_URL = "https://contracts.tempo.xyz"
$CHAIN_ID     = "42431"

# ── Contract list ──────────────────────────────────────────────────────────────
$CONTRACTS = @(
    @{
        address  = "0x5c480582a063689a282637e8fB23a9C300127662"
        label    = "poolAlphaBeta"
        name     = "ReTempPool"
        file     = "contracts/ReTempPool.sol"
        artifact = "out/ReTempPool.sol/ReTempPool.json"
        txHash   = "0x46c449306b05afe53bdef4d5ec6e7b0501a0c8762e195e3100c0ab5cbef47700"
    },
    @{
        address  = "0x524Ec330c1Ae05E05669664a93310Fe30cB6f10e"
        label    = "poolAlphaTheta"
        name     = "ReTempPool"
        file     = "contracts/ReTempPool.sol"
        artifact = "out/ReTempPool.sol/ReTempPool.json"
        txHash   = "0x6ae2d319a58f59e3e144e020c43652f8063041686738aebaa16fc03c911c86c4"
    },
    @{
        address  = "0x6Ff5BBED78E0CF0e1f42bCB0FE3796924545f173"
        label    = "poolAlphaPath"
        name     = "ReTempPool"
        file     = "contracts/ReTempPool.sol"
        artifact = "out/ReTempPool.sol/ReTempPool.json"
        txHash   = "0xdbdc45a98c0f4d93daaa12a11c666387cf48811b853e2865488d5639583e5db5"
    },
    @{
        address  = "0x9A54F31caEb1e6097f55F9A9D6E211A931C612F6"
        label    = "ReTempRouter"
        name     = "ReTempRouter"
        file     = "contracts/ReTempRouter.sol"
        artifact = "out/ReTempRouter.sol/ReTempRouter.json"
        txHash   = "0x7e39c1ccac470e4e08da762fee4464350671c174225c659b8e55365099569982"
    }
)

# ── Read build-info (contains stdJsonInput) ────────────────────────────────────
$buildInfoDir = "out/build-info"
$buildInfoFiles = Get-ChildItem "$buildInfoDir/*.json" | Sort-Object LastWriteTime -Descending
if ($buildInfoFiles.Count -eq 0) {
    Write-Error "No build-info found. Run: forge build"
    exit 1
}
# Use the most recent build-info
$buildInfoPath = $buildInfoFiles[0].FullName
Write-Host "Reading build-info: $buildInfoPath" -ForegroundColor Cyan
$buildInfo = Get-Content $buildInfoPath -Raw | ConvertFrom-Json

$stdJsonInput  = $buildInfo.input
$compilerVersion = $buildInfo.solcLongVersion  # e.g. "0.8.20+commit...."

Write-Host "Compiler: $compilerVersion" -ForegroundColor Cyan
Write-Host ""

# ── Verify each contract ───────────────────────────────────────────────────────
foreach ($c in $CONTRACTS) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host " Verifying: $($c.label) ($($c.address))" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    $endpoint = "$VERIFIER_URL/v2/verify/$CHAIN_ID/$($c.address)"

    $body = @{
        stdJsonInput            = $stdJsonInput
        compilerVersion         = $compilerVersion
        contractIdentifier      = "$($c.file):$($c.name)"
        creationTransactionHash = $c.txHash
    } | ConvertTo-Json -Depth 100

    try {
        $response = Invoke-RestMethod `
            -Uri $endpoint `
            -Method POST `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop

        $verificationId = $response.verificationId
        Write-Host " Submitted! verificationId: $verificationId" -ForegroundColor Green

        # ── Poll for result ─────────────────────────────────────────────────
        Write-Host " Polling for result..." -ForegroundColor Cyan
        $maxAttempts = 20
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            Start-Sleep -Seconds 3
            $status = Invoke-RestMethod `
                -Uri "$VERIFIER_URL/v2/verify/$verificationId" `
                -Method GET `
                -ErrorAction SilentlyContinue

            if ($status.isJobCompleted) {
                if ($status.contract.match) {
                    Write-Host " ✅ VERIFIED! Match: $($status.contract.match)" -ForegroundColor Green
                } else {
                    Write-Host " ❌ Verification FAILED" -ForegroundColor Red
                    if ($status.error) {
                        Write-Host "   Error: $($status.error.message)" -ForegroundColor Red
                    }
                }
                break
            } else {
                Write-Host "   Still processing... ($($i+1)/$maxAttempts)" -ForegroundColor DarkGray
            }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host " ❌ Request failed (HTTP $statusCode)" -ForegroundColor Red
        # Try to read error body
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errBody = $reader.ReadToEnd()
            Write-Host "   $errBody" -ForegroundColor Red
        } catch {}
    }

    Write-Host ""
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Done! View on explorer: https://explore.tempo.xyz" -ForegroundColor Cyan
