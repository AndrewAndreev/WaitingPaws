package xiaomi

// Waiting Paws addition, copied into go2rtc's internal/xiaomi by GoMobile/build.sh.
//
// Upstream go2rtc can sign in to a Mi Home account (POST /api/xiaomi) but never forgets one: the token
// stays in go2rtc.yaml. The app's «Выйти из аккаунта Xiaomi» needs the opposite.

import (
	"net/http"

	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/app"
)

// InitLogout registers POST /api/xiaomi/logout (form field `id` – the account's user id). The token is
// dropped from memory and from the config file; streams of that account stop working on reconnect.
func InitLogout() {
	api.HandleFunc("api/xiaomi/logout", apiLogout)
}

func apiLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	id := r.FormValue("id")
	if id == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}

	cloudsMu.Lock()
	delete(tokens, id)
	delete(clouds, id)
	cloudsMu.Unlock()

	// A nil value deletes the key; an account that was never saved has nothing to delete.
	_ = app.PatchConfig([]string{"xiaomi", id}, nil)

	w.WriteHeader(http.StatusNoContent)
}
