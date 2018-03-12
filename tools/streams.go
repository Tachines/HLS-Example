package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"strings"

	uuid "github.com/streamco/gouuid"
	mpx "github.com/streamco/streamco-mpx-go"
)

var shouldDump = os.Getenv("DUMP_TRAFFIC") != ""

func fetch(url string) (io.ReadCloser, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	if shouldDump {
		dump, _ := httputil.DumpRequest(req, true)
		println(string(dump))
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	if shouldDump {
		dump, _ := httputil.DumpResponse(res, true)
		println(string(dump))
	}
	return res.Body, nil
}

func getJSON(url string, out interface{}) error {
	res, err := fetch(url)
	if err != nil {
		return err
	}
	defer res.Close()
	return json.NewDecoder(res).Decode(&out)
}

func getGUID(show string) (string, error) {
	var apiResponse struct {
		Entries []struct {
			GUID string
		}
	}
	if err := getJSON("https://v12.search.api.stan.com.au/search?q="+url.QueryEscape(show), &apiResponse); err != nil {
		return "", err
	}
	if len(apiResponse.Entries) == 0 {
		return "", fmt.Errorf("program not found")
	}
	return apiResponse.Entries[0].GUID, nil
}

type episode struct {
	id        string
	pid       string
	videoURL  string
	contentID string
}

func getEpisode(guid string, seasonNumber, episodeNumber int) (episode, error) {
	var seriesRes struct {
		GUID    string
		Seasons []struct {
			URL          string
			SeasonNumber int
		}
	}
	if err := getJSON("https://v12.cat.api.stan.com.au/programs/"+guid+".json", &seriesRes); err != nil {
		return episode{}, err
	}
	seasonURL := ""
	for _, s := range seriesRes.Seasons {
		if s.SeasonNumber == seasonNumber {
			seasonURL = s.URL
			break
		}
	}
	if seasonURL == "" {
		return episode{}, fmt.Errorf("no season %d, only these:%v", seasonNumber, seriesRes.Seasons)
	}
	var seasonRes struct {
		Entries []struct {
			URL           string
			EpisodeNumber int `json:"tvSeasonEpisodeNumber"`
		}
	}
	if err := getJSON(seasonURL, &seasonRes); err != nil {
		return episode{}, err
	}
	episodeURL := ""
	for _, entry := range seasonRes.Entries {
		if entry.EpisodeNumber == episodeNumber {
			episodeURL = entry.URL
		}
	}
	if episodeURL == "" {
		return episode{}, fmt.Errorf("no season %d episode %d", seasonNumber, episodeNumber)
	}
	var episodeRes struct {
		GUID    string
		Streams struct {
			HD struct {
				HLS struct {
					Auto struct {
						Pid string
					}
				}
			}
		}
	}
	if err := getJSON(episodeURL, &episodeRes); err != nil {
		return episode{}, err
	}
	return episode{id: episodeRes.GUID, pid: episodeRes.Streams.HD.HLS.Auto.Pid}, nil
}

// Fetches the m3u8, and translates the skd of the form:
// skd://brightcove/license/c8b3c68a17fb7946fa38f43db2251186/394234A_hd_6
// to the hex string:
// `2e17488975fc5d8f4b29ffc21a407a38`
// this is the UUIDv5 form of `394234A_hd_6` in the URL namespace
func overrideSKD(videoURL, variant string) (string, error) {
	m3u8URL, err := url.Parse(videoURL)
	if err != nil {
		return "", err
	}
	res, err := fetch(videoURL)
	if err != nil {
		return "", err
	}
	defer res.Close()
	var renditionm3u8 string
	scanner := bufio.NewScanner(res)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasSuffix(line, ".m3u8") {
			renditionPath, err := url.Parse(line)
			if err != nil {
				return "", fmt.Errorf("couldn't parse %s as URL: %s", line, err)
			}
			renditionm3u8 = m3u8URL.ResolveReference(renditionPath).String()
			break
		}
	}
	if renditionm3u8 == "" {
		return "", fmt.Errorf("couldn't find any renditions in %s", videoURL)
	}
	res, err = fetch(renditionm3u8)
	if err != nil {
		return "", err
	}
	defer res.Close()
	scanner = bufio.NewScanner(res)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=") {
			var (
				uri               string
				keyFormat         string
				keyFormatVersions string
			)
			if _, err := fmt.Sscanf(line, `#EXT-X-KEY:METHOD=SAMPLE-AES,URI=%q,KEYFORMAT=%q,KEYFORMATVERSIONS=%q`, &uri, &keyFormat, &keyFormatVersions); err != nil {
				return "", fmt.Errorf("in %s, couldn't parse line %s", renditionm3u8, line)
			}
			// example brightcove uri
			// skd://brightcove/license/c8b3c68a17fb7946fa38f43db2251186/394234A_hd_6
			// we want the uuid v5 of 394234A_hd_6
			// so we call path.Base and plug it into a UUIDv5
			base := path.Base(uri)
			v5uuid, err := uuid.NewV5(uuid.NamespaceURL, []byte(base))
			if err != nil {
				return "", fmt.Errorf("couldn't create a UUID from %s: %s", base, err)
			}
			assetId := strings.Replace(v5uuid.String(), "-", "", -1)
			return fmt.Sprintf(`drmtoday?variantId=%s&assetId=%s`, variant, assetId), nil
		}
	}
	return "", fmt.Errorf("no EXT-X-KEY header found in %s", renditionm3u8)
}

func populateVideoDeets(client mpx.Client, ep *episode) error {
	var apiResponse struct {
		mpx.Response
		Entries []struct {
			Content []struct {
				StreamingURL string `json:"streamingUrl"`
				Quality      string `json:"sco$videoquality"`
				Releases     []struct {
					Pid string
				}
			}
		}
	}
	if err := client.Get(mpx.Media, url.Values{
		"byAvailabilityState": {"available"},
		"byReleasePid":        {ep.pid},
		"count":               {"false"},
		"fields":              {"content,content.releases,content.sco$videoquality,content.streamingUrl"},
		"schema":              {"1.8"},
	}, &apiResponse); err != nil {
		return err
	}
	for _, entry := range apiResponse.Entries {
		for _, content := range entry.Content {
			for _, release := range content.Releases {
				if release.Pid == ep.pid {
					ep.videoURL = content.StreamingURL
					skd, err := overrideSKD(content.StreamingURL, content.Quality)
					if err != nil {
						return fmt.Errorf("couldn't get SKD from %s: %s", content.StreamingURL, err)
					}
					ep.contentID = skd
					return nil
				}
			}
		}
	}
	return fmt.Errorf("no media found for pid %s", ep.pid)
}

func encode(out io.Writer, title string, ep episode) error {
	plist := `
    <dict>
        <key>AssetNameKey</key>
        <string>%s</string>
        <key>AAPLStreamPlaylistURL</key>
        <string>%s</string>
        <key>ContentID</key>
        <string>%s</string>
        <key>ProgramID</key>
        <string>%s</string>
    </dict>`
	if _, err := fmt.Fprintf(out, plist+"\n", title, ep.videoURL, strings.Replace(ep.contentID, "&", "&amp;", -1), ep.id); err != nil {
		return err
	}
	return nil
}

func main() {
	if len(os.Args) <= 2 {
		log.Fatal("usage: streams younger s1e1")
	}
	show := strings.Join(os.Args[1:len(os.Args)-1], " ")
	guid, err := getGUID(show)
	if err != nil {
		log.Fatalf("couldn't find show: %s", err)
	}
	episodeShorthand := os.Args[len(os.Args)-1] // e.g. s1e1
	var (
		season  int
		episode int
	)
	if _, err := fmt.Sscanf(episodeShorthand, "s%de%d", &season, &episode); err != nil {
		log.Fatalf("couldn't parse %s as sNeN: %s", episodeShorthand, err)
	}
	ep, err := getEpisode(guid, season, episode)
	if err != nil {
		log.Fatalf("couldn't get episode: %s", err)
	}
	client := mpx.NewDefaultClient()
	if err := populateVideoDeets(client, &ep); err != nil {
		log.Fatalf("couldn't get video deets for episode: %s", err)
	}
	if err := encode(os.Stdout, show+" "+episodeShorthand, ep); err != nil {
		log.Fatal(err)
	}
}
