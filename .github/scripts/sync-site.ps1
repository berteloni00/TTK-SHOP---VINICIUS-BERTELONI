param(
    [string]$StartUrl = 'https://elevate-4d-hub-git-main-fox-squad-s-projects.vercel.app/',
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
    [int]$MaxFiles = 1000
)

$ErrorActionPreference = 'Stop'
$startUri = [Uri]$StartUrl
$rootHost = $startUri.Host
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('elevate-hub-' + [Guid]::NewGuid().ToString('N'))
$statePath = Join-Path $repositoryRoot '.github/site-mirror-files.txt'
$preservedRootNames = @('README.md', 'README-AUTOMACAO.md', 'LICENSE', 'CNAME', '.nojekyll')

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $true
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(90)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 ElevateHubWeeklyMirror/1.0')

$queue = [Collections.Generic.Queue[Uri]]::new()
$queued = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$results = [Collections.Generic.List[object]]::new()

function Get-CanonicalUri([Uri]$uri) {
    $builder = [UriBuilder]::new($uri)
    $builder.Fragment = ''
    $builder.Query = ''
    return $builder.Uri
}

function Add-InternalUri([Uri]$uri) {
    if ($uri.Scheme -notin @('http', 'https')) { return }
    if ($uri.Host -ne $rootHost) { return }
    $canonical = Get-CanonicalUri $uri
    if ($queued.Add($canonical.AbsoluteUri)) {
        $queue.Enqueue($canonical)
    }
}

function Get-LocalPath([Uri]$uri, [string]$mediaType) {
    $decodedPath = [Uri]::UnescapeDataString($uri.AbsolutePath).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($decodedPath)) {
        $decodedPath = 'index.html'
    } elseif ($decodedPath.EndsWith('/')) {
        $decodedPath += 'index.html'
    } elseif ([string]::IsNullOrEmpty([IO.Path]::GetExtension($decodedPath)) -and $mediaType -match 'text/html') {
        $decodedPath = Join-Path $decodedPath 'index.html'
    }

    $normalized = $decodedPath.Replace('\', '/')
    if ($normalized -match '^(?:\.git|\.github)(?:/|$)') {
        throw "O site remoto tentou gravar uma pasta protegida: $decodedPath"
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $stagingRoot $decodedPath))
    if (-not $candidate.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho fora da área temporária: $candidate"
    }
    return $candidate
}

function Find-LinkedUris([string]$text, [Uri]$baseUri, [string]$mediaType) {
    $values = [Collections.Generic.List[string]]::new()
    if ($mediaType -match 'text/html') {
        foreach ($match in [regex]::Matches($text, '(?is)(?:href|src)\s*=\s*["'']([^"'']+)["'']')) {
            $values.Add($match.Groups[1].Value)
        }
        foreach ($match in [regex]::Matches($text, '(?is)url\(\s*["'']?([^\)"'']+)["'']?\s*\)')) {
            $values.Add($match.Groups[1].Value)
        }
    } elseif ($mediaType -match 'text/css') {
        foreach ($match in [regex]::Matches($text, '(?is)url\(\s*["'']?([^\)"'']+)["'']?\s*\)')) {
            $values.Add($match.Groups[1].Value)
        }
        foreach ($match in [regex]::Matches($text, '(?is)@import\s+(?:url\()?\s*["'']([^"'']+)["'']')) {
            $values.Add($match.Groups[1].Value)
        }
    }

    foreach ($value in $values) {
        $clean = $value.Trim()
        if (-not $clean -or $clean -match '^(?:#|data:|javascript:|mailto:|tel:|blob:)') { continue }
        try {
            Add-InternalUri ([Uri]::new($baseUri, $clean))
        } catch {
            $results.Add([PSCustomObject]@{ Url=$clean; Status='INVALID_LINK'; Local=''; Detail=$_.Exception.Message })
        }
    }
}

Add-InternalUri $startUri

try {
    while ($queue.Count -gt 0 -and $visited.Count -lt $MaxFiles) {
        $uri = $queue.Dequeue()
        if (-not $visited.Add($uri.AbsoluteUri)) { continue }

        try {
            $response = $client.GetAsync($uri).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if (-not $response.IsSuccessStatusCode) {
                $results.Add([PSCustomObject]@{ Url=$uri.AbsoluteUri; Status=$status; Local=''; Detail=$response.ReasonPhrase })
                continue
            }

            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $mediaType = $response.Content.Headers.ContentType.MediaType
            $localPath = Get-LocalPath $uri $mediaType
            $directory = Split-Path -Parent $localPath
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            [IO.File]::WriteAllBytes($localPath, $bytes)

            $relative = [IO.Path]::GetRelativePath($stagingRoot, $localPath).Replace('\', '/')
            $results.Add([PSCustomObject]@{ Url=$uri.AbsoluteUri; Status=$status; Local=$relative; Detail=$mediaType })

            if ($mediaType -match 'text/(?:html|css)') {
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Find-LinkedUris $text $uri $mediaType
            }

            Write-Host ("[{0}/{1}] {2}" -f $visited.Count, ($visited.Count + $queue.Count), $relative)
        } catch {
            $results.Add([PSCustomObject]@{ Url=$uri.AbsoluteUri; Status='ERROR'; Local=''; Detail=$_.Exception.Message })
            Write-Warning ("Falha em {0}: {1}" -f $uri.AbsoluteUri, $_.Exception.Message)
        }
    }

    if ($queue.Count -gt 0) {
        throw "Limite de $MaxFiles atingido antes do fim da varredura."
    }

    $results | Export-Csv -LiteralPath (Join-Path $stagingRoot '_mirror-manifest.csv') -NoTypeInformation -Encoding UTF8

    $newFiles = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($stagingRoot, $_.FullName).Replace('\', '/')
    } | Sort-Object -Unique)

    if (Test-Path -LiteralPath $statePath) {
        $previousFiles = @(Get-Content -LiteralPath $statePath | Where-Object { $_ })
    } else {
        $previousFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
            $relative = [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName).Replace('\', '/')
            $topName = $relative.Split('/')[0]
            $relative -notmatch '^(?:\.git|\.github)(?:/|$)' -and $topName -notin $preservedRootNames
        } | ForEach-Object {
            [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName).Replace('\', '/')
        })
    }

    $newSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $newFiles) {
        [void]$newSet.Add($relative)
    }
    foreach ($relative in $previousFiles) {
        if (-not $newSet.Contains($relative)) {
            $target = Join-Path $repositoryRoot $relative
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force
            }
        }
    }

    foreach ($relative in $newFiles) {
        $source = Join-Path $stagingRoot $relative
        $target = Join-Path $repositoryRoot $relative
        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $target -Force
    }

    $stateDirectory = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllLines($statePath, $newFiles, [Text.UTF8Encoding]::new($false))

    Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' -and $_.FullName -notmatch '[\\/]\.github(?:[\\/]|$)' } |
        ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }

    $ok = @($results | Where-Object { $_.Status -eq 200 }).Count
    $failed = @($results | Where-Object { $_.Status -ne 200 }).Count
    [PSCustomObject]@{
        RepositoryRoot = $repositoryRoot
        Downloaded = $ok
        Failed = $failed
        Discovered = $queued.Count
        MirroredFiles = $newFiles.Count
    }
} finally {
    $client.Dispose()
    $handler.Dispose()
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
