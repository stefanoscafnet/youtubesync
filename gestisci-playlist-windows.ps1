# ============================================================
# YouTubeSync PC Gestisci playlist v1 — ScafNet
# Per Max: aggiungere, togliere e vedere le playlist sincronizzate,
# con le finestre normali di Windows. Le modifiche vanno nel foglio
# Google di Stefano (lo stesso del Mac: valgono per tutti e due).
# Installato e aggiornato da solo dallo script di sincronizzazione.
# ============================================================

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir = $PSScriptRoot
$Title  = 'YouTubeSync'
$YtDlp  = Join-Path (Join-Path $AppDir 'bin') 'yt-dlp.exe'
$SyncScript = Join-Path $AppDir 'sync-windows.ps1'
$MusicRoot = [Environment]::GetFolderPath('MyMusic')
if (-not $MusicRoot -or $MusicRoot -match 'OneDrive') { $MusicRoot = Join-Path $env:USERPROFILE 'Music' }
$Dest = Join-Path $MusicRoot 'Youtube'

$EndpointUrl = ''
$cfg = Join-Path $AppDir 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }

# ---------------------------------------------------------------- finestre
function Msg([string]$text, [string]$icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$icon)
}
function Ask([string]$text, [string]$icon = 'Question') {
    $r = [System.Windows.Forms.MessageBox]::Show($text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::$icon)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}
function New-Btn([string]$text, [int]$y, $result) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Width = 300; $b.Height = 46; $b.Left = 30; $b.Top = $y
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $b.DialogResult = $result
    return $b
}
function Show-Menu {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title + ' - Gestisci playlist'; $f.Width = 380; $f.Height = 330
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'Cosa vuoi fare?'; $l.Left = 30; $l.Top = 18; $l.Width = 300; $l.Height = 28
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $f.Controls.Add($l)
    $f.Controls.Add((New-Btn 'Aggiungi una playlist' 55  ([System.Windows.Forms.DialogResult]::Yes)))
    $f.Controls.Add((New-Btn 'Togli una playlist'    110 ([System.Windows.Forms.DialogResult]::No)))
    $f.Controls.Add((New-Btn 'Vedi le playlist'      165 ([System.Windows.Forms.DialogResult]::Retry)))
    $c = New-Btn 'Chiudi' 225 ([System.Windows.Forms.DialogResult]::Cancel); $c.Height = 34
    $f.Controls.Add($c); $f.CancelButton = $c
    $r = $f.ShowDialog(); $f.Dispose()
    return $r
}
function Pick-One([string]$prompt, [string[]]$items) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.Width = 420; $f.Height = 460; $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $prompt; $l.Left = 20; $l.Top = 15; $l.Width = 370; $l.Height = 40
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Left = 20; $lb.Top = 60; $lb.Width = 365; $lb.Height = 290
    $lb.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    [void]$lb.Items.AddRange($items)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Scegli'; $ok.Left = 190; $ok.Top = 365; $ok.Width = 95; $ok.Height = 32
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $no = New-Object System.Windows.Forms.Button
    $no.Text = 'Annulla'; $no.Left = 290; $no.Top = 365; $no.Width = 95; $no.Height = 32
    $no.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($l, $lb, $ok, $no)); $f.AcceptButton = $ok; $f.CancelButton = $no
    $lb.Add_DoubleClick({ $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close() })
    $r = $f.ShowDialog()
    $sel = $lb.SelectedIndex
    $f.Dispose()
    if ($r -ne [System.Windows.Forms.DialogResult]::OK -or $sel -lt 0) { return -1 }
    return $sel
}
function Show-Wait([string]$text) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.Width = 360; $f.Height = 130; $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'; $f.ControlBox = $false; $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Left = 20; $l.Top = 25; $l.Width = 310; $l.Height = 40
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $f.Controls.Add($l); $f.Show(); $f.Refresh()
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    return $f
}

# ---------------------------------------------------------------- foglio
function Get-Text([string]$url) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    return $wc.DownloadString($url)
}
function Post-Form([hashtable]$fields) {
    $parts = @()
    foreach ($k in $fields.Keys) { $parts += ([Uri]::EscapeDataString($k) + '=' + [Uri]::EscapeDataString([string]$fields[$k])) }
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return $wc.UploadString($EndpointUrl, 'POST', ($parts -join '&'))
}
function Load-List {
    # oggetti: Id, Name, Link
    $txt = Get-Text ($EndpointUrl + '?action=list')
    $out = @()
    foreach ($l in ($txt -split "`r?`n")) {
        $p = $l -split "`t"
        if ($p.Count -ge 3 -and $p[0]) {
            $n = $p[1].Trim(); if (-not $n) { $n = $p[0] }
            $out += [pscustomobject]@{ Id = $p[0]; Name = $n; Link = $p[2] }
        }
    }
    return ,$out
}

# ---------------------------------------------------------------- controlli
if ($EndpointUrl -notmatch '^https') { Msg 'Manca la configurazione. Chiama Stefano.' 'Warning'; exit 1 }
try { $ver = (Get-Text ($EndpointUrl + '?action=version')).Trim() } catch { $ver = '' }
if (-not $ver) { Msg 'Non riesco a collegarmi. Controlla la connessione a internet e riprova.' 'Warning'; exit 1 }
if ($ver -ne 'YTS-GAS v3') { Msg 'Questa funzione non e'' ancora attiva. Chiama Stefano.' 'Warning'; exit 1 }

# ---------------------------------------------------------------- azioni
function Do-Add {
    $def = ''
    try { $clip = [System.Windows.Forms.Clipboard]::GetText(); if ($clip -match 'list=') { $def = ($clip -split "`r?`n")[0].Trim() } } catch {}
    $link = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Incolla qui il link della playlist.`n`nSu YouTube: apri la playlist, clicca Condividi e poi Copia.", $Title, $def)
    if (-not $link) { return }
    if ($link -notmatch 'list=([A-Za-z0-9_-]+)') {
        Msg "Questo non e' il link di una playlist.`n`nIl link giusto contiene la parola «list=». Riprova copiandolo da YouTube con Condividi > Copia." 'Warning'
        return
    }
    $id = $Matches[1]
    if ($id -like 'RD*') { Msg "Questo e' un «Mix» creato da YouTube, non una tua playlist: non si puo' sincronizzare.`n`nCrea una playlist tua con i brani che vuoi e aggiungi quella." 'Warning'; return }
    if ($id -ceq 'LL' -or $id -ceq 'WL') { Msg "Questa lista e' privata per forza (Mi piace / Guarda piu' tardi) e non si puo' sincronizzare.`n`nCrea una playlist tua con i brani che vuoi e aggiungi quella." 'Warning'; return }
    try { $list = Load-List } catch { $list = @() }
    $dup = @($list | Where-Object { $_.Id -ceq $id })
    if ($dup.Count -gt 0) { Msg ("La playlist «" + $dup[0].Name + "» e' gia' nell'elenco."); return }

    $w = Show-Wait 'Controllo la playlist su YouTube...'
    $tmpO = [IO.Path]::GetTempFileName(); $tmpE = [IO.Path]::GetTempFileName()
    $title = ''; $count = 0
    try {
        $ytArgs = '--encoding utf-8 --flat-playlist --print "%(playlist_title)s' + "`t" + '%(id)s" "https://www.youtube.com/playlist?list=' + $id + '"'
        Start-Process -FilePath $YtDlp -ArgumentList $ytArgs -NoNewWindow -Wait -RedirectStandardOutput $tmpO -RedirectStandardError $tmpE | Out-Null
        $lines = @([IO.File]::ReadAllLines($tmpO, [Text.Encoding]::UTF8) | Where-Object { $_ -match "`t" })
        if ($lines.Count -gt 0) { $title = ($lines[0] -split "`t")[0]; $count = $lines.Count }
    } catch {}
    Remove-Item -LiteralPath $tmpO, $tmpE -ErrorAction SilentlyContinue
    $w.Close(); $w.Dispose()

    if (-not $title -or $title -eq 'NA') {
        Msg "Non riesco a leggere questa playlist.`n`nDi solito succede quando e' «Privata». Su YouTube apri la playlist, cambia la visibilita' in «Non in elenco» (o «Pubblica») e riprova." 'Warning'
        return
    }
    if (-not (Ask ("Ho trovato:`n`n«" + $title + "»`n" + $count + " brani`n`nLa aggiungo alla sincronizzazione?"))) { return }
    try { $resp = (Post-Form @{ action = 'add'; link = ('https://www.youtube.com/playlist?list=' + $id); name = $title }).Trim() } catch { $resp = '' }
    switch ($resp) {
        'OK' {
            if (Ask ("Fatto! «" + $title + "» e' stata aggiunta.`n`nI brani verranno scaricati alla prossima sincronizzazione.`n`nVuoi sincronizzare adesso?")) {
                Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $SyncScript + '"')
                exit 0
            }
        }
        'GIA_PRESENTE' { Msg ("La playlist «" + $title + "» e' gia' nell'elenco.") }
        default { Msg "Non sono riuscito a salvarla. Controlla internet e riprova; se continua, chiama Stefano." 'Warning' }
    }
}

function Do-Remove {
    try { $list = Load-List } catch { Msg "Non riesco a leggere l'elenco. Controlla internet e riprova." 'Warning'; return }
    if ($list.Count -eq 0) { Msg 'Non ci sono playlist da togliere.'; return }
    $i = Pick-One 'Quale playlist vuoi togliere dalla sincronizzazione?' ([string[]]($list | ForEach-Object { $_.Name }))
    if ($i -lt 0) { return }
    $pl = $list[$i]
    if (-not (Ask ("Togliere «" + $pl.Name + "» dalla sincronizzazione?`n`nI brani gia' scaricati restano sul PC."))) { return }
    try { $resp = (Post-Form @{ action = 'remove'; listid = $pl.Id }).Trim() } catch { $resp = '' }
    if ($resp -ne 'OK' -and $resp -ne 'NON_TROVATA') { Msg "Non sono riuscito a toglierla. Controlla internet e riprova; se continua, chiama Stefano." 'Warning'; return }

    $safe = ($pl.Name -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.').Trim()
    $folder = Join-Path $Dest $safe
    $sameName = @($list | Where-Object { $_.Name -eq $pl.Name -and $_.Id -cne $pl.Id }).Count
    if ($safe -and $safe -notlike '_*' -and (Test-Path -LiteralPath $folder -PathType Container) -and $sameName -eq 0) {
        if (Ask ("Fatto: «" + $pl.Name + "» non verra' piu' sincronizzata.`n`nVuoi spostare anche la sua cartella nel Cestino? (Se cambi idea la recuperi dal Cestino.)")) {
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($folder,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                Msg ("Cartella «" + $pl.Name + "» spostata nel Cestino.")
            } catch {
                Msg "Non sono riuscito a spostare la cartella. Puoi trascinarla nel Cestino tu dalla cartella Musica > Youtube." 'Warning'
            }
        }
    } else {
        Msg ("Fatto: «" + $pl.Name + "» non verra' piu' sincronizzata.")
    }
}

function Do-List {
    try { $list = Load-List } catch { Msg "Non riesco a leggere l'elenco. Controlla internet e riprova." 'Warning'; return }
    $txt = ($list | ForEach-Object { '•  ' + $_.Name }) -join "`n"
    Msg ("Playlist sincronizzate (" + $list.Count + "):`n`n" + $txt)
}

# ---------------------------------------------------------------- menu
while ($true) {
    $c = Show-Menu
    if ($c -eq [System.Windows.Forms.DialogResult]::Yes) { Do-Add }
    elseif ($c -eq [System.Windows.Forms.DialogResult]::No) { Do-Remove }
    elseif ($c -eq [System.Windows.Forms.DialogResult]::Retry) { Do-List }
    else { break }
}
exit 0
