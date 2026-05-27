# Etsy 产品图自动化

这个工作区用于搭建一个由 Codex 驱动的 Etsy 风格产品图生成流程。

## 文件夹规则

你配置的产品根目录下面，每一个一级子文件夹代表一个产品。

每个产品文件夹需要包含：

- `product.txt`：产品说明文件
- `product.inferred.json`：AI 根据源图自动生成的补充说明，通常不需要手写
- `automation.done.txt`：完成标记，生成成功后自动写入
- `ready.txt`：就绪标记文件，表示这个产品可以开始处理
- 产品源图：可以放 `.jpg`、`.jpeg`、`.png`、`.webp`、`.bmp`、`.tif`、`.tiff`

`product.txt` 建议格式：

```text
Product Name:
Category:
Core Description:
Materials / Colors:
Target Customer:
Style / Mood:
Intro Text:
Must Include:
Avoid:
Extra Notes:
```

固定字段后面可以继续写自由补充说明。如果没有填写 `Product Name`，流程会使用产品文件夹名作为产品名。

字段可以留空。只要产品文件夹里有源图，Codex 自动化会把源图作为主要视觉参考，并从图片里推断空字段，例如产品类别、颜色、风格和适合的使用场景。它会尽量只推断图片里看得出来的内容，不会硬编具体材质、宝石名称、尺寸或功能。

AI 推断出来的内容会写入同一个产品文件夹里的 `product.inferred.json`。生成 7 张图时，流程会先读取 `product.txt`，再用 `product.inferred.json` 补齐空字段。你手写在 `product.txt` 里的字段永远优先，不会被 AI 覆盖。

`product.inferred.json` 支持下面这些字段名：

```json
{
  "productName": "",
  "category": "",
  "coreDescription": "",
  "materialsColors": "",
  "targetCustomer": "",
  "styleMood": "",
  "introText": "",
  "mustInclude": "",
  "avoid": "",
  "extraNotes": "",
  "referenceImageSummary": "",
  "visualIdentity": "",
  "consistencyRules": "",
  "uncertaintyNotes": "",
  "backgroundStrategy": "",
  "mainImageDirection": "",
  "sceneHomeDirection": "",
  "sceneUseDirection": "",
  "sceneGiftDirection": "",
  "sceneDetailDirection": "",
  "modelImageDirection": "",
  "introImageDirection": ""
}
```

其中最重要的是：

- `visualIdentity`：锁定产品不可变特征，例如形状、颜色、结构、吊坠位置、纹理、比例。
- `consistencyRules`：规定 7 张图必须保持一致的内容，避免一张图变成另一个产品。
- `uncertaintyNotes`：记录图片里不能确定的内容，例如不能确认具体宝石、材质、尺寸或功能。
- `backgroundStrategy`：根据产品类型选择统一的 Etsy 背景方向。
- `mainImageDirection` 到 `introImageDirection`：分别规定 7 张图各自应该怎么拍，但都共享同一个产品身份。

从 `direction-v2` 开始，每一张图的方向不应该只是一句话。每个方向应尽量包含：

- 镜头距离或画面尺度：全景、半身、近景、微距，产品占画面比例。
- 镜头角度：正俯拍、45 度、平视、微距侧角、佩戴视角。
- 构图：主体位置、留白、前景/背景层次、裁切边界。
- 背景和道具：使用什么表面、什么道具，哪些道具不能抢产品。
- 光线和质感：主光方向、阴影、景深、金属/布料/宝石质感。
- 产品锁定：这一张图里哪些结构、颜色、比例、细节必须和源图一致。
- 该图目的：主图、场景、佩戴、礼品、细节、模特、介绍图各自服务什么购买决策。

如果源图本身内容比较少，比如只有一个产品小图、背景很普通或构图很窄，流程会要求 Codex image2 为产品生成适合 Etsy 的背景和场景图。产品本体仍以源图为准，背景可以根据产品类型自动丰富。

## 配置

默认工作流改为从 `old\1688-products.csv` 读取 1688 商品链接。你只需要在表格里新增一行，把 `enabled` 改成 `true`，填入 `productUrl`，脚本会自动把链接同步成 `old\products\<产品>` 目录，下载源图，写入 `product.txt` 和 `ready.txt`。

示例：

```json
{
  "inputRoot": "old\\products",
  "outputRoot": "old\\outputs",
  "outputRootMode": "sibling",
  "linkTableFile": "old\\1688-products.csv",
  "linkSyncBeforeScan": true,
  "linkImageLimit": 8,
  "linkMinImageSize": 600,
  "linkDownloadTimeoutSeconds": 30,
  "briefFile": "product.txt",
  "generatedBriefFile": "product.inferred.json",
  "promptSchemaVersion": "direction-v2",
  "completeMarkerFile": "automation.done.txt",
  "readyMarker": "ready.txt",
  "language": "en",
  "scanCadence": "hourly",
  "pendingStaleHours": 24,
  "imageMinSize": 1024,
  "requirePngImages": true,
  "lockStaleMinutes": 120,
  "imageBackend": "codex-image2",
  "codexImageModel": "image2",
  "productIdentityMode": "reference-strict",
  "requireImageReference": true,
  "allowReferenceLimitedDrafts": true,
  "stopOnIdentityDrift": true,
  "continueAfterImageFailure": true,
  "sourcePreserveOutputSize": 1600
}
```

如果继续使用手动产品文件夹，也可以把 `linkTableFile` 留空，并把 `inputRoot` 指向你的产品目录。当前项目默认把生成结果放到 `old\outputs`。

`old\1688-products.csv` 字段：

- `enabled`：`true` 才会处理这一行；示例行默认是 `false`。
- `productId`：可选，填写后作为产品文件夹名；不填时优先用 `productName`，再用 1688 链接里的 offer id。
- `productName`、`category`、`coreDescription` 等字段会写入自动生成的 `product.txt`。
- `productUrl`：1688 商品详情页链接。

`linkSyncBeforeScan` 为 `true` 时，运行 `scan` 会先同步链接表，再扫描生成任务。`linkImageLimit` 控制每个商品最多下载多少张源图。`linkMinImageSize` 用来过滤小缩略图，默认建议至少 600px。

`pendingStaleHours` 用来标记长时间没有补齐图片的 `pending_generation` 运行。超过这个小时数后，`scan` 会把它放到 `stalled` 列表里，方便人工处理；它不会自动修改 `run.json`。

`imageMinSize` 和 `requirePngImages` 用于 `inspect`、`validate -DryRun` 和 `validate`。默认要求输出图是 PNG，且宽高都不低于 1024 像素。

`lockStaleMinutes` 用于写入型命令的运行锁。`prepare` 会使用产品级锁，`validate`、`mark-failed` 和 `mark-superseded` 会使用运行目录级锁；超过该分钟数的旧锁会被视为过期。

`imageBackend` 控制图片生成后端：

- `codex-image2`：生产模式，Codex 自动化会使用内置 `image2` 生图能力，并把图片保存到运行目录。
- `manual`：只准备 prompt 和任务清单，不自动生成图片。
- `mock`：只用于本地测试，写入 1x1 PNG 占位图。

使用生产模式时，`codexImageModel` 必须是 `image2`。脚本会强制检查这一点；配置成其他模型会直接失败。

1688 流程不是纯文生图。表格里的 `productUrl` 只负责创建产品输入；`sync-links` 下载到 `old\products\<产品>\source-*` 的本地源图会进入 `run.json`，并通过 `referencePolicy` 和 `sourceImagePaths` 作为 `image2` 图生图参考。默认 `productIdentityMode` 是 `reference-strict`，表示可以改背景、光线、构图和使用场景，但产品本体的形状、比例、材质观感、细节位置、款式数量和颜色分布必须跟源图一致。

`requireImageReference=true` 时，如果产品有源图，`generate` 会把 `referencePolicy.mustUseActualSourceImageReferences` 标为 `true`，并把 `promptOnlyProductionAllowed` 标为 `false`。这表示自动化必须优先把 `sourceImagePaths` 里的本地图片作为 `image2` 参考图/附件；如果当前环境不能附加图片，只允许生成 `reference-limited draft`，必须人工视觉比对，产品变形、重绘成另一个款式或细节漂移时不能保存为生产图。

## 本地命令

从 `old\1688-products.csv` 同步 1688 链接，下载源图并创建产品目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command sync-links
```

预览同步结果但不写入文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command sync-links -DryRun
```

扫描已经就绪、并且还没有处理过的产品：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command scan
```

只扫描已经同步到本地的产品目录，不在本次扫描里访问 1688 网络：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command scan -NoLinkSync
```

定时自动化默认使用 `scan -NoLinkSync`，因为无人值守运行不能弹出网络提权审批。新增 1688 链接后，先手动运行一次 `sync-links` 抓源图，再让定时任务继续处理本地源图、生图和校验。

执行系统体检，检查配置、产品输入、历史运行和锁文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command doctor
```

为某个产品准备一次生成任务，并写入 7 个提示词文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command prepare -Product "sample-product-folder"
```

列出某个运行目录还缺哪些图片，以及每张缺图对应的 prompt 和输出路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command generate -RunDir "D:\Shop\outputs\sample-product-folder\v001"
```

测试配置的图片后端。生产配置 `codex-image2` 由 Codex 自动化层执行，PowerShell 命令不会直接生图：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command generate-images -RunDir "D:\Shop\outputs\sample-product-folder\v001"
```

非破坏性检查某次运行的图片完整性，不修改 `run.json` 或完成标记：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command inspect -RunDir "D:\Shop\outputs\sample-product-folder\v001"
```

查看某次运行的 7 张图逐张任务状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command task-status -RunDir "D:\Shop\outputs\sample-product-folder\v001"
```

汇总所有历史运行版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command list-runs
```

只看某个产品的历史运行版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command list-runs -Product "sample-product-folder"
```

预览哪些旧的 `pending_generation` 版本会被标记为 `superseded`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command mark-superseded -DryRun
```

把已有更新版本的旧 `pending_generation` 运行标记为 `superseded`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command mark-superseded
```

校验某次已经生成的结果：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command validate -RunDir "D:\Shop\outputs\sample-product-folder\v001"
```

如果只想看校验结果但不写入状态，可以使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command validate -RunDir "D:\Shop\outputs\sample-product-folder\v001" -DryRun
```

如果只有某一张图生成失败，可以只标记这张图：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\etsy-picture.ps1 -Command mark-failed -RunDir "D:\Shop\outputs\sample-product-folder\v001" -File "03-scene-use.png" -Message "Image generation failed."
```

## Codex 自动化行为

定时 Codex 任务会：

1. 运行 `scan -NoLinkSync`，只扫描已经存在于 `old\products` 的本地产品目录，避免无人值守任务因网络提权不可用而失败。
2. 如果有新增 1688 链接但还没有本地源图，先手动运行 `sync-links` 抓图；定时任务不会在 `approval policy = never` 的环境里尝试联网。
3. 对每个待处理产品，先读取 `product.txt` 和源图。
4. 如果有空字段或缺少 `product.inferred.json`，先根据源图生成 `product.inferred.json`。
5. 运行 `prepare`，把手写字段和 AI 推断字段合并成 7 个提示词。
6. 运行 `generate`，取得缺失图片的任务清单、`sourceImagePaths` 和 `referencePolicy`。
7. 读取 `<runDir>\prompts` 下面的 7 个提示词文件。
8. 如果任务包含 `sourceImagePaths`，必须优先把这些本地源图作为 `image2` 参考图/附件，按 `reference-strict` 策略做图生图。
9. 使用 Codex 内置 `image2` 为每个提示词生成一张高清方图，只允许改场景、光线、构图和背景；如果图片先出现在 `C:\Users\Administrator\.codex\generated_images` 缓存里，自动任务会把最新 PNG 复制到本次输出目录。
10. 把图片按下面的文件名保存到本次输出目录：
   - `01-main.png`
   - `02-scene-home.png`
   - `03-scene-use.png`
   - `04-scene-gift.png`
   - `05-scene-detail.png`
   - `06-model.png`
   - `07-intro.png`
11. 运行 `validate`。
12. 如果某一张图生成失败，运行 `mark-failed` 并写入错误原因；如果只是当前 Codex 环境不能把内置 `image2` 结果保存成运行目录里的 PNG，不要把任务关闭为人工审核，保持 `pending_generation` 等待可落盘的自动任务重试。

成功完成的任务会在 `run.json` 里标记为 `complete`，并在产品文件夹写入 `automation.done.txt`。之后每小时扫描会先读取这个完成标记；如果当前 `product.txt`、源图、推断说明和 prompt 版本都没有变化，就直接跳过，不再重新分析图片。缺图、图片不可读或校验失败的任务会标记为 `needs_review`。如果 `pending_generation` 运行超过 `pendingStaleHours` 仍然缺图，`scan` 会把它放到 `stalled` 列表里。如果你修改了说明文件、替换了源图、更新了 `product.inferred.json` 或升级了 `promptSchemaVersion`，会生成新的版本目录。

每个运行目录的 `run.json` 会维护 `imageTasks`，记录每张图的 `pending`、`generated`、`failed` 或 `needs_review` 状态。写入型命令还会追加 `run.log.jsonl`，便于追踪 prepare、validate、mark-failed 和 mark-superseded 的执行历史。

## 测试

运行烟测：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-smoke.ps1
```
