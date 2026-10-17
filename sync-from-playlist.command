#!/bin/bash
# ============================================================
# YouTubeSync v16 — ScafNet
# NOVITA' rispetto alla v15:
#  - Log pulito: dell'aggiornamento Homebrew resta solo la riga
#    "yt-dlp vecchia -> nuova"; il dettaglio inviato al foglio e'
#    tagliato sotto il limite di 50.000 caratteri della cella.
#  - Per ogni brano mancante il log riporta link, titolo e motivo
#    (morto / bloccato), cosi' Stefano puo' aprirlo e verificarlo.
#  - Secondo tentativo automatico per i brani bloccati (403 ecc.)
#    con altre modalita' di yt-dlp (RETRY_CLIENTS).
# Dalla v15:
#  - CARTELLE COMPLETE: ogni cartella playlist contiene TUTTI i suoi
#    brani. Un brano presente in piu' playlist si scarica una volta
#    sola e nelle altre cartelle viene messo come "clone" APFS
#    (cp -c): zero spazio in piu', nessun nuovo download.
#  - Lo stato si legge dai FILE su disco (non piu' dall'archivio):
#    per ogni playlist si scaricano esattamente i brani mancanti.
#  - Una sola lettura della playlist da YouTube (prima erano 3).
#  - yt-dlp si aggiorna da solo (al massimo una volta al giorno).
#  - Rimozioni: se il brano tolto esiste ancora in un'altra cartella
#    si toglie solo il doppione; se era l'unica copia va in _RIMOSSI.
#  - UI: barra ASCII, schermo pulito (niente schermate accumulate),
#    ✓ / ✓* / ⚠ veritieri, messaggi distinti per video morti e bloccati.
#  - Resta: AUTO-AGGIORNANTE da GitHub, log completo a Stefano.
# ============================================================

APP_VERSION="v16"
GHRAW="https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/sync-from-playlist.command"

export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_COLLATE=C   # ordinamento coerente per sort/comm

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"
CONFIG_FILE="$SELF_DIR/config.sh"

# --- AUTO-UPDATE DELLO SCRIPT DA GITHUB (silenzioso) ---
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
LOG_FILE="$DEST_FOLDER/youtube_sync.log"
PLAYLIST_CACHE="$DEST_FOLDER/playlist_cache.txt"
PLAYLIST_LOCAL="$HOME/Desktop/playlist.txt"
REMOVED_FOLDER="$DEST_FOLDER/_RIMOSSI"
YTDLP_STAMP="$DEST_FOLDER/.ytdlp_update_stamp"
LOG_KEEP_LINES=5000
DETAIL_MAX=45000                 # byte max del dettaglio inviato al foglio (cella: 50.000 caratteri)
RETRY_CLIENTS=(tv web_safari)    # modalita' yt-dlp per il secondo tentativo sui bloccati

YT_NET_OPTS=(--retries 5 --fragment-retries 5 --extractor-retries 3)
YT_META_OPTS=(--retries 5 --extractor-retries 3)

# --- STATO ---
VALID_PLAYLISTS=0; SKIPPED_LINES=0; UNREACHABLE=0
TOTAL_NEW=0; TOTAL_CLONED=0; TOTAL_RESTORED=0; TOTAL_REMOVED=0; TOTAL_DUPDEL=0
TOTAL_RETRY_OK=0; TOTAL_DLERR=0; DEAD=0; BOT=0; E403=0; E429=0
MISSING_DEAD=0; MISSING_OTHER=0
START_TIME=$(date +%s)

mkdir -p "$DEST_FOLDER"
WORK=$(mktemp -d)
RUN_LOG="$WORK/run.log"; RPT="$WORK/report.tsv"; INDEX="$WORK/index.tsv"
: > "$RUN_LOG"; : > "$RPT"

log() {
  local line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >> "$RUN_LOG"
}

# ---------- INDICE DEI FILE (id <TAB> percorso) ----------
build_index() {
  find "$DEST_FOLDER" -type f -name '*].mp3' 2>/dev/null | while IFS= read -r p; do
    b="${p##*/}"
    if [[ "$b" =~ \[([A-Za-z0-9_-]{11})\]\.mp3$ ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$p"
    fi
  done > "$INDEX"
}
# ID presenti in una cartella (solo primo livello), ordinati
ids_in_folder() {
  find "$1" -maxdepth 1 -type f -name '*].mp3' 2>/dev/null \
    | sed -nE 's/.*\[([A-Za-z0-9_-]{11})\]\.mp3$/\1/p' | sort -u
}
# sorgente per un id mancante in $2: prima un'altra cartella playlist, poi _RIMOSSI
find_src() {
  awk -F'\t' -v id="$1" -v F="$2/" -v R="$REMOVED_FOLDER/" '
    $1==id && index($2,F)!=1 {
      if (index($2,R)==1) { if (r=="") r=$2 }
      else { print $2; found=1; exit }
    }
    END { if (!found && r!="") print r }' "$INDEX"
}
# esiste una copia dell'id fuori da $2 e fuori da _RIMOSSI?
other_copy() {
  awk -F'\t' -v id="$1" -v F="$2/" -v R="$REMOVED_FOLDER/" '
    $1==id && index($2,F)!=1 && index($2,R)!=1 { print $2; exit }' "$INDEX"
}

# ---------- INTERFACCIA ----------
UI_LINE='   ------------------------------------------------'
draw_header() {
  printf '\033[2J\033[3J\033[H\n'
  printf '   ================================================\n'
  printf '      🎵  YouTubeSync      %s\n' "$APP_VERSION"
  printf '   ================================================\n\n'
}
draw_progress() {
  # $1 idx  $2 total  $3 playlist  $4 fase
  local idx=$1 total=$2 name=$3 stage=$4
  local bl=30 f=0 i=0 bar=""
  [ "$total" -gt 0 ] && f=$(( idx * bl / total ))
  [ "$f" -gt "$bl" ] && f=$bl
  while [ $i -lt $f ];  do bar="$bar#"; i=$((i+1)); done
  while [ $i -lt $bl ]; do bar="$bar."; i=$((i+1)); done
  draw_header
  printf '      Sincronizzazione in corso...\n\n'
  printf '      [%s]  %d / %d\n\n' "$bar" "$idx" "$total"
  printf '      >  %s\n' "$name"
  printf '         %s\n\n' "$stage"
  printf '      Brani nuovi scaricati:  %d\n' "$TOTAL_NEW"
  [ "$TOTAL_CLONED" -gt 0 ] && printf '      Brani aggiunti da altre playlist:  %d\n' "$TOTAL_CLONED"
  printf '\n\n      (lascia pure la finestra aperta, ci penso io)\n'
}
draw_simple() { draw_header; printf '      %s\n' "$1"; }

draw_simple "Avvio in corso..."
osascript -e 'display notification "Sincronizzazione avviata" with title "YouTubeSync"' 2>/dev/null
log "inizio sincronizzazione ($APP_VERSION)"

# --- CHECK DIPENDENZE ---
missing=""
command -v yt-dlp >/dev/null 2>&1 || missing="yt-dlp"
command -v ffmpeg >/dev/null 2>&1 || missing="${missing:+$missing, }ffmpeg"
if [ -n "$missing" ]; then
  draw_header
  printf '      ⚠  Manca un componente (%s).\n\n      Chiama Stefano.\n\n' "$missing"
  osascript -e 'display notification "Manca un componente. Chiama Stefano." with title "YouTubeSync"' 2>/dev/null
  log "ERRORE componente mancante: $missing"
  exit 1
fi
command -v deno >/dev/null 2>&1 || log "AVVISO deno non trovato — alcuni video potrebbero fallire (JS challenge)"

# --- AGGIORNAMENTO yt-dlp (max 1 volta al giorno) ---
if command -v brew >/dev/null 2>&1; then
  if [ ! -f "$YTDLP_STAMP" ] || [ -n "$(find "$YTDLP_STAMP" -mtime +0 2>/dev/null)" ]; then
    draw_simple "Controllo aggiornamenti..."
    log "aggiornamento yt-dlp (brew)"
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade yt-dlp </dev/null >"$WORK/brew.out" 2>&1
    brew_rc=$?
    up=$(grep -E '^yt-dlp [^ ]+ -> ' "$WORK/brew.out" | head -n1)
    already=$(grep -iE 'yt-dlp.*already installed' "$WORK/brew.out" | head -n1)
    if [ -n "$up" ]; then log "   brew: $up"
    elif [ -n "$already" ]; then log "   brew: yt-dlp gia' all'ultima versione"
    else log "   brew: esito $brew_rc (nessun aggiornamento di yt-dlp)"
      grep -iE '^Error' "$WORK/brew.out" | head -n 3 | sed 's/^/     /' >> "$RUN_LOG"
    fi
    touch "$YTDLP_STAMP"
  fi
fi
YTDLP_VER=$(yt-dlp --version 2>/dev/null | head -n1)
log "yt-dlp versione: ${YTDLP_VER:-sconosciuta}"

# --- LISTA PLAYLIST (web -> cache -> locale) ---
PLAYLIST_FILE=""
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  if curl -fsSL "$ENDPOINT_URL" -o "${PLAYLIST_CACHE}.new" 2>/dev/null && [ -s "${PLAYLIST_CACHE}.new" ]; then
    mv "${PLAYLIST_CACHE}.new" "$PLAYLIST_CACHE"; PLAYLIST_FILE="$PLAYLIST_CACHE"
    log "lista playlist aggiornata da internet"
  else
    rm -f "${PLAYLIST_CACHE}.new"
    [ -s "$PLAYLIST_CACHE" ] && { PLAYLIST_FILE="$PLAYLIST_CACHE"; log "AVVISO internet assente: uso lista in cache"; }
  fi
fi
[ -z "$PLAYLIST_FILE" ] && [ -s "$PLAYLIST_LOCAL" ] && { PLAYLIST_FILE="$PLAYLIST_LOCAL"; log "AVVISO uso playlist.txt locale"; }
if [ -z "$PLAYLIST_FILE" ]; then
  draw_header
  printf '      ⚠  Non trovo la lista delle playlist.\n\n      Chiama Stefano.\n\n'
  osascript -e 'display notification "Non trovo la lista playlist. Chiama Stefano." with title "YouTubeSync"' 2>/dev/null
  log "ERRORE nessuna lista playlist disponibile."
  [ -n "$ENDPOINT_URL" ] && curl -fsS -X POST "$ENDPOINT_URL" --data-urlencode "summary=ERRORE: nessuna lista playlist" --data-urlencode "detail@$RUN_LOG" >/dev/null 2>&1
  rm -rf "$WORK"; exit 1
fi

TOTAL_PL=$(grep -cE 'list=' "$PLAYLIST_FILE"); [ "$TOTAL_PL" -eq 0 ] && TOTAL_PL=1
idx=0
build_index

# --- LOOP PLAYLIST (lista letta da fd 3, cosi' nessun comando interno la "mangia") ---
while IFS= read -r raw_line <&3; do

  listid=$(printf '%s' "$raw_line" | grep -oE 'list=[A-Za-z0-9_-]+' | head -n1 | cut -d= -f2)
  if [ -z "$listid" ]; then SKIPPED_LINES=$((SKIPPED_LINES + 1)); continue; fi
  idx=$((idx + 1))
  playlist_url="https://www.youtube.com/playlist?list=$listid"

  draw_progress "$idx" "$TOTAL_PL" "playlist $idx" "lettura da YouTube..."

  # UNA sola lettura: titolo + id di tutti i brani
  META="$WORK/meta"; CUR="$WORK/cur"
  yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --print $'%(playlist_title)s\t%(id)s\t%(title)s' "$playlist_url" </dev/null 2>/dev/null > "$META"
  folder_name=$(head -n1 "$META" | cut -f1)
  cut -f2 "$META" | grep -E '^[A-Za-z0-9_-]{11}$' | sort -u > "$CUR"
  yt_count=$(wc -l < "$CUR" | tr -d ' ')

  if [ -z "$folder_name" ] || [ "$folder_name" = "NA" ]; then
    log "playlist non raggiungibile: $playlist_url"
    UNREACHABLE=$((UNREACHABLE + 1))
    printf 'UNREACH\t%s\t-\t-\t0\n' "playlist n.$idx (non raggiungibile)" >> "$RPT"
    continue
  fi

  VALID_PLAYLISTS=$((VALID_PLAYLISTS + 1))
  F="$DEST_FOLDER/$folder_name"
  mkdir -p "$F"
  log "sync: $folder_name ($yt_count brani su YouTube)"

  if [ "$yt_count" -eq 0 ]; then
    log "AVVISO \"$folder_name\": letti 0 brani — playlist saltata per sicurezza."
    mac_now=$(ids_in_folder "$F" | wc -l | tr -d ' ')
    printf 'WARN\t%s\t?\t%s\t0\n' "$folder_name" "$mac_now" >> "$RPT"
    continue
  fi

  HAVE="$WORK/have"; MISS="$WORK/miss"; DEADIDS="$WORK/deadids"
  : > "$DEADIDS"

  # FASE 1 — completa da altre cartelle (clone) o da _RIMOSSI (ripristino)
  ids_in_folder "$F" > "$HAVE"
  comm -23 "$CUR" "$HAVE" > "$MISS"
  if [ -s "$MISS" ]; then
    draw_progress "$idx" "$TOTAL_PL" "$folder_name" "controllo brani gia' presenti in altre playlist..."
    while IFS= read -r id; do
      src=$(find_src "$id" "$F")
      [ -z "$src" ] && continue
      [ -e "$src" ] || continue
      case "$src" in
        "$REMOVED_FOLDER"/*)
          if mv "$src" "$F/"; then
            TOTAL_RESTORED=$((TOTAL_RESTORED + 1)); log "   ripristinato da _RIMOSSI: ${src##*/}"
          fi ;;
        *)
          if cp -c "$src" "$F/" 2>/dev/null || cp -p "$src" "$F/"; then
            TOTAL_CLONED=$((TOTAL_CLONED + 1)); log "   copiato da altra playlist: ${src##*/}"
          fi ;;
      esac
    done < "$MISS"
  fi

  # FASE 2 — scarica SOLO i brani ancora mancanti
  ids_in_folder "$F" > "$HAVE"
  comm -23 "$CUR" "$HAVE" > "$MISS"
  new=0
  n_miss=$(wc -l < "$MISS" | tr -d ' ')
  if [ "$n_miss" -gt 0 ]; then
    draw_progress "$idx" "$TOTAL_PL" "$folder_name" "scarico $n_miss brani..."
    URLS="$WORK/urls"; ERRLOG="$WORK/err"
    sed 's#^#https://www.youtube.com/watch?v=#' "$MISS" > "$URLS"
    before=$(ids_in_folder "$F" | wc -l | tr -d ' ')
    ( cd "$F" && yt-dlp \
        --quiet --no-warnings --ignore-errors --no-overwrites \
        "${YT_NET_OPTS[@]}" \
        --extract-audio --audio-format mp3 --audio-quality 0 \
        --embed-thumbnail --add-metadata \
        --output "%(title)s [%(id)s].%(ext)s" \
        -a "$URLS" </dev/null >>"$RUN_LOG" 2>"$ERRLOG" )
    after=$(ids_in_folder "$F" | wc -l | tr -d ' ')
    new=$((after - before)); [ "$new" -lt 0 ] && new=0
    TOTAL_NEW=$((TOTAL_NEW + new))
    [ "$new" -gt 0 ] && log "nuovi in \"$folder_name\": $new"

    dlerr=$(grep -c '^ERROR:' "$ERRLOG" 2>/dev/null); dlerr=${dlerr:-0}
    if [ "$dlerr" -gt 0 ]; then
      DEADRE='^ERROR:.*(unavailable|private|removed|terminated|copyright|not available|no longer)'
      d_dead=$(grep -ciE "$DEADRE" "$ERRLOG")
      d_bot=$(grep -ciE '^ERROR:.*(sign in to confirm|not a bot|confirm you)' "$ERRLOG")
      d_403=$(grep -ciE '^ERROR:.*(403|forbidden)' "$ERRLOG")
      d_429=$(grep -ciE '^ERROR:.*(429|too many requests)' "$ERRLOG")
      DEAD=$((DEAD + d_dead)); BOT=$((BOT + d_bot)); E403=$((E403 + d_403)); E429=$((E429 + d_429))
      TOTAL_DLERR=$((TOTAL_DLERR + dlerr))
      grep -iE "$DEADRE" "$ERRLOG" | sed -nE 's/^ERROR: \[[^]]*\] ([A-Za-z0-9_-]{11}):.*/\1/p' | sort -u > "$DEADIDS"
      log "   $dlerr non scaricabili in \"$folder_name\" (morti:$d_dead signin:$d_bot 403:$d_403 429:$d_429)"
      grep '^ERROR:' "$ERRLOG" | head -n 40 | sed 's/^/     /' >> "$RUN_LOG"
    fi

    # secondo tentativo: solo i mancanti NON morti, con altre modalita' di yt-dlp
    ids_in_folder "$F" > "$HAVE"
    comm -23 "$CUR" "$HAVE" | comm -23 - "$DEADIDS" > "$WORK/retry"
    for client in "${RETRY_CLIENTS[@]}"; do
      n_retry=$(wc -l < "$WORK/retry" | tr -d ' ')
      [ "$n_retry" -eq 0 ] && break
      draw_progress "$idx" "$TOTAL_PL" "$folder_name" "secondo tentativo per $n_retry brani..."
      sed 's#^#https://www.youtube.com/watch?v=#' "$WORK/retry" > "$URLS"
      b2=$(ids_in_folder "$F" | wc -l | tr -d ' ')
      ( cd "$F" && yt-dlp \
          --quiet --no-warnings --ignore-errors --no-overwrites \
          "${YT_NET_OPTS[@]}" \
          --extractor-args "youtube:player_client=$client" \
          --extract-audio --audio-format mp3 --audio-quality 0 \
          --embed-thumbnail --add-metadata \
          --output "%(title)s [%(id)s].%(ext)s" \
          -a "$URLS" </dev/null >>"$RUN_LOG" 2>"$WORK/err2" )
      a2=$(ids_in_folder "$F" | wc -l | tr -d ' ')
      got=$((a2 - b2)); [ "$got" -lt 0 ] && got=0
      TOTAL_RETRY_OK=$((TOTAL_RETRY_OK + got)); TOTAL_NEW=$((TOTAL_NEW + got))
      log "   secondo tentativo ($client) in \"$folder_name\": recuperati $got su $n_retry"
      grep '^ERROR:' "$WORK/err2" | head -n 5 | sed "s/^/     [$client] /" >> "$RUN_LOG"
      ids_in_folder "$F" > "$HAVE"
      comm -23 "$CUR" "$HAVE" | comm -23 - "$DEADIDS" > "$WORK/retry"
    done
  fi

  # FASE 3 — brani tolti dalla playlist
  draw_progress "$idx" "$TOTAL_PL" "$folder_name" "riordino..."
  build_index
  ids_in_folder "$F" > "$HAVE"
  comm -13 "$CUR" "$HAVE" > "$MISS"     # qui: id presenti in cartella ma non piu' in playlist
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    find "$F" -maxdepth 1 -type f -name "*\[$id\].mp3" 2>/dev/null | while IFS= read -r file; do
      other=$(other_copy "$id" "$F")
      if [ -n "$other" ] && [ -e "$other" ]; then
        rm -f "$file" && od="${other%/*}"; log "   tolto doppione (resta in ${od##*/}): ${file##*/}" && echo D >> "$WORK/cnt"
      else
        mkdir -p "$REMOVED_FOLDER"
        mv -f "$file" "$REMOVED_FOLDER/" && log "   rimosso da \"$folder_name\" -> _RIMOSSI: ${file##*/}" && echo R >> "$WORK/cnt"
      fi
    done
  done < "$MISS"
  build_index

  # riga tabella finale
  ids_in_folder "$F" > "$HAVE"
  mac_count=$(comm -12 "$CUR" "$HAVE" | wc -l | tr -d ' ')
  comm -23 "$CUR" "$HAVE" > "$MISS"
  miss_n=$(wc -l < "$MISS" | tr -d ' ')
  miss_dead=$(comm -12 "$MISS" "$DEADIDS" | wc -l | tr -d ' ')
  MISSING_DEAD=$((MISSING_DEAD + miss_dead))
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    t=$(awk -F'\t' -v id="$id" '$2==id { print $3; exit }' "$META")
    if grep -qxF -- "$id" "$DEADIDS"; then why="non esiste piu'"; else why="bloccato"; fi
    log "   manca in \"$folder_name\": https://youtu.be/$id  ($why)  $t"
  done < "$MISS"
  MISSING_OTHER=$((MISSING_OTHER + miss_n - miss_dead))
  if [ "$miss_n" -eq 0 ]; then st="OK"
  elif [ "$miss_n" -eq "$miss_dead" ]; then st="DEAD"
  else st="WARN"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$folder_name" "$yt_count" "$mac_count" "$miss_dead" >> "$RPT"

done 3< <(grep -vE '^\s*$|^\s*#' "$PLAYLIST_FILE")

[ -f "$WORK/cnt" ] && { TOTAL_DUPDEL=$(grep -c D "$WORK/cnt"); TOTAL_REMOVED=$(grep -c R "$WORK/cnt"); }

# --- SUMMARY TECNICO ---
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME))
DMIN=$((DURATION / 60)); DSEC=$((DURATION % 60))
OTHER=$((TOTAL_DLERR - DEAD - BOT - E403 - E429)); [ "$OTHER" -lt 0 ] && OTHER=0
SUMMARY="Sync $APP_VERSION (yt-dlp ${YTDLP_VER:-?}) — playlist:$VALID_PLAYLISTS, nuovi:$TOTAL_NEW (di cui al 2o tentativo:$TOTAL_RETRY_OK), copiati_da_altre:$TOTAL_CLONED, ripristinati:$TOTAL_RESTORED, rimossi:$TOTAL_REMOVED, doppioni_tolti:$TOTAL_DUPDEL, mancanti:$((MISSING_DEAD + MISSING_OTHER)) [morti:$MISSING_DEAD altri:$MISSING_OTHER], errori_download:$TOTAL_DLERR [morti:$DEAD signin:$BOT 403:$E403 429:$E429 altro:$OTHER], righe_saltate:$SKIPPED_LINES, non_raggiungibili:$UNREACHABLE (${DMIN}m${DSEC}s)"
{ [ "$UNREACHABLE" -gt 0 ] || [ "$MISSING_OTHER" -gt 0 ]; } && SUMMARY="ATTENZIONE $SUMMARY"
log "durata: ${DMIN}m ${DSEC}s"
log "fine — $SUMMARY"
{
  echo "---- RIEPILOGO PLAYLIST (stato / YouTube / Mac / mancanti morti) ----"
  awk -F'\t' '{printf "  [%-7s] %-30s yt:%-4s mac:%-4s morti:%s\n",$1,$2,$3,$4,$5}' "$RPT"
  echo "--------------------------------------------------------------------"
} >> "$RUN_LOG"
echo "----------------------------------------" >> "$LOG_FILE"
# il log locale non cresce all'infinito
tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$WORK/logtrim" 2>/dev/null && cat "$WORK/logtrim" > "$LOG_FILE"

# --- INVIO LOG COMPLETO A STEFANO (sotto il limite della cella) ---
DETAIL="$WORK/detail"
det_size=$(wc -c < "$RUN_LOG" | tr -d ' ')
if [ "$det_size" -gt "$DETAIL_MAX" ]; then
  {
    head -c $((DETAIL_MAX / 3)) "$RUN_LOG"
    printf '\n\n... [log tagliato: %s byte in tutto, qui sotto la parte finale; completo sul Mac in youtube_sync.log] ...\n\n' "$det_size"
    tail -c $((DETAIL_MAX * 2 / 3 - 300)) "$RUN_LOG"
  } > "$DETAIL"
else
  cp "$RUN_LOG" "$DETAIL"
fi
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  curl -fsS -X POST "$ENDPOINT_URL" \
    --data-urlencode "summary=$SUMMARY" \
    --data-urlencode "detail@$DETAIL" >/dev/null 2>&1 \
    && log "stato inviato a Stefano" || log "AVVISO invio stato non riuscito"
fi

# ---------- SCHERMATA FINALE PER MAX ----------
draw_header
if [ "$MISSING_OTHER" -gt 0 ] || [ "$UNREACHABLE" -gt 0 ]; then
  printf '      ✅  Fatto   (con qualche avviso, vedi sotto)\n\n'
else
  printf '      ✅  Tutto sincronizzato!\n\n'
fi
printf '      %-30s %7s %5s\n' "Playlist" "YouTube" "Mac"
printf '%s\n' "$UI_LINE"
awk -F'\t' '{
  name=$2; if (length(name)>28) name=substr(name,1,27) "~";
  mark=($1=="OK")?"✓":(($1=="DEAD")?"✓*":(($1=="UNREACH")?"—":"⚠"));
  printf "      %-30s %7s %5s  %s\n", name, $3, $4, mark
}' "$RPT"
printf '%s\n\n' "$UI_LINE"
printf '      Brani nuovi scaricati:            %d\n' "$TOTAL_NEW"
[ "$TOTAL_CLONED" -gt 0 ] && printf '      Brani aggiunti da altre playlist: %d\n' "$TOTAL_CLONED"
if grep -q '^DEAD' "$RPT"; then
  printf '\n      ✓* = completa: mancano solo brani spariti da YouTube\n'
fi
if [ "$MISSING_DEAD" -gt 0 ]; then
  printf '\n      *  Brani che non esistono piu'\'' su YouTube:  %d\n' "$MISSING_DEAD"
  printf '         Normale, non si possono recuperare.\n'
fi
if [ "$MISSING_OTHER" -gt 0 ]; then
  printf '\n      ⚠  Brani non scaricati per ora:  %d\n' "$MISSING_OTHER"
  printf '         Riprovo da solo al prossimo avvio. Se restano\n'
  printf '         per qualche giorno, avvisa Stefano.\n'
fi
if [ "$UNREACHABLE" -gt 0 ]; then
  printf '\n      —  Playlist non trovate su YouTube:  %d\n' "$UNREACHABLE"
  printf '         (cancellate o private). Avvisa Stefano.\n'
fi
printf '\n\n      Puoi chiudere questa finestra.  👋\n\n'

if [ "$VALID_PLAYLISTS" -eq 0 ]; then
  osascript -e 'display notification "Nessuna musica aggiornata. Se non e giusto, chiama Stefano." with title "YouTubeSync"' 2>/dev/null
else
  msg="Fatto! Musica aggiornata."
  [ "$TOTAL_NEW" -gt 0 ] && msg="$msg $TOTAL_NEW brani nuovi."
  osascript -e "display notification \"$msg\" with title \"YouTubeSync\" sound name \"Glass\"" 2>/dev/null
fi

rm -rf "$WORK"
