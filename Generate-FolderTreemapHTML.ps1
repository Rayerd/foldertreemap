param(
    [string]$Path = ".",
    [string]$OutputHtml = "nested_treemap.html"
)

function Get-FolderSizeJson {
    param (
        [string]$BasePath,
        [int]$DepthLimit = 8
    )

    $stack = New-Object System.Collections.Stack
    $visited = @{ }

    $root = [PSCustomObject]@{
        name = Split-Path $BasePath -Leaf
        fullPath = (Resolve-Path $BasePath).Path
        type = "folder"
        children = @()
        size = 0
        depth = 0
    }

    $stack.Push($root)

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()

        if (-not $node.fullPath) { continue }
        if ($visited.ContainsKey($node.fullPath)) { continue }
        $visited[$node.fullPath] = $true

        if ($node.depth -ge $DepthLimit) {
            continue
        }

        $children = @()
        $files = Get-ChildItem -Path $node.fullPath -File -ErrorAction SilentlyContinue
        $totalSize = 0
        foreach ($file in $files) {
            if ($file.Length -ge 1MB) {
                $children += [PSCustomObject]@{
                    name = $file.Name
                    size = $file.Length
                    type = "file"
					fullPath = $file.FullName
                }
                $totalSize += $file.Length
            } else {
                $totalSize += $file.Length
            }
        }

        $subfolders = Get-ChildItem -Path $node.fullPath -Directory -ErrorAction SilentlyContinue
        foreach ($subfolder in $subfolders) {
            $childNode = [PSCustomObject]@{
                name = $subfolder.Name
                fullPath = $subfolder.FullName
                type = "folder"
                children = @()
                size = 0
                depth = $node.depth + 1
            }
            $children += $childNode
            $stack.Push($childNode)
        }

        $node.children = $children
        $node.size = $totalSize + ($children | Measure-Object -Property size -Sum).Sum
    }

    function FilterSmallNodes([PSCustomObject]$node) {
        if ($node.type -eq "file") {
            return ($node.size -ge 1MB)
        }
        if ($node.children) {
            $node.children = $node.children | Where-Object { FilterSmallNodes $_ }
            $node.size = ($node.children | Measure-Object -Property size -Sum).Sum
        }
        return ($node.size -ge 1MB)
    }

    if (-not (FilterSmallNodes $root)) {
        return $null
    }

    function ConvertTo-JsonCustom($obj) {
        return $obj | ConvertTo-Json -Depth 100 -Compress
    }

    return ConvertTo-JsonCustom $root
}

$json = Get-FolderSizeJson -BasePath $Path

if (-not $json) {
    Write-Warning "指定フォルダに1MB以上のフォルダ/ファイルがありません。"
    exit
}

$utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$base64 = [Convert]::ToBase64String($utf8Bytes)

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<title>Nested Folder Treemap</title>
<style>
    body { margin: 0; font-family: sans-serif; }
    h2 { margin: 10px; }
    #breadcrumb {
        margin: 10px;
        font-size: 14px;
        user-select: none;
    }
    #breadcrumb span {
        cursor: pointer;
        color: #337ab7;
        margin-right: 5px;
    }
    #breadcrumb span:hover {
        text-decoration: underline;
    }
    #chart {
        position: relative;
        width: 100vw;
        height: 80vh;
        overflow: auto;
        padding: 10px;
        box-sizing: border-box;
    }
    .node {
        position: absolute;
        border: 2px solid white;
        box-sizing: border-box;
        border-radius: 4px;
        color: white;
        font-size: 12px;
        overflow: hidden;
        transition: transform 0.2s;
        cursor: default;
        display: flex;
        flex-direction: column;
        justify-content: flex-start;
        padding: 4px;
    }
    .node.folder {
        background-color: #f39c12;
    }
    .node.file {
        background-color: #2980b9;
    }
    .node.enlarge:hover {
        transform: scale(1.05);
        z-index: 10;
        cursor: pointer;
    }
    .label {
        font-weight: bold;
        font-size: 11px;
        color: white;
        text-shadow: 0 0 3px rgba(0,0,0,0.7);
        word-break: break-word;
        z-index: 1000;
        position: relative;
        user-select: none;
    }
    .label.folder-label {
        position: absolute;
        top: 4px;
        left: 4px;
        background: rgba(0,0,0,0.3);
        padding: 2px 4px;
        border-radius: 3px;
        user-select: none;
    }
    #backButton {
        margin: 10px 5px 10px 10px;
        padding: 6px 12px;
        font-size: 14px;
        user-select: none;
    }
    #folderPath {
        vertical-align: middle;
        margin-left: 10px;
        font-size: 13px;
        /* 横幅をウィンドウ幅からボタン分を引いた幅に調整 */
        width: calc(100vw - 150px);
        max-width: 80vw;
        user-select: all;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        padding: 6px 8px;
        box-sizing: border-box;
    }
    .node.file {
        cursor: default !important;
    }
    /* コピー完了ツールチップ */
    #copyTooltip {
        position: fixed;
        background: #444;
        color: white;
        padding: 5px 10px;
        border-radius: 4px;
        font-size: 14px;
        pointer-events: none;
        opacity: 0;
        transition: opacity 0.3s ease;
        z-index: 10000;
        user-select: none;
    }
	.link-icon {
	    position: absolute;
	    top: 2px;
	    right: 2px;
	    width: 16px;
	    height: 16px;
	    background: rgba(255, 255, 255, 0.8);
	    border-radius: 3px;
	    text-align: center;
	    font-size: 12px;
	    color: #333;
	    text-decoration: none;
	    z-index: 2000;
	    opacity: 0;
	    pointer-events: none;
	    transition: opacity 0.2s ease;
	}
	/* ノードにホバーしたときだけチェーンマークを表示 */
	.node:hover .link-icon {
	    opacity: 1;
	    pointer-events: auto;
	}
</style>
</head>
<body>
<h2>Nested Folder Treemap for '$Path'</h2>
<div id='breadcrumb'></div>
<button id='backButton'>1つ上の階層へ</button>
<input type='text' id='folderPath' readonly />
<div id='chart'></div>
<div id='copyTooltip'>コピーしました</div>

<script>
const base64 = '$base64';

function base64ToUtf8(str) {
    const bytes = Uint8Array.from(atob(str), c => c.charCodeAt(0));
    return new TextDecoder('utf-8').decode(bytes);
}

const jsonStr = base64ToUtf8(base64);
const data = JSON.parse(jsonStr);

function assignParents(node, parent = null) {
    node._parent = parent;
    if (node.children) {
        if (!Array.isArray(node.children)) {
            node.children = [node.children];
        }
        node.children.forEach(child => assignParents(child, node));
    }
}
assignParents(data);

let currentNode = data;
let backButton = document.getElementById('backButton');
let folderPathInput = document.getElementById('folderPath');
let copyTooltip = document.getElementById('copyTooltip');
let tooltipTimeout = null;
let tooltipFadeInterval = null;

function updateBreadcrumb() {
    const breadcrumb = document.getElementById('breadcrumb');
    breadcrumb.innerHTML = '';
    let path = [];
    let temp = currentNode;
    while (temp) {
        path.unshift(temp);
        temp = temp._parent;
    }
    path.forEach((node, i) => {
        const span = document.createElement('span');
        span.textContent = node.name || 'Root';
        span.addEventListener('click', () => {
            currentNode = node;
            createTreemap(document.getElementById('chart'), currentNode, currentNode.size);
            updateBreadcrumb();
            updateBackButton();
            updateFolderPath();
        });
        breadcrumb.appendChild(span);
        if (i < path.length - 1) breadcrumb.appendChild(document.createTextNode(' > '));
    });
}

function updateBackButton() {
    backButton.disabled = !currentNode._parent;
}

function updateFolderPath() {
    folderPathInput.value = currentNode.fullPath || '';
}

function createTreemap(container, node, totalSize, scale = 1, level = 0) {
    container.innerHTML = '';
    const sorted = node.children?.slice().sort((a, b) => b.size - a.size) || [];
    const containerRect = container.getBoundingClientRect();
    const maxW = containerRect.width;
    const maxH = containerRect.height;
    const area = maxW * maxH * 0.90;
    const ratio = area / totalSize;
    let x = 0, y = 0, rowH = 0;

    sorted.forEach(child => {
        const w = Math.max(80, Math.sqrt((child.size || 1) * ratio * scale));
        const h = w * 0.75;
        if (x + w > maxW) {
            x = 0;
            y += rowH + 10;
            rowH = 0;
        }

        const div = document.createElement('div');
        div.className = 'node ' + (child.type === 'file' ? 'file' : 'folder');
        div.style.width = w + 'px';
        div.style.height = h + 'px';
        div.style.left = x + 'px';
        div.style.top = (y + 20) + 'px';

        // サブフォルダのみenlargeを付与(見た目向上)
        if (child.type === 'folder' && child.children && child.children.length > 0) {
            div.classList.add('enlarge');
            div.style.cursor = 'pointer';
        } else if (child.type === 'folder') {
            div.style.cursor = 'default';
        }

        const label = document.createElement('div');
        label.className = 'label';
        if (child.type === 'folder') {
            label.classList.add('folder-label');
        }
        label.textContent = child.name + ' (' + (child.size / 1024 / 1024).toFixed(1) + ' MB)';
        div.appendChild(label);
        container.appendChild(div);

		// file:/// リンクを右上に追加（↗マーク）
		if (child.type === 'folder' || child.type === 'file') {
		    const fileUrl = 'file:///' + encodeURIComponent((child.fullPath || '').replace(/\\/g, '/')).replace(/%2F/g, '/');
		    const link = document.createElement('a');
		    link.href = fileUrl;
		    link.target = '_blank';
		    link.className = 'link-icon';
		    link.title = 'このフォルダ/ファイルを開く';
		    link.textContent = '↗';
		    link.addEventListener('click', e => e.stopPropagation()); // 親のクリックイベントを無効化
		    div.appendChild(link);
		}

        // 2階層下までのサブツリーマップをネスト表示
        if (child.type === 'folder' && child.children?.length && level < 2) {
            const subContainer = document.createElement('div');
            subContainer.style.position = 'relative';
            subContainer.style.width = '100%';
            subContainer.style.height = '100%';
            subContainer.style.padding = '4px';
            div.appendChild(subContainer);
            setTimeout(() => createTreemap(subContainer, child, child.size, 0.85, level + 1), 0);
        }

        div.addEventListener('click', e => {
            e.stopPropagation();
            if (child.type === 'folder' && child.children?.length) {
                currentNode = child;
                createTreemap(document.getElementById('chart'), currentNode, currentNode.size);
                updateBreadcrumb();
                updateBackButton();
                updateFolderPath();
            }
        });

        x += w + 10;
        if (h > rowH) rowH = h;
    });
}

backButton.addEventListener('click', () => {
    if (currentNode._parent) {
        currentNode = currentNode._parent;
        createTreemap(document.getElementById('chart'), currentNode, currentNode.size);
        updateBreadcrumb();
        updateBackButton();
        updateFolderPath();
    }
});

folderPathInput.addEventListener('click', async (e) => {
    folderPathInput.select();
    try {
        await navigator.clipboard.writeText(folderPathInput.value);
        // コピー完了後も選択状態を維持
        folderPathInput.select();
        showCopyTooltip(e.pageX, e.pageY);
    } catch {
        alert('クリップボードへのコピーに失敗しました。');
    }
});

// コピー完了ツールチップの管理
function showCopyTooltip(x, y) {
    if (tooltipTimeout) clearTimeout(tooltipTimeout);
    if (tooltipFadeInterval) clearInterval(tooltipFadeInterval);

    copyTooltip.style.opacity = 1;
    copyTooltip.style.left = (x + 10) + 'px';  // マウスカーソルの右に10pxずらす
    copyTooltip.style.top = (y + 10) + 'px';   // マウスカーソルの下に10pxずらす
    copyTooltip.style.pointerEvents = 'none';

    let elapsed = 0;
    tooltipFadeInterval = setInterval(() => {
        elapsed += 100;
        let opacity = 1 - (elapsed / 3000);
        if (opacity <= 0) {
            opacity = 0;
            clearInterval(tooltipFadeInterval);
            copyTooltip.style.opacity = 0;
        } else {
            copyTooltip.style.opacity = opacity;
        }
    }, 100);

    tooltipTimeout = setTimeout(() => {
        clearInterval(tooltipFadeInterval);
        copyTooltip.style.opacity = 0;
    }, 3000);
}

updateBreadcrumb();
updateBackButton();
updateFolderPath();
createTreemap(document.getElementById('chart'), currentNode, currentNode.size);
</script>
</body>
</html>
"@

Set-Content -Path $OutputHtml -Value $html -Encoding utf8
Write-Host "Treemap HTML file saved as '$OutputHtml'"
Start-Process $OutputHtml
