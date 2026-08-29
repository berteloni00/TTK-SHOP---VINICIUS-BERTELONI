param(
    [Parameter(Mandatory=$true)][string]$MarkdownPath,
    [Parameter(Mandatory=$true)][string]$TelegramPath,
    [string]$Title = 'Atualizacao encontrada no site original'
)

$ErrorActionPreference = 'Stop'

function Convert-ToPlainText([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $clean = [regex]::Replace($value, '(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>', ' ')
    $clean = [regex]::Replace($clean, '(?is)<[^>]+>', ' ')
    $clean = [Net.WebUtility]::HtmlDecode($clean)
    return ([regex]::Replace($clean, '\s+', ' ')).Trim()
}

function Limit-Text([string]$value, [int]$length) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ($value.Length -le $length) { return $value }
    return $value.Substring(0, $length).TrimEnd() + '...'
}

function Get-HtmlDetails([string]$path, [bool]$deleted) {
    try {
        if ($deleted) {
            $html = (& git show "HEAD:$path" 2>$null) -join "`n"
        } else {
            $html = [IO.File]::ReadAllText((Join-Path (Get-Location) $path))
        }
    } catch {
        return $null
    }

    $titleMatch = [regex]::Match($html, '(?is)<title[^>]*>(.*?)</title>')
    $h1Match = [regex]::Match($html, '(?is)<h1[^>]*>(.*?)</h1>')
    $h2Matches = [regex]::Matches($html, '(?is)<h2[^>]*>(.*?)</h2>') | Select-Object -First 3

    $titleText = Convert-ToPlainText $titleMatch.Groups[1].Value
    $h1Text = Convert-ToPlainText $h1Match.Groups[1].Value
    $sections = @($h2Matches | ForEach-Object { Convert-ToPlainText $_.Groups[1].Value } | Where-Object { $_ })

    if (-not $titleText -and -not $h1Text -and $sections.Count -eq 0) {
        $bodyMatch = [regex]::Match($html, '(?is)<body[^>]*>(.*?)</body>')
        $preview = Limit-Text (Convert-ToPlainText $bodyMatch.Groups[1].Value) 220
    } else {
        $preview = ''
    }

    return [PSCustomObject]@{
        Title = $titleText
        Heading = $h1Text
        Sections = $sections
        Preview = $preview
    }
}

$lines = @(& git diff --cached --name-status --no-renames)
$changes = [Collections.Generic.List[object]]::new()

foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "`t", 2
    if ($parts.Count -lt 2) { continue }
    $code = $parts[0].Substring(0,1)
    $path = $parts[1]
    $deleted = $code -eq 'D'
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()

    $label = switch ($code) {
        'A' { 'Adicionado' }
        'D' { 'Removido' }
        default { 'Alterado' }
    }
    $emoji = switch ($code) {
        'A' { '🆕' }
        'D' { '🗑️' }
        default { '✏️' }
    }
    $kind = switch ($extension) {
        '.html' { 'Página' }
        '.pdf' { 'PDF' }
        '.xlsx' { 'Planilha' }
        '.xls' { 'Planilha' }
        '.png' { 'Imagem' }
        '.jpg' { 'Imagem' }
        '.jpeg' { 'Imagem' }
        '.webp' { 'Imagem' }
        '.mp4' { 'Vídeo' }
        '.js' { 'Recurso técnico' }
        default { 'Arquivo' }
    }

    $details = if ($extension -eq '.html') { Get-HtmlDetails $path $deleted } else { $null }
    $size = if (-not $deleted -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        $bytes = (Get-Item -LiteralPath $path).Length
        if ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) }
        elseif ($bytes -ge 1KB) { '{0:N1} KB' -f ($bytes / 1KB) }
        else { "$bytes bytes" }
    } else { '' }

    $changes.Add([PSCustomObject]@{
        Code = $code
        Label = $label
        Emoji = $emoji
        Kind = $kind
        Path = $path
        Details = $details
        Size = $size
    })
}

$added = @($changes | Where-Object Code -eq 'A').Count
$modified = @($changes | Where-Object Code -eq 'M').Count
$deleted = @($changes | Where-Object Code -eq 'D').Count

$markdown = [Text.StringBuilder]::new()
[void]$markdown.AppendLine("# $Title")
[void]$markdown.AppendLine()
[void]$markdown.AppendLine('## Resumo rápido')
[void]$markdown.AppendLine()
[void]$markdown.AppendLine("- **$added** arquivo(s) adicionado(s)")
[void]$markdown.AppendLine("- **$modified** arquivo(s) alterado(s)")
[void]$markdown.AppendLine("- **$deleted** arquivo(s) removido(s)")
[void]$markdown.AppendLine()
[void]$markdown.AppendLine('## O que mudou')
[void]$markdown.AppendLine()

$maxMarkdownFiles = 40
foreach ($change in ($changes | Select-Object -First $maxMarkdownFiles)) {
    [void]$markdown.AppendLine("### $($change.Emoji) $($change.Kind) $($change.Label.ToLowerInvariant())")
    [void]$markdown.AppendLine()
    [void]$markdown.AppendLine("- **Arquivo:** ``$($change.Path)``")
    if ($change.Size) { [void]$markdown.AppendLine("- **Tamanho:** $($change.Size)") }
    if ($change.Details) {
        if ($change.Details.Title) { [void]$markdown.AppendLine("- **Título:** $($change.Details.Title)") }
        if ($change.Details.Heading -and $change.Details.Heading -ne $change.Details.Title) {
            [void]$markdown.AppendLine("- **Assunto principal:** $($change.Details.Heading)")
        }
        if ($change.Details.Sections.Count -gt 0) {
            [void]$markdown.AppendLine("- **Seções identificadas:** $($change.Details.Sections -join ' · ')")
        }
        if ($change.Details.Preview) { [void]$markdown.AppendLine("- **Conteúdo:** $($change.Details.Preview)") }
    }
    [void]$markdown.AppendLine()
}

if ($changes.Count -gt $maxMarkdownFiles) {
    [void]$markdown.AppendLine("_Mais $($changes.Count - $maxMarkdownFiles) arquivo(s) não exibidos neste resumo. A lista completa continua disponível em Files changed._")
    [void]$markdown.AppendLine()
}

[void]$markdown.AppendLine('## Como decidir pelo celular')
[void]$markdown.AppendLine()
[void]$markdown.AppendLine('- **Aprovar:** toque em **Merge pull request** e depois em **Confirm merge**.')
[void]$markdown.AppendLine('- **Rejeitar:** toque em **Close pull request**.')
[void]$markdown.AppendLine('- A tela **Files changed** continua disponível apenas para uma revisão técnica opcional.')

$telegram = [Text.StringBuilder]::new()
[void]$telegram.AppendLine("🔔 $Title")
[void]$telegram.AppendLine()
[void]$telegram.AppendLine("Resumo: $added adicionado(s), $modified alterado(s), $deleted removido(s).")
[void]$telegram.AppendLine()
foreach ($change in ($changes | Select-Object -First 12)) {
    $description = "$($change.Emoji) $($change.Label): $($change.Path)"
    if ($change.Details -and $change.Details.Title) {
        $description += " — $($change.Details.Title)"
    } elseif ($change.Details -and $change.Details.Heading) {
        $description += " — $($change.Details.Heading)"
    }
    [void]$telegram.AppendLine((Limit-Text $description 260))
}
if ($changes.Count -gt 12) {
    [void]$telegram.AppendLine("...e mais $($changes.Count - 12) arquivo(s).")
}
[void]$telegram.AppendLine()
[void]$telegram.AppendLine('Abra o link abaixo para ler o resumo e aprovar ou rejeitar pelo celular:')

[IO.File]::WriteAllText($MarkdownPath, $markdown.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($TelegramPath, $telegram.ToString(), [Text.UTF8Encoding]::new($false))

[PSCustomObject]@{
    Added = $added
    Modified = $modified
    Deleted = $deleted
    Total = $changes.Count
    MarkdownPath = $MarkdownPath
    TelegramPath = $TelegramPath
}
