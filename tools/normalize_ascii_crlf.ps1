param([string[]]$Files)
foreach ($f in $Files) {
    $raw  = [System.IO.File]::ReadAllBytes($f)
    $text = [System.Text.Encoding]::GetEncoding('windows-1252').GetString($raw)
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, '(?<!\r)\n', "`r`n")
    $bareLF   = [System.Text.RegularExpressions.Regex]::Matches($text, '(?<!\r)\n').Count
    $nonAscii = [System.Text.RegularExpressions.Regex]::Matches($text, '[^\x00-\x7F]').Count
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
    [System.IO.File]::WriteAllBytes($f, $bytes)
    $name = [System.IO.Path]::GetFileName($f)
    Write-Host ("  {0,-65} bareLF={1} nonAscii={2}" -f $name, $bareLF, $nonAscii)
}
Write-Host "Normalization done."
