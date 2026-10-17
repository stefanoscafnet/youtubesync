#!/bin/bash
# ============================================================
# YouTubeSync v9 — ScafNet
# AUTO-AGGIORNANTE: a ogni avvio lo script controlla se su
# GitHub c'e' una versione piu' recente e, se c'e', si
# sostituisce da solo prima di partire. Cosi' Stefano aggiorna
# il codice sul repo (push) e il Mac di Max lo prende da solo
# al sync successivo, senza AnyDesk.
#
# SEPARAZIONE CODICE/CONFIG:
#  - Questo file (codice) sta su GitHub, pubblico, senza segreti.
#  - L'ENDPOINT_URL (web app GAS) sta in config.sh LOCALE accanto
#    a questo script, scritto dall'installer e MAI committato.
#
# Come la v8: lista playlist da web app GAS (con cache), log
# inviato a Stefano, _RIMOSSI unica generale, auto-correzione
# righe, nomi con ID, nessuna notifica allarmante per Max.
# ============================================================

# URL "grezzo" del file su GitHub da cui auto-aggiornarsi.
GHRAW="https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/sync-from-playlist.command"

export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"
CONFIG_FILE="$SELF_DIR/config.sh"

# --- AUTO-UPDATE DA GITHUB (prima di tutto) ---
# Sicurezza: aggiorna solo se il file scaricato non e' vuoto, contiene
# il marcatore "YouTubeSync v" ed e' sintatticamente valido. Se qualcosa
# non torna, tiene la versione attuale e prosegue. Niente loop grazie a
# YTS_SELFUPDATE_DONE.
if [ -z "$YTS_SELFUPDATE_DONE" ] && printf '%s' "$GHRAW" | grep -q "^https"; then
  NEW="$(mktemp)"
  if curl -fsSL "$GHRAW" -o "$NEW" 2>/dev/null \
     && [ -s "$NEW" ] \
     && grep -q "YouTubeSync v" "$NEW" \
     && bash -n "$NEW" 2>/dev/null; then
    if ! cmp -s "$NEW" "$SELF_PATH"; then
      cp "$NEW" "$SELF_PATH" && chmod +x "$SELF_PATH"
      rm -f "$NEW"
      export YTS_SELFUPDATE_DONE=1
      exec "$SELF_PATH"
    fi
  fi
  rm -f "$NEW"
fi

# --- CONFIG LOCALE (ENDPOINT_URL) ---
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${ENDPOINT_URL:=}"

# --- CONFIG ---
DEST_FOLDER="$HOME/Music/Youtube"
ARCHIVE_FILE="$DEST_FOLDER/archive_global.txt"
LOG_FILE="$DEST_FOLDER/youtube_sync.log"
PLAYLIST_CACHE="$DEST_FOLDER/playlist_cache.txt"
PLAYLIST_LOCAL="$HOME/Desktop/playlist.txt"
REMOVED_DIRNAME="_RIMOSSI"
REMOVED_FOLDER="$DEST_FOLDER/$REMOVED_DIRNAME"

# --- STATO ---
ANY_NEW=false; ANY_REMOVED=false; ANY_RESTORED=false
VALID_PLAYLISTS=0; SKIPPED_LINES=0; UNREACHABLE=0
TOTAL_REMOVED=0; TOTAL_RESTORED=0
START_TIME=$(date +%s)

mkdir -p "$DEST_FOLDER"
RUN_LOG=$(mktemp)

log() {
  local line="$(date) $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >> "$RUN_LOG"
}

osascript -e 'display notification "Sincronizzazione in corso..." with title "YouTubeSync" sound name "Submarine"'
log "inizio sincronizzazione (v9)"

# --- CHECK DIPENDENZE ---
if ! command -v yt-dlp >/dev/null 2>&1; then
  osascript -e 'display notification "Manca un componente. Chiama Stefano." with title "YouTubeSync"'
  log "ERRORE yt-dlp non trovato."; exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  osascript -e 'display notification "Manca un componente. Chiama Stefano." with title "YouTubeSync"'
  log "ERRORE ffmpeg non trovato."; exit 1
fi
if ! command -v deno >/dev/null 2>&1; then
  log "AVVISO deno non trovato — alcuni video potrebbero fallire (JS challenge)"
fi

# --- SCARICA LA LISTA PLAYLIST DAL WEB APP (con fallback a cache) ---
PLAYLIST_FILE=""
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  if curl -fsSL "$ENDPOINT_URL" -o "${PLAYLIST_CACHE}.new" 2>/dev/null && [ -s "${PLAYLIST_CACHE}.new" ]; then
    mv "${PLAYLIST_CACHE}.new" "$PLAYLIST_CACHE"
    PLAYLIST_FILE="$PLAYLIST_CACHE"
    log "lista playlist aggiornata da internet"
  else
    rm -f "${PLAYLIST_CACHE}.new"
    if [ -s "$PLAYLIST_CACHE" ]; then
      PLAYLIST_FILE="$PLAYLIST_CACHE"
      log "AVVISO internet non disponibile: uso la lista in cache"
    fi
  fi
fi
if [ -z "$PLAYLIST_FILE" ] && [ -s "$PLAYLIST_LOCAL" ]; then
  PLAYLIST_FILE="$PLAYLIST_LOCAL"
  log "AVVISO uso il file playlist.txt locale sulla Scrivania"
fi
if [ -z "$PLAYLIST_FILE" ]; then
  osascript -e 'display notification "Non trovo la lista delle playlist. Chiama Stefano." with title "YouTubeSync"'
  log "ERRORE nessuna lista playlist disponibile (ne web ne cache ne locale)."
  [ -n "$ENDPOINT_URL" ] && curl -fsS -X POST "$ENDPOINT_URL" --data-urlencode "summary=ERRORE: nessuna lista playlist" --data-urlencode "detail@$RUN_LOG" >/dev/null 2>&1
  rm -f "$RUN_LOG"; exit 1
fi

extract_id_from_filename() {
  local name="$1"
  if [[ "$name" =~ \[([A-Za-z0-9_-]{11})\]\.mp3$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# --- LOOP PLAYLIST ---
while IFS= read -r raw_line; do

  listid=$(printf '%s' "$raw_line" | grep -oE 'list=[A-Za-z0-9_-]+' | head -n1 | cut -d= -f2)
  if [ -z "$listid" ]; then
    SKIPPED_LINES=$((SKIPPED_LINES + 1)); continue
  fi

  playlist_url="https://www.youtube.com/playlist?list=$listid"
  folder_name=$(yt-dlp --flat-playlist --playlist-items 1 --print "%(playlist_title)s" "$playlist_url" 2>/dev/null | head -n 1)
  if [ -z "$folder_name" ]; then
    log "playlist non raggiungibile ora: $playlist_url"
    UNREACHABLE=$((UNREACHABLE + 1)); continue
  fi

  VALID_PLAYLISTS=$((VALID_PLAYLISTS + 1))
  playlist_folder="$DEST_FOLDER/$folder_name"
  mkdir -p "$playlist_folder"
  log "sync: $folder_name"

  # FASE 0 — RIPRISTINO dalla _RIMOSSI GENERALE
  if [ -d "$REMOVED_FOLDER" ]; then
    CUR0=$(mktemp)
    yt-dlp --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR0"
    if [ -s "$CUR0" ]; then
      for file in "$REMOVED_FOLDER"/*.mp3; do
        [ ! -e "$file" ] && continue
        base=$(basename "$file")
        fid=$(extract_id_from_filename "$base"); [ -z "$fid" ] && continue
        if grep -Fxq "$fid" "$CUR0" && [ ! -e "$playlist_folder/$base" ]; then
          mv "$file" "$playlist_folder/"
          echo "youtube $fid" >> "$ARCHIVE_FILE"
          log "   ripristinato da _RIMOSSI: $base -> $folder_name"
          TOTAL_RESTORED=$((TOTAL_RESTORED + 1)); ANY_RESTORED=true
        fi
      done
    fi
    rm -f "$CUR0"
  fi

  # FASE 1 — DOWNLOAD nuovi
  cd "$playlist_folder" || continue
  before=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  yt-dlp \
    --yes-playlist --ignore-errors --no-overwrites \
    --extract-audio --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail --add-metadata \
    --download-archive "$ARCHIVE_FILE" \
    --output "%(title)s [%(id)s].%(ext)s" \
    "$playlist_url"
  after=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  new=$((after - before))
  if [ "$new" -gt 0 ]; then ANY_NEW=true; log "nuovi in \"$folder_name\": $new"; fi

  # FASE 2 — RIMOZIONI -> _RIMOSSI GENERALE
  CUR=$(mktemp)
  yt-dlp --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR"
  ids_count=$(grep -cvE '^\s*$' "$CUR")
  if [ "$ids_count" -eq 0 ]; then
    log "AVVISO lettura \"$folder_name\" a 0 brani: rimozioni SALTATE per sicurezza."
    rm -f "$CUR"
  else
    removed_here=0
    for file in *.mp3; do
      [ ! -e "$file" ] && continue
      fid=$(extract_id_from_filename "$file")
      if [ -z "$fid" ]; then log "   senza ID, ignorato dalla rimozione: $file"; continue; fi
      if ! grep -Fxq "$fid" "$CUR"; then
        mkdir -p "$REMOVED_FOLDER"
        mv -f "$file" "$REMOVED_FOLDER/"
        if [ -f "$ARCHIVE_FILE" ]; then
          grep -v "youtube $fid" "$ARCHIVE_FILE" > "${ARCHIVE_FILE}.tmp" 2>/dev/null && mv "${ARCHIVE_FILE}.tmp" "$ARCHIVE_FILE"
        fi
        log "   rimosso da \"$folder_name\" -> _RIMOSSI: $file"
        removed_here=$((removed_here + 1)); TOTAL_REMOVED=$((TOTAL_REMOVED + 1)); ANY_REMOVED=true
      fi
    done
    [ "$removed_here" -gt 0 ] && log "rimossi da \"$folder_name\": $removed_here"
    rm -f "$CUR"
  fi

done < <(grep -vE '^\s*$|^\s*#' "$PLAYLIST_FILE")

# --- FINE ---
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME))
DMIN=$((DURATION / 60)); DSEC=$((DURATION % 60))
log "durata: ${DMIN}m ${DSEC}s"

SUMMARY="Sync OK — playlist:$VALID_PLAYLISTS, nuovi:$ANY_NEW, rimossi:$TOTAL_REMOVED, ripristinati:$TOTAL_RESTORED, righe_saltate:$SKIPPED_LINES, non_raggiungibili:$UNREACHABLE (${DMIN}m${DSEC}s)"
[ "$UNREACHABLE" -gt 0 ] && SUMMARY="ATTENZIONE $SUMMARY"
log "fine — $SUMMARY"
echo "----------------------------------------" >> "$LOG_FILE"

# --- INVIO STATO A STEFANO ---
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  curl -fsS -X POST "$ENDPOINT_URL" \
    --data-urlencode "summary=$SUMMARY" \
    --data-urlencode "detail@$RUN_LOG" >/dev/null 2>&1 \
    && log "stato inviato a Stefano" || log "AVVISO invio stato a Stefano non riuscito"
fi
rm -f "$RUN_LOG"

# --- NOTIFICA FINALE ---
if [ "$VALID_PLAYLISTS" -eq 0 ]; then
  osascript -e 'display notification "Nessuna musica da aggiornare. Se non e giusto, chiama Stefano." with title "YouTubeSync"'
else
  msg="Fatto! Musica aggiornata."
  [ "$ANY_NEW" = true ] && msg="$msg Scaricati brani nuovi."
  osascript -e "display notification \"$msg\" with title \"YouTubeSync\" sound name \"Glass\""
fi
