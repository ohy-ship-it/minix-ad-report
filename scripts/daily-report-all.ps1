# 메타 + 구글 통합 데일리 리포트
$scriptsDir = $PSScriptRoot

Write-Host "=== 메타 리포트 실행 ==="
& "$scriptsDir\meta-daily-report.ps1"

Write-Host "=== 구글 리포트 실행 ==="
& "$scriptsDir\google-daily-report.ps1"

Write-Host "=== 전송 완료 ==="
