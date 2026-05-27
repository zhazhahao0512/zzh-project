[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot "scripts\etsy-picture.ps1"
$TmpRoot = Join-Path $RepoRoot ".tmp\smoke"
$ProductsRoot = Join-Path $TmpRoot "products"
$ConfigPath = Join-Path $TmpRoot "test.config.json"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-ToolJson {
    param([string[]]$ToolArgs)
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ToolArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Tool command failed: $($ToolArgs -join ' ')"
    }
    return ($output | Out-String | ConvertFrom-Json)
}

if (Test-Path -LiteralPath $TmpRoot) {
    Remove-Item -LiteralPath $TmpRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $ProductsRoot | Out-Null

$readyProduct = Join-Path $ProductsRoot "sample-mug"
$notReadyProduct = Join-Path $ProductsRoot "not-ready"
New-Item -ItemType Directory -Force -Path $readyProduct, $notReadyProduct | Out-Null

@"
Product Name: Speckled Ceramic Mug
Category:
Core Description:
Materials / Colors: cream ceramic, blue speckles
Target Customer: gift shoppers and coffee lovers
Style / Mood: warm, modern, cozy
Intro Text: Speckled Ceramic Mug
Must Include: speckled glaze, comfortable handle
Avoid: plastic, logos, extra text
Extra Notes: Keep the product premium and simple.
"@ | Set-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Encoding UTF8
"" | Set-Content -LiteralPath (Join-Path $readyProduct "ready.txt") -Encoding UTF8
"Product Name: Not Ready" | Set-Content -LiteralPath (Join-Path $notReadyProduct "product.txt") -Encoding UTF8
$sourcePngBytes = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l1I3mwAAAABJRU5ErkJggg==")
[System.IO.File]::WriteAllBytes((Join-Path $readyProduct "source-reference.png"), $sourcePngBytes)

$LinkTmpRoot = Join-Path $TmpRoot "link-flow"
$LinkProductsRoot = Join-Path $LinkTmpRoot "products"
$LinkOutputRoot = Join-Path $LinkTmpRoot "outputs"
$LinkTablePath = Join-Path $LinkTmpRoot "1688-products.csv"
$LinkFixtureHtml = Join-Path $LinkTmpRoot "fixture-offer.html"
$LinkFixtureImage = Join-Path $LinkTmpRoot "fixture-product.png"
New-Item -ItemType Directory -Force -Path $LinkTmpRoot | Out-Null
[System.IO.File]::WriteAllBytes($LinkFixtureImage, $sourcePngBytes)
$linkImageUri = ([System.Uri]$LinkFixtureImage).AbsoluteUri
$linkHtml = "<html><body><script>window.__offer={images:['$linkImageUri']};</script></body></html>"
$linkHtml | Set-Content -LiteralPath $LinkFixtureHtml -Encoding UTF8
$linkHtmlUri = ([System.Uri]$LinkFixtureHtml).AbsoluteUri
@"
enabled,productId,productName,productUrl,category,coreDescription,materialsColors,targetCustomer,styleMood,introText,mustInclude,avoid,extraNotes
true,fixture-linked-product,Fixture Linked Product,$linkHtmlUri,Fixture Category,Fixture description,blue sample,online shoppers,clean studio,Fixture Intro,main product,logos,table sourced
"@ | Set-Content -LiteralPath $LinkTablePath -Encoding UTF8
$LinkConfigPath = Join-Path $LinkTmpRoot "link.config.json"
@{
    inputRoot      = $LinkProductsRoot
    outputRoot     = $LinkOutputRoot
    outputRootMode = "sibling"
    linkTableFile  = $LinkTablePath
    linkSyncBeforeScan = $true
    linkImageLimit = 3
    linkMinImageSize = 1
    linkDownloadTimeoutSeconds = 5
    briefFile      = "product.txt"
    generatedBriefFile = "product.inferred.json"
    readyMarker    = "ready.txt"
    completeMarkerFile = "automation.done.txt"
    language       = "en"
    scanCadence    = "hourly"
    promptSchemaVersion = "direction-v2"
    pendingStaleHours = 1
    imageMinSize = 1
    requirePngImages = $true
    lockStaleMinutes = 60
    imageBackend = "mock"
    codexImageModel = "image2"
} | ConvertTo-Json | Set-Content -LiteralPath $LinkConfigPath -Encoding UTF8

$syncedLinks = Invoke-ToolJson @("-Command", "sync-links", "-Config", $LinkConfigPath)
Assert-True ($syncedLinks.status -eq "ok") "sync-links should sync fixture link"
Assert-True ($syncedLinks.syncedCount -eq 1) "sync-links should report one synced row"
Assert-True (Test-Path -LiteralPath (Join-Path $LinkProductsRoot "fixture-linked-product\source-01.png")) "sync-links should download source image"
Assert-True (Test-Path -LiteralPath (Join-Path $LinkProductsRoot "fixture-linked-product\product.txt")) "sync-links should write product brief"
Assert-True (Test-Path -LiteralPath (Join-Path $LinkProductsRoot "fixture-linked-product\ready.txt")) "sync-links should write ready marker"

$linkScan = Invoke-ToolJson @("-Command", "scan", "-Config", $LinkConfigPath)
Assert-True ($linkScan.linkSync.syncedCount -eq 1) "scan should run link sync first when configured"
Assert-True (@($linkScan.pending).Count -eq 1) "synced linked product should enter pending queue"
Assert-True ($linkScan.pending[0].productName -eq "fixture-linked-product") "pending linked product should use productId as folder"

@{
    category = "Mug"
    coreDescription = "Inferred ceramic coffee mug from the reference image."
    materialsColors = "should not override written field"
    visualIdentity = "Same speckled ceramic mug with rounded handle and cream body in every image."
    consistencyRules = "Keep the handle shape, speckled glaze, proportions, and cream-and-blue color palette consistent across all seven images."
    uncertaintyNotes = "Do not claim handmade or dishwasher safe unless written by the user."
    backgroundStrategy = "Use warm kitchen and gifting backgrounds that do not change the mug."
    mainImageDirection = "Clean studio hero image with the mug centered."
    sceneHomeDirection = "Cozy kitchen counter scene."
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $readyProduct "product.inferred.json") -Encoding UTF8

@{
    inputRoot      = $ProductsRoot
    outputRootMode = "sibling"
    briefFile      = "product.txt"
    generatedBriefFile = "product.inferred.json"
    readyMarker    = "ready.txt"
    completeMarkerFile = "automation.done.txt"
    language       = "en"
    scanCadence    = "hourly"
    promptSchemaVersion = "direction-v2"
    pendingStaleHours = 1
    imageMinSize = 1
    requirePngImages = $true
    lockStaleMinutes = 60
    imageBackend = "mock"
    codexImageModel = "image2"
} | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

$scan1 = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scan1.pending).Count -eq 1) "one ready product should be pending"
Assert-True ($scan1.pending[0].productName -eq "sample-mug") "sample-mug should be pending"
Assert-True (@($scan1.skipped | Where-Object { $_.reason -eq "missing_ready_marker" }).Count -eq 1) "not-ready should be skipped"

$prepared = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")
Assert-True ($prepared.status -eq "prepared") "prepare should create a run"
Assert-True (@($prepared.promptSet).Count -eq 7) "prepare should create seven prompts"
Assert-True (@($prepared.sourceImages).Count -eq 1) "prepare should include source images"
Assert-True ($prepared.referencePolicy.mustUseActualSourceImageReferences -eq $true) "prepare should require real source image references when source images exist"
Assert-True ($prepared.referencePolicy.promptOnlyProductionAllowed -eq $false) "prepare should block prompt-only production for referenced products"
Assert-True ($prepared.promptSet[0].prompt -like "*Category: Mug*") "inferred category should fill blank field"
Assert-True ($prepared.promptSet[0].prompt -like "*Core Description: Inferred ceramic coffee mug from the reference image.*") "inferred description should fill blank field"
Assert-True ($prepared.promptSet[0].prompt -like "*Materials / Colors: cream ceramic, blue speckles*") "written fields should override inferred fields"
Assert-True ($prepared.promptSet[0].prompt -like "*Visual Identity Lock: Same speckled ceramic mug*") "visual identity lock should be included"
Assert-True ($prepared.promptSet[0].prompt -like "*Specific direction for this image:*") "asset-specific direction section should be included"
Assert-True ($prepared.promptSet[0].prompt -like "*Direction quality requirements:*") "direction quality requirements should be included"
Assert-True ($prepared.promptSet[0].prompt -like "*Product identity mode is reference-strict*") "prompts should include strict image-to-image identity policy"
Assert-True ($prepared.promptSet[1].prompt -like "*Cozy kitchen counter scene.*") "asset-specific inferred direction should be used"
Assert-True ($prepared.promptSet[0].prompt -like "*Use the source product images as the primary visual reference*") "prompts should mention source image inference"
Assert-True (Test-Path -LiteralPath (Join-Path $prepared.runDir "run.json")) "run.json should exist"

$scan2 = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scan2.pending).Count -eq 1) "prepared but unfinished hash should stay queued for generation"
Assert-True ($scan2.pending[0].reason -eq "resume_existing_pending_generation") "unfinished run should resume instead of creating a duplicate"
Assert-True ($scan2.pending[0].runDir -eq $prepared.runDir) "unfinished run should point to the existing run directory"

foreach ($fileName in @("01-main.png", "02-scene-home.png", "03-scene-use.png", "04-scene-gift.png", "05-scene-detail.png", "06-model.png", "07-intro.png")) {
    [System.IO.File]::WriteAllBytes((Join-Path $prepared.runDir $fileName), $sourcePngBytes)
}

$validated = Invoke-ToolJson @("-Command", "validate", "-RunDir", $prepared.runDir)
Assert-True ($validated.status -eq "complete") "complete image set should validate"
Assert-True ($validated.files[0].format -eq "png") "validate should report detected image format"
Assert-True (@($validated.imageTasks | Where-Object { $_.status -eq "generated" }).Count -eq 7) "validate should write generated image task statuses"
Assert-True (Test-Path -LiteralPath (Join-Path $prepared.runDir "run.log.jsonl")) "validate should append a run log"
Assert-True (Test-Path -LiteralPath (Join-Path $readyProduct "automation.done.txt")) "complete validation should write a product marker"

$scan3 = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scan3.pending).Count -eq 0) "completed hash should not be pending"
Assert-True (@($scan3.skipped | Where-Object { $_.reason -eq "completion_marker_complete" }).Count -eq 1) "completion marker should short-circuit completed products"

Add-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Value "Extra Notes: updated version"
$scan4 = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scan4.pending).Count -eq 1) "changed product text should create a new pending version"
Assert-True ($scan4.pending[0].version -eq "v002") "changed text should plan v002"

$prepared2 = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")

$dryRun = Invoke-ToolJson @("-Command", "validate", "-RunDir", $prepared2.runDir, "-DryRun")
Assert-True ($dryRun.status -eq "needs_review") "dry-run validate should report missing images"
Assert-True ($dryRun.dryRun -eq $true) "dry-run validate should identify that it did not write state"
$manifestAfterDryRun = Get-Content -LiteralPath (Join-Path $prepared2.runDir "run.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($manifestAfterDryRun.status -eq "pending_generation") "dry-run validate should not update run status"

$inspected = Invoke-ToolJson @("-Command", "inspect", "-RunDir", $prepared2.runDir)
Assert-True ($inspected.status -eq "needs_review") "inspect should report missing images without writing"
Assert-True ($inspected.manifestStatus -eq "pending_generation") "inspect should expose the manifest status separately"
$manifestAfterInspect = Get-Content -LiteralPath (Join-Path $prepared2.runDir "run.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($manifestAfterInspect.status -eq "pending_generation") "inspect should not update run status"

$generationPlan = Invoke-ToolJson @("-Command", "generate", "-RunDir", $prepared2.runDir)
Assert-True ($generationPlan.status -eq "ready") "generate should create a task plan when prompts exist"
Assert-True (@($generationPlan.tasks).Count -eq 7) "generate should list one task per missing image"
Assert-True ($generationPlan.tasks[0].promptExists -eq $true) "generate tasks should point at existing prompt files"
Assert-True (@($generationPlan.tasks[0].sourceImagePaths).Count -eq 1) "generate tasks should include source image reference paths"
Assert-True ($generationPlan.tasks[0].referencePolicy.mustUseActualSourceImageReferences -eq $true) "generate tasks should include strict reference policy"
Assert-True ($generationPlan.tasks[0].referencePolicy.promptOnlyProductionAllowed -eq $false) "generate tasks should block prompt-only production"

$taskStatus = Invoke-ToolJson @("-Command", "task-status", "-RunDir", $prepared2.runDir)
Assert-True (@($taskStatus.imageTasks).Count -eq 7) "task-status should report one task per expected image"
Assert-True (@($taskStatus.imageTasks | Where-Object { $_.status -eq "pending" }).Count -eq 7) "task-status should mark missing images pending"

$listedRuns = Invoke-ToolJson @("-Command", "list-runs", "-Config", $ConfigPath)
Assert-True (@($listedRuns.runs).Count -ge 2) "list-runs should summarize generated run directories"
Assert-True (@($listedRuns.runs | Where-Object { $_.productName -eq "sample-mug" -and $_.version -eq "v001" }).Count -eq 1) "list-runs should include complete v001"

$doctor = Invoke-ToolJson @("-Command", "doctor", "-Config", $ConfigPath)
Assert-True ($doctor.productCount -eq 2) "doctor should inspect product folders"
Assert-True ($doctor.runCount -ge 2) "doctor should inspect run manifests"
Assert-True ($doctor.lockCount -eq 0) "commands should release locks after mutation"

$manifestAfterInspect.updatedAt = (Get-Date).AddHours(-2).ToUniversalTime().ToString("o")
$manifestAfterInspect | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $prepared2.runDir "run.json") -Encoding UTF8
$scanStalled = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scanStalled.pending).Count -eq 0) "stale unfinished runs should not remain in the active pending queue"
Assert-True (@($scanStalled.stalled).Count -eq 1) "stale unfinished runs should be reported separately"
Assert-True ($scanStalled.stalled[0].reason -eq "pending_generation_stale") "stalled runs should explain the stale pending generation"

$failed = Invoke-ToolJson @("-Command", "validate", "-RunDir", $prepared2.runDir)
Assert-True ($failed.status -eq "needs_review") "missing images should need review"

$scan5 = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scan5.pending).Count -eq 0) "needs_review hash should not be retried forever"

Add-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Value "Extra Notes: third version"
$prepared3 = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")
Assert-True ($prepared3.version -eq "v003") "third content hash should create v003"
Add-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Value "Extra Notes: fourth version"
$prepared4 = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")
Assert-True ($prepared4.version -eq "v004") "fourth content hash should create v004"
$supersededDryRun = Invoke-ToolJson @("-Command", "mark-superseded", "-Config", $ConfigPath, "-DryRun")
Assert-True (@($supersededDryRun.candidates | Where-Object { $_.version -eq "v003" }).Count -eq 1) "mark-superseded dry-run should identify old pending runs"
$superseded = Invoke-ToolJson @("-Command", "mark-superseded", "-Config", $ConfigPath)
Assert-True (@($superseded.updated | Where-Object { $_.version -eq "v003" }).Count -eq 1) "mark-superseded should update old pending runs"
$v3Manifest = Get-Content -LiteralPath (Join-Path $prepared3.runDir "run.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($v3Manifest.status -eq "superseded") "superseded run should be marked in manifest"

$imageFailed = Invoke-ToolJson @("-Command", "mark-failed", "-RunDir", $prepared4.runDir, "-File", "03-scene-use.png", "-Message", "test image failure")
Assert-True ($imageFailed.status -eq "needs_review") "single-image mark-failed should put the run in review"
Assert-True (@($imageFailed.imageTasks | Where-Object { $_.file -eq "03-scene-use.png" -and $_.status -eq "failed" }).Count -eq 1) "single-image mark-failed should update image task status"

Add-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Value "Extra Notes: fifth version"
$prepared5 = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")
$blockerMessage = "Built-in image2 generation is available, but this session cannot persist generated image files to the required local PNG paths in the run directory."
$blockedGeneration = Invoke-ToolJson @("-Command", "mark-failed", "-RunDir", $prepared5.runDir, "-Message", $blockerMessage)
Assert-True ($blockedGeneration.status -eq "pending_generation") "image2 persistence blocker should stay retryable"
Assert-True ($blockedGeneration.retryable -eq $true) "image2 persistence blocker should be reported as retryable"
$scanRetryable = Invoke-ToolJson @("-Command", "scan", "-Config", $ConfigPath)
Assert-True (@($scanRetryable.pending | Where-Object { $_.runDir -eq $prepared5.runDir }).Count -eq 1) "image2 persistence blocker should remain in the pending queue"

Add-Content -LiteralPath (Join-Path $readyProduct "product.txt") -Value "Extra Notes: sixth version"
$prepared6 = Invoke-ToolJson @("-Command", "prepare", "-Config", $ConfigPath, "-Product", "sample-mug")
$generatedImages = Invoke-ToolJson @("-Command", "generate-images", "-RunDir", $prepared6.runDir)
Assert-True ($generatedImages.status -eq "complete") "mock image backend should generate and validate a complete run"
Assert-True ($generatedImages.generatedCount -eq 7) "mock image backend should write all missing images"
Assert-True (Test-Path -LiteralPath (Join-Path $prepared6.runDir "07-intro.png")) "generate-images should persist output files"

Write-Host "Smoke tests passed."
