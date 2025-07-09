param(
    [string]$WorkspaceFolder
)

$buildPath = Join-Path -Path $WorkspaceFolder -ChildPath "build"
$debugPath = Join-Path -Path $buildPath -ChildPath "debug"

# 确保 build 目录存在
if (-not (Test-Path -Path $buildPath -PathType Container)) {
    New-Item -ItemType Directory -Path $buildPath | Out-Null
    Write-Host "Created build directory"
}

# 处理 debug 目录
if (Test-Path -Path $debugPath -PathType Container) {
    # 保留 taglib-prefix 并删除其他内容
    $items = Get-ChildItem -Path $debugPath -Exclude "taglib-prefix"
    if ($items) {
        $items | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cleaned debug directory (preserved taglib-prefix)"
    }
    
    # 确保目录结构存在（如果只保留了 taglib-prefix）
    if (Test-Path (Join-Path -Path $debugPath -ChildPath "taglib-prefix")) {
        New-Item -ItemType Directory -Path $debugPath -Force | Out-Null
    }
} else {
    # 创建 debug 目录
    New-Item -ItemType Directory -Path $debugPath | Out-Null
    Write-Host "Created debug directory"
}