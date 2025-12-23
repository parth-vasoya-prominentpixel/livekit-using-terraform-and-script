# LiveKit Deployment Script for Windows
# Runs the bash deployment script using WSL or Git Bash

param(
    [switch]$Help
)

if ($Help) {
    Write-Host "LiveKit EKS Deployment Script" -ForegroundColor Green
    Write-Host "=============================" -ForegroundColor Green
    Write-Host ""
    Write-Host "This script deploys LiveKit to your EKS cluster with dynamic configuration."
    Write-Host ""
    Write-Host "Prerequisites:" -ForegroundColor Yellow
    Write-Host "  - AWS CLI configured"
    Write-Host "  - kubectl installed"
    Write-Host "  - Helm installed"
    Write-Host "  - Terraform infrastructure deployed"
    Write-Host "  - WSL or Git Bash available"
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\deploy-livekit.ps1"
    Write-Host "  .\deploy-livekit.ps1 -Help"
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Yellow
    Write-Host "  Edit livekit.env to customize your deployment"
    Write-Host ""
    exit 0
}

Write-Host "🎥 LiveKit EKS Deployment (Windows)" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host ""

# Check if livekit.env exists
if (-not (Test-Path "livekit.env")) {
    Write-Host "❌ livekit.env not found" -ForegroundColor Red
    Write-Host "💡 Please create livekit.env with your configuration" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ Configuration file found: livekit.env" -ForegroundColor Green

# Check if deployment script exists
if (-not (Test-Path "scripts/03-deploy-livekit.sh")) {
    Write-Host "❌ Deployment script not found: scripts/03-deploy-livekit.sh" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Deployment script found" -ForegroundColor Green
Write-Host ""

# Try to run with WSL first, then Git Bash
Write-Host "🚀 Starting LiveKit deployment..." -ForegroundColor Green
Write-Host ""

$wslAvailable = $false
$gitBashAvailable = $false

# Check for WSL
try {
    $wslCheck = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        $wslAvailable = $true
        Write-Host "✅ WSL detected" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️ WSL not available" -ForegroundColor Yellow
}

# Check for Git Bash
$gitBashPaths = @(
    "${env:ProgramFiles}\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "${env:LOCALAPPDATA}\Programs\Git\bin\bash.exe"
)

foreach ($path in $gitBashPaths) {
    if (Test-Path $path) {
        $gitBashAvailable = $true
        $gitBashPath = $path
        Write-Host "✅ Git Bash detected: $path" -ForegroundColor Green
        break
    }
}

if (-not $gitBashAvailable) {
    Write-Host "⚠️ Git Bash not found in common locations" -ForegroundColor Yellow
}

Write-Host ""

# Run the deployment
if ($wslAvailable) {
    Write-Host "🔄 Running deployment with WSL..." -ForegroundColor Cyan
    wsl bash scripts/03-deploy-livekit.sh
} elseif ($gitBashAvailable) {
    Write-Host "🔄 Running deployment with Git Bash..." -ForegroundColor Cyan
    & $gitBashPath scripts/03-deploy-livekit.sh
} else {
    Write-Host "❌ Neither WSL nor Git Bash available" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install one of the following:" -ForegroundColor Yellow
    Write-Host "  - Windows Subsystem for Linux (WSL)" -ForegroundColor Yellow
    Write-Host "  - Git for Windows (includes Git Bash)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Alternative: Run the script manually in your preferred bash environment:" -ForegroundColor Yellow
    Write-Host "  bash scripts/03-deploy-livekit.sh" -ForegroundColor Yellow
    exit 1
}

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "🎉 Deployment completed successfully!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "❌ Deployment failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "💡 Check the output above for troubleshooting information" -ForegroundColor Yellow
}