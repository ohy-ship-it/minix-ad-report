# 메타 광고 전일 성과 슬랙 리포트
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# .env 로드
$envPath = Join-Path $PSScriptRoot "..\\.env"
Get-Content $envPath -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
    }
}

$token     = $env:META_ACCESS_TOKEN
$slackHook = $env:SLACK_WEBHOOK_META_REPORT
$accounts  = ($env:REPORT_AD_ACCOUNTS -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")

$acctNameMap = @{
    "act_370223898721955"  = "미닉스"
    "act_876846528408565"  = "컬리"
    "act_1467742828251405" = "CJ"
    "act_1194498995371808" = "오늘의집"
    "act_1010891704382690" = "네이버"
    "act_1182774429560123" = "쿠팡"
}

function Format-Won { param($n); $v = [long][double]$n; return ($v.ToString("N0")) + "원" }
function Format-Num { param($n); return ([long][double]$n).ToString("N0") }
function Format-Pct { param($n); return ([double]$n).ToString("F2") + "%" }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add(":large_blue_circle: [메타] 앳홈 미닉스 소재별 성과 ($yesterday)")
$lines.Add("")

foreach ($acct in $accounts) {

    # 광고계정명
    $acctName = if ($acctNameMap.ContainsKey($acct)) { $acctNameMap[$acct] } else { $acct }

    # 맞춤전환 ID -> 이름 매핑
    $ccMap = @{}
    try {
        $ccUrl  = "https://graph.facebook.com/v21.0/$acct/customconversions?fields=id,name&limit=200&access_token=$token"
        $ccResp = Invoke-RestMethod $ccUrl
        foreach ($cc in $ccResp.data) {
            $ccMap["offsite_conversion.custom.$($cc.id)"] = $cc.name
        }
    } catch {}

    # 광고세트별 promoted_object + optimization_goal 조회 → 전환 타입/이름 매핑
    $adsetCCMap = @{}  # adset_name -> @{actionType; displayName}
    $goalActionMap = @{
        "LANDING_PAGE_VIEWS" = @{ actionType = "landing_page_view";  displayName = "랜딩페이지 조회" }
        "LINK_CLICKS"        = @{ actionType = "link_click";          displayName = "링크 클릭" }
        "REACH"              = @{ actionType = "reach";               displayName = "도달" }
        "VIDEO_VIEWS"        = @{ actionType = "video_view";          displayName = "동영상 조회" }
        "ENGAGED_USERS"      = @{ actionType = "post_engagement";     displayName = "게시물 참여" }
        "PAGE_LIKES"         = @{ actionType = "like";                displayName = "페이지 좋아요" }
    }
    try {
        $asUrl  = "https://graph.facebook.com/v21.0/$acct/adsets?fields=name,optimization_goal,promoted_object&effective_status=['ACTIVE']&limit=200&access_token=$token"
        $asResp = Invoke-RestMethod $asUrl
        foreach ($as in $asResp.data) {
            $po   = $as.promoted_object
            $goal = $as.optimization_goal

            # 맞춤전환/픽셀 이벤트 우선
            if ($po) {
                if ($po | Get-Member -Name "custom_conversion_id" -ErrorAction SilentlyContinue) {
                    $key = "offsite_conversion.custom.$($po.custom_conversion_id)"
                    $adsetCCMap[$as.name] = @{ actionType = $key; displayName = if ($ccMap.ContainsKey($key)) { $ccMap[$key] } else { $po.custom_conversion_id } }
                    continue
                } elseif ($po | Get-Member -Name "custom_event_str" -ErrorAction SilentlyContinue) {
                    $adsetCCMap[$as.name] = @{ actionType = "offsite_conversion.fb_pixel_custom"; displayName = $po.custom_event_str }
                    continue
                } elseif (($po | Get-Member -Name "custom_event_type" -ErrorAction SilentlyContinue) -and $po.custom_event_type -ne "OTHER") {
                    $typeNameMap = @{ "PURCHASE" = "구매"; "ADD_TO_CART" = "장바구니 추가"; "INITIATED_CHECKOUT" = "결제 시작"; "COMPLETE_REGISTRATION" = "회원가입"; "LEAD" = "리드"; "VIEW_CONTENT" = "콘텐츠 조회" }
                    $dn = if ($typeNameMap.ContainsKey($po.custom_event_type)) { $typeNameMap[$po.custom_event_type] } else { $po.custom_event_type }
                    $adsetCCMap[$as.name] = @{ actionType = "offsite_conversion.fb_pixel_$($po.custom_event_type.ToLower())"; displayName = $dn }
                    continue
                }
            }

            # 전환 외 목적 → optimization_goal 기반 매핑
            if ($goal -and $goalActionMap.ContainsKey($goal)) {
                $adsetCCMap[$as.name] = $goalActionMap[$goal]
            }
        }
    } catch {}

    # 광고 단위 인사이트 (전체 페이지)
    $timeRange = '{"since":"' + $yesterday + '","until":"' + $yesterday + '"}'
    $filtering = [Uri]::EscapeDataString('[{"field":"adset.effective_status","operator":"IN","value":["ACTIVE"]}]')
    $insUrl = "https://graph.facebook.com/v21.0/$acct/insights?level=ad" +
              "&fields=adset_name,ad_name,spend,actions,clicks,cpc,ctr,impressions,reach" +
              "&time_range=" + [Uri]::EscapeDataString($timeRange) +
              "&filtering=$filtering" +
              "&limit=500&access_token=$token"

    $resp = Invoke-RestMethod $insUrl
    $data = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $resp.data) { $data.Add($d) }
    while ($resp.paging -and ($resp.paging | Get-Member -Name "next" -ErrorAction SilentlyContinue)) {
        $resp = Invoke-RestMethod $resp.paging.next
        foreach ($d in $resp.data) { $data.Add($d) }
    }

    if ($data.Count -eq 0) { continue }

    # 지출 없는 데이터 제거
    $data = $data | Where-Object { [double]$_.spend -gt 0 }
    if ($data.Count -eq 0) { continue }

    $byAdset = $data | Group-Object adset_name

    $lines.Add("[ $acctName ]")

    foreach ($adsetGrp in $byAdset) {
        $ads = $adsetGrp.Group

        $totalSpend  = ($ads | ForEach-Object { [double]$_.spend }     | Measure-Object -Sum).Sum
        $totalClicks = ($ads | ForEach-Object { [long]$_.clicks }       | Measure-Object -Sum).Sum
        $totalImpr   = ($ads | ForEach-Object { [long]$_.impressions }  | Measure-Object -Sum).Sum

        $avgCpc = if ($totalClicks -gt 0) { $totalSpend / $totalClicks } else { 0 }
        $avgCtr = if ($totalImpr   -gt 0) { ($totalClicks / $totalImpr) * 100 } else { 0 }

        # 광고세트 전환 타입 결정: promoted_object 우선, 없으면 가장 많은 맞춤전환
        $primaryCC    = $null
        $primaryCount = 0
        $primaryName  = "결과"

        # 직접 필드로 오는 액션 타입 (actions 배열이 아님)
        # actions 배열이 아닌 직접 필드로 오는 항목
        $directFieldMap = @{
            "reach"      = "reach"
            "link_click" = "clicks"
        }

        if ($adsetCCMap.ContainsKey($adsetGrp.Name)) {
            $primaryCC   = $adsetCCMap[$adsetGrp.Name].actionType
            $primaryName = $adsetCCMap[$adsetGrp.Name].displayName
            if ($directFieldMap.ContainsKey($primaryCC)) {
                $fieldName = $directFieldMap[$primaryCC]
                foreach ($ad in $ads) {
                    if ($ad | Get-Member -Name $fieldName -ErrorAction SilentlyContinue) {
                        $primaryCount += [long]$ad.$fieldName
                    }
                }
            } else {
                foreach ($ad in $ads) {
                    if (-not ($ad | Get-Member -Name "actions" -ErrorAction SilentlyContinue)) { continue }
                    $found = $ad.actions | Where-Object { $_.action_type -eq $primaryCC }
                    if ($found) { $primaryCount += [int]($found | Select-Object -First 1).value }
                }
            }
        } else {
            $ccTotals = @{}
            foreach ($ad in $ads) {
                if (-not ($ad | Get-Member -Name "actions" -ErrorAction SilentlyContinue)) { continue }
                foreach ($action in $ad.actions) {
                    if ($action.action_type -like "offsite_conversion.custom.*") {
                        if (-not $ccTotals.ContainsKey($action.action_type)) { $ccTotals[$action.action_type] = 0 }
                        $ccTotals[$action.action_type] += [int]$action.value
                    }
                }
            }
            foreach ($k in $ccTotals.Keys) {
                if ($ccTotals[$k] -gt $primaryCount) {
                    $primaryCount = $ccTotals[$k]
                    $primaryCC    = $k
                    $primaryName  = if ($ccMap.ContainsKey($k)) { $ccMap[$k] } else { $k -replace "offsite_conversion.custom.", "" }
                }
            }
        }

        $cpa = if ($primaryCount -gt 0) { $totalSpend / $primaryCount } else { 0 }

        $lines.Add("━━━━━━━━━━━━━━━━")
        $lines.Add("광고세트: $($adsetGrp.Name)")
        $lines.Add("지출: $(Format-Won $totalSpend)  |  결과($primaryName): $(Format-Num $primaryCount)건  |  CPA: $(Format-Won $cpa)")
        $lines.Add("클릭: $(Format-Num $totalClicks)  |  CPC: $(Format-Won $avgCpc)  |  CTR: $(Format-Pct $avgCtr)")
        $lines.Add("소재별:")

        foreach ($ad in ($ads | Sort-Object { [double]$_.spend } -Descending)) {
            $adSpend  = [double]$ad.spend
            $adClicks = [long]$ad.clicks
            $adCpc    = if (($ad | Get-Member -Name "cpc"  -ErrorAction SilentlyContinue)) { [double]$ad.cpc } else { 0 }
            $adCtr    = if (($ad | Get-Member -Name "ctr"  -ErrorAction SilentlyContinue)) { [double]$ad.ctr } else { 0 }

            $adCcCount = 0
            if ($primaryCC) {
                if ($directFieldMap.ContainsKey($primaryCC)) {
                    $fieldName = $directFieldMap[$primaryCC]
                    if ($ad | Get-Member -Name $fieldName -ErrorAction SilentlyContinue) { $adCcCount = [long]$ad.$fieldName }
                } elseif ($ad | Get-Member -Name "actions" -ErrorAction SilentlyContinue) {
                    $found = $ad.actions | Where-Object { $_.action_type -eq $primaryCC }
                    if ($found) { $adCcCount = [int]($found | Select-Object -First 1).value }
                }
            }
            $adCpa = if ($adCcCount -gt 0) { $adSpend / $adCcCount } else { 0 }

            $lines.Add("  · $($ad.ad_name)")
            $lines.Add("    지출: $(Format-Won $adSpend)  |  결과: $(Format-Num $adCcCount)건  |  CPA: $(Format-Won $adCpa)  |  CPC: $(Format-Won $adCpc)  |  CTR: $(Format-Pct $adCtr)")
        }

        $lines.Add("")
    }
}

$text    = $lines -join "`n"
$payload = ConvertTo-Json -Compress ([ordered]@{ text = $text })
$bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
Invoke-RestMethod -Uri $slackHook -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
Write-Host "슬랙 전송 완료 ($yesterday)"