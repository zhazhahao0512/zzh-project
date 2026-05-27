[CmdletBinding()]
param(
    [ValidateSet("sync-links", "scan", "prepare", "generate", "generate-images", "inspect", "task-status", "list-runs", "doctor", "mark-superseded", "validate", "mark-failed")]
    [string]$Command = "scan",

    [string]$Config = "",

    [string]$Product = "",

    [string]$RunDir = "",

    [string]$Message = "",

    [string]$File = "",

    [switch]$DryRun,

    [switch]$NoLinkSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}
$Script:RepoRoot = Split-Path $Script:ScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Join-Path $Script:RepoRoot "etsy-picture.config.json"
}

$FieldMap = [ordered]@{
    "product name"       = "productName"
    "category"           = "category"
    "core description"   = "coreDescription"
    "materials / colors" = "materialsColors"
    "materials/colors"   = "materialsColors"
    "materials colors"   = "materialsColors"
    "target customer"    = "targetCustomer"
    "style / mood"       = "styleMood"
    "style/mood"         = "styleMood"
    "style mood"         = "styleMood"
    "intro text"         = "introText"
    "must include"       = "mustInclude"
    "avoid"              = "avoid"
    "extra notes"        = "extraNotes"
}

$BriefKeys = @(
    "productName",
    "category",
    "coreDescription",
    "materialsColors",
    "targetCustomer",
    "styleMood",
    "introText",
    "mustInclude",
    "avoid",
    "extraNotes"
)

$BriefLabels = [ordered]@{
    productName       = "Product Name"
    category          = "Category"
    coreDescription   = "Core Description"
    materialsColors   = "Materials / Colors"
    targetCustomer    = "Target Customer"
    styleMood         = "Style / Mood"
    introText         = "Intro Text"
    mustInclude       = "Must Include"
    avoid             = "Avoid"
    extraNotes        = "Extra Notes"
}

$InferredContextLabels = [ordered]@{
    referenceImageSummary = "Reference Image Summary"
    visualIdentity        = "Visual Identity Lock"
    consistencyRules      = "Set Consistency Rules"
    uncertaintyNotes      = "Uncertainty Notes"
    backgroundStrategy    = "Background Strategy"
    mainImageDirection    = "01 Main Image Direction"
    sceneHomeDirection    = "02 Home Scene Direction"
    sceneUseDirection     = "03 In-Use Scene Direction"
    sceneGiftDirection    = "04 Gift Scene Direction"
    sceneDetailDirection  = "05 Detail Scene Direction"
    modelImageDirection   = "06 Model Image Direction"
    introImageDirection   = "07 Intro Image Direction"
}

$SourceImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff")

function Write-Json {
    param([Parameter(ValueFromPipeline = $true)]$Value)
    process {
        $Value | ConvertTo-Json -Depth 50
    }
}

function Format-ExceptionSummary {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return ""
    }

    $exception = $ErrorRecord.Exception
    if ($null -eq $exception) {
        return ([string]$ErrorRecord).Trim()
    }

    $messages = New-Object "System.Collections.Generic.List[string]"
    $messages.Add($exception.Message)
    $inner = $exception.InnerException
    while ($null -ne $inner) {
        if (-not [string]::IsNullOrWhiteSpace($inner.Message)) {
            $messages.Add($inner.Message)
        }
        $inner = $inner.InnerException
    }

    return (($messages.ToArray() | Select-Object -Unique) -join " | ")
}

function Get-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        $DefaultValue
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function Set-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        $Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    else {
        $property.Value = $Value
    }
}

function Resolve-WorkspacePath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-ConfigObject {
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        throw "Config file not found: $Config"
    }

    $repoRoot = $Script:RepoRoot
    $raw = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
    $source = $raw | ConvertFrom-Json
    $inputRoot = Resolve-WorkspacePath (Get-ObjectValue $source "inputRoot" "") $repoRoot
    $linkTableFileRaw = Get-ObjectValue $source "linkTableFile" ""
    $linkTableFile = Resolve-WorkspacePath $linkTableFileRaw $repoRoot

    if ([string]::IsNullOrWhiteSpace($inputRoot)) {
        throw "Config inputRoot is empty. Set inputRoot in $Config to the external product folder before running automation."
    }

    if (-not (Test-Path -LiteralPath $inputRoot -PathType Container)) {
        if ([string]::IsNullOrWhiteSpace($linkTableFile)) {
            throw "Input root not found or not readable: $inputRoot"
        }

        New-Item -ItemType Directory -Force -Path $inputRoot | Out-Null
    }

    $outputRootMode = Get-ObjectValue $source "outputRootMode" "sibling"
    if ($outputRootMode -ne "sibling") {
        throw "Unsupported outputRootMode '$outputRootMode'. This v1 implementation supports only 'sibling'."
    }

    $parent = Split-Path -Parent $inputRoot
    $explicitOutputRoot = Get-ObjectValue $source "outputRoot" ""
    if ([string]::IsNullOrWhiteSpace($explicitOutputRoot)) {
        $outputRoot = Join-Path $parent "outputs"
    }
    else {
        $outputRoot = Resolve-WorkspacePath $explicitOutputRoot $repoRoot
    }

    $imageBackend = Get-ObjectValue $source "imageBackend" "codex-image2"
    $codexImageModel = Get-ObjectValue $source "codexImageModel" "image2"
    $productIdentityMode = Get-ObjectValue $source "productIdentityMode" "reference-strict"
    $requireImageReference = [bool](Get-ObjectValue $source "requireImageReference" $true)
    $allowReferenceLimitedDrafts = [bool](Get-ObjectValue $source "allowReferenceLimitedDrafts" $true)
    $stopOnIdentityDrift = [bool](Get-ObjectValue $source "stopOnIdentityDrift" $true)
    $continueAfterImageFailure = [bool](Get-ObjectValue $source "continueAfterImageFailure" $true)
    $sourcePreserveOutputSize = [int](Get-ObjectValue $source "sourcePreserveOutputSize" 1600)
    if ($codexImageModel -ne "image2") {
        throw "codexImageModel must be image2. Current value: $codexImageModel"
    }

    if (@("codex-image2", "mock", "manual") -notcontains $imageBackend) {
        throw "Unsupported imageBackend '$imageBackend'. Use codex-image2 for production."
    }

    if (@("reference-strict", "source-preserve", "ai-redraw") -notcontains $productIdentityMode) {
        throw "Unsupported productIdentityMode '$productIdentityMode'. Use reference-strict for strict AI generation with source similarity checks."
    }

    if ($sourcePreserveOutputSize -lt 1024) {
        $sourcePreserveOutputSize = 1024
    }

    [pscustomobject]@{
        RepoRoot       = $repoRoot
        ConfigPath     = [System.IO.Path]::GetFullPath($Config)
        InputRoot      = $inputRoot
        OutputRoot     = $outputRoot
        OutputRootMode = $outputRootMode
        BriefFile      = Get-ObjectValue $source "briefFile" "product.txt"
        GeneratedBriefFile = Get-ObjectValue $source "generatedBriefFile" "product.inferred.json"
        PromptSchemaVersion = Get-ObjectValue $source "promptSchemaVersion" "direction-v2"
        CompleteMarkerFile = Get-ObjectValue $source "completeMarkerFile" "automation.done.txt"
        ReadyMarker    = Get-ObjectValue $source "readyMarker" "ready.txt"
        LinkTableFile  = $linkTableFile
        LinkSyncBeforeScan = [bool](Get-ObjectValue $source "linkSyncBeforeScan" $false)
        LinkImageLimit = [int](Get-ObjectValue $source "linkImageLimit" 8)
        LinkMinImageSize = [int](Get-ObjectValue $source "linkMinImageSize" 600)
        LinkDownloadTimeoutSeconds = [int](Get-ObjectValue $source "linkDownloadTimeoutSeconds" 30)
        Language       = Get-ObjectValue $source "language" "en"
        ScanCadence    = Get-ObjectValue $source "scanCadence" "hourly"
        PendingStaleHours = [double](Get-ObjectValue $source "pendingStaleHours" 24)
        ImageMinSize   = [int](Get-ObjectValue $source "imageMinSize" 1024)
        RequirePngImages = [bool](Get-ObjectValue $source "requirePngImages" $true)
        LockStaleMinutes = [double](Get-ObjectValue $source "lockStaleMinutes" 120)
        ImageBackend   = $imageBackend
        CodexImageModel = $codexImageModel
        ProductIdentityMode = $productIdentityMode
        RequireImageReference = $requireImageReference
        AllowReferenceLimitedDrafts = $allowReferenceLimitedDrafts
        StopOnIdentityDrift = $stopOnIdentityDrift
        ContinueAfterImageFailure = $continueAfterImageFailure
        SourcePreserveOutputSize = $sourcePreserveOutputSize
    }
}

function Get-SafeName {
    param([string]$Name)

    $safe = [regex]::Replace($Name, '[<>:"/\\|?*\x00-\x1F]', "_").Trim(" .")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "product"
    }
    return $safe
}

function Get-TextHash {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SourceImages {
    param([string]$ProductDir)

    $images = New-Object "System.Collections.Generic.List[object]"
    foreach ($file in (Get-ChildItem -LiteralPath $ProductDir -File | Sort-Object Name)) {
        $extension = $file.Extension.ToLowerInvariant()
        if ($SourceImageExtensions -notcontains $extension) {
            continue
        }

        $images.Add([pscustomobject]@{
            name             = $file.Name
            path             = $file.FullName
            extension        = $extension
            bytes            = $file.Length
            lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
        })
    }

    return @($images.ToArray())
}

function Get-LinkRowValue {
    param(
        [object]$Row,
        [string[]]$Names,
        [string]$DefaultValue = ""
    )

    foreach ($name in $Names) {
        if ($null -eq $Row) {
            continue
        }

        $property = $Row.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = ([string]$property.Value).Trim()
            if ($value.Length -gt 0) {
                return $value
            }
        }
    }

    return $DefaultValue
}

function Test-LinkRowEnabled {
    param([object]$Row)

    $value = (Get-LinkRowValue $Row @("enabled", "enable", "active") "true").ToLowerInvariant()
    if (@("false", "no", "n", "0", "disabled", "off") -contains $value) {
        return $false
    }

    return $true
}

function Get-1688OfferId {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    if ($Url -match '(?i)/offer/([0-9]+)') {
        return $Matches[1]
    }

    if ($Url -match '(?i)(?:offerId|offer_id|id)=([0-9]+)') {
        return $Matches[1]
    }

    return ""
}

function Get-LinkFetchUrls {
    param([string]$Url)

    $urls = New-Object "System.Collections.Generic.List[string]"
    $offerId = Get-1688OfferId $Url
    if (-not [string]::IsNullOrWhiteSpace($offerId)) {
        $urls.Add("https://m.1688.com/offer/$offerId.html")
        $urls.Add("https://detail.1688.com/offer/$offerId.html")
    }

    if (-not [string]::IsNullOrWhiteSpace($Url) -and -not $urls.Contains($Url)) {
        $urls.Add($Url)
    }

    return @($urls.ToArray())
}

function Get-ShortTextHash {
    param([string]$Text)

    return (Get-TextHash $Text).Substring(0, 12)
}

function Get-LinkProductFolderName {
    param(
        [object]$Row,
        [string]$Url
    )

    $explicitId = Get-LinkRowValue $Row @("productId", "id", "sku")
    if (-not [string]::IsNullOrWhiteSpace($explicitId)) {
        return Get-SafeName $explicitId
    }

    $productName = Get-LinkRowValue $Row @("productName", "name", "title")
    if (-not [string]::IsNullOrWhiteSpace($productName)) {
        return Get-SafeName $productName
    }

    $offerId = Get-1688OfferId $Url
    if (-not [string]::IsNullOrWhiteSpace($offerId)) {
        return "1688-$offerId"
    }

    return "1688-$(Get-ShortTextHash $Url)"
}

function ConvertFrom-LinkEscapedText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $value = $Text -replace '\\u002[fF]', '/'
    $value = $value -replace '\\/', '/'
    $value = $value -replace '&amp;', '&'
    $value = $value -replace '&quot;', '"'
    $value = $value -replace '&#39;', "'"
    return $value
}

function Resolve-LocalPathFromLink {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    if (Test-Path -LiteralPath $Url -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($Url)
    }

    if ($Url -match '^(?i:file:)') {
        try {
            return ([System.Uri]$Url).LocalPath
        }
        catch {
            return ""
        }
    }

    return ""
}

function ConvertTo-AbsoluteLinkUrl {
    param(
        [string]$Url,
        [string]$BaseUrl
    )

    $clean = (ConvertFrom-LinkEscapedText $Url).Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return ""
    }

    if ($clean.StartsWith("///")) {
        return "file:$clean"
    }

    if ($clean.StartsWith("//")) {
        return "https:$clean"
    }

    if ($clean -match '^(?i:https?:|file:)') {
        return $clean
    }

    if ([System.IO.Path]::IsPathRooted($clean)) {
        return ([System.Uri]([System.IO.Path]::GetFullPath($clean))).AbsoluteUri
    }

    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        try {
            $baseUri = if (Test-Path -LiteralPath $BaseUrl -PathType Leaf) {
                [System.Uri]([System.IO.Path]::GetFullPath($BaseUrl))
            }
            else {
                [System.Uri]$BaseUrl
            }
            return ([System.Uri]::new($baseUri, $clean)).AbsoluteUri
        }
        catch {
            return $clean
        }
    }

    return $clean
}

function Normalize-ImageUrl {
    param(
        [string]$Url,
        [string]$BaseUrl
    )

    $absolute = ConvertTo-AbsoluteLinkUrl $Url $BaseUrl
    if ([string]::IsNullOrWhiteSpace($absolute)) {
        return ""
    }

    try {
        $absolute = [System.Uri]::UnescapeDataString($absolute)
    }
    catch {
    }

    $clean = $absolute -replace '(?i)(\.(?:jpg|jpeg|png|webp))_[^?&"''<>\s]*', '$1'
    $clean = $clean -replace '(?i)\.(?:\d{2,4}x\d{2,4}|search|summ|thumb|small|medium)\.(jpg|jpeg|png|webp)(?=($|\?))', '.$1'
    return $clean
}

function Get-ImageUrlScore {
    param([string]$Url)

    $lower = $Url.ToLowerInvariant()
    $score = 0
    if ($lower -match 'alicdn|cbu01|imgextra') { $score += 20 }
    if ($lower -match '/img/ibank/|/bao/uploaded/') { $score += 20 }
    if ($lower -match 'offer|detail|main|image') { $score += 5 }
    if ($lower -match 'logo|icon|sprite|avatar|barcode|qrcode|qr') { $score -= 30 }
    if ($lower -match '_[0-9]{2,4}x[0-9]{2,4}') { $score -= 5 }
    return $score
}

function Get-ImageCandidatesFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $normalized = ConvertFrom-LinkEscapedText $Html
    $patterns = @(
        '(?i)(?:https?:)?//[^"''<>\s]+?\.(?:jpg|jpeg|png|webp)(?:\?[^"''<>\s]*)?',
        '(?i)file:///[^\s"''<>]+?\.(?:jpg|jpeg|png|webp)(?:\?[^"''<>\s]*)?'
    )
    $seen = @{}
    $order = 0
    $items = New-Object "System.Collections.Generic.List[object]"

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($normalized, $pattern)) {
            $url = Normalize-ImageUrl $match.Value $BaseUrl
            if ([string]::IsNullOrWhiteSpace($url) -or $seen.ContainsKey($url)) {
                continue
            }

            $seen[$url] = $true
            $order += 1
            $items.Add([pscustomobject]@{
                url   = $url
                score = Get-ImageUrlScore $url
                order = $order
            })
        }
    }

    $orderedItems = @($items.ToArray() | Sort-Object order)
    $productItems = @($orderedItems | Where-Object { $_.url -match '(?i)/(?:img/ibank|bao/uploaded)/' })
    if ($productItems.Count -gt 0) {
        $orderedItems = $productItems
    }
    else {
        $orderedItems = @($orderedItems | Where-Object { $_.url -notmatch '(?i)/(?:tps|cms/upload)/' })
    }

    return @($orderedItems | ForEach-Object { $_.url })
}

function Read-LinkTextResource {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $localPath = Resolve-LocalPathFromLink $Url
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return [pscustomobject]@{
            content    = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8
            finalUrl   = ([System.Uri]([System.IO.Path]::GetFullPath($localPath))).AbsoluteUri
            statusCode = 0
        }
    }

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $isMobile1688 = $Url -match '(?i)://m\.1688\.com/'
    $userAgent = if ($isMobile1688) {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
    else {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
    }

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -Headers @{
        "User-Agent"      = $userAgent
        "Accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "Accept-Language" = "zh-CN,zh;q=0.9,en;q=0.8"
    }

    return [pscustomobject]@{
        content    = [string]$response.Content
        finalUrl   = $Url
        statusCode = $response.StatusCode
    }
}

function Read-LinkBytesResource {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $localPath = Resolve-LocalPathFromLink $Url
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return [System.IO.File]::ReadAllBytes($localPath)
    }

    if ($Url -notmatch '^(?i:https?:)') {
        throw "Unsupported image URL: $Url"
    }

    $tmpDir = Join-Path $Script:RepoRoot ".tmp\link-downloads"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpPath = Join-Path $tmpDir ("download-" + [System.Guid]::NewGuid().ToString("n") + ".bin")
    try {
        Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -OutFile $tmpPath -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
            "Referer"    = "https://detail.1688.com/"
            "Accept"     = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        }
        return [System.IO.File]::ReadAllBytes($tmpPath)
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath -PathType Leaf) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ImageExtensionFromUrl {
    param([string]$Url)

    $withoutQuery = ($Url -split '\?')[0]
    if ($withoutQuery -match '(?i)\.(jpg|jpeg|png|webp)$') {
        $extension = "." + $Matches[1].ToLowerInvariant()
        if ($extension -eq ".jpeg") {
            return ".jpg"
        }
        return $extension
    }

    return ".jpg"
}

function Get-BytesHash {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ImageInfoFromBytes {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -le 0) {
        return [pscustomobject]@{
            readable = $false
            width    = 0
            height   = 0
            error    = "empty image bytes"
        }
    }

    $stream = $null
    $image = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $stream = [System.IO.MemoryStream]::new($Bytes)
        $image = [System.Drawing.Image]::FromStream($stream)
        return [pscustomobject]@{
            readable = $true
            width    = $image.Width
            height   = $image.Height
            error    = ""
        }
    }
    catch {
        return [pscustomobject]@{
            readable = $false
            width    = 0
            height   = 0
            error    = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Write-BytesIfChanged {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllBytes($Path)
        if ((Get-BytesHash $existing) -eq (Get-BytesHash $Bytes)) {
            return $false
        }
    }

    [System.IO.File]::WriteAllBytes($Path, $Bytes)
    return $true
}

function Write-TextIfChanged {
    param(
        [string]$Path,
        [string]$Text
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($existing -eq $Text) {
            return $false
        }
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
    return $true
}

function New-LinkProductBriefText {
    param(
        [object]$Row,
        [string]$FolderName,
        [string]$Url
    )

    $productName = Get-LinkRowValue $Row @("productName", "name", "title") $FolderName
    $extraNotes = Get-LinkRowValue $Row @("extraNotes", "notes")
    if ([string]::IsNullOrWhiteSpace($extraNotes)) {
        $extraNotes = "Source 1688 URL: $Url"
    }
    else {
        $extraNotes = "$extraNotes`nSource 1688 URL: $Url"
    }

    $lines = @(
        "Product Name: $productName",
        "Category: $(Get-LinkRowValue $Row @("category"))",
        "Core Description: $(Get-LinkRowValue $Row @("coreDescription", "description"))",
        "Materials / Colors: $(Get-LinkRowValue $Row @("materialsColors", "materials", "colors"))",
        "Target Customer: $(Get-LinkRowValue $Row @("targetCustomer"))",
        "Style / Mood: $(Get-LinkRowValue $Row @("styleMood", "style"))",
        "Intro Text: $(Get-LinkRowValue $Row @("introText") $productName)",
        "Must Include: $(Get-LinkRowValue $Row @("mustInclude"))",
        "Avoid: $(Get-LinkRowValue $Row @("avoid"))",
        "Extra Notes: $extraNotes"
    )

    return (($lines | ForEach-Object { $_ }) -join "`r`n") + "`r`n"
}

function Test-LinkProductAlreadySynced {
    param(
        [object]$Cfg,
        [string]$ProductDir,
        [string]$Url
    )

    if (-not (Test-Path -LiteralPath $ProductDir -PathType Container)) {
        return $false
    }

    $sourceImages = @(Get-SourceImages $ProductDir)
    if ($sourceImages.Count -eq 0) {
        return $false
    }

    $minImageSize = [int](Get-ObjectValue $Cfg "LinkMinImageSize" 600)
    if ($minImageSize -gt 0) {
        foreach ($sourceImage in $sourceImages) {
            $info = Get-ImageInfo $sourceImage.path
            $width = [int](Get-ObjectValue $info "width" 0)
            $height = [int](Get-ObjectValue $info "height" 0)
            if ($width -lt $minImageSize -or $height -lt $minImageSize) {
                return $false
            }
        }
    }

    $metadataPath = Join-Path $ProductDir "source.1688.json"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $false
    }

    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $metadataUrl = Get-ObjectValue $metadata "productUrl" ""
        foreach ($image in @(Get-ObjectValue $metadata "downloadedImages" @())) {
            $fileName = Get-ObjectValue $image "file" ""
            if (-not [string]::IsNullOrWhiteSpace($fileName) -and -not (Test-Path -LiteralPath (Join-Path $ProductDir $fileName) -PathType Leaf)) {
                continue
            }

            $sourceUrl = Get-ObjectValue $image "sourceUrl" ""
            if (-not [string]::IsNullOrWhiteSpace($sourceUrl) -and $sourceUrl -notmatch '(?i)/(?:img/ibank|bao/uploaded)/') {
                return $false
            }
        }

        return ($metadataUrl -eq $Url)
    }
    catch {
        return $false
    }
}

function Get-UsableLinkSourceImages {
    param(
        [object]$Cfg,
        [string]$ProductDir
    )

    if (-not (Test-Path -LiteralPath $ProductDir -PathType Container)) {
        return @()
    }

    $metadataByFile = @{}
    $metadataPath = Join-Path $ProductDir "source.1688.json"
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($image in @(Get-ObjectValue $metadata "downloadedImages" @())) {
                $fileName = Get-ObjectValue $image "file" ""
                if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                    $metadataByFile[$fileName] = Get-ObjectValue $image "sourceUrl" ""
                }
            }
        }
        catch {
        }
    }

    $minImageSize = [int](Get-ObjectValue $Cfg "LinkMinImageSize" 600)
    $usable = New-Object "System.Collections.Generic.List[object]"
    foreach ($sourceImage in @(Get-SourceImages $ProductDir)) {
        $sourceUrl = ""
        if ($metadataByFile.ContainsKey($sourceImage.name)) {
            $sourceUrl = $metadataByFile[$sourceImage.name]
        }

        if (-not [string]::IsNullOrWhiteSpace($sourceUrl) -and $sourceUrl -notmatch '(?i)/(?:img/ibank|bao/uploaded)/') {
            continue
        }

        $info = Get-ImageInfo $sourceImage.path
        $width = [int](Get-ObjectValue $info "width" 0)
        $height = [int](Get-ObjectValue $info "height" 0)
        if ($minImageSize -gt 0 -and ($width -lt $minImageSize -or $height -lt $minImageSize)) {
            continue
        }

        $usable.Add([pscustomobject]@{
            name      = $sourceImage.name
            path      = $sourceImage.path
            sourceUrl = $sourceUrl
            width     = $width
            height    = $height
            bytes     = $sourceImage.bytes
        })
    }

    return @($usable.ToArray())
}

function Remove-UnusableLinkSourceImages {
    param(
        [string]$ProductDir,
        [object[]]$UsableImages
    )

    $keep = @{}
    foreach ($image in @($UsableImages)) {
        $keep[$image.path] = $true
    }

    foreach ($sourceImage in @(Get-SourceImages $ProductDir)) {
        if (-not $keep.ContainsKey($sourceImage.path)) {
            Remove-Item -LiteralPath $sourceImage.path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LinkSyncCore {
    param([object]$Cfg)

    $tablePath = Get-ObjectValue $Cfg "LinkTableFile" ""
    if ([string]::IsNullOrWhiteSpace($tablePath)) {
        return [pscustomobject]@{
            status  = "disabled"
            message = "No linkTableFile is configured."
        }
    }

    if (-not (Test-Path -LiteralPath $tablePath -PathType Leaf)) {
        return [pscustomobject]@{
            status = "needs_attention"
            table  = $tablePath
            errors = @("Link table file not found: $tablePath")
            rows   = @()
        }
    }

    $rows = @(Import-Csv -LiteralPath $tablePath -Encoding UTF8)
    $results = New-Object "System.Collections.Generic.List[object]"
    $errors = New-Object "System.Collections.Generic.List[string]"
    $rowNumber = 1

    foreach ($row in $rows) {
        $rowNumber += 1
        $url = Get-LinkRowValue $row @("productUrl", "url", "link")
        if (-not (Test-LinkRowEnabled $row)) {
            $results.Add([pscustomobject]@{
                rowNumber = $rowNumber
                status    = "skipped"
                reason    = "disabled"
                url       = $url
            })
            continue
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            $results.Add([pscustomobject]@{
                rowNumber = $rowNumber
                status    = "skipped"
                reason    = "blank_product_url"
            })
            continue
        }

        $folderName = Get-LinkProductFolderName $row $url
        $productDir = Join-Path $Cfg.InputRoot $folderName
        $downloaded = New-Object "System.Collections.Generic.List[object]"
        $rowErrors = New-Object "System.Collections.Generic.List[string]"

        try {
            if (Test-LinkProductAlreadySynced $Cfg $productDir $url) {
                $sourceImages = @(Get-SourceImages $productDir)
                $briefText = New-LinkProductBriefText $row $folderName $url
                $briefChanged = $false
                if (-not $DryRun) {
                    $briefChanged = Write-TextIfChanged (Join-Path $productDir $Cfg.BriefFile) $briefText
                    "" | Set-Content -LiteralPath (Join-Path $productDir $Cfg.ReadyMarker) -Encoding UTF8
                }

                $results.Add([pscustomobject]@{
                    rowNumber       = $rowNumber
                    status          = "synced"
                    reason          = "existing_local_images"
                    dryRun          = [bool]$DryRun
                    productName     = $folderName
                    productPath     = $productDir
                    url             = $url
                    candidateCount  = 0
                    downloadedCount = 0
                    existingSourceImageCount = $sourceImages.Count
                    briefChanged    = $briefChanged
                    metadataChanged = $false
                    errors          = @()
                })
                continue
            }

            $page = $null
            $candidates = @()
            $pageErrors = New-Object "System.Collections.Generic.List[string]"
            foreach ($fetchUrl in @(Get-LinkFetchUrls $url)) {
                try {
                    $page = Read-LinkTextResource $fetchUrl $Cfg.LinkDownloadTimeoutSeconds
                    $candidates = @(Get-ImageCandidatesFromHtml $page.content $page.finalUrl)
                    if ($candidates.Count -gt 0) {
                        break
                    }

                    $pageErrors.Add("No image URLs found at $fetchUrl")
                }
                catch {
                    $pageErrors.Add("Page fetch failed: $fetchUrl - $(Format-ExceptionSummary $_)")
                }
            }

            if ($candidates.Count -eq 0) {
                $usableExisting = @(Get-UsableLinkSourceImages $Cfg $productDir)
                if ($usableExisting.Count -gt 0) {
                    $briefText = New-LinkProductBriefText $row $folderName $url
                    $briefChanged = $false
                    if (-not $DryRun) {
                        Remove-UnusableLinkSourceImages $productDir $usableExisting
                        $briefChanged = Write-TextIfChanged (Join-Path $productDir $Cfg.BriefFile) $briefText
                        "" | Set-Content -LiteralPath (Join-Path $productDir $Cfg.ReadyMarker) -Encoding UTF8
                    }

                    $results.Add([pscustomobject]@{
                        rowNumber       = $rowNumber
                        status          = "synced"
                        reason          = "existing_product_images_after_page_unavailable"
                        dryRun          = [bool]$DryRun
                        productName     = $folderName
                        productPath     = $productDir
                        url             = $url
                        candidateCount  = 0
                        downloadedCount = 0
                        existingSourceImageCount = $usableExisting.Count
                        briefChanged    = $briefChanged
                        metadataChanged = $false
                        errors          = $pageErrors.ToArray()
                    })
                    continue
                }

                throw "No product image URLs were found on the linked page. $($pageErrors.ToArray() -join ' ; ')"
            }

            if (-not $DryRun) {
                New-Item -ItemType Directory -Force -Path $productDir | Out-Null
            }

            $index = 0
            foreach ($imageUrl in $candidates) {
                if ($downloaded.Count -ge $Cfg.LinkImageLimit) {
                    break
                }

                try {
                    $bytes = Read-LinkBytesResource $imageUrl $Cfg.LinkDownloadTimeoutSeconds
                    if ($null -eq $bytes -or $bytes.Length -le 0) {
                        throw "Downloaded image was empty."
                    }

                    $imageInfo = Get-ImageInfoFromBytes $bytes
                    if (-not $imageInfo.readable) {
                        throw "Downloaded image was not readable: $($imageInfo.error)"
                    }

                    $minImageSize = [int](Get-ObjectValue $Cfg "LinkMinImageSize" 600)
                    if ($minImageSize -gt 0 -and ($imageInfo.width -lt $minImageSize -or $imageInfo.height -lt $minImageSize)) {
                        $rowErrors.Add("Skipped small image: $imageUrl ($($imageInfo.width) x $($imageInfo.height), minimum ${minImageSize}px)")
                        continue
                    }

                    $index += 1
                    $extension = Get-ImageExtensionFromUrl $imageUrl
                    $targetName = "source-{0:d2}{1}" -f $index, $extension
                    $targetPath = Join-Path $productDir $targetName
                    $changed = $false
                    if (-not $DryRun) {
                        $changed = Write-BytesIfChanged $targetPath $bytes
                    }

                    $downloaded.Add([pscustomobject]@{
                        sourceUrl = $imageUrl
                        file      = $targetName
                        path      = $targetPath
                        bytes     = $bytes.Length
                        width     = $imageInfo.width
                        height    = $imageInfo.height
                        changed   = $changed
                    })
                }
                catch {
                    $rowErrors.Add("Image download failed: $imageUrl - $(Format-ExceptionSummary $_)")
                }
            }

            $sourceImages = @(if (Test-Path -LiteralPath $productDir -PathType Container) {
                Get-SourceImages $productDir
            }
            else {
                $downloaded.ToArray()
            })

            if ($downloaded.Count -eq 0 -and $sourceImages.Count -eq 0) {
                throw "No usable product images were downloaded."
            }

            $briefText = New-LinkProductBriefText $row $folderName $url
            $briefChanged = $false
            $metadataChanged = $false
            if (-not $DryRun) {
                if ($downloaded.Count -gt 0) {
                    $keptPaths = @{}
                    foreach ($item in @($downloaded.ToArray())) {
                        $keptPaths[$item.path] = $true
                    }

                    foreach ($oldSource in @(Get-SourceImages $productDir)) {
                        if (-not $keptPaths.ContainsKey($oldSource.path)) {
                            Remove-Item -LiteralPath $oldSource.path -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                $briefChanged = Write-TextIfChanged (Join-Path $productDir $Cfg.BriefFile) $briefText
                $metadata = [ordered]@{
                    sourceMode = "1688-link-table"
                    syncedAt   = (Get-Date).ToUniversalTime().ToString("o")
                    table      = $tablePath
                    rowNumber  = $rowNumber
                    productUrl = $url
                    productFolder = $folderName
                    downloadedImages = $downloaded.ToArray()
                    errors     = $rowErrors.ToArray()
                }
                $metadataText = ($metadata | ConvertTo-Json -Depth 30)
                $metadataChanged = Write-TextIfChanged (Join-Path $productDir "source.1688.json") ($metadataText + "`r`n")
                "" | Set-Content -LiteralPath (Join-Path $productDir $Cfg.ReadyMarker) -Encoding UTF8
            }

            $results.Add([pscustomobject]@{
                rowNumber       = $rowNumber
                status          = "synced"
                dryRun          = [bool]$DryRun
                productName     = $folderName
                productPath     = $productDir
                url             = $url
                candidateCount  = $candidates.Count
                downloadedCount = $downloaded.Count
                existingSourceImageCount = $sourceImages.Count
                briefChanged    = $briefChanged
                metadataChanged = $metadataChanged
                errors          = $rowErrors.ToArray()
            })
        }
        catch {
            $messageText = "Row ${rowNumber}: $(Format-ExceptionSummary $_)"
            $errors.Add($messageText)
            $results.Add([pscustomobject]@{
                rowNumber   = $rowNumber
                status      = "needs_attention"
                productName = $folderName
                productPath = $productDir
                url         = $url
                errors      = @($messageText) + $rowErrors.ToArray()
            })
        }
    }

    $resultArray = @($results.ToArray())
    $errorArray = @($errors.ToArray())
    $syncedCount = @($resultArray | Where-Object { $_.status -eq "synced" }).Count
    $skippedCount = @($resultArray | Where-Object { $_.status -eq "skipped" }).Count
    $attentionCount = @($resultArray | Where-Object { $_.status -eq "needs_attention" }).Count

    return [pscustomobject]@{
        status         = if ($attentionCount -gt 0) { "needs_attention" } else { "ok" }
        dryRun         = [bool]$DryRun
        table          = $tablePath
        inputRoot      = $Cfg.InputRoot
        rowCount       = $rows.Count
        syncedCount    = $syncedCount
        skippedCount   = $skippedCount
        attentionCount = $attentionCount
        rows           = $resultArray
        errors         = $errorArray
    }
}

function Invoke-LinkSync {
    $cfg = Get-ConfigObject
    Invoke-LinkSyncCore $cfg | Write-Json
}

function Get-InputHash {
    param(
        [string]$Text,
        [object[]]$SourceImages,
        [string]$PromptSchemaVersion,
        [string]$InferredBriefText
    )

    $fingerprint = [ordered]@{
        promptSchemaVersion = $PromptSchemaVersion
        productText         = $Text
        inferredBrief       = $InferredBriefText
        sourceImages        = @($SourceImages | ForEach-Object {
            [ordered]@{
                name             = $_.name
                bytes            = $_.bytes
                lastWriteTimeUtc = $_.lastWriteTimeUtc
            }
        })
    }

    return Get-TextHash ($fingerprint | ConvertTo-Json -Depth 20)
}

function Read-InferredBriefText {
    param(
        [object]$Cfg,
        [string]$ProductDir
    )

    $inferredPath = Join-Path $ProductDir $Cfg.GeneratedBriefFile
    if (-not (Test-Path -LiteralPath $inferredPath -PathType Leaf)) {
        return ""
    }

    return Get-Content -LiteralPath $inferredPath -Raw -Encoding UTF8
}

function Read-CompletionMarker {
    param(
        [object]$Cfg,
        [string]$ProductDir
    )

    $markerPath = Join-Path $ProductDir $Cfg.CompleteMarkerFile
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return [pscustomobject]@{
            path   = $markerPath
            exists = $false
            values = [ordered]@{}
        }
    }

    $values = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $markerPath -Encoding UTF8)) {
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $values[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    return [pscustomobject]@{
        path   = $markerPath
        exists = $true
        values = $values
    }
}

function Write-CompletionMarker {
    param(
        [object]$Manifest,
        [string]$RunDirectory
    )

    $productPath = Get-ObjectValue $Manifest "productPath" ""
    if ([string]::IsNullOrWhiteSpace($productPath) -or -not (Test-Path -LiteralPath $productPath -PathType Container)) {
        return
    }

    $completeMarkerFile = Get-ObjectValue $Manifest "completeMarkerFile" "automation.done.txt"
    $markerPath = Join-Path $productPath $completeMarkerFile
    $lines = @(
        "status=complete",
        ("inputHash={0}" -f (Get-ObjectValue $Manifest "inputHash" "")),
        ("productTextHash={0}" -f (Get-ObjectValue $Manifest "productTextHash" "")),
        ("runDir={0}" -f $RunDirectory),
        ("version={0}" -f (Get-ObjectValue $Manifest "version" "")),
        ("promptSchemaVersion={0}" -f (Get-ObjectValue $Manifest "promptSchemaVersion" "")),
        ("completedAt={0}" -f (Get-Date).ToUniversalTime().ToString("o"))
    )

    $lines | Set-Content -LiteralPath $markerPath -Encoding UTF8
}

function Read-ProductText {
    param(
        [object]$Cfg,
        [string]$ProductDir
    )

    $briefPath = Join-Path $ProductDir $Cfg.BriefFile
    if (-not (Test-Path -LiteralPath $briefPath -PathType Leaf)) {
        throw "Brief file not found: $briefPath"
    }

    return Get-Content -LiteralPath $briefPath -Raw -Encoding UTF8
}

function Parse-Brief {
    param(
        [string]$Text,
        [string]$FallbackProductName
    )

    $values = @{}
    foreach ($key in $BriefKeys) {
        $values[$key] = New-Object "System.Collections.Generic.List[string]"
    }

    $freeLines = New-Object "System.Collections.Generic.List[string]"
    $currentKey = $null

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([^:]{2,60})\s*:\s*(.*)$') {
            $label = $Matches[1].Trim().ToLowerInvariant()
            if ($FieldMap.Contains($label)) {
                $currentKey = $FieldMap[$label]
                $value = $Matches[2].Trim()
                if ($value.Length -gt 0) {
                    $values[$currentKey].Add($value)
                }
                continue
            }
        }

        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) {
            continue
        }

        if ($null -ne $currentKey) {
            $values[$currentKey].Add($trimmed)
        }
        else {
            $freeLines.Add($trimmed)
        }
    }

    foreach ($line in $freeLines) {
        $values["extraNotes"].Add($line)
    }

    $brief = [ordered]@{}
    $missingFields = New-Object "System.Collections.Generic.List[string]"
    $userProvidedFields = New-Object "System.Collections.Generic.List[string]"
    foreach ($key in $BriefKeys) {
        $brief[$key] = (($values[$key] | ForEach-Object { $_ }) -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($brief[$key])) {
            $missingFields.Add($BriefLabels[$key])
        }
        else {
            $userProvidedFields.Add($key)
        }
    }

    if ([string]::IsNullOrWhiteSpace($brief["productName"])) {
        $brief["productName"] = $FallbackProductName
    }

    $brief["_missingFields"] = $missingFields.ToArray()
    $brief["_userProvidedFields"] = $userProvidedFields.ToArray()

    return $brief
}

function ConvertTo-PlainText {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [array]) {
        return (($Value | ForEach-Object { ConvertTo-PlainText $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "; ").Trim()
    }

    return ([string]$Value).Trim()
}

function Read-InferredBrief {
    param(
        [object]$Cfg,
        [string]$ProductDir
    )

    $inferredPath = Join-Path $ProductDir $Cfg.GeneratedBriefFile
    if (-not (Test-Path -LiteralPath $inferredPath -PathType Leaf)) {
        return [pscustomobject]@{
            path   = $inferredPath
            exists = $false
            values = [ordered]@{}
            errors = @()
        }
    }

    try {
        $raw = Get-Content -LiteralPath $inferredPath -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
        $values = [ordered]@{}

        foreach ($key in $BriefKeys) {
            $value = ""
            $label = $BriefLabels[$key]
            $camelProperty = $json.PSObject.Properties[$key]
            $labelProperty = $json.PSObject.Properties[$label]

            if ($null -ne $camelProperty) {
                $value = ConvertTo-PlainText $camelProperty.Value
            }
            elseif ($null -ne $labelProperty) {
                $value = ConvertTo-PlainText $labelProperty.Value
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $values[$key] = $value
            }
        }

        foreach ($key in $InferredContextLabels.Keys) {
            $value = ""
            $label = $InferredContextLabels[$key]
            $camelProperty = $json.PSObject.Properties[$key]
            $labelProperty = $json.PSObject.Properties[$label]

            if ($null -ne $camelProperty) {
                $value = ConvertTo-PlainText $camelProperty.Value
            }
            elseif ($null -ne $labelProperty) {
                $value = ConvertTo-PlainText $labelProperty.Value
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $values[$key] = $value
            }
        }

        return [pscustomobject]@{
            path   = $inferredPath
            exists = $true
            values = $values
            errors = @()
        }
    }
    catch {
        return [pscustomobject]@{
            path   = $inferredPath
            exists = $true
            values = [ordered]@{}
            errors = @("Unable to read inferred brief: $($_.Exception.Message)")
        }
    }
}

function Merge-InferredBrief {
    param(
        [hashtable]$Brief,
        [object]$InferredBrief
    )

    $userProvidedFields = @(Get-ObjectValue $Brief "_userProvidedFields" @())
    $appliedFields = New-Object "System.Collections.Generic.List[string]"
    $inferredContext = [ordered]@{}

    if ($null -ne $InferredBrief -and $InferredBrief.exists) {
        foreach ($key in $BriefKeys) {
            if ($userProvidedFields -contains $key) {
                continue
            }

            $value = Get-ObjectValue $InferredBrief.values $key ""
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $Brief[$key] = $value
            $appliedFields.Add($BriefLabels[$key])
        }

        foreach ($key in $InferredContextLabels.Keys) {
            $value = Get-ObjectValue $InferredBrief.values $key ""
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $inferredContext[$key] = $value
            }
        }
    }

    $missingFields = New-Object "System.Collections.Generic.List[string]"
    foreach ($key in $BriefKeys) {
        if ([string]::IsNullOrWhiteSpace($Brief[$key])) {
            $missingFields.Add($BriefLabels[$key])
        }
    }

    $Brief["_missingFields"] = $missingFields.ToArray()
    $Brief["_inferredAppliedFields"] = $appliedFields.ToArray()
    $Brief["_inferredContext"] = $inferredContext

    return $Brief
}

function Format-BriefLines {
    param([hashtable]$Brief)

    $lines = New-Object "System.Collections.Generic.List[string]"
    foreach ($key in $BriefLabels.Keys) {
        if ($key -eq "introText") {
            continue
        }

        $value = $Brief[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $lines.Add(("{0}: {1}" -f $BriefLabels[$key], $value))
        }
    }
    return (($lines | ForEach-Object { $_ }) -join "`n")
}

function Format-InferredContextLines {
    param([hashtable]$Brief)

    $context = Get-ObjectValue $Brief "_inferredContext" $null
    if ($null -eq $context) {
        return "No separate inferred identity lock was provided. Use the written brief and source images conservatively."
    }

    $lines = New-Object "System.Collections.Generic.List[string]"
    foreach ($key in $InferredContextLabels.Keys) {
        $value = Get-ObjectValue $context $key ""
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $lines.Add(("{0}: {1}" -f $InferredContextLabels[$key], $value))
        }
    }

    if ($lines.Count -eq 0) {
        return "No separate inferred identity lock was provided. Use the written brief and source images conservatively."
    }

    return (($lines | ForEach-Object { $_ }) -join "`n")
}

function Get-InferredContextValue {
    param(
        [hashtable]$Brief,
        [string]$Key
    )

    $context = Get-ObjectValue $Brief "_inferredContext" $null
    if ($null -eq $context) {
        return ""
    }

    return Get-ObjectValue $context $Key ""
}

function Format-SourceImageLines {
    param([object[]]$SourceImages)

    if ($null -eq $SourceImages -or $SourceImages.Count -eq 0) {
        return "No source images were found in the product folder."
    }

    return (($SourceImages | ForEach-Object {
        "- {0}: {1}" -f $_.name, $_.path
    }) -join "`n")
}

function Format-InferenceGuidance {
    param(
        [hashtable]$Brief,
        [object[]]$SourceImages
    )

    $missing = @(Get-ObjectValue $Brief "_missingFields" @())
    $sourceCount = if ($null -eq $SourceImages) { 0 } else { $SourceImages.Count }

    if ($sourceCount -gt 0) {
        $missingText = if ($missing.Count -gt 0) {
            "Missing or blank brief fields to infer from the source images when visually clear: $($missing -join ', ')."
        }
        else {
            "All main brief fields have text, but still use the source images as the visual truth."
        }

        return @"
Use the source product images as the primary visual reference. $missingText
Infer only what is visible or strongly implied by the images. Do not invent exact materials, gemstones, sizes, claims, or functions that are not visible or stated.
If the source images are simple, tightly cropped, or contain little usable background, create a suitable Etsy-style background/context for this asset while keeping the product itself faithful to the images.
"@.Trim()
    }

    if ($missing.Count -gt 0) {
        return "Some brief fields are blank and no source images were found. Use only the folder name and provided text; keep assumptions broad and avoid specific claims."
    }

    return "Use the written brief as the source of truth."
}

function Format-ProductFidelityRules {
    param(
        [object[]]$SourceImages,
        [string]$ProductIdentityMode = "reference-strict"
    )

    $sourceCount = if ($null -eq $SourceImages) { 0 } else { $SourceImages.Count }
    if ($sourceCount -le 0) {
        return @"
No source images are available, so keep the product broad and conservative. Do not invent precise product geometry, stones, engravings, logos, sizes, or material claims from generic category text.
"@.Trim()
    }

    $sourcePreserveRequirement = if ($ProductIdentityMode -eq "reference-strict") {
        "Product identity mode is reference-strict: AI may improve the scene, background, lighting, camera angle, and listing composition, but the visible product must remain highly similar to the source photos. This is a global rule for every product category, not a product-specific rule. Actual source image references/attachments should be used when the environment supports them. If only a prompt-only image2 draft is available, it may be generated as a candidate, but it is not automatically valid; accept it only after strict visual comparison against the source photos. Accept only minor perspective, lighting, reflection, and scale changes. Reject outputs that noticeably change the visible product type, silhouette, proportions, geometry, component count, component placement, motif/character/face/graphic/engraving/lettering layout, stones/beads/charms/buttons/ports/handles/clasps/links, color placement, material finish, surface texture, pattern, variant differences, item count, or bundle/set count. If a generated image would not be immediately recognizable as the same product beside the source photo, mark it failed/needs_review instead of validating it."
    }
    elseif ($ProductIdentityMode -eq "source-preserve") {
        "Product identity mode is source-preserve: pure text-to-image redraws of the product are not valid production outputs. The product itself must be source-derived, source-attached, or edited/composited from the source images so the visible geometry and details remain unchanged. If the available image2 path cannot preserve the source product, stop and mark the image failed/needs_review instead of generating a newly designed replacement product."
    }
    else {
        "Product identity mode is ai-redraw, but source images still control product identity and visible product details must not drift."
    }

    return @"
The source product images are the highest-priority product identity lock. User-written brief text may set category, mood, buyer context, and background preferences, but it must not override visible product geometry, proportions, component layout, color placement, chain/link/clasp/stone/lettering details, or material finish.
If the source images show multiple distinct items, variants, numbered options, or a bundle/set, the item count and each visible variant difference are part of the identity lock. Do not select a single representative item, merge variants into one hybrid item, or change a multi-item listing into one product unless a specific direction intentionally asks for one named detail view.
Do not invent choose-one wording such as "choose your style" unless the user brief explicitly says the listing is a variant/option listing. When sale mode is unclear, preserve all visible items as included together.
Do not redesign, idealize, simplify, repair, replace, or "upgrade" the product. Do not add, remove, move, resize, duplicate, or reinterpret charms, stones, settings, clasps, links, engravings, printed marks, cutouts, holes, seams, or visible defects.
If a source detail is blurry, cropped, hidden, or uncertain, keep it conservative or partly hidden; do not turn uncertainty into a clean invented feature. Backgrounds, props, lighting, hands, and scene context may change only around the product.
If any typed brief field conflicts with the source images or Visual Identity Lock, preserve the source-image appearance and ignore the conflicting typed detail.
$sourcePreserveRequirement
"@.Trim()
}

function New-Prompt {
    param(
        [string]$AssetName,
        [string]$PrimaryRequest,
        [string]$Composition,
        [string]$TextInstruction,
        [string]$AssetDirectionKey,
        [hashtable]$Brief,
        [object[]]$SourceImages,
        [string]$ProductIdentityMode = "reference-strict"
    )

    $briefLines = Format-BriefLines $Brief
    $sourceImageLines = Format-SourceImageLines $SourceImages
    $inferenceGuidance = Format-InferenceGuidance $Brief $SourceImages
    $productFidelityRules = Format-ProductFidelityRules $SourceImages $ProductIdentityMode
    $inferredContextLines = Format-InferredContextLines $Brief
    $assetDirection = if ([string]::IsNullOrWhiteSpace($AssetDirectionKey)) { "" } else { Get-InferredContextValue $Brief $AssetDirectionKey }
    if ([string]::IsNullOrWhiteSpace($assetDirection)) {
        $assetDirection = "Follow the primary request and composition for this image while preserving the shared product identity."
    }
    $avoid = $Brief["avoid"]
    if ([string]::IsNullOrWhiteSpace($avoid)) {
        $avoid = "watermarks, logos, unreadable text, distorted product details, extra products not requested"
    }

    $directionQualityRules = @"
For this image direction, apply a complete product-photography brief: specify camera distance or shot scale, camera angle, product placement, product size in frame, background surface, foreground/background layers, allowed props, lighting direction, shadow style, depth of field, buyer-use purpose, exact product details, and item/variant count that must remain unchanged. If any of those details are missing from the specific direction, infer them conservatively from the asset type, source images, Visual Identity Lock, and Background Strategy.
"@.Trim()

    return @"
Use case: product-mockup
Asset type: Etsy square product image - $AssetName
Primary request: $PrimaryRequest

Product brief:
$briefLines

Source product images:
$sourceImageLines

Image inference and background guidance:
$inferenceGuidance

Product fidelity priority:
$productFidelityRules

Shared product identity and set consistency:
$inferredContextLines

Specific direction for this image:
$assetDirection

Direction quality requirements:
$directionQualityRules

Style/medium: polished photorealistic product photography suitable for Etsy.
Composition/framing: $Composition
Lighting/mood: clean commercial lighting, attractive but natural, high-quality finish.
Color palette: follow the product brief; keep colors tasteful and buyer-friendly.
Text requirement: $TextInstruction
Constraints: 1:1 square image; English only if text appears; no watermark; no fake brand logo; keep the product faithful to the source images, Visual Identity Lock, and Set Consistency Rules; source images outrank typed brief text for product shape, item count, variant differences, and details; include required details from Must Include only when they match the source images.
Avoid: $avoid
"@.Trim()
}

function New-PromptSet {
    param(
        [hashtable]$Brief,
        [object[]]$SourceImages,
        [string]$ProductIdentityMode = "reference-strict"
    )

    $introText = $Brief["introText"]
    if ([string]::IsNullOrWhiteSpace($introText)) {
        $introText = $Brief["productName"]
    }

    @(
        [ordered]@{
            id     = "01-main"
            title  = "Main listing image"
            file   = "01-main.png"
            prompt = New-Prompt `
                -AssetName "01 of 07 main listing image" `
                -PrimaryRequest "Create the main listing image for this product with the product as the clear hero." `
                -Composition "centered product hero, clean uncluttered studio background, generous padding, no cropping" `
                -TextInstruction "No text." `
                -AssetDirectionKey "mainImageDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "02-scene-home"
            title  = "Product scene 1 - home lifestyle"
            file   = "02-scene-home.png"
            prompt = New-Prompt `
                -AssetName "02 of 07 home lifestyle scene" `
                -PrimaryRequest "Create a realistic lifestyle scene showing the product naturally placed in a warm home or personal space." `
                -Composition "product visible and central enough to understand, contextual props allowed only when they support the product" `
                -TextInstruction "No text." `
                -AssetDirectionKey "sceneHomeDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "03-scene-use"
            title  = "Product scene 2 - in use"
            file   = "03-scene-use.png"
            prompt = New-Prompt `
                -AssetName "03 of 07 in-use scene" `
                -PrimaryRequest "Create a scene showing how the target customer would use, wear, hold, display, or enjoy the product." `
                -Composition "natural usage moment, product clearly visible, believable scale and materials" `
                -TextInstruction "No text." `
                -AssetDirectionKey "sceneUseDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "04-scene-gift"
            title  = "Product scene 3 - giftable setting"
            file   = "04-scene-gift.png"
            prompt = New-Prompt `
                -AssetName "04 of 07 giftable setting" `
                -PrimaryRequest "Create an appealing gift-oriented scene that makes the product feel special and ready to buy." `
                -Composition "product with tasteful wrapping, desk, table, or shelf context as appropriate; keep product as the hero" `
                -TextInstruction "No text." `
                -AssetDirectionKey "sceneGiftDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "05-scene-detail"
            title  = "Product scene 4 - detail and texture"
            file   = "05-scene-detail.png"
            prompt = New-Prompt `
                -AssetName "05 of 07 detail and texture scene" `
                -PrimaryRequest "Create a close product detail image that highlights materials, texture, finish, color, and craftsmanship." `
                -Composition "close-up or cropped detail, still square, product details sharp and readable, no misleading extra features" `
                -TextInstruction "No text." `
                -AssetDirectionKey "sceneDetailDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "06-model"
            title  = "Model image"
            file   = "06-model.png"
            prompt = New-Prompt `
                -AssetName "06 of 07 model image" `
                -PrimaryRequest "Create a model image with an adult model using, wearing, holding, or presenting the product in a way that fits the category." `
                -Composition "model and product both visible, product remains the focus, natural pose, realistic scale" `
                -TextInstruction "No text." `
                -AssetDirectionKey "modelImageDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        },
        [ordered]@{
            id     = "07-intro"
            title  = "Introduction image"
            file   = "07-intro.png"
            prompt = New-Prompt `
                -AssetName "07 of 07 introduction graphic" `
                -PrimaryRequest "Create an Etsy-style product introduction image with the product and clean English informational text." `
                -Composition "clear product visual plus simple editorial layout; leave enough room for legible text; avoid clutter" `
                -TextInstruction ("Render this English text as accurately as possible, verbatim: `"{0}`"" -f $introText.Replace("`r", " ").Replace("`n", " ")) `
                -AssetDirectionKey "introImageDirection" `
                -Brief $Brief `
                -SourceImages $SourceImages `
                -ProductIdentityMode $ProductIdentityMode
        }
    )
}

function Get-ProductOutputRoot {
    param(
        [object]$Cfg,
        [string]$ProductName
    )

    Join-Path $Cfg.OutputRoot (Get-SafeName $ProductName)
}

function Get-RunManifests {
    param(
        [object]$Cfg,
        [string]$ProductName
    )

    $productOutputRoot = Get-ProductOutputRoot $Cfg $ProductName
    if (-not (Test-Path -LiteralPath $productOutputRoot -PathType Container)) {
        return @()
    }

    $manifests = New-Object "System.Collections.Generic.List[object]"
    foreach ($dir in (Get-ChildItem -LiteralPath $productOutputRoot -Directory | Sort-Object Name)) {
        $manifestPath = Join-Path $dir.FullName "run.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifests.Add([pscustomobject]@{
                RunDir       = $dir.FullName
                ManifestPath = $manifestPath
                Manifest     = $manifest
            })
        }
        catch {
            $manifests.Add([pscustomobject]@{
                RunDir       = $dir.FullName
                ManifestPath = $manifestPath
                Manifest     = [pscustomobject]@{
                    status          = "needs_review"
                    productTextHash = ""
                    errors          = @("Unreadable run.json: $($_.Exception.Message)")
                }
            })
        }
    }

    return @($manifests.ToArray())
}

function Get-RunForHash {
    param(
        [object]$Cfg,
        [string]$ProductName,
        [string]$InputHash,
        [string]$ProductTextHash
    )

    $matches = @(Get-RunManifests $Cfg $ProductName | Where-Object {
        $manifestInputHash = Get-ObjectValue $_.Manifest "inputHash" ""
        if (-not [string]::IsNullOrWhiteSpace($manifestInputHash)) {
            $manifestInputHash -eq $InputHash
        }
        else {
            (Get-ObjectValue $_.Manifest "productTextHash" "") -eq $ProductTextHash
        }
    } | Sort-Object RunDir -Descending)

    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Get-NextVersionName {
    param([string]$ProductOutputRoot)

    $max = 0
    if (Test-Path -LiteralPath $ProductOutputRoot -PathType Container) {
        foreach ($dir in (Get-ChildItem -LiteralPath $ProductOutputRoot -Directory)) {
            if ($dir.Name -match '^v(\d{3,})$') {
                $number = [int]$Matches[1]
                if ($number -gt $max) {
                    $max = $number
                }
            }
        }
    }

    return ("v{0:D3}" -f ($max + 1))
}

function Get-ExpectedFiles {
    param([object]$Manifest)

    $expected = @(Get-ObjectValue $Manifest "expectedFiles" @())
    if ($expected.Count -eq 0) {
        return @("01-main.png", "02-scene-home.png", "03-scene-use.png", "04-scene-gift.png", "05-scene-detail.png", "06-model.png", "07-intro.png")
    }

    return $expected
}

function Get-RunFilePresence {
    param(
        [string]$RunDirectory,
        [object]$Manifest
    )

    $expected = @(Get-ExpectedFiles $Manifest)
    $missing = New-Object "System.Collections.Generic.List[string]"
    $present = New-Object "System.Collections.Generic.List[string]"

    foreach ($fileName in $expected) {
        $imagePath = Join-Path $RunDirectory $fileName
        if (Test-Path -LiteralPath $imagePath -PathType Leaf) {
            $present.Add($fileName)
        }
        else {
            $missing.Add($fileName)
        }
    }

    return [pscustomobject]@{
        expectedFiles = $expected
        expectedCount = $expected.Count
        presentFiles  = $present.ToArray()
        presentCount  = $present.Count
        missingFiles  = $missing.ToArray()
        missingCount  = $missing.Count
    }
}

function ConvertTo-UtcDateTimeOrNull {
    param($Value)

    $text = ConvertTo-PlainText $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ([datetime]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-RunAgeHours {
    param([object]$Manifest)

    $timestamp = ConvertTo-UtcDateTimeOrNull (Get-ObjectValue $Manifest "updatedAt" "")
    if ($null -eq $timestamp) {
        $timestamp = ConvertTo-UtcDateTimeOrNull (Get-ObjectValue $Manifest "createdAt" "")
    }

    if ($null -eq $timestamp) {
        return $null
    }

    return [Math]::Round(((Get-Date).ToUniversalTime() - $timestamp).TotalHours, 3)
}

function Test-RetryableGenerationReview {
    param([object]$Manifest)

    $status = Get-ObjectValue $Manifest "status" ""
    if ($status -ne "needs_review") {
        return $false
    }

    foreach ($errorText in @(Get-ObjectValue $Manifest "errors" @())) {
        if (Test-Image2PersistenceBlocker $errorText) {
            return $true
        }
    }

    return $false
}

function Test-Image2PersistenceBlocker {
    param($Message)

    $plainText = (ConvertTo-PlainText $Message).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($plainText)) {
        return $false
    }

    $isBuiltInImageGeneration = (
        $plainText -like "*image2*" -or
        $plainText -like "*built-in image generation*" -or
        $plainText -like "*built-in image2*" -or
        $plainText -like "*codex image2*"
    )

    return (
        $isBuiltInImageGeneration -and
        $plainText -like "*cannot persist*" -and
        (
            $plainText -like "*run directory*" -or
            $plainText -like "*local png*" -or
            $plainText -like "*generated image files*"
        )
    )
}

function Read-LockFile {
    param([string]$LockPath)

    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        return [pscustomobject]@{
            path   = $LockPath
            exists = $false
        }
    }

    try {
        $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $createdAt = ConvertTo-UtcDateTimeOrNull (Get-ObjectValue $lock "createdAt" "")
        $ageMinutes = if ($null -eq $createdAt) {
            $null
        }
        else {
            [Math]::Round(((Get-Date).ToUniversalTime() - $createdAt).TotalMinutes, 3)
        }

        return [pscustomobject]@{
            path       = $LockPath
            exists     = $true
            readable   = $true
            scope      = Get-ObjectValue $lock "scope" ""
            command    = Get-ObjectValue $lock "command" ""
            pid        = Get-ObjectValue $lock "pid" ""
            token      = Get-ObjectValue $lock "token" ""
            createdAt  = Get-ObjectValue $lock "createdAt" ""
            ageMinutes = $ageMinutes
        }
    }
    catch {
        return [pscustomobject]@{
            path       = $LockPath
            exists     = $true
            readable   = $false
            scope      = ""
            command    = ""
            pid        = ""
            token      = ""
            createdAt  = ""
            ageMinutes = $null
            error      = $_.Exception.Message
        }
    }
}

function New-AutomationLock {
    param(
        [string]$LockPath,
        [string]$Scope,
        [double]$StaleMinutes
    )

    $parent = Split-Path -Parent $LockPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $existing = Read-LockFile $LockPath
    $replacedStale = $false
    if ($existing.exists) {
        $ageMinutes = Get-ObjectValue $existing "ageMinutes" $null
        $isStale = $StaleMinutes -gt 0 -and $null -ne $ageMinutes -and $ageMinutes -ge $StaleMinutes
        if (-not $isStale) {
            throw "Lock exists for ${Scope}: $LockPath"
        }

        Remove-Item -LiteralPath $LockPath -Force
        $replacedStale = $true
    }

    $token = [guid]::NewGuid().ToString("n")
    $lock = [ordered]@{
        scope     = $Scope
        command   = $Command
        pid       = $PID
        token     = $token
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
    }

    $json = $lock | ConvertTo-Json -Depth 10
    $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
        try {
            $writer.Write($json)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    return [pscustomobject]@{
        path          = $LockPath
        token         = $token
        scope         = $Scope
        acquired      = $true
        replacedStale = $replacedStale
    }
}

function Remove-AutomationLock {
    param($Lock)

    if ($null -eq $Lock -or -not (Get-ObjectValue $Lock "acquired" $false)) {
        return
    }

    $lockPath = Get-ObjectValue $Lock "path" ""
    $token = Get-ObjectValue $Lock "token" ""
    if ([string]::IsNullOrWhiteSpace($lockPath) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return
    }

    $existing = Read-LockFile $lockPath
    if ((Get-ObjectValue $existing "token" "") -eq $token) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}

function Get-ProductInputHealth {
    param(
        [object]$Cfg,
        [System.IO.DirectoryInfo]$ProductDir,
        [string]$Text,
        [object[]]$SourceImages
    )

    $brief = Parse-Brief $Text $ProductDir.Name
    $missingFields = @(Get-ObjectValue $brief "_missingFields" @())
    $userProvidedFields = @(Get-ObjectValue $brief "_userProvidedFields" @())
    $inferredBrief = Read-InferredBrief $Cfg $ProductDir.FullName
    $warnings = New-Object "System.Collections.Generic.List[string]"

    if ($SourceImages.Count -eq 0) {
        $warnings.Add("no_source_images")
    }

    if ($missingFields.Count -gt 0 -and -not $inferredBrief.exists) {
        $warnings.Add("brief_missing_fields_without_inferred_brief")
    }

    if ($userProvidedFields.Count -eq 0 -and $inferredBrief.exists) {
        $warnings.Add("brief_empty_using_inferred_brief")
    }

    if (@($inferredBrief.errors).Count -gt 0) {
        $warnings.Add("inferred_brief_error")
    }

    return [pscustomobject]@{
        userProvidedFieldCount = $userProvidedFields.Count
        briefMissingFields     = $missingFields
        inferredBriefExists    = $inferredBrief.exists
        inferredBriefErrors    = @($inferredBrief.errors)
        inputWarnings          = $warnings.ToArray()
    }
}

function Get-ProductState {
    param(
        [object]$Cfg,
        [System.IO.DirectoryInfo]$ProductDir
    )

    $readyPath = Join-Path $ProductDir.FullName $Cfg.ReadyMarker
    $briefPath = Join-Path $ProductDir.FullName $Cfg.BriefFile

    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        return [pscustomobject]@{
            productName = $ProductDir.Name
            productPath = $ProductDir.FullName
            status      = "skipped"
            reason      = "missing_ready_marker"
        }
    }

    if (-not (Test-Path -LiteralPath $briefPath -PathType Leaf)) {
        return [pscustomobject]@{
            productName = $ProductDir.Name
            productPath = $ProductDir.FullName
            status      = "skipped"
            reason      = "missing_brief_file"
        }
    }

    $text = Read-ProductText $Cfg $ProductDir.FullName
    $sourceImages = @(Get-SourceImages $ProductDir.FullName)
    $inferredBriefText = Read-InferredBriefText $Cfg $ProductDir.FullName
    $productTextHash = Get-TextHash $text
    $inputHash = Get-InputHash $text $sourceImages $Cfg.PromptSchemaVersion $inferredBriefText
    $inputHealth = Get-ProductInputHealth $Cfg $ProductDir $text $sourceImages
    $completionMarker = Read-CompletionMarker $Cfg $ProductDir.FullName
    if ($completionMarker.exists -and
        (Get-ObjectValue $completionMarker.values "status" "") -eq "complete" -and
        (Get-ObjectValue $completionMarker.values "inputHash" "") -eq $inputHash) {
        return [pscustomobject]@{
            productName     = $ProductDir.Name
            productPath     = $ProductDir.FullName
            productTextHash = $productTextHash
            inputHash       = $inputHash
            sourceImageCount = $sourceImages.Count
            userProvidedFieldCount = $inputHealth.userProvidedFieldCount
            briefMissingFields = $inputHealth.briefMissingFields
            inferredBriefExists = $inputHealth.inferredBriefExists
            inputWarnings = $inputHealth.inputWarnings
            status          = "skipped"
            reason          = "completion_marker_complete"
            runDir          = Get-ObjectValue $completionMarker.values "runDir" ""
            markerPath      = $completionMarker.path
        }
    }

    $existing = Get-RunForHash $Cfg $ProductDir.Name $inputHash $productTextHash
    if ($null -ne $existing) {
        $existingStatus = Get-ObjectValue $existing.Manifest "status" "unknown"
        $retryableReview = Test-RetryableGenerationReview $existing.Manifest
        if ($existingStatus -eq "pending_generation" -or $retryableReview) {
            $presence = Get-RunFilePresence $existing.RunDir $existing.Manifest
            $ageHours = Get-RunAgeHours $existing.Manifest
            $staleHours = [double](Get-ObjectValue $Cfg "PendingStaleHours" 24)
            if ($presence.missingCount -gt 0 -and $staleHours -gt 0 -and $null -ne $ageHours -and $ageHours -ge $staleHours) {
                return [pscustomobject]@{
                    productName      = $ProductDir.Name
                    productPath      = $ProductDir.FullName
                productTextHash  = $productTextHash
                inputHash        = $inputHash
                sourceImageCount = $sourceImages.Count
                userProvidedFieldCount = $inputHealth.userProvidedFieldCount
                briefMissingFields = $inputHealth.briefMissingFields
                inferredBriefExists = $inputHealth.inferredBriefExists
                inputWarnings = $inputHealth.inputWarnings
                status           = "stalled"
                reason           = "pending_generation_stale"
                runDir           = $existing.RunDir
                    version          = Get-ObjectValue $existing.Manifest "version" ""
                    ageHours         = $ageHours
                    staleAfterHours  = $staleHours
                    missingCount     = $presence.missingCount
                    missingFiles     = $presence.missingFiles
                }
            }

            $pendingReason = if ($retryableReview) {
                "retry_generation_after_backend_change"
            }
            else {
                "resume_existing_pending_generation"
            }

            return [pscustomobject]@{
                productName      = $ProductDir.Name
                productPath      = $ProductDir.FullName
                productTextHash  = $productTextHash
                inputHash        = $inputHash
                sourceImageCount = $sourceImages.Count
                userProvidedFieldCount = $inputHealth.userProvidedFieldCount
                briefMissingFields = $inputHealth.briefMissingFields
                inferredBriefExists = $inputHealth.inferredBriefExists
                inputWarnings = $inputHealth.inputWarnings
                status           = "pending"
                reason           = $pendingReason
                runDir           = $existing.RunDir
                version          = Get-ObjectValue $existing.Manifest "version" ""
                ageHours         = $ageHours
                missingCount     = $presence.missingCount
                missingFiles     = $presence.missingFiles
            }
        }

        return [pscustomobject]@{
            productName     = $ProductDir.Name
            productPath     = $ProductDir.FullName
            productTextHash = $productTextHash
            inputHash       = $inputHash
            sourceImageCount = $sourceImages.Count
            userProvidedFieldCount = $inputHealth.userProvidedFieldCount
            briefMissingFields = $inputHealth.briefMissingFields
            inferredBriefExists = $inputHealth.inferredBriefExists
            inputWarnings = $inputHealth.inputWarnings
            status          = "skipped"
            reason          = "existing_run_$existingStatus"
            runDir          = $existing.RunDir
        }
    }

    $productOutputRoot = Get-ProductOutputRoot $Cfg $ProductDir.Name
    $version = Get-NextVersionName $productOutputRoot

    return [pscustomobject]@{
        productName     = $ProductDir.Name
        productPath     = $ProductDir.FullName
        productTextHash = $productTextHash
        inputHash       = $inputHash
        sourceImageCount = $sourceImages.Count
        userProvidedFieldCount = $inputHealth.userProvidedFieldCount
        briefMissingFields = $inputHealth.briefMissingFields
        inferredBriefExists = $inputHealth.inferredBriefExists
        inputWarnings = $inputHealth.inputWarnings
        status          = "pending"
        outputRoot      = $productOutputRoot
        version         = $version
        runDir          = (Join-Path $productOutputRoot $version)
    }
}

function Invoke-Scan {
    $cfg = Get-ConfigObject
    $linkSync = $null
    $linkSyncSkippedReason = $null
    if ($NoLinkSync) {
        $linkSyncSkippedReason = "disabled_by_NoLinkSync"
    }
    elseif ($cfg.LinkSyncBeforeScan -and -not [string]::IsNullOrWhiteSpace($cfg.LinkTableFile)) {
        $linkSync = Invoke-LinkSyncCore $cfg
    }

    $pending = New-Object "System.Collections.Generic.List[object]"
    $stalled = New-Object "System.Collections.Generic.List[object]"
    $skipped = New-Object "System.Collections.Generic.List[object]"

    foreach ($productDir in (Get-ChildItem -LiteralPath $cfg.InputRoot -Directory | Sort-Object Name)) {
        $state = Get-ProductState $cfg $productDir
        if ($state.status -eq "pending") {
            $pending.Add($state)
        }
        elseif ($state.status -eq "stalled") {
            $stalled.Add($state)
        }
        else {
            $skipped.Add($state)
        }
    }

    $pendingArray = $pending.ToArray()
    $stalledArray = $stalled.ToArray()
    $skippedArray = $skipped.ToArray()

    [ordered]@{
        status     = "ok"
        scannedAt  = (Get-Date).ToUniversalTime().ToString("o")
        inputRoot  = $cfg.InputRoot
        outputRoot = $cfg.OutputRoot
        linkSync   = $linkSync
        linkSyncSkippedReason = $linkSyncSkippedReason
        pending    = $pendingArray
        stalled    = $stalledArray
        skipped    = $skippedArray
    } | Write-Json
}

function Resolve-ProductDir {
    param(
        [object]$Cfg,
        [string]$ProductValue
    )

    if ([string]::IsNullOrWhiteSpace($ProductValue)) {
        throw "Product is required for prepare."
    }

    if ([System.IO.Path]::IsPathRooted($ProductValue)) {
        if (Test-Path -LiteralPath $ProductValue -PathType Container) {
            return [System.IO.DirectoryInfo]$ProductValue
        }
        throw "Product folder not found: $ProductValue"
    }

    $candidate = Join-Path $Cfg.InputRoot $ProductValue
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return [System.IO.DirectoryInfo]$candidate
    }

    throw "Product folder '$ProductValue' not found under $($Cfg.InputRoot)."
}

function Write-RunManifest {
    param(
        [string]$RunDirectory,
        [object]$Manifest
    )

    $manifestPath = Join-Path $RunDirectory "run.json"
    $Manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

function Write-RunLog {
    param(
        [string]$RunDirectory,
        [string]$Event,
        $Details = $null
    )

    if ([string]::IsNullOrWhiteSpace($RunDirectory) -or -not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        return
    }

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        command   = $Command
        event     = $Event
        details   = $Details
    }

    $line = $entry | ConvertTo-Json -Depth 30 -Compress
    Add-Content -LiteralPath (Join-Path $RunDirectory "run.log.jsonl") -Value $line -Encoding UTF8
}

function New-ReferencePolicy {
    param(
        [string]$ProductIdentityMode,
        [bool]$RequireImageReference,
        [bool]$AllowReferenceLimitedDrafts,
        [object[]]$SourceImages
    )

    $sourceImageCount = @($SourceImages).Count
    $mustUseActualSourceImageReferences = (
        $ProductIdentityMode -eq "reference-strict" -and
        $RequireImageReference -and
        $sourceImageCount -gt 0
    )

    return [ordered]@{
        productIdentityMode = $ProductIdentityMode
        requireImageReference = $RequireImageReference
        allowReferenceLimitedDrafts = $AllowReferenceLimitedDrafts
        sourceImageCount = $sourceImageCount
        mustUseActualSourceImageReferences = $mustUseActualSourceImageReferences
        promptOnlyProductionAllowed = -not $mustUseActualSourceImageReferences
        promptOnlyDraftGenerationAllowed = $mustUseActualSourceImageReferences -and $AllowReferenceLimitedDrafts
        invalidFinalProductionPath = $(if ($mustUseActualSourceImageReferences) { "prompt_only_generation_without_strict_visual_acceptance" } else { "" })
    }
}

function Invoke-Prepare {
    $cfg = Get-ConfigObject
    $productDir = Resolve-ProductDir $cfg $Product

    $readyPath = Join-Path $productDir.FullName $cfg.ReadyMarker
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        throw "Product is not ready. Missing marker: $readyPath"
    }

    $text = Read-ProductText $cfg $productDir.FullName
    $sourceImages = @(Get-SourceImages $productDir.FullName)
    $inferredBriefText = Read-InferredBriefText $cfg $productDir.FullName
    $productTextHash = Get-TextHash $text
    $inputHash = Get-InputHash $text $sourceImages $cfg.PromptSchemaVersion $inferredBriefText
    $productOutputRoot = Get-ProductOutputRoot $cfg $productDir.Name
    $lock = New-AutomationLock (Join-Path $productOutputRoot ".prepare.lock") "prepare:$($productDir.Name)" $cfg.LockStaleMinutes
    try {
    $existing = Get-RunForHash $cfg $productDir.Name $inputHash $productTextHash
    $existingPendingRun = $null
    if ($null -ne $existing) {
        $existingStatus = Get-ObjectValue $existing.Manifest "status" "unknown"
        $retryableReview = Test-RetryableGenerationReview $existing.Manifest
        if ($existingStatus -ne "pending_generation" -and -not $retryableReview) {
            [ordered]@{
                status          = "existing"
                productName     = $productDir.Name
                productTextHash = $productTextHash
                inputHash       = $inputHash
                runDir          = $existing.RunDir
                existingStatus  = $existingStatus
            } | Write-Json
            return
        }

        $existingPendingRun = $existing
    }

    $brief = Parse-Brief $text $productDir.Name
    $inferredBrief = Read-InferredBrief $cfg $productDir.FullName
    $brief = Merge-InferredBrief $brief $inferredBrief
    $prompts = @(New-PromptSet $brief $sourceImages $cfg.ProductIdentityMode)
    $referencePolicy = New-ReferencePolicy $cfg.ProductIdentityMode $cfg.RequireImageReference $cfg.AllowReferenceLimitedDrafts $sourceImages
    if ($null -ne $existingPendingRun) {
        $runDirectory = $existingPendingRun.RunDir
        $version = Get-ObjectValue $existingPendingRun.Manifest "version" (Split-Path -Leaf $runDirectory)
        $createdAt = Get-ObjectValue $existingPendingRun.Manifest "createdAt" (Get-Date).ToUniversalTime().ToString("o")
        $prepareStatus = "prepared_refreshed"
    }
    else {
        $version = Get-NextVersionName $productOutputRoot
        $runDirectory = Join-Path $productOutputRoot $version
        $createdAt = (Get-Date).ToUniversalTime().ToString("o")
        $prepareStatus = "prepared"
    }
    $promptDirectory = Join-Path $runDirectory "prompts"

    New-Item -ItemType Directory -Force -Path $promptDirectory | Out-Null

    foreach ($prompt in $prompts) {
        $promptPath = Join-Path $promptDirectory ($prompt.id + ".txt")
        $prompt.prompt | Set-Content -LiteralPath $promptPath -Encoding UTF8
    }

    $manifest = [ordered]@{
        status          = "pending_generation"
        createdAt       = $createdAt
        updatedAt       = (Get-Date).ToUniversalTime().ToString("o")
        configPath      = $cfg.ConfigPath
        inputRoot       = $cfg.InputRoot
        outputRoot      = $cfg.OutputRoot
        productFolder   = $productDir.Name
        productPath     = $productDir.FullName
        briefFile       = $cfg.BriefFile
        generatedBriefFile = $cfg.GeneratedBriefFile
        promptSchemaVersion = $cfg.PromptSchemaVersion
        completeMarkerFile = $cfg.CompleteMarkerFile
        readyMarker     = $cfg.ReadyMarker
        language        = $cfg.Language
        imageMinSize    = $cfg.ImageMinSize
        requirePngImages = $cfg.RequirePngImages
        lockStaleMinutes = $cfg.LockStaleMinutes
        imageBackend   = $cfg.ImageBackend
        codexImageModel = $cfg.CodexImageModel
        productIdentityMode = $cfg.ProductIdentityMode
        requireImageReference = $cfg.RequireImageReference
        allowReferenceLimitedDrafts = $cfg.AllowReferenceLimitedDrafts
        stopOnIdentityDrift = $cfg.StopOnIdentityDrift
        continueAfterImageFailure = $cfg.ContinueAfterImageFailure
        sourcePreserveOutputSize = $cfg.SourcePreserveOutputSize
        referencePolicy = $referencePolicy
        productTextHash = $productTextHash
        inputHash       = $inputHash
        version         = $version
        brief           = $brief
        inferredBrief   = $inferredBrief
        sourceImages    = $sourceImages
        promptSet       = $prompts
        expectedFiles   = @($prompts | ForEach-Object { $_.file })
        imageTasks      = @(New-InitialImageTasks $runDirectory $prompts)
        files           = @()
        errors          = @()
    }

    Write-RunManifest $runDirectory $manifest
    Write-RunLog $runDirectory "prepare" ([ordered]@{
        status    = $prepareStatus
        product   = $productDir.Name
        version   = $version
        promptCount = $prompts.Count
    })

    [ordered]@{
        status          = $prepareStatus
        productName     = $productDir.Name
        productTextHash = $productTextHash
        inputHash       = $inputHash
        inferredBrief   = $inferredBrief
        sourceImages    = $sourceImages
        referencePolicy = $referencePolicy
        version         = $version
        runDir          = $runDirectory
        promptDir       = $promptDirectory
        promptSet       = $prompts
    } | Write-Json
    }
    finally {
        Remove-AutomationLock $lock
    }
}

function Get-ImageInfo {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            path   = $Path
            exists = $false
        }
    }

    $item = Get-Item -LiteralPath $Path
    $info = [ordered]@{
        path   = $Path
        exists = $true
        bytes  = $item.Length
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $image = [System.Drawing.Image]::FromFile($Path)
        try {
            $info["width"] = $image.Width
            $info["height"] = $image.Height
            if ($image.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Png.Guid) {
                $info["format"] = "png"
            }
            elseif ($image.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid) {
                $info["format"] = "jpeg"
            }
            elseif ($image.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Bmp.Guid) {
                $info["format"] = "bmp"
            }
            elseif ($image.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Gif.Guid) {
                $info["format"] = "gif"
            }
            elseif ($image.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Tiff.Guid) {
                $info["format"] = "tiff"
            }
            else {
                $info["format"] = "unknown"
            }
        }
        finally {
            $image.Dispose()
        }
    }
    catch {
        $info["imageError"] = $_.Exception.Message
    }

    return [pscustomobject]$info
}

function Read-RunManifest {
    if ([string]::IsNullOrWhiteSpace($RunDir)) {
        throw "RunDir is required."
    }

    $resolvedRunDir = [System.IO.Path]::GetFullPath($RunDir)
    $manifestPath = Join-Path $resolvedRunDir "run.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "run.json not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    return [pscustomobject]@{
        RunDir       = $resolvedRunDir
        ManifestPath = $manifestPath
        Manifest     = $manifest
    }
}

function Get-ManifestImageTask {
    param(
        [object]$Manifest,
        [string]$Id,
        [string]$FileName
    )

    foreach ($task in @(Get-ObjectValue $Manifest "imageTasks" @())) {
        $taskId = Get-ObjectValue $task "id" ""
        $taskFile = Get-ObjectValue $task "file" ""
        if ($taskId -eq $Id -or $taskFile -eq $FileName) {
            return $task
        }
    }

    return $null
}

function New-InitialImageTasks {
    param(
        [string]$RunDirectory,
        [object[]]$PromptSet
    )

    $promptDirectory = Join-Path $RunDirectory "prompts"
    $now = (Get-Date).ToUniversalTime().ToString("o")
    return @($PromptSet | ForEach-Object {
        $id = Get-ObjectValue $_ "id" ""
        $fileName = Get-ObjectValue $_ "file" ""
        [pscustomobject]@{
            id           = $id
            file         = $fileName
            status       = "pending"
            outputPath   = Join-Path $RunDirectory $fileName
            promptPath   = Join-Path $promptDirectory ($id + ".txt")
            promptExists = Test-Path -LiteralPath (Join-Path $promptDirectory ($id + ".txt")) -PathType Leaf
            updatedAt    = $now
            errors       = @()
        }
    })
}

function Set-ImageTaskFailure {
    param(
        [object]$Manifest,
        [string]$TargetFile,
        [string]$FailureMessage
    )

    $expected = @(Get-ExpectedFiles $Manifest)
    $taskList = New-Object "System.Collections.Generic.List[object]"
    $matched = $false
    $now = (Get-Date).ToUniversalTime().ToString("o")

    foreach ($fileName in $expected) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $existing = Get-ManifestImageTask $Manifest $id $fileName
        $task = if ($null -ne $existing) {
            $existing
        }
        else {
            [pscustomobject]@{
                id           = $id
                file         = $fileName
                status       = "pending"
                outputPath   = ""
                promptPath   = ""
                promptExists = $false
                updatedAt    = $now
                errors       = @()
            }
        }

        if ($TargetFile -eq $fileName -or $TargetFile -eq $id) {
            $matched = $true
            Set-ObjectValue $task "status" "failed"
            Set-ObjectValue $task "updatedAt" $now
            Set-ObjectValue $task "failedAt" $now
            Set-ObjectValue $task "message" $FailureMessage
            Set-ObjectValue $task "errors" @(@(Get-ObjectValue $task "errors" @()) + $FailureMessage)
        }

        $taskList.Add($task)
    }

    if (-not $matched) {
        throw "File '$TargetFile' is not one of the expected output files."
    }

    return $taskList.ToArray()
}

function Test-RunImages {
    param(
        [string]$RunDirectory,
        [object]$Manifest
    )

    $expected = @(Get-ExpectedFiles $Manifest)
    $imageMinSize = [int](Get-ObjectValue $Manifest "imageMinSize" 1024)
    $requirePngImages = [bool](Get-ObjectValue $Manifest "requirePngImages" $true)
    $files = New-Object "System.Collections.Generic.List[object]"
    $errors = New-Object "System.Collections.Generic.List[string]"
    $missing = New-Object "System.Collections.Generic.List[string]"
    $imageTasks = New-Object "System.Collections.Generic.List[object]"
    $promptDirectory = Join-Path $RunDirectory "prompts"

    foreach ($fileName in $expected) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $imagePath = Join-Path $RunDirectory $fileName
        $promptPath = Join-Path $promptDirectory ($id + ".txt")
        $existingTask = Get-ManifestImageTask $Manifest $id $fileName
        $previousStatus = Get-ObjectValue $existingTask "status" ""
        $taskErrors = New-Object "System.Collections.Generic.List[string]"
        $info = Get-ImageInfo $imagePath
        $files.Add($info)

        if (-not $info.exists) {
            $messageText = "Missing image: $fileName"
            $errors.Add($messageText)
            $taskErrors.Add($messageText)
            $missing.Add($fileName)
        }
        else {
            if ($info.bytes -le 0) {
                $messageText = "Empty image file: $fileName"
                $errors.Add($messageText)
                $taskErrors.Add($messageText)
            }

            $width = Get-ObjectValue $info "width" 0
            $height = Get-ObjectValue $info "height" 0
            if ($width -le 0 -or $height -le 0) {
                $imageError = Get-ObjectValue $info "imageError" "unable to read dimensions"
                $messageText = "Unreadable image dimensions for ${fileName}: $imageError"
                $errors.Add($messageText)
                $taskErrors.Add($messageText)
            }
            else {
                $ratioDelta = [Math]::Abs($width - $height) / [Math]::Max($width, $height)
                if ($ratioDelta -gt 0.08) {
                    $messageText = "Image is not close to square: $fileName ($width x $height)"
                    $errors.Add($messageText)
                    $taskErrors.Add($messageText)
                }

                if ($imageMinSize -gt 0 -and ($width -lt $imageMinSize -or $height -lt $imageMinSize)) {
                    $messageText = "Image is smaller than minimum size: $fileName ($width x $height, minimum ${imageMinSize}px)"
                    $errors.Add($messageText)
                    $taskErrors.Add($messageText)
                }

                $format = Get-ObjectValue $info "format" ""
                if ($requirePngImages -and $format -ne "png") {
                    $messageText = "Image is not PNG format: $fileName ($format)"
                    $errors.Add($messageText)
                    $taskErrors.Add($messageText)
                }
            }
        }

        $taskStatus = if ($info.exists -and $taskErrors.Count -eq 0) {
            "generated"
        }
        elseif (-not $info.exists -and $previousStatus -eq "failed") {
            "failed"
        }
        elseif ($info.exists) {
            "needs_review"
        }
        else {
            "pending"
        }

        $storedErrors = @(Get-ObjectValue $existingTask "errors" @())
        if ($taskStatus -eq "failed" -and $storedErrors.Count -gt 0) {
            foreach ($storedError in $storedErrors) {
                if ($taskErrors -notcontains $storedError) {
                    $taskErrors.Add($storedError)
                }
            }
        }

        $imageTasks.Add([pscustomobject]@{
            id           = $id
            file         = $fileName
            status       = $taskStatus
            previousStatus = $previousStatus
            outputPath   = $imagePath
            promptPath   = $promptPath
            promptExists = Test-Path -LiteralPath $promptPath -PathType Leaf
            exists       = $info.exists
            width        = Get-ObjectValue $info "width" 0
            height       = Get-ObjectValue $info "height" 0
            format       = Get-ObjectValue $info "format" ""
            bytes        = Get-ObjectValue $info "bytes" 0
            updatedAt    = (Get-Date).ToUniversalTime().ToString("o")
            errors       = $taskErrors.ToArray()
        })
    }

    return [pscustomobject]@{
        status        = if ($errors.Count -eq 0) { "complete" } else { "needs_review" }
        expectedFiles = $expected
        files         = $files.ToArray()
        imageTasks    = $imageTasks.ToArray()
        errors        = $errors.ToArray()
        missingFiles  = $missing.ToArray()
        missingCount  = $missing.Count
    }
}

function Invoke-Inspect {
    $run = Read-RunManifest
    $manifest = $run.Manifest
    $result = Test-RunImages $run.RunDir $manifest

    [ordered]@{
        status         = $result.status
        manifestStatus = Get-ObjectValue $manifest "status" ""
        runDir         = $run.RunDir
        productName    = Get-ObjectValue $manifest "productFolder" ""
        version        = Get-ObjectValue $manifest "version" ""
        expectedFiles  = $result.expectedFiles
        files          = $result.files
        imageTasks     = $result.imageTasks
        missingFiles   = $result.missingFiles
        missingCount   = $result.missingCount
        errors         = $result.errors
    } | Write-Json
}

function Invoke-TaskStatus {
    $run = Read-RunManifest
    $manifest = $run.Manifest
    $result = Test-RunImages $run.RunDir $manifest

    [ordered]@{
        status         = $result.status
        manifestStatus = Get-ObjectValue $manifest "status" ""
        runDir         = $run.RunDir
        productName    = Get-ObjectValue $manifest "productFolder" ""
        version        = Get-ObjectValue $manifest "version" ""
        taskCount      = @($result.imageTasks).Count
        imageTasks     = $result.imageTasks
        missingCount   = $result.missingCount
        missingFiles   = $result.missingFiles
        errors         = $result.errors
    } | Write-Json
}

function Invoke-Generate {
    $run = Read-RunManifest
    $manifest = $run.Manifest
    $cfg = Get-ConfigObject
    $result = Test-RunImages $run.RunDir $manifest
    $presence = Get-RunFilePresence $run.RunDir $manifest
    $manifestSourceImages = @(Get-ObjectValue $manifest "sourceImages" @())
    $referencePolicy = New-ReferencePolicy `
        (Get-ObjectValue $manifest "productIdentityMode" $cfg.ProductIdentityMode) `
        ([bool](Get-ObjectValue $manifest "requireImageReference" $cfg.RequireImageReference)) `
        ([bool](Get-ObjectValue $manifest "allowReferenceLimitedDrafts" $cfg.AllowReferenceLimitedDrafts)) `
        $manifestSourceImages
    $sourceImagePaths = @($manifestSourceImages | ForEach-Object {
        Get-ObjectValue $_ "path" ""
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $tasks = New-Object "System.Collections.Generic.List[object]"
    foreach ($imageTask in @($result.imageTasks | Where-Object { @("pending", "failed", "needs_review") -contains $_.status })) {
        $tasks.Add([pscustomobject]@{
            id               = $imageTask.id
            file             = $imageTask.file
            status           = $imageTask.status
            outputPath       = $imageTask.outputPath
            promptPath       = $imageTask.promptPath
            promptExists     = $imageTask.promptExists
            errors           = $imageTask.errors
            sourceImagePaths = $sourceImagePaths
            referencePolicy  = $referencePolicy
        })
    }

    $missingPrompts = @($tasks.ToArray() | Where-Object { -not $_.promptExists })
    $status = if ($tasks.Count -eq 0) {
        "nothing_to_generate"
    }
    elseif ($missingPrompts.Count -gt 0) {
        "needs_review"
    }
    else {
        "ready"
    }

    [ordered]@{
        status         = $status
        manifestStatus = Get-ObjectValue $manifest "status" ""
        runDir         = $run.RunDir
        productName    = Get-ObjectValue $manifest "productFolder" ""
        version        = Get-ObjectValue $manifest "version" ""
        promptDir      = Join-Path $run.RunDir "prompts"
        expectedFiles  = $presence.expectedFiles
        presentFiles   = $presence.presentFiles
        missingFiles   = $presence.missingFiles
        missingCount   = $presence.missingCount
        referencePolicy = $referencePolicy
        generationBatchPolicy = [ordered]@{
            saveRejectedCandidates = $true
            generateAllSlotsBeforeReview = $true
            imageAttemptsPerSlot = 1
        }
        imageTasks     = $result.imageTasks
        taskCount      = $tasks.Count
        tasks          = $tasks.ToArray()
    } | Write-Json
}

function Get-ContentTypeForPath {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg"  { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png"  { return "image/png" }
        ".webp" { return "image/webp" }
        ".bmp"  { return "image/bmp" }
        ".tif"  { return "image/tiff" }
        ".tiff" { return "image/tiff" }
        default { return "application/octet-stream" }
    }
}

function Invoke-ImageBackend {
    param(
        [string]$Backend,
        [object]$Manifest,
        [string]$Prompt,
        [string]$OutputPath
    )

    switch ($Backend) {
        "mock" {
            $bytes = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l1I3mwAAAABJRU5ErkJggg==")
            [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
            return
        }
        default {
            throw "imageBackend '$Backend' is handled by the Codex automation layer, not by this PowerShell command."
        }
    }
}

function Invoke-GenerateImages {
    if ([string]::IsNullOrWhiteSpace($RunDir)) {
        throw "RunDir is required for generate-images."
    }

    $run = Read-RunManifest
    $manifest = $run.Manifest
    $cfg = Get-ConfigObject
    foreach ($configField in @(
        @("imageBackend", $cfg.ImageBackend),
        @("codexImageModel", $cfg.CodexImageModel),
        @("productIdentityMode", $cfg.ProductIdentityMode),
        @("requireImageReference", $cfg.RequireImageReference),
        @("allowReferenceLimitedDrafts", $cfg.AllowReferenceLimitedDrafts),
        @("stopOnIdentityDrift", $cfg.StopOnIdentityDrift),
        @("continueAfterImageFailure", $cfg.ContinueAfterImageFailure),
        @("sourcePreserveOutputSize", $cfg.SourcePreserveOutputSize),
        @("imageMinSize", $cfg.ImageMinSize),
        @("requirePngImages", $cfg.RequirePngImages),
        @("lockStaleMinutes", $cfg.LockStaleMinutes)
    )) {
        $name = $configField[0]
        $value = $configField[1]
        $current = ConvertTo-PlainText (Get-ObjectValue $manifest $name "")
        if ($name -eq "codexImageModel") {
            if ($current -ne "image2") {
                Set-ObjectValue $manifest $name $value
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($current)) {
            Set-ObjectValue $manifest $name $value
        }
    }

    $backend = Get-ObjectValue $manifest "imageBackend" $cfg.ImageBackend
    if ($backend -eq "manual" -or $backend -eq "codex-image2") {
        [ordered]@{
            status  = "backend_blocked"
            backend = $backend
            runDir  = $run.RunDir
            message = "imageBackend '$backend' is handled by the Codex automation layer; this PowerShell command will not create files."
            tasks   = (Invoke-Generate | ConvertFrom-Json).tasks
        } | Write-Json
        return
    }

    $lock = New-AutomationLock (Join-Path $run.RunDir ".run.lock") "generate-images:$($run.RunDir)" (Get-ObjectValue $manifest "lockStaleMinutes" 120)
    try {
        $before = Test-RunImages $run.RunDir $manifest
        $targets = @($before.imageTasks | Where-Object { @("pending", "failed", "needs_review") -contains $_.status })
        $generated = New-Object "System.Collections.Generic.List[object]"
        $failed = New-Object "System.Collections.Generic.List[object]"

        foreach ($task in $targets) {
            if (-not $task.promptExists) {
                $failed.Add([pscustomobject]@{
                    file = $task.file
                    error = "Prompt file is missing: $($task.promptPath)"
                })
                continue
            }

            try {
                $prompt = Get-Content -LiteralPath $task.promptPath -Raw -Encoding UTF8
                Invoke-ImageBackend $backend $manifest $prompt $task.outputPath
                $generated.Add([pscustomobject]@{
                    file = $task.file
                    outputPath = $task.outputPath
                })
                Write-RunLog $run.RunDir "image-generated" ([ordered]@{
                    backend = $backend
                    file = $task.file
                    outputPath = $task.outputPath
                })
            }
            catch {
                $failed.Add([pscustomobject]@{
                    file = $task.file
                    error = $_.Exception.Message
                })
                Set-ObjectValue $manifest "imageTasks" (Set-ImageTaskFailure $manifest $task.file $_.Exception.Message)
                Write-RunLog $run.RunDir "image-generate-failed" ([ordered]@{
                    backend = $backend
                    file = $task.file
                    error = $_.Exception.Message
                })
            }
        }

        $result = Test-RunImages $run.RunDir $manifest
        $now = (Get-Date).ToUniversalTime().ToString("o")
        $status = if ($failed.Count -gt 0) {
            "needs_review"
        }
        elseif ($result.errors.Count -eq 0) {
            "complete"
        }
        else {
            "pending_generation"
        }

        Set-ObjectValue $manifest "status" $status
        Set-ObjectValue $manifest "updatedAt" $now
        Set-ObjectValue $manifest "files" $result.files
        Set-ObjectValue $manifest "imageTasks" $result.imageTasks
        Set-ObjectValue $manifest "errors" $result.errors
        if ($status -eq "complete") {
            Set-ObjectValue $manifest "validatedAt" $now
            Write-CompletionMarker $manifest $run.RunDir
        }

        Write-RunManifest $run.RunDir $manifest
        Write-RunLog $run.RunDir "generate-images" ([ordered]@{
            backend = $backend
            status = $status
            generatedCount = $generated.Count
            failedCount = $failed.Count
            missingCount = $result.missingCount
        })

        [ordered]@{
            status = $status
            backend = $backend
            runDir = $run.RunDir
            generatedCount = $generated.Count
            failedCount = $failed.Count
            missingCount = $result.missingCount
            generated = $generated.ToArray()
            failed = $failed.ToArray()
            imageTasks = $result.imageTasks
            errors = $result.errors
        } | Write-Json
    }
    finally {
        Remove-AutomationLock $lock
    }
}

function Get-VersionNumber {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return -1
    }

    if ($Version -match '^v(\d+)$') {
        return [int]$Matches[1]
    }

    return -1
}

function Invoke-ListRuns {
    $cfg = Get-ConfigObject
    $runs = New-Object "System.Collections.Generic.List[object]"

    if (-not (Test-Path -LiteralPath $cfg.OutputRoot -PathType Container)) {
        [ordered]@{
            status     = "ok"
            outputRoot = $cfg.OutputRoot
            product    = $Product
            runs       = @()
        } | Write-Json
        return
    }

    $productDirs = if ([string]::IsNullOrWhiteSpace($Product)) {
        @(Get-ChildItem -LiteralPath $cfg.OutputRoot -Directory | Sort-Object Name)
    }
    else {
        $productOutputRoot = Join-Path $cfg.OutputRoot (Get-SafeName $Product)
        if (Test-Path -LiteralPath $productOutputRoot -PathType Container) {
            @([System.IO.DirectoryInfo]$productOutputRoot)
        }
        else {
            @()
        }
    }

    foreach ($productOutputDir in $productDirs) {
        foreach ($versionDir in (Get-ChildItem -LiteralPath $productOutputDir.FullName -Directory | Sort-Object Name)) {
            $manifestPath = Join-Path $versionDir.FullName "run.json"
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                continue
            }

            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $presence = Get-RunFilePresence $versionDir.FullName $manifest
                $runs.Add([pscustomobject]@{
                    productName    = Get-ObjectValue $manifest "productFolder" $productOutputDir.Name
                    version        = Get-ObjectValue $manifest "version" $versionDir.Name
                    status         = Get-ObjectValue $manifest "status" "unknown"
                    reason         = Get-ObjectValue $manifest "reason" ""
                    runDir         = $versionDir.FullName
                    createdAt      = Get-ObjectValue $manifest "createdAt" ""
                    updatedAt      = Get-ObjectValue $manifest "updatedAt" ""
                    ageHours       = Get-RunAgeHours $manifest
                    expectedCount  = $presence.expectedCount
                    presentCount   = $presence.presentCount
                    missingCount   = $presence.missingCount
                    missingFiles   = $presence.missingFiles
                    errorCount     = @(Get-ObjectValue $manifest "errors" @()).Count
                })
            }
            catch {
                $runs.Add([pscustomobject]@{
                    productName    = $productOutputDir.Name
                    version        = $versionDir.Name
                    status         = "unreadable"
                    reason         = $_.Exception.Message
                    runDir         = $versionDir.FullName
                    createdAt      = ""
                    updatedAt      = ""
                    ageHours       = $null
                    expectedCount  = 0
                    presentCount   = 0
                    missingCount   = 0
                    missingFiles   = @()
                    errorCount     = 1
                })
            }
        }
    }

    [ordered]@{
        status     = "ok"
        outputRoot = $cfg.OutputRoot
        product    = $Product
        runCount   = $runs.Count
        runs       = $runs.ToArray()
    } | Write-Json
}

function Invoke-MarkSuperseded {
    $cfg = Get-ConfigObject
    $candidates = New-Object "System.Collections.Generic.List[object]"
    $updated = New-Object "System.Collections.Generic.List[object]"

    if (-not (Test-Path -LiteralPath $cfg.OutputRoot -PathType Container)) {
        [ordered]@{
            status     = "ok"
            dryRun     = [bool]$DryRun
            outputRoot = $cfg.OutputRoot
            product    = $Product
            candidates = @()
            updated    = @()
        } | Write-Json
        return
    }

    $productDirs = if ([string]::IsNullOrWhiteSpace($Product)) {
        @(Get-ChildItem -LiteralPath $cfg.OutputRoot -Directory | Sort-Object Name)
    }
    else {
        $productOutputRoot = Join-Path $cfg.OutputRoot (Get-SafeName $Product)
        if (Test-Path -LiteralPath $productOutputRoot -PathType Container) {
            @([System.IO.DirectoryInfo]$productOutputRoot)
        }
        else {
            @()
        }
    }

    foreach ($productOutputDir in $productDirs) {
        $records = New-Object "System.Collections.Generic.List[object]"
        foreach ($versionDir in (Get-ChildItem -LiteralPath $productOutputDir.FullName -Directory | Sort-Object Name)) {
            $manifestPath = Join-Path $versionDir.FullName "run.json"
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                continue
            }

            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $version = Get-ObjectValue $manifest "version" $versionDir.Name
                $records.Add([pscustomobject]@{
                    productName  = Get-ObjectValue $manifest "productFolder" $productOutputDir.Name
                    version      = $version
                    versionNo    = Get-VersionNumber $version
                    status       = Get-ObjectValue $manifest "status" "unknown"
                    runDir       = $versionDir.FullName
                    manifestPath = $manifestPath
                })
            }
            catch {
                continue
            }
        }

        $recordArray = @($records.ToArray())
        if ($recordArray.Count -le 1) {
            continue
        }

        $latest = @($recordArray | Sort-Object versionNo, version | Select-Object -Last 1)[0]
        foreach ($record in $recordArray) {
            if ($record.runDir -eq $latest.runDir) {
                continue
            }

            if ($record.status -ne "pending_generation") {
                continue
            }

            $candidate = [pscustomobject]@{
                productName      = $record.productName
                version          = $record.version
                previousStatus   = $record.status
                runDir           = $record.runDir
                supersededBy     = $latest.version
                supersededByRunDir = $latest.runDir
            }
            $candidates.Add($candidate)

            if ($DryRun) {
                continue
            }

            $lock = New-AutomationLock (Join-Path $record.runDir ".run.lock") "mark-superseded:$($record.runDir)" $cfg.LockStaleMinutes
            try {
                $manifest = Get-Content -LiteralPath $record.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $currentStatus = Get-ObjectValue $manifest "status" "unknown"
                if ($currentStatus -ne "pending_generation") {
                    continue
                }

                $now = (Get-Date).ToUniversalTime().ToString("o")
                Set-ObjectValue $manifest "previousStatus" $currentStatus
                Set-ObjectValue $manifest "status" "superseded"
                Set-ObjectValue $manifest "updatedAt" $now
                Set-ObjectValue $manifest "supersededAt" $now
                Set-ObjectValue $manifest "supersededByRunDir" $latest.runDir
                Set-ObjectValue $manifest "supersededReason" $(if ([string]::IsNullOrWhiteSpace($Message)) { "Superseded by newer run." } else { $Message })
                Write-RunManifest $record.runDir $manifest
                Write-RunLog $record.runDir "mark-superseded" ([ordered]@{
                    supersededBy = $latest.version
                    supersededByRunDir = $latest.runDir
                })
                $updated.Add($candidate)
            }
            finally {
                Remove-AutomationLock $lock
            }
        }
    }

    [ordered]@{
        status         = "ok"
        dryRun         = [bool]$DryRun
        outputRoot     = $cfg.OutputRoot
        product        = $Product
        candidateCount = $candidates.Count
        updatedCount   = $updated.Count
        candidates     = $candidates.ToArray()
        updated        = $updated.ToArray()
    } | Write-Json
}

function Add-DoctorCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Level,
        [string]$Area,
        [string]$Message,
        [string]$Path = ""
    )

    $Checks.Add([pscustomobject]@{
        level   = $Level
        area    = $Area
        message = $Message
        path    = $Path
    })
}

function Invoke-Doctor {
    $checks = New-Object "System.Collections.Generic.List[object]"
    $products = New-Object "System.Collections.Generic.List[object]"
    $runs = New-Object "System.Collections.Generic.List[object]"
    $locks = New-Object "System.Collections.Generic.List[object]"

    try {
        $cfg = Get-ConfigObject
    }
    catch {
        Add-DoctorCheck $checks "error" "config" $_.Exception.Message $Config
        [ordered]@{
            status     = "needs_attention"
            checkedAt  = (Get-Date).ToUniversalTime().ToString("o")
            checks     = $checks.ToArray()
            products   = @()
            runs       = @()
            locks      = @()
        } | Write-Json
        return
    }

    Add-DoctorCheck $checks "info" "config" "Config loaded." $cfg.ConfigPath

    if ($cfg.ImageBackend -eq "codex-image2" -and $cfg.CodexImageModel -eq "image2") {
        Add-DoctorCheck $checks "info" "image-backend" "Codex built-in image2 backend is configured." $cfg.ConfigPath
    }
    elseif ($cfg.ImageBackend -eq "manual") {
        Add-DoctorCheck $checks "warning" "image-backend" "imageBackend is manual; automatic image generation is disabled." $cfg.ConfigPath
    }

    if (Test-Path -LiteralPath $cfg.InputRoot -PathType Container) {
        Add-DoctorCheck $checks "info" "input" "Input root exists." $cfg.InputRoot
    }
    else {
        Add-DoctorCheck $checks "error" "input" "Input root is missing." $cfg.InputRoot
    }

    if (Test-Path -LiteralPath $cfg.OutputRoot -PathType Container) {
        Add-DoctorCheck $checks "info" "output" "Output root exists." $cfg.OutputRoot
    }
    else {
        Add-DoctorCheck $checks "warning" "output" "Output root does not exist yet; prepare will create it when needed." $cfg.OutputRoot
    }

    foreach ($productDir in (Get-ChildItem -LiteralPath $cfg.InputRoot -Directory | Sort-Object Name)) {
        $readyPath = Join-Path $productDir.FullName $cfg.ReadyMarker
        $briefPath = Join-Path $productDir.FullName $cfg.BriefFile
        $readyExists = Test-Path -LiteralPath $readyPath -PathType Leaf
        $briefExists = Test-Path -LiteralPath $briefPath -PathType Leaf
        $sourceImages = @(Get-SourceImages $productDir.FullName)
        $inferred = Read-InferredBrief $cfg $productDir.FullName
        $inputWarnings = @()
        $missingFields = @()
        $userProvidedFieldCount = 0

        if ($briefExists) {
            $text = Read-ProductText $cfg $productDir.FullName
            $health = Get-ProductInputHealth $cfg $productDir $text $sourceImages
            $inputWarnings = @($health.inputWarnings)
            $missingFields = @($health.briefMissingFields)
            $userProvidedFieldCount = $health.userProvidedFieldCount
        }

        if (-not $readyExists) {
            Add-DoctorCheck $checks "warning" "product" "Product is missing ready marker." $productDir.FullName
        }

        if (-not $briefExists -and $readyExists) {
            Add-DoctorCheck $checks "error" "product" "Ready product is missing brief file." $productDir.FullName
        }

        if ($readyExists -and $sourceImages.Count -eq 0) {
            Add-DoctorCheck $checks "warning" "product" "Ready product has no source images." $productDir.FullName
        }

        foreach ($warning in $inputWarnings) {
            Add-DoctorCheck $checks "warning" "product" $warning $productDir.FullName
        }

        foreach ($errorText in @($inferred.errors)) {
            Add-DoctorCheck $checks "warning" "product" "Inferred brief issue: $errorText" $inferred.path
        }

        $products.Add([pscustomobject]@{
            productName            = $productDir.Name
            productPath            = $productDir.FullName
            ready                  = $readyExists
            briefExists            = $briefExists
            sourceImageCount       = $sourceImages.Count
            inferredBriefExists    = $inferred.exists
            userProvidedFieldCount = $userProvidedFieldCount
            briefMissingFields     = $missingFields
            inputWarnings          = $inputWarnings
        })
    }

    if (Test-Path -LiteralPath $cfg.OutputRoot -PathType Container) {
        foreach ($manifestFile in (Get-ChildItem -LiteralPath $cfg.OutputRoot -Recurse -Filter "run.json" -File | Sort-Object FullName)) {
            $runDir = Split-Path -Parent $manifestFile.FullName
            try {
                $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $presence = Get-RunFilePresence $runDir $manifest
                $status = Get-ObjectValue $manifest "status" "unknown"
                if ($status -eq "pending_generation" -and $presence.missingCount -gt 0) {
                    Add-DoctorCheck $checks "warning" "run" "Run is pending and missing images." $runDir
                }

                $runs.Add([pscustomobject]@{
                    productName   = Get-ObjectValue $manifest "productFolder" ""
                    version       = Get-ObjectValue $manifest "version" (Split-Path -Leaf $runDir)
                    status        = $status
                    runDir        = $runDir
                    missingCount  = $presence.missingCount
                    errorCount    = @(Get-ObjectValue $manifest "errors" @()).Count
                    ageHours      = Get-RunAgeHours $manifest
                })
            }
            catch {
                Add-DoctorCheck $checks "error" "run" "Unreadable run manifest: $($_.Exception.Message)" $manifestFile.FullName
            }
        }

        foreach ($lockFile in (Get-ChildItem -LiteralPath $cfg.OutputRoot -Recurse -Filter "*.lock" -File | Sort-Object FullName)) {
            $lockInfo = Read-LockFile $lockFile.FullName
            $ageMinutes = Get-ObjectValue $lockInfo "ageMinutes" $null
            $isStale = $cfg.LockStaleMinutes -gt 0 -and $null -ne $ageMinutes -and $ageMinutes -ge $cfg.LockStaleMinutes
            $level = if ($isStale) { "warning" } else { "info" }
            Add-DoctorCheck $checks $level "lock" $(if ($isStale) { "Stale lock exists." } else { "Active lock exists." }) $lockFile.FullName
            $locks.Add([pscustomobject]@{
                path       = $lockInfo.path
                readable   = Get-ObjectValue $lockInfo "readable" $false
                scope      = Get-ObjectValue $lockInfo "scope" ""
                command    = Get-ObjectValue $lockInfo "command" ""
                pid        = Get-ObjectValue $lockInfo "pid" ""
                createdAt  = Get-ObjectValue $lockInfo "createdAt" ""
                ageMinutes = $ageMinutes
                stale      = $isStale
            })
        }
    }

    $checkArray = @($checks.ToArray())
    $errorCount = @($checkArray | Where-Object { $_.level -eq "error" }).Count
    $warningCount = @($checkArray | Where-Object { $_.level -eq "warning" }).Count
    $status = if ($errorCount -gt 0) {
        "needs_attention"
    }
    elseif ($warningCount -gt 0) {
        "warning"
    }
    else {
        "ok"
    }

    [ordered]@{
        status       = $status
        checkedAt    = (Get-Date).ToUniversalTime().ToString("o")
        configPath   = $cfg.ConfigPath
        inputRoot    = $cfg.InputRoot
        outputRoot   = $cfg.OutputRoot
        errorCount   = $errorCount
        warningCount = $warningCount
        productCount = $products.Count
        runCount     = $runs.Count
        lockCount    = $locks.Count
        checks       = $checkArray
        products     = $products.ToArray()
        runs         = $runs.ToArray()
        locks        = $locks.ToArray()
    } | Write-Json
}

function Invoke-Validate {
    if ([string]::IsNullOrWhiteSpace($RunDir)) {
        throw "RunDir is required for validate."
    }

    $run = Read-RunManifest
    $manifest = $run.Manifest

    if ($DryRun) {
        $result = Test-RunImages $run.RunDir $manifest
        [ordered]@{
            status         = $result.status
            dryRun         = $true
            manifestStatus = Get-ObjectValue $manifest "status" ""
            runDir         = $run.RunDir
            productName    = Get-ObjectValue $manifest "productFolder" ""
            version        = Get-ObjectValue $manifest "version" ""
            expectedFiles  = $result.expectedFiles
            files          = $result.files
            imageTasks     = $result.imageTasks
            missingFiles   = $result.missingFiles
            missingCount   = $result.missingCount
            errors         = $result.errors
        } | Write-Json
        return
    }

    $lock = New-AutomationLock (Join-Path $run.RunDir ".run.lock") "validate:$($run.RunDir)" (Get-ObjectValue $manifest "lockStaleMinutes" 120)
    try {
    $result = Test-RunImages $run.RunDir $manifest

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $newStatus = $result.status
    Set-ObjectValue $manifest "status" $newStatus
    Set-ObjectValue $manifest "updatedAt" $now
    Set-ObjectValue $manifest "validatedAt" $now
    Set-ObjectValue $manifest "files" $result.files
    Set-ObjectValue $manifest "imageTasks" $result.imageTasks
    Set-ObjectValue $manifest "errors" $result.errors

    if ($newStatus -eq "complete") {
        Write-CompletionMarker $manifest $run.RunDir
    }

    Write-RunManifest $run.RunDir $manifest
    Write-RunLog $run.RunDir "validate" ([ordered]@{
        status       = $newStatus
        missingCount = $result.missingCount
        errorCount   = @($result.errors).Count
    })

    [ordered]@{
        status = $manifest.status
        runDir = $run.RunDir
        files  = $result.files
        imageTasks = $result.imageTasks
        errors = $result.errors
    } | Write-Json
    }
    finally {
        Remove-AutomationLock $lock
    }
}

function Invoke-MarkFailed {
    if ([string]::IsNullOrWhiteSpace($RunDir)) {
        throw "RunDir is required for mark-failed."
    }

    $run = Read-RunManifest
    $manifest = $run.Manifest
    $lock = New-AutomationLock (Join-Path $run.RunDir ".run.lock") "mark-failed:$($run.RunDir)" (Get-ObjectValue $manifest "lockStaleMinutes" 120)
    try {
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $isImage2PersistenceBlocker = Test-Image2PersistenceBlocker $Message
    $newStatus = if ($isImage2PersistenceBlocker) { "pending_generation" } else { "needs_review" }
    Set-ObjectValue $manifest "status" $newStatus
    Set-ObjectValue $manifest "updatedAt" $now
    $existingErrors = @(Get-ObjectValue $manifest "errors" @())
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "Generation failed before validation."
    }
    $errorMessage = if ([string]::IsNullOrWhiteSpace($File)) {
        $Message
    }
    else {
        "Image failed: ${File} - $Message"
    }
    Set-ObjectValue $manifest "errors" @($existingErrors + $errorMessage)
    if ($isImage2PersistenceBlocker) {
        Set-ObjectValue $manifest "generationBlocker" "image2_persistence_unavailable"
        Set-ObjectValue $manifest "lastGenerationBlockerAt" $now
    }

    if (-not [string]::IsNullOrWhiteSpace($File)) {
        Set-ObjectValue $manifest "imageTasks" (Set-ImageTaskFailure $manifest $File $Message)
    }

    Write-RunManifest $run.RunDir $manifest
    Write-RunLog $run.RunDir "mark-failed" ([ordered]@{
        status  = $newStatus
        file    = $File
        message = $Message
        retryable = $isImage2PersistenceBlocker
    })

    [ordered]@{
        status = $newStatus
        runDir = $run.RunDir
        file   = $File
        retryable = $isImage2PersistenceBlocker
        imageTasks = @(Get-ObjectValue $manifest "imageTasks" @())
        errors = $manifest.errors
    } | Write-Json
    }
    finally {
        Remove-AutomationLock $lock
    }
}

switch ($Command) {
    "sync-links" { Invoke-LinkSync }
    "scan" { Invoke-Scan }
    "prepare" { Invoke-Prepare }
    "generate" { Invoke-Generate }
    "generate-images" { Invoke-GenerateImages }
    "inspect" { Invoke-Inspect }
    "task-status" { Invoke-TaskStatus }
    "list-runs" { Invoke-ListRuns }
    "doctor" { Invoke-Doctor }
    "mark-superseded" { Invoke-MarkSuperseded }
    "validate" { Invoke-Validate }
    "mark-failed" { Invoke-MarkFailed }
}
