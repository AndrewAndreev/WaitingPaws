package xiaomi

// Waiting Paws addition, copied into go2rtc's internal/xiaomi by GoMobile/build.sh.
//
// Camera settings (night mode, image flip, status light…) live in the camera itself and are
// changed through the Mi Cloud MIoT API, the way Mi Home does it. go2rtc already keeps a signed-in
// cloud client per account for streaming, so the app reuses it instead of logging in on its own.

import (
	"encoding/json"
	"net/http"
	"net/url"

	"github.com/AlexxIT/go2rtc/internal/api"
)

// InitMiot registers POST /api/xiaomi/miot. Call it after Init.
//
// Form fields:
//
//	src    – the camera's xiaomi:// source; account, region and device id are taken from it
//	method – "get" or "set"
//	params – JSON array of {"siid":2,"piid":3} for get, {"siid":2,"piid":3,"value":1} for set
//
// Responds with Mi Cloud's result array, one item per property:
// [{"did":"…","siid":2,"piid":3,"code":0,"value":1}]. A non-zero code means that property failed
// (e.g. -704042011: the camera is offline).
func InitMiot() {
	api.HandleFunc("api/xiaomi/miot", apiMiot)
}

func apiMiot(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	src, err := url.Parse(r.Form.Get("src"))
	if err != nil || src.Scheme != "xiaomi" || src.User == nil {
		http.Error(w, "src must be a xiaomi:// source with an account", http.StatusBadRequest)
		return
	}
	did := src.Query().Get("did")
	if did == "" {
		http.Error(w, "src has no did", http.StatusBadRequest)
		return
	}

	var path string
	switch r.Form.Get("method") {
	case "get":
		path = "/miotspec/prop/get"
	case "set":
		path = "/miotspec/prop/set"
	default:
		http.Error(w, "method must be get or set", http.StatusBadRequest)
		return
	}

	var items []map[string]any
	if err = json.Unmarshal([]byte(r.Form.Get("params")), &items); err != nil || len(items) == 0 {
		http.Error(w, "params must be a non-empty JSON array", http.StatusBadRequest)
		return
	}
	for _, item := range items {
		item["did"] = did // only the camera of this source, whatever the caller sent
	}
	params, err := json.Marshal(map[string]any{"params": items})
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	res, err := cloudUserRequest(src.User, path, string(params))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", api.MimeJSON)
	_, _ = w.Write(res)
}
