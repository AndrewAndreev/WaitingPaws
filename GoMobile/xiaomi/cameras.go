package xiaomi

// Waiting Paws addition, copied into go2rtc's internal/xiaomi by GoMobile/build.sh.
//
// Upstream GET /api/xiaomi?id=…&region=… lists /v2/home/device_list_page without parameters: the account's
// own devices and the ones shared with it one by one, but not the devices of a home another account shares
// with it (Mi Home «Общий доступ» to a whole home) – such a member sees no cameras at all. Mi Home and
// Xiaomi's own Home Assistant integration (ha_xiaomi_home, miot/miot_cloud.py) first list the homes, own and
// shared, and then ask for their devices by id. This endpoint does the same.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/app"
)

// InitCameras registers GET /api/xiaomi/cameras?id=…&region=…: the cameras of every home the account sees,
// in the format of GET /api/xiaomi ({"sources":[…]}). No cameras is an empty list with 200, not 404, so the
// app can tell it from a go2rtc without this endpoint. Call it after Init.
func InitCameras() {
	api.HandleFunc("api/xiaomi/cameras", apiCameras)
}

func apiCameras(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	query := r.URL.Query()
	user, region := query.Get("id"), query.Get("region")
	if user == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}

	devices, err := listDevices(user, region)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	items := []*api.Source{}
	for _, device := range devices {
		if !strings.Contains(device.Model, ".camera.") && !strings.Contains(device.Model, ".cateye.") {
			continue
		}
		ip := device.IP
		if ip == "" {
			ip = device.LocalIP
		}
		// The same URL as upstream's, so streams added before keep matching by did.
		items = append(items, &api.Source{
			Name: device.Name,
			Info: fmt.Sprintf("ip: %s, mac: %s", ip, device.MAC),
			URL:  fmt.Sprintf("xiaomi://%s:%s@%s?did=%s&model=%s", user, region, ip, device.Did, device.Model),
		})
	}
	api.ResponseJSON(w, struct {
		Sources []*api.Source `json:"sources"`
	}{items})
}

type cloudDevice struct {
	Did     string `json:"did"`
	Name    string `json:"name"`
	Model   string `json:"model"`
	MAC     string `json:"mac"`
	IP      string `json:"localip"`
	LocalIP string `json:"local_ip"`
}

// listDevices returns the devices upstream lists, then the ones of homes it misses (shared homes).
func listDevices(user, region string) ([]*cloudDevice, error) {
	devices, err := deviceListPage(user, region, []string{})
	if err != nil {
		return nil, err
	}

	// A variable: zerolog's level methods need an addressable Logger.
	log := app.GetLogger("xiaomi")
	dids, err := homeDeviceIDs(user, region)
	if err != nil {
		// Without the homes the account's own devices are still worth showing.
		log.Warn().Err(err).Msg("[xiaomi] homes")
		return devices, nil
	}

	seen := make(map[string]bool, len(devices))
	for _, device := range devices {
		seen[device.Did] = true
	}
	var missing []string
	for _, did := range dids {
		if !seen[did] {
			seen[did] = true
			missing = append(missing, did)
		}
	}

	// Up to 150 ids per request, like Mi Home's integration.
	for len(missing) > 0 {
		n := min(len(missing), 150)
		more, err := deviceListPage(user, region, missing[:n])
		if err != nil {
			log.Warn().Err(err).Msg("[xiaomi] shared home devices")
			break
		}
		devices = append(devices, more...)
		missing = missing[n:]
	}
	return devices, nil
}

// deviceListPage asks /v2/home/device_list_page for the given device ids, or for the own and one-by-one
// shared devices when dids is empty, following its pages.
func deviceListPage(user, region string, dids []string) ([]*cloudDevice, error) {
	var devices []*cloudDevice
	startDid := ""
	for page := 0; page < 50; page++ {
		request := map[string]any{"limit": 200, "get_split_device": true, "get_third_device": true, "dids": dids}
		if startDid != "" {
			request["start_did"] = startDid
		}
		params, err := json.Marshal(request)
		if err != nil {
			return nil, err
		}
		res, err := cloudRequest(user, region, "/v2/home/device_list_page", string(params))
		if err != nil {
			return nil, err
		}
		var v struct {
			List         []*cloudDevice `json:"list"`
			HasMore      bool           `json:"has_more"`
			NextStartDid string         `json:"next_start_did"`
		}
		if err = json.Unmarshal(res, &v); err != nil {
			return nil, err
		}
		devices = append(devices, v.List...)
		if !v.HasMore || v.NextStartDid == "" || v.NextStartDid == startDid {
			break
		}
		startDid = v.NextStartDid
	}
	return devices, nil
}

type cloudHome struct {
	Dids  []string `json:"dids"` // devices without a room
	Rooms []struct {
		Dids []string `json:"dids"`
	} `json:"roomlist"`
}

func (h *cloudHome) appendDids(dids []string) []string {
	dids = append(dids, h.Dids...)
	for _, room := range h.Rooms {
		dids = append(dids, room.Dids...)
	}
	return dids
}

// homeDeviceIDs returns the device ids of every home the account sees: its own (homelist) and the ones
// other accounts share with it (share_home_list). A long list continues in /v2/homeroom/get_dev_room_page.
func homeDeviceIDs(user, region string) ([]string, error) {
	const params = `{"limit":150,"fetch_share":true,"fetch_share_dev":true,"plat_form":0,"app_ver":9}`
	res, err := cloudRequest(user, region, "/v2/homeroom/gethome", params)
	if err != nil {
		return nil, err
	}
	var v struct {
		Homes       []cloudHome `json:"homelist"`
		SharedHomes []cloudHome `json:"share_home_list"`
		HasMore     bool        `json:"has_more"`
		MaxID       any         `json:"max_id"`
	}
	if err = json.Unmarshal(res, &v); err != nil {
		return nil, err
	}

	var dids []string
	for _, home := range append(v.Homes, v.SharedHomes...) {
		dids = home.appendDids(dids)
	}

	hasMore, maxID := v.HasMore, v.MaxID
	for page := 0; hasMore && page < 50; page++ {
		startID, ok := maxID.(string)
		if !ok || startID == "" {
			break
		}
		params, err := json.Marshal(map[string]any{"start_id": startID, "limit": 150})
		if err != nil {
			return nil, err
		}
		res, err = cloudRequest(user, region, "/v2/homeroom/get_dev_room_page", string(params))
		if err != nil {
			return dids, nil // the first page is still worth it
		}
		var more struct {
			Homes   []cloudHome `json:"info"`
			HasMore bool        `json:"has_more"`
			MaxID   any         `json:"max_id"`
		}
		if err = json.Unmarshal(res, &more); err != nil {
			return dids, nil
		}
		for _, home := range more.Homes {
			dids = home.appendDids(dids)
		}
		if next, _ := more.MaxID.(string); next == startID {
			break
		}
		hasMore, maxID = more.HasMore, more.MaxID
	}
	return dids, nil
}
