#!/bin/bash
# ============================================================
# YouTubeSync v12 — ScafNet
# FIX: aggiunto "--" ai grep che usano un video ID come pattern.
#      Gli ID che iniziano con "-" venivano scambiati per opzioni di grep
#      (errori "invalid option"), falsando rimozioni e ripristini.
# NOVITA' rispetto alla v10 (fix della causa vera dei rallentamenti
# e dei "video falliti"):
#  1) RIALLINEAMENTO ARCHIVIO: all'avvio lo script legge gli ID dai
#     nomi dei file MP3 gia' presenti ([xxxxxxxxxxx].mp3) e li scrive
#     nell'archivio. Cosi' yt-dlp salta per ID (prima di toccare la
#     rete) tutto cio' che e' gia' scaricato, anche se il TITOLO del
#     video e' cambiato. Il sync diventa di secondi e sparisce il
#     throttling che generava i "video falliti".
#  2) RIMOSSO --sleep-requests: non serve piu' (pochissime richieste).
#     Tenuti i retry e il conteggio video_falliti.
#
# Resto come v10: AUTO-AGGIORNANTE da GitHub, lista da web app GAS
# (con cache), _RIMOSSI unica, config locale (config.sh), ecc.
# ============================================================

GHRAW="https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/sync-from-playlist.command"

export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"
CONFIG_FILE="$SELF_DIR/config.sh"

# --- AUTO-UPDATE DA GITHUB ---
if [ -z "$YTS_SELFUPDATE_DONE" ] && printf '%s' "$GHRAW" | grep -q "^https"; then
  NEW="$(mktemp)"
  if curl -fsSL "$GHRAW" -o "$NEW" 2>/dev/null \
     && [ -s "$NEW" ] \
     && grep -q "YouTubeSync v" "$NEW" \
     && bash -n "$NEW" 2>/dev/null; then
    if ! cmp -s "$NEW" "$SELF_PATH"; then
      cp "$NEW" "$SELF_PATH" && chmod +x "$SELF_PATH"
      rm -f "$NEW"; export YTS_SELFUPDATE_DONE=1; exec "$SELF_PATH"
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

# Opzioni yt-dlp (retry per robustezza; niente sleep: ora si scarica poco)
YT_NET_OPTS=(--retries 5 --fragment-retries 5 --extractor-retries 3)
YT_META_OPTS=(--retries 5 --extractor-retries 3)

# --- STATO ---
ANY_NEW=false; ANY_REMOVED=false; ANY_RESTORED=false
VALID_PLAYLISTS=0; SKIPPED_LINES=0; UNREACHABLE=0
TOTAL_REMOVED=0; TOTAL_RESTORED=0; TOTAL_DLERR=0
START_TIME=$(date +%s)

mkdir -p "$DEST_FOLDER"
RUN_LOG=$(mktemp)

log() {
  local line="$(date) $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >> "$RUN_LOG"
}

extract_id_from_filename() {
  local name="$1"
  if [[ "$name" =~ \[([A-Za-z0-9_-]{11})\]\.mp3$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

osascript -e 'display notification "Sincronizzazione in corso..." with title "YouTubeSync" sound name "Submarine"'
log "inizio sincronizzazione (v12)"

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

# --- RIALLINEAMENTO ARCHIVIO DAI FILE GIA' PRESENTI ---
# Per ogni MP3 con ID nel nome (escluse le _RIMOSSI) assicura che
# "youtube <id>" sia nell'archivio, cosi' yt-dlp lo salta per ID.
touch "$ARCHIVE_FILE"
EXIST_IDS=$(mktemp); ARCH_IDS=$(mktemp)
find "$DEST_FOLDER" -type f -name "*].mp3" ! -path "$REMOVED_FOLDER/*" 2>/dev/null \
  | grep -oE '\[[A-Za-z0-9_-]{11}\]\.mp3$' | sed -E 's/^\[//; s/\]\.mp3$//' | sort -u > "$EXIST_IDS"
awk '/^youtube /{print $2}' "$ARCHIVE_FILE" | sort -u > "$ARCH_IDS"
added=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! grep -qx -- "$id" "$ARCH_IDS"; then
    echo "youtube $id" >> "$ARCHIVE_FILE"
    added=$((added + 1))
  fi
done < "$EXIST_IDS"
rm -f "$EXIST_IDS" "$ARCH_IDS"
[ "$added" -gt 0 ] && log "archivio riallineato: +$added id dai file esistenti"

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

# --- LOOP PLAYLIST ---
while IFS= read -r raw_line; do

  listid=$(printf '%s' "$raw_line" | grep -oE 'list=[A-Za-z0-9_-]+' | head -n1 | cut -d= -f2)
  if [ -z "$listid" ]; then
    SKIPPED_LINES=$((SKIPPED_LINES + 1)); continue
  fi

  playlist_url="https://www.youtube.com/playlist?list=$listid"
  folder_name=$(yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --playlist-items 1 --print "%(playlist_title)s" "$playlist_url" 2>/dev/null | head -n 1)
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
    yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR0"
    if [ -s "$CUR0" ]; then
      for file in "$REMOVED_FOLDER"/*.mp3; do
        [ ! -e "$file" ] && continue
        base=$(basename "$file")
        fid=$(extract_id_from_filename "$base"); [ -z "$fid" ] && continue
        if grep -Fxq -- "$fid" "$CUR0" && [ ! -e "$playlist_folder/$base" ]; then
          mv "$file" "$playlist_folder/"
          echo "youtube $fid" >> "$ARCHIVE_FILE"
          log "   ripristinato da _RIMOSSI: $base -> $folder_name"
          TOTAL_RESTORED=$((TOTAL_RESTORED + 1)); ANY_RESTORED=true
        fi
      done
    fi
    rm -f "$CUR0"
  fi

  # FASE 1 — DOWNLOAD nuovi (errori yt-dlp catturati e contati)
  cd "$playlist_folder" || continue
  before=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  ERRLOG=$(mktemp)
  yt-dlp \
    --yes-playlist --ignore-errors --no-overwrites \
    "${YT_NET_OPTS[@]}" \
    --extract-audio --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail --add-metadata \
    --download-archive "$ARCHIVE_FILE" \
    --output "%(title)s [%(id)s].%(ext)s" \
    "$playlist_url" 2>"$ERRLOG"
  dlerr=$(grep -c '^ERROR:' "$ERRLOG" 2>/dev/null)
  rm -f "$ERRLOG"
  if [ "${dlerr:-0}" -gt 0 ]; then
    log "   $dlerr video non scaricabili in \"$folder_name\" (rimossi/privati o throttling)"
    TOTAL_DLERR=$((TOTAL_DLERR + dlerr))
  fi
  after=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  new=$((after - before))
  if [ "$new" -gt 0 ]; then ANY_NEW=true; log "nuovi in \"$folder_name\": $new"; fi

  # FASE 2 — RIMOZIONI -> _RIMOSSI GENERALE
  CUR=$(mktemp)
  yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR"
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
      if ! grep -Fxq -- "$fid" "$CUR"; then
        mkdir -p "$REMOVED_FOLDER"
        mv -f "$file" "$REMOVED_FOLDER/"
        if [ -f "$ARCHIVE_FILE" ]; then
          grep -vxF -- "youtube $fid" "$ARCHIVE_FILE" > "${ARCHIVE_FILE}.tmp" 2>/dev/null && mv "${ARCHIVE_FILE}.tmp" "$ARCHIVE_FILE"
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

SUMMARY="Sync OK — playlist:$VALID_PLAYLISTS, nuovi:$ANY_NEW, rimossi:$TOTAL_REMOVED, ripristinati:$TOTAL_RESTORED, video_falliti:$TOTAL_DLERR, righe_saltate:$SKIPPED_LINES, non_raggiungibili:$UNREACHABLE (${DMIN}m${DSEC}s)"
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
