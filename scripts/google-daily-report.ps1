# 구글 광고 전일 성과 슬랙 리포트 (Pipeboard MCP HTTP)
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# .env 로드
$envPath = Join-Path $PSScriptRoot "..\\.env"
Get-Content $envPath -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
    }
}

$slackHook  = $env:SLACK_WEBHOOK_META_REPORT
$pipeToken  = $env:PIPEBOARD_GOOGLE_TOKEN
$yesterday  = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")

function Format-Won { param($n); $v = [long][double]$n; return ($v.ToString("N0")) + "원" }
function Format-Num { param($n); return ([long][double]$n).ToString("N0") }
function Format-Pct { param($n); return ([double]$n).ToString("F2") + "%" }

function Invoke-MCP {
    param([string]$ToolName, [hashtable]$Args)
    $body = @{
        jsonrpc = "2.0"
        id      = 1
        method  = "tools/call"
        params  = @{
            name      = $ToolName
            arguments = $Args
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $resp = Invoke-RestMethod "https://google-ads.mcp.pipeboard.co/?token=$pipeToken" `
        -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
    if ($resp.error) { throw "MCP 오류: $($resp.error.message)" }
    $text = $resp.result.content[0].text
    if ($text -like "MCP usage limit*") { throw $text }
    return $text | ConvertFrom-Json
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add(":large_green_circle: [구글] 앳홈 미닉스 소재별 성과 ($yesterday)")
$lines.Add("")

try {
    # 계정 목록 조회
    $customers = Invoke-MCP -ToolName "list_google_ads_customers" -Args @{}
    $activeCustomers = $customers.customers | Where-Object { $_.can_query_metrics -eq $true }

    foreach ($cust in $activeCustomers) {
        $custId   = $cust.customer_id
        $custName = if ($cust.descriptive_name) { $cust.descriptive_name } else { $custId }

        # 소재(ad) 단위 성과 조회 (전일)
        $adData = Invoke-MCP -ToolName "get_google_ads_ad_metrics" -Args @{
            customer_id = $custId
            date_range  = "YESTERDAY"
            page_size   = 500
        }

        $ads = $adData.ads | Where-Object { [double]$_.metrics.cost -gt 0 }
        if (-not $ads -or $ads.Count -eq 0) { continue }

        $lines.Add("[ $custName ]")

        # 광고그룹별 그룹핑
        $byAdGroup = $ads | Group-Object { $_.ad_group_name }

        foreach ($grp in $byAdGroup) {
            $grpAds = $grp.Group

            $totalSpend  = ($grpAds | ForEach-Object { [double]$_.metrics.cost }        | Measure-Object -Sum).Sum
            $totalClicks = ($grpAds | ForEach-Object { [long]$_.metrics.clicks }         | Measure-Object -Sum).Sum
            $totalImpr   = ($grpAds | ForEach-Object { [long]$_.metrics.impressions }    | Measure-Object -Sum).Sum
            $totalConv   = ($grpAds | ForEach-Object { [double]$_.metrics.conversions }  | Measure-Object -Sum).Sum

            $avgCpc = if ($totalClicks -gt 0) { $totalSpend / $totalClicks } else { 0 }
            $avgCtr = if ($totalImpr   -gt 0) { ($totalClicks / $totalImpr) * 100 } else { 0 }
            $totalCpa = if ($totalConv -gt 0) { $totalSpend / $totalConv } else { 0 }

            $lines.Add("━━━━━━━━━━━━━━━━")
            $lines.Add("광고그룹: $($grp.Name)")
            $lines.Add("지출: $(Format-Won $totalSpend)  |  전환: $(Format-Num $totalConv)건  |  CPA: $(Format-Won $totalCpa)")
            $lines.Add("클릭: $(Format-Num $totalClicks)  |  CPC: $(Format-Won $avgCpc)  |  CTR: $(Format-Pct $avgCtr)")
            $lines.Add("소재별:")

            foreach ($ad in ($grpAds | Sort-Object { [double]$_.metrics.cost } -Descending)) {
                $adSpend  = [double]$ad.metrics.cost
                $adClicks = [long]$ad.metrics.clicks
                $adConv   = [double]$ad.metrics.conversions
                $adCpc    = if ($adClicks -gt 0) { $adSpend / $adClicks } else { 0 }
                $adCtr    = if ([long]$ad.metrics.impressions -gt 0) { ($adClicks / [long]$ad.metrics.impressions) * 100 } else { 0 }
                $adCpa    = if ($adConv -gt 0) { $adSpend / $adConv } else { 0 }
                $adName   = if ($ad.name) { $ad.name } else { "$($ad.ad_group_name)_$($ad.id)" }

                $lines.Add("  · $adName")
                $lines.Add("    지출: $(Format-Won $adSpend)  |  전환: $(Format-Num $adConv)건  |  CPA: $(Format-Won $adCpa)  |  CPC: $(Format-Won $adCpc)  |  CTR: $(Format-Pct $adCtr)")
            }

            $lines.Add("")
        }
    }
} catch {
    $lines.Add("구글 광고 데이터 조회 실패: $_")
}

$text    = $lines -join "`n"
$payload = ConvertTo-Json -Compress ([ordered]@{ text = $text })
$bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
Invoke-RestMethod -Uri $slackHook -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
Write-Host "구글 슬랙 전송 완료 ($yesterday)"
