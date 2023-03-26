#!/usr/bin/env bash
scriptVersion="1.0.1"

if [ -z "$arrUrl" ] || [ -z "$arrApiKey" ]; then
  arrUrlBase="$(cat /config/config.xml | xq | jq -r .Config.UrlBase)"
  if [ "$arrUrlBase" == "null" ]; then
    arrUrlBase=""
  else
    arrUrlBase="/$(echo "$arrUrlBase" | sed "s/\///g")"
  fi
  arrApiKey="$(cat /config/config.xml | xq | jq -r .Config.ApiKey)"
  arrPort="$(cat /config/config.xml | xq | jq -r .Config.Port)"
  arrUrl="http://127.0.0.1:${arrPort}${arrUrlBase}"
fi

log () {
  m_time=`date "+%F %T"`
  echo $m_time" :: InvalidSeriesAutoCleaner :: $scriptVersion :: "$1
}

# auto-clean up log file to reduce space usage
if [ -f "/config/logs/SeriesAutoDelete.txt" ]; then
	find /config/logs -type f -name "InvalidSeriesAutoCleaner.txt" -size +1024k -delete
fi

if [ ! -f "/config/logs/InvalidSeriesAutoCleaner.txt" ]; then
    touch "/config/logs/InvalidSeriesAutoCleaner.txt"
    chmod 666 "/config/logs/InvalidSeriesAutoCleaner.txt"
fi
exec &> >(tee -a "/config/logs/InvalidSeriesAutoCleaner.txt")

# Get invalid series tvdb id's
seriesTvdbId="$(curl -s --header "X-Api-Key:"$arrApiKey --request GET  "$arrUrl/api/v3/health" | jq -r '.[] | select(.source=="RemovedSeriesCheck") | select(.type=="error")' | grep "message" | grep -o '[[:digit:]]*')"

if [ -z "$seriesTvdbId" ]; then
  log "No invalid series (tvdbid) reported by Sonarr health check, skipping..."
  exit
fi

# Process each invalid series tvdb id
for tvdbId in $(echo $seriesTvdbId); do
    seriesData="$(curl -s --header "X-Api-Key:"$arrApiKey --request GET  "$arrUrl/api/v3/series" | jq -r ".[] | select(.tvdbId==$tvdbId)")"
    seriesId="$(echo "$seriesData" | jq -r .id)"
    seriesTitle="$(echo "$seriesData" | jq -r .title)"
    seriesPath="$(echo "$seriesData" | jq -r .path)"
    
    log "$seriesId :: $seriesTitle :: $seriesPath :: Removing and deleting invalid Series (tvdbId: $tvdbId) based on Sonarr Health Check error..."

    # Send command to Sonarr to delete series and files
    arrCommand=$(curl -s --header "X-Api-Key:"$arrApiKey --request DELETE "$arrUrl/api/v3/series/$seriesId?deleteFiles=true")
    

    # trigger a plex scan to rmeove the deleted series
    folderToScan="$(dirname "$seriesPath")"
    log "Using PlexNotify.bash to update Plex.... ($folderToScan)"
    bash /config/extended/scripts/PlexNotify.bash "$folderToScan" "true"
done


exit
