<#
  AI Feed Monitor
  Theo dõi RSS/Atom + danh mục CISA KEV, lọc theo từ khóa, gửi bản tin qua Telegram và/hoặc Email.

  Cách dùng:
    .\monitor.ps1             Chạy bình thường: lấy bài mới, gửi bản tin, lưu trạng thái
    .\monitor.ps1 -DryRun     Chỉ in bản tin ra màn hình, không gửi, không lưu trạng thái
    .\monitor.ps1 -Init       Đánh dấu mọi bài hiện có là "đã xem" (chạy 1 lần đầu để khỏi bị ngập)
    .\monitor.ps1 -Check      Kiểm tra từng nguồn có đọc được không
    .\monitor.ps1 -TestSend   Gửi 1 tin nhắn thử để kiểm tra Telegram/Email
    .\monitor.ps1 -Resend     Gửi lại cả những bài đã gửi (trong lookbackDays ngày gần nhất)
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Init,
    [switch]$Check,
    [switch]$TestSend,
    [switch]$Resend
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = $PSScriptRoot
$ConfigPath  = Join-Path $Root 'config.json'
$SecretsPath = Join-Path $Root 'secrets.json'
$StatePath   = Join-Path $Root 'data\seen.json'
$LogPath     = Join-Path $Root 'logs\monitor.log'
$DigestDir   = Join-Path $Root 'digests'

# ---------------------------------------------------------------- tiện ích

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    $dir = Split-Path $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Read-JsonFile([string]$Path) {
    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Url([string]$Url) {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 `
        -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ai-feed-monitor/1.0'
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function ConvertTo-PlainText([string]$Html, [int]$Max = 220) {
    if (-not $Html) { return '' }
    $t = [regex]::Replace($Html, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($Max -gt 0 -and $t.Length -gt $Max) { $t = $t.Substring(0, $Max).TrimEnd() + '…' }
    return $t
}

function ConvertTo-Date([string]$s) {
    if (-not $s) { return $null }
    $s = $s.Trim()
    $s2 = [regex]::Replace($s, '^[A-Za-z]{3},\s*', '')
    $s2 = [regex]::Replace($s2, '\s(GMT|UTC|UT|Z)$', ' +0000')
    $s2 = [regex]::Replace($s2, '\sEDT$', ' -0400')
    $s2 = [regex]::Replace($s2, '\sEST$', ' -0500')
    $s2 = [regex]::Replace($s2, '\sPDT$', ' -0700')
    $s2 = [regex]::Replace($s2, '\sPST$', ' -0800')
    $s2 = [regex]::Replace($s2, '\s([+-]\d{2})(\d{2})$', ' $1:$2')
    $d = [DateTimeOffset]::MinValue
    foreach ($cand in @($s2, $s)) {
        if ([DateTimeOffset]::TryParse($cand, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    }
    return $null
}

function Get-Key([string]$s) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.Trim().ToLowerInvariant()))
    return ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Escape-Html([string]$s) {
    if (-not $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-ChildText($Node, [string]$Name) {
    $n = $Node.SelectSingleNode("*[local-name()='$Name']")
    if ($n) { return $n.InnerText } else { return '' }
}

function New-FeedItem($Feed, [string]$Title, [string]$Link, [string]$Summary, [string]$Date, [string]$Id) {
    if (-not $Id) { $Id = $Link }
    # arXiv: tách "arXiv:xxxx Announce Type: new|cross|replace Abstract:" khỏi tóm tắt
    $announce = ''
    $m = [regex]::Match(($Summary + ''), '^\s*arXiv:\S+\s+Announce Type:\s*(\S+)\s+Abstract:\s*')
    if ($m.Success) { $announce = $m.Groups[1].Value; $Summary = $Summary.Substring($m.Length) }
    # Hacker News (hnrss): thay khối "Article URL / Comments URL / Points" bằng dòng ngắn gọn
    $hn = [regex]::Match(($Summary + ''), 'Points:\s*(\d+).*?Comments:\s*(\d+)', 'Singleline')
    if ($hn.Success -and ($Summary -match 'Article URL')) { $Summary = "$($hn.Groups[1].Value) điểm · $($hn.Groups[2].Value) bình luận." }
    [pscustomobject]@{
        Announce = $announce
        Source   = $Feed.name
        Category = $Feed.category
        Title    = ConvertTo-PlainText $Title 300
        Link     = ($Link + '').Trim()
        Summary  = ConvertTo-PlainText $Summary 0
        Date     = ConvertTo-Date $Date
        Id       = ($Id + '').Trim()
        Matched  = @()
        Shown    = $false
    }
}

# ---------------------------------------------------------------- đọc nguồn

function Get-KevItems($Feed, [string]$Text) {
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $json = $ser.DeserializeObject($Text)
    foreach ($v in $json['vulnerabilities']) {
        $title = '{0}: {1}' -f $v['cveID'], $v['vulnerabilityName']
        $summary = '{0} {1}. {2}' -f $v['vendorProject'], $v['product'], $v['shortDescription']
        New-FeedItem $Feed $title "https://nvd.nist.gov/vuln/detail/$($v['cveID'])" $summary $v['dateAdded'] $v['cveID']
    }
}

function Get-FeedItems($Feed) {
    $text = Get-Url $Feed.url
    if ($Feed.type -eq 'kev') { return Get-KevItems $Feed $text }

    [xml]$xml = $text
    $root = $xml.DocumentElement

    if ($root.LocalName -eq 'feed') {
        # Atom
        foreach ($e in $root.SelectNodes("*[local-name()='entry']")) {
            $link = ''
            foreach ($l in $e.SelectNodes("*[local-name()='link']")) {
                $rel = $l.GetAttribute('rel')
                if (-not $rel -or $rel -eq 'alternate') { $link = $l.GetAttribute('href'); break }
            }
            $summary = Get-ChildText $e 'summary'
            if (-not $summary) { $summary = Get-ChildText $e 'content' }
            $date = Get-ChildText $e 'published'
            if (-not $date) { $date = Get-ChildText $e 'updated' }
            New-FeedItem $Feed (Get-ChildText $e 'title') $link $summary $date (Get-ChildText $e 'id')
        }
    }
    else {
        # RSS 2.0 / RSS 1.0 (RDF)
        foreach ($i in $xml.SelectNodes("//*[local-name()='item']")) {
            $date = Get-ChildText $i 'pubDate'
            if (-not $date) { $date = Get-ChildText $i 'date' }
            $id = Get-ChildText $i 'guid'
            New-FeedItem $Feed (Get-ChildText $i 'title') (Get-ChildText $i 'link') (Get-ChildText $i 'description') $date $id
        }
    }
}

function Get-KeywordPattern($Keywords) {
    $list = @($Keywords | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    return '(?i)\b(' + (($list | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')s?\b'
}

function Get-MatchedKeywords($Item, [string]$Pattern) {
    if (-not $Pattern) { return @() }
    $set = [ordered]@{}
    foreach ($m in [regex]::Matches("$($Item.Title) $($Item.Summary)", $Pattern)) {
        $set[$m.Groups[1].Value.ToLowerInvariant()] = $true
    }
    return @($set.Keys)
}

# ---------------------------------------------------------------- gửi bản tin

function Test-Configured($Value) {
    return ($Value -and ("$Value" -notmatch '^<.*>$') -and ("$Value".Trim() -ne ''))
}

function Send-Telegram($Secrets, [string]$Text, $ThreadId = $null) {
    $uri = "https://api.telegram.org/bot$($Secrets.telegram.botToken)/sendMessage"
    $payload = @{
        chat_id                  = $Secrets.telegram.chatId
        text                     = $Text
        parse_mode               = 'HTML'
        disable_web_page_preview = $true
    }
    if ($ThreadId) { $payload.message_thread_id = [int64]$ThreadId }
    $body = $payload | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

function Send-Email($Secrets, [string]$Subject, [string]$HtmlBody) {
    $e = $Secrets.email
    $pw = ConvertTo-SecureString $e.password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($e.username, $pw)
    Send-MailMessage -SmtpServer $e.smtpServer -Port ([int]$e.port) -UseSsl -Credential $cred `
        -From $e.from -To $e.to -Subject $Subject -Body $HtmlBody -BodyAsHtml -Encoding UTF8 `
        -WarningAction SilentlyContinue
}

# Nhóm có bật Topics: mỗi mục gửi vào topic tương ứng trong secrets.telegram.topics.
# Mục không khai báo (và tin nhắn tổng quan) dùng topics."_default"; không có thì vào "General".
function Get-TopicId($Secrets, [string]$Category) {
    $topics = $Secrets.telegram.topics
    if (-not $topics) { return $null }
    $id = $null
    if ($Category) { $id = $topics.$Category }
    if (-not $id) { $id = $topics.'_default' }
    if ($id -and [int64]$id -gt 1) { return [int64]$id }   # 0/1 = General
    return $null
}

function New-TgMessage([string]$Category, [string]$Text) {
    return [pscustomobject]@{ Category = $Category; Text = $Text }
}

# Trả về $true nếu ít nhất một kênh gửi thành công (hoặc không cấu hình kênh nào).
function Send-Digest($Secrets, [string]$Subject, $TelegramMessages, [string]$EmailHtml) {
    $channels = 0; $ok = 0
    if ($Secrets -and (Test-Configured $Secrets.telegram.botToken) -and (Test-Configured $Secrets.telegram.chatId)) {
        $channels++
        try {
            foreach ($m in $TelegramMessages) {
                Send-Telegram $Secrets $m.Text (Get-TopicId $Secrets $m.Category)
                Start-Sleep -Milliseconds 400
            }
            $ok++; Write-Log "Đã gửi Telegram ($($TelegramMessages.Count) tin nhắn)"
        } catch { Write-Log "LỖI gửi Telegram: $($_.Exception.Message)" }
    }
    if ($Secrets -and (Test-Configured $Secrets.email.smtpServer) -and (Test-Configured $Secrets.email.to)) {
        $channels++
        try { Send-Email $Secrets $Subject $EmailHtml; $ok++; Write-Log 'Đã gửi Email' }
        catch { Write-Log "LỖI gửi Email: $($_.Exception.Message)" }
    }
    if ($channels -eq 0) {
        Write-Log 'Chưa cấu hình Telegram/Email trong secrets.json — chỉ lưu bản tin vào thư mục digests\'
        return $true
    }
    return ($ok -gt 0)
}

# ---------------------------------------------------------------- dựng bản tin

function Get-FirstSentence([string]$Text, [int]$Max) {
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, '^(.{40,}?[.!?])(\s|$)')
    $s = if ($m.Success) { $m.Groups[1].Value } else { $Text }
    if ($Max -gt 0 -and $s.Length -gt $Max) { $s = $s.Substring(0, $Max).TrimEnd() + '…' }
    return $s
}

# "arXiv cs.SE (Kỹ thuật phần mềm)" -> "arXiv cs.SE"
function Get-ShortSource([string]$Name) { return ($Name -replace '\s*\([^)]*\)\s*$', '') }

function Get-Tags($Item, [int]$Max) {
    return (@($Item.Matched | Select-Object -First $Max | ForEach-Object { '#' + ($_ -replace '[^\p{L}\p{N}]+', '_') }) -join ' ')
}

function Get-CategoryIcon($Config, [string]$Category) {
    $icon = $null
    if ($Config.categoryIcons) { $icon = $Config.categoryIcons.$Category }
    if ($icon) { return $icon } else { return '•' }
}

# Gộp các khối thành tin nhắn ≤ 3800 ký tự (Telegram giới hạn 4096)
function Split-Messages([string[]]$Blocks, [int]$Limit = 3800) {
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($b in $Blocks) {
        if ($cur -and ($cur.Length + $b.Length + 2) -gt $Limit) { $out.Add($cur); $cur = '' }
        $cur = if ($cur) { "$cur`n`n$b" } else { $b }
    }
    if ($cur) { $out.Add($cur) }
    return $out.ToArray()
}

function Build-Digest($Config, $Items, $FailedFeeds, [string]$ArchiveName) {
    $now = Get-Date
    $days = @('Chủ Nhật', 'Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy')
    $dateLabel = '{0}, {1}' -f $days[[int]$now.DayOfWeek], $now.ToString('dd/MM/yyyy')
    $title = $Config.digestTitle
    $summaryMax = [int]$Config.summaryMaxChars
    $showSummary = [bool]$Config.showSummary
    $maxTags = if ($Config.maxTags) { [int]$Config.maxTags } else { 3 }
    $line = '━━━━━━━━━━━━━━━━'

    $shown = @($Items | Where-Object { $_.Shown })
    $hidden = $Items.Count - $shown.Count
    $categoryOrder = @($Config.feeds | ForEach-Object { $_.category } | Select-Object -Unique)

    $messages = New-Object System.Collections.Generic.List[object]
    $md = New-Object System.Text.StringBuilder
    $html = New-Object System.Text.StringBuilder

    # ---- Tin nhắn mở đầu: tổng quan theo mục
    $overview = New-Object System.Collections.Generic.List[string]
    foreach ($cat in $categoryOrder) {
        $n = @($shown | Where-Object { $_.Category -eq $cat }).Count
        if ($n -gt 0) { $overview.Add("$(Get-CategoryIcon $Config $cat)  $(Escape-Html $cat): <b>$n</b>") }
    }
    $head = "📰 <b>$(Escape-Html $title)</b>`n<i>$dateLabel</i>`n$line`n" + ($overview -join "`n") + "`n$line`nHôm nay có <b>$($shown.Count)</b> bài nổi bật"
    if ($hidden -gt 0) { $head += ", thêm <b>$hidden</b> bài khác được lưu trong file lưu trữ" }
    $head += '.'
    if ($FailedFeeds.Count -gt 0) { $head += "`n`n⚠️ Nguồn không đọc được hôm nay: " + (Escape-Html ($FailedFeeds -join ', ')) }
    $messages.Add((New-TgMessage '' $head))

    [void]$md.AppendLine("# 📰 $title").AppendLine()
    [void]$md.AppendLine("**$dateLabel** — $($Items.Count) bài khớp từ khóa; $($shown.Count) bài đã gửi lên Telegram (đánh dấu ⭐).").AppendLine()
    if ($FailedFeeds.Count -gt 0) { [void]$md.AppendLine("> ⚠️ Nguồn không đọc được: $($FailedFeeds -join ', ')").AppendLine() }
    [void]$html.Append("<h2>📰 $(Escape-Html $title)</h2><p><i>$dateLabel</i> — $($shown.Count) bài nổi bật</p>")

    foreach ($cat in $categoryOrder) {
        $catAll = @($Items | Where-Object { $_.Category -eq $cat })
        if ($catAll.Count -eq 0) { continue }
        $catShown = @($catAll | Where-Object { $_.Shown })
        $more = $catAll.Count - $catShown.Count
        $icon = Get-CategoryIcon $Config $cat

        # ---- Telegram: mỗi mục một tin nhắn riêng
        if ($catShown.Count -gt 0) {
            $blocks = New-Object System.Collections.Generic.List[string]
            $blocks.Add("$icon <b>$(Escape-Html $cat.ToUpper())</b>  ·  $($catShown.Count) bài`n$line")
            $i = 0
            foreach ($it in $catShown) {
                $i++
                $meta = "<i>$(Escape-Html (Get-ShortSource $it.Source))</i>"
                $tags = Get-Tags $it $maxTags
                if ($tags) { $meta += "  ·  $tags" }
                $b = "<b>$i.</b> <a href=`"$(Escape-Html $it.Link)`">$(Escape-Html $it.Title)</a>`n$meta"
                if ($showSummary -and $it.Summary) { $b += "`n" + (Escape-Html (Get-FirstSentence $it.Summary $summaryMax)) }
                $blocks.Add($b)
            }
            if ($more -gt 0) { $blocks.Add("<i>… và $more bài khác trong mục này (xem file lưu trữ)</i>") }
            foreach ($m in (Split-Messages $blocks.ToArray())) { $messages.Add((New-TgMessage $cat $m)) }
        }

        # ---- File lưu trữ Markdown: ghi ĐẦY ĐỦ mọi bài
        [void]$md.AppendLine("## $icon $cat — $($catAll.Count) bài").AppendLine()
        $i = 0
        foreach ($it in $catAll) {
            $i++
            $star = if ($it.Shown) { '⭐ ' } else { '' }
            $meta = Get-ShortSource $it.Source
            if ($it.Date) { $meta += ' · ' + $it.Date.ToLocalTime().ToString('dd/MM/yyyy') }
            $kw = if ($it.Matched.Count -gt 0) { ' · ' + (($it.Matched | ForEach-Object { "``$_``" }) -join ' ') } else { '' }
            [void]$md.AppendLine("$i. $star**[$($it.Title)]($($it.Link))**  ")
            [void]$md.AppendLine("   _$($meta)_$kw  ")
            if ($it.Summary) {
                $s = $it.Summary
                if ($s.Length -gt 600) { $s = $s.Substring(0, 600).TrimEnd() + '…' }
                [void]$md.AppendLine("   $s")
            }
            [void]$md.AppendLine()
        }

        # ---- Email HTML
        if ($catShown.Count -gt 0) {
            [void]$html.Append("<h3>$icon $(Escape-Html $cat)</h3><ol>")
            foreach ($it in $catShown) {
                [void]$html.Append("<li style='margin-bottom:12px'><a href=`"$(Escape-Html $it.Link)`"><b>$(Escape-Html $it.Title)</b></a><br><small><i>$(Escape-Html (Get-ShortSource $it.Source))</i> &nbsp;$(Escape-Html (Get-Tags $it $maxTags))</small>")
                if ($showSummary -and $it.Summary) { [void]$html.Append("<br><span style='color:#555'>$(Escape-Html (Get-FirstSentence $it.Summary $summaryMax))</span>") }
                [void]$html.Append('</li>')
            }
            [void]$html.Append('</ol>')
            if ($more -gt 0) { [void]$html.Append("<p><i>… và $more bài khác (xem file lưu trữ)</i></p>") }
        }
    }

    # ---- Dòng cuối: chỉ đường tới file lưu trữ
    if ($hidden -gt 0) {
        $footer = "📂 <i>Danh sách đầy đủ $($Items.Count) bài: digests\$ArchiveName</i>"
        # Gắn vào tin nhắn tổng quan (đầu tiên) để dù chia topic vẫn dễ thấy
        if (($messages[0].Text.Length + $footer.Length + 2) -lt 3800) { $messages[0].Text = $messages[0].Text + "`n`n$footer" }
        else { $messages.Add((New-TgMessage '' $footer)) }
        [void]$html.Append("<p>📂 <i>Danh sách đầy đủ $($Items.Count) bài: digests\$(Escape-Html $ArchiveName)</i></p>")
    }

    return [pscustomobject]@{
        Subject  = "$title — $dateLabel"
        Telegram = $messages.ToArray()
        Markdown = $md.ToString()
        Html     = $html.ToString()
    }
}

# ---------------------------------------------------------------- chương trình chính

$cfg = Read-JsonFile $ConfigPath
$secrets = $null
if (Test-Path $SecretsPath) { $secrets = Read-JsonFile $SecretsPath }

if ($TestSend) {
    $time = Get-Date -Format 'HH:mm dd/MM/yyyy'
    $msg = "<b>AI Feed Monitor</b>`nKết nối thành công lúc $time."
    # Gửi 1 tin thử vào mỗi topic đã khai báo để kiểm tra đúng chỗ chưa
    $tests = New-Object System.Collections.Generic.List[object]
    $tests.Add((New-TgMessage '' "$msg`nĐây là nơi nhận <b>tin nhắn tổng quan</b>."))
    $categories = @($cfg.feeds | ForEach-Object { $_.category } | Select-Object -Unique)
    if ($secrets -and $secrets.telegram.topics) {
        foreach ($cat in $categories) {
            if ($secrets.telegram.topics.$cat) {
                $tests.Add((New-TgMessage $cat "✅ Topic này sẽ nhận mục <b>$(Escape-Html $cat)</b>."))
            }
        }
    }
    $ok = Send-Digest $secrets 'AI Feed Monitor — tin nhắn thử' $tests.ToArray() ($msg -replace "`n", '<br>')
    if ($ok) { Write-Log 'Gửi thử xong.' } else { Write-Log 'Gửi thử THẤT BẠI — xem lỗi ở trên.'; exit 1 }
    exit 0
}

# Trạng thái: các bài đã xem (key -> ngày)
$seen = @{}
if ($Resend) {
    Write-Log "Resend: bỏ qua lịch sử, gửi lại mọi bài trong $($cfg.lookbackDays) ngày gần nhất."
}
elseif (Test-Path $StatePath) {
    $obj = Read-JsonFile $StatePath
    foreach ($p in $obj.PSObject.Properties) { $seen[$p.Name] = $p.Value }
}
$todayStr = Get-Date -Format 'yyyy-MM-dd'
$cutoff = (Get-Date).ToUniversalTime().AddDays(-[double]$cfg.lookbackDays)
$globalPattern = Get-KeywordPattern $cfg.keywords

$allItems = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[string]

foreach ($feed in $cfg.feeds) {
    if ($feed.enabled -eq $false) { continue }
    try {
        $items = @(Get-FeedItems $feed)
        if ($Check) { Write-Host ('[OK]   {0,-34} {1,4} mục' -f $feed.name, $items.Count) -ForegroundColor Green; continue }

        $pattern = if ($feed.keywords) { Get-KeywordPattern $feed.keywords } else { $globalPattern }
        $max = if ($feed.max) { [int]$feed.max } else { [int]$cfg.maxItemsPerFeed }

        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($it in $items) {
            if (-not $it.Id -or -not $it.Title) { continue }
            $key = Get-Key $it.Id
            # Cùng một bài có thể xuất hiện ở nhiều nguồn (vd. arXiv và Hugging Face) với link khác nhau
            $titleKey = Get-Key ('title:' + ([regex]::Replace($it.Title.ToLowerInvariant(), '[^\p{L}\p{N}]+', '')))
            if ($seen.ContainsKey($key) -or $seen.ContainsKey($titleKey)) { continue }
            $seen[$key] = $todayStr
            $seen[$titleKey] = $todayStr
            if ($Init) { continue }
            if ($it.Date -and $it.Date.UtcDateTime -lt $cutoff) { continue }
            if ($cfg.arxivSkipRevisions -and $it.Announce -like 'replace*') { continue }

            $it.Matched = @(Get-MatchedKeywords $it $pattern)
            if ($feed.filter -and $it.Matched.Count -eq 0) { continue }

            # Điểm nổi bật: mỗi từ khóa khớp +1, từ khóa nằm ngay trong TIÊU ĐỀ thêm +2,
            # cộng "weight" của nguồn (nếu có) để ưu tiên nguồn bạn quan tâm hơn.
            $titleHits = 0
            if ($pattern) { $titleHits = @([regex]::Matches($it.Title, $pattern) | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Select-Object -Unique).Count }
            $weight = if ($feed.weight) { [double]$feed.weight } else { 0 }
            $it | Add-Member -NotePropertyName Score -NotePropertyValue ($it.Matched.Count + 2 * $titleHits + $weight) -Force
            $allItems.Add($it)
        }
    }
    catch {
        $failed.Add($feed.name)
        if ($Check) { Write-Host ('[LỖI]  {0,-34} {1}' -f $feed.name, $_.Exception.Message) -ForegroundColor Red }
        else { Write-Log "LỖI nguồn '$($feed.name)': $($_.Exception.Message)" }
    }
}

if ($Check) { exit 0 }

function Save-State {
    $retention = (Get-Date).AddDays(-[double]$cfg.stateRetentionDays)
    $out = [ordered]@{}
    foreach ($k in $seen.Keys) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$seen[$k], 'yyyy-MM-dd', $null, 'None', [ref]$d) -and $d -lt $retention) { continue }
        $out[$k] = $seen[$k]
    }
    $dir = Split-Path $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    ($out | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8
}

if ($Init) {
    Save-State
    Write-Log "Khởi tạo xong: đã đánh dấu $($seen.Count) bài là đã xem. Từ lần chạy sau chỉ nhận bài mới."
    exit 0
}

# ---- Chọn bài nổi bật theo từng MỤC (không phải từng nguồn)
# Mỗi mục: tối đa maxPerCategory bài; bài phải đạt minScore, nhưng luôn có ít nhất minPerCategory bài (nếu có);
# mỗi nguồn tối đa maxPerSourceInCategory bài để mục không bị một nguồn chiếm hết.
$maxCat  = if ($cfg.maxPerCategory) { [int]$cfg.maxPerCategory } else { 5 }
$minCat  = if ($cfg.minPerCategory) { [int]$cfg.minPerCategory } else { 2 }
$minScr  = if ($cfg.minScore) { [double]$cfg.minScore } else { 0 }
$maxSrc  = if ($cfg.maxPerSourceInCategory) { [int]$cfg.maxPerSourceInCategory } else { 2 }
$byDate  = @{ Expression = { if ($_.Date) { $_.Date.UtcDateTime } else { [datetime]::MinValue } }; Descending = $true }

$ordered = New-Object System.Collections.Generic.List[object]
foreach ($cat in @($cfg.feeds | ForEach-Object { $_.category } | Select-Object -Unique)) {
    $ranked = @($allItems | Where-Object { $_.Category -eq $cat } |
        Sort-Object @{ Expression = { $_.Score }; Descending = $true }, $byDate)
    $perSrc = @{}; $picked = 0
    foreach ($it in $ranked) {
        if ($picked -ge $maxCat) { break }
        if ($picked -ge $minCat -and $it.Score -lt $minScr) { break }
        if ([int]$perSrc[$it.Source] -ge $maxSrc) { continue }
        $it.Shown = $true; $perSrc[$it.Source] = 1 + [int]$perSrc[$it.Source]; $picked++
    }
    # Chưa đủ tối thiểu (vì giới hạn mỗi nguồn) -> lấy thêm bài điểm cao kế tiếp
    foreach ($it in $ranked) {
        if ($picked -ge $minCat) { break }
        if (-not $it.Shown) { $it.Shown = $true; $picked++ }
    }
    # Bài nổi bật lên trước (theo điểm), phần còn lại theo sau -> dùng cho cả Telegram và file lưu trữ
    foreach ($it in @($ranked | Where-Object { $_.Shown })) { $ordered.Add($it) }
    foreach ($it in @($ranked | Where-Object { -not $_.Shown })) { $ordered.Add($it) }
}
$allItems = $ordered

$shownCount = @($allItems | Where-Object { $_.Shown }).Count
Write-Log "Tìm thấy $($allItems.Count) bài khớp ($shownCount bài nổi bật); $($failed.Count) nguồn lỗi."

if ($allItems.Count -eq 0 -and -not $cfg.sendWhenEmpty) {
    if (-not $DryRun) { Save-State }
    Write-Log 'Không có bài mới — không gửi bản tin.'
    exit 0
}

$archiveName = "$(Get-Date -Format 'yyyy-MM-dd_HHmm').md"
$digest = Build-Digest $cfg $allItems $failed $archiveName

if ($DryRun) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    Write-Host ''
    $n = 0
    foreach ($m in $digest.Telegram) {
        $n++
        $topic = if ($secrets) { Get-TopicId $secrets $m.Category } else { $null }
        $where = if ($topic) { "topic #$topic" } else { 'General' }
        Write-Host "┌── Tin nhắn $n/$($digest.Telegram.Count)  →  $where" -ForegroundColor DarkGray
        Write-Host ([System.Net.WebUtility]::HtmlDecode([regex]::Replace($m.Text, '<[^>]+>', '')))
        Write-Host ''
    }
    Write-Log "DryRun: $($digest.Telegram.Count) tin nhắn Telegram sẽ được gửi. Không gửi, không lưu trạng thái."
    exit 0
}

if (-not (Test-Path $DigestDir)) { New-Item -ItemType Directory -Path $DigestDir | Out-Null }
$digest.Markdown | Set-Content -Path (Join-Path $DigestDir $archiveName) -Encoding UTF8
Write-Log "Đã lưu danh sách đầy đủ: digests\$archiveName"

if (Send-Digest $secrets $digest.Subject $digest.Telegram $digest.Html) {
    Save-State
} else {
    Write-Log 'Mọi kênh gửi đều lỗi — KHÔNG lưu trạng thái để lần sau gửi lại.'
    exit 1
}
