#!/usr/bin/env bash
scriptVersion="1.0.3"

if [ -z "$arrUrl" ] || [ -z "$arrApiKey" ]; then
  arrUrlBase="$(cat /config/config.xml | xq | jq -r .Config.UrlBase)"
  if [ "$arrUrlBase" == "null" ]; then
    arrUrlBase=""
  else
    arrUrlBase="/$(echo "$arrUrlBase" | sed "s/\///g")"
  fi
  arrApiKey="$(cat /config/config.xml | xq | jq -r .Config.ApiKey)"
  arrPort="$(cat /config/config.xml | xq | jq -r .Config.Port)"
  arrUrl="http://localhost:${arrPort}${arrUrlBase}"
fi

log () {
  m_time=`date "+%F %T"`
  echo $m_time" :: Youtube Series Downloader :: $scriptVersion :: "$1
}

# auto-clean up log file to reduce space usage
if [ -f "/config/logs/Youtube-Series-Downloader.txt" ]; then
	find /config/logs -type f -name "Youtube-Series-Downloader.txt" -size +1024k -delete
fi

if [ ! -f "/config/logs/Youtube-Series-Downloader.txt" ]; then
    touch "/config/logs/Youtube-Series-Downloader.txt"
    chmod 666 "/config/logs/Youtube-Series-Downloader.txt"
fi
exec &> >(tee -a "/config/logs/Youtube-Series-Downloader.txt")

if [ "$arrEventType" == "Test" ]; then
	log "Tested Successfully"
	exit 0	
fi

CookiesCheck () {
    # Check for cookies file
    if find /config -type f -name "cookies.txt" | read; then
        cookiesFile="$(find /config -type f -iname "cookies.txt" | head -n1)"
        log "Cookies File Found!"
    else
        log "Cookies File Not Found!"
        cookiesFile=""
    fi
}

NotifySonarrForImport () {
    sonarrProcessIt=$(curl -s "$arrUrl/api/v3/command" --header "X-Api-Key:"${arrApiKey} -H "Content-Type: application/json" --data "{\"name\":\"DownloadedEpisodesScan\", \"path\":\"$1\"}")
}

SonarrTaskStatusCheck () {
	alerted=no
	until false
	do
		taskCount=$(curl -s "$arrUrl/api/v3/command?apikey=${arrApiKey}" | jq -r '.[] | select(.status=="started") | .name' | grep -v "RescanFolders" | wc -l)
		if [ "$taskCount" -ge "1" ]; then
			if [ "$alerted" == "no" ]; then
				alerted=yes
				log "STATUS :: SONARR BUSY :: Pausing/waiting for all active Sonarr tasks to end..."
			fi
			sleep 2
		else
			break
		fi
	done
}


CookiesCheck

sonarrSeriesList=$(curl -s --header "X-Api-Key:"${arrApiKey} --request GET  "$arrUrl/api/v3/series")
sonarrSeriesIds=$(echo "${sonarrSeriesList}" | jq -r '.[] | select(.network=="YouTube") |.id')
sonarrSeriesTotal=$(echo "${sonarrSeriesIds}" | wc -l)

loopCount=0
for id in $(echo $sonarrSeriesIds); do
    loopCount=$(( $loopCount + 1 ))

    seriesId=$id
    seriesData=$(curl -s "$arrUrl/api/v3/series/$seriesId?apikey=$arrApiKey")
    seriesTitle=$(echo "$seriesData" | jq -r .title)
    seriesTitleDots=$(echo "$seriesTitle" | sed s/\ /./g)
    seriesTvdbTitleSlug=$(echo "$seriesData" | jq -r .titleSlug)
    seriesNetwork=$(echo "$seriesData" | jq -r .network)
    seriesEpisodeData=$(curl -s "$arrUrl/api/v3/episode?seriesId=$seriesId&apikey=$arrApiKey")
    seriesEpisodeTvdbIds=$(echo $seriesEpisodeData | jq -r ".[] | select(.monitored==true) | select(.hasFile==false) | .tvdbId")
    seriesEpisodeTvdbIdsCount=$(echo "$seriesEpisodeTvdbIds" | wc -l)

    currentLoopIteration=0
    for episodeId in $(echo $seriesEpisodeTvdbIds); do
        currentLoopIteration=$(( $currentLoopIteration + 1 ))
        seriesEpisdodeData=$(echo $seriesEpisodeData | jq -r ".[] | select(.tvdbId==$episodeId)")
        episodeSeasonNumber=$(echo $seriesEpisdodeData | jq -r .seasonNumber)
        episodeNumber=$(echo $seriesEpisdodeData | jq -r .episodeNumber)
        tvdbPageData=$(curl -s "https://thetvdb.com/series/$seriesTvdbTitleSlug/episodes/$episodeId")
        downloadUrl=$(echo "$tvdbPageData" | grep -i youtube.com  | grep -i watch | grep -Eo "(http|https)://[a-zA-Z0-9./?=_%:-]*")
        
        if [ -z $downloadUrl ]; then
            network="$(echo "$tvdbPageData" | grep -i "/companies/youtube")"
            if [ ! -z "$network" ]; then 
                downloadUrl=$(echo "$tvdbPageData" | grep -iws "production code" -A 2 | sed 's/\ //g' | tail -n1)
                if [ ! -z $downloadUrl ]; then
                    downloadUrl="https://www.youtube.com/watch?v=$downloadUrl"
                fi
            fi
        fi

        if [ -z $downloadUrl ]; then
            log "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: ERROR :: No Download URL found, skipping"
            continue
        fi
        downloadLocation="/config/temp"
        if [ ! -d $downloadLocation ]; then
            mkdir $downloadLocation
        else 
            rm -rf $downloadLocation
            mkdir $downloadLocation
        fi
        fileName="$seriesTitleDots.S${episodeSeasonNumber}E${episodeNumber}.WEB-DL-SonarrExtended"
        log "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: Downloading via yt-dlp ($videoFormat)..."
        if [ ! -z "$cookiesFile" ]; then
            yt-dlp -f "$videoFormat" --no-video-multistreams --cookies "$cookiesFile" -o "$downloadLocation/$fileName" --write-sub --sub-lang $videoLanguages --embed-subs --merge-output-format mkv --no-mtime --geo-bypass "$downloadUrl"
        else
            yt-dlp -f "$videoFormat" --no-video-multistreams -o "$downloadLocation/$fileName" --write-sub --sub-lang $videoLanguages --embed-subs --merge-output-format mkv --no-mtime --geo-bypass "$downloadUrl"
        fi

        if python3 /usr/local/sma/manual.py --config "/sma.ini" -i "$downloadLocation/$fileName.mkv" -nt; then
            sleep 0.01
            log "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: Processed with SMA..."
            rm  /usr/local/sma/config/*log*
        else
            og "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: ERROR :: SMA Processing Error"
            rm "$downloadLocation/$fileName.mkv"
            log "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: INFO: deleted: $downloadLocation/$fileName.mkv"
        fi
        if [ -f "$downloadLocation/$fileName.mkv" ]; then
            chmod -R 777 $downloadLocation
            NotifySonarrForImport "$downloadLocation/$fileName.mkv"
            log "$loopCount/$sonarrSeriesTotal :: $currentLoopIteration/$seriesEpisodeTvdbIdsCount :: $seriesTitle :: S${episodeSeasonNumber}E${episodeNumber} :: Notified Sonarr to import \"$fileName.mkv\"" 
        fi
        SonarrTaskStatusCheck
    done
done
exit
