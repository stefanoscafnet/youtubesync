# YouTubeSync

Script `.command` (macOS) che sincronizza le playlist YouTube di un DJ in MP3
locali. Mantenuto da **ScafNet** per Massimo Rossi.

## Auto-aggiornamento
Lo script, a ogni avvio, scarica da questo repo (`raw`) la versione più recente
di sé stesso e, se valida e diversa, si sostituisce prima di partire. Per
aggiornare il Mac del DJ **basta fare push qui**: niente accesso remoto.

## Codice vs configurazione
- Qui c'è **solo il codice** (nessun segreto).
- L'`ENDPOINT_URL` (web app Google Apps Script) sta in un `config.sh` **locale**
  sul Mac del DJ, scritto dall'installer e **mai committato** (vedi `.gitignore`).

## File
- `sync-from-playlist.command` — lo script (questo è il "master" da cui parte l'auto-update).

## Sicurezza
L'auto-update esegue sul Mac del DJ ciò che sta in questo repo: tenere il **2FA**
attivo sull'account GitHub. Lo script valida sintassi e marcatore prima di
sostituirsi, ma questo ferma un file rotto, non uno malevolo.
