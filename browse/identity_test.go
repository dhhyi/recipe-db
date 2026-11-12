package main

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIdentityLookup(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		body       string
		enabled    bool
		disconnect bool
		want       string
		failure    bool
	}{
		{"anonymous", 200, `{"data":{"myCapabilities":{"role":"anonymous"}}}`, true, false, `<header-component auth-role="anonymous" auth-enabled></header-component>`, false},
		{"owner", 200, `{"data":{"myCapabilities":{"role":"owner"}}}`, true, false, `<header-component auth-role="owner" auth-enabled></header-component>`, false},
		{"disabled", 200, `{"data":{"myCapabilities":{"role":"anonymous"}}}`, false, false, `<header-component auth-role="anonymous"></header-component>`, false},
		{"upstream 401", 401, `rejected`, true, false, `<header-component auth-role="anonymous" auth-enabled></header-component>`, true},
		{"upstream 401 disabled", 401, `rejected`, false, false, `<header-component></header-component>`, true},
		{"invalid credentials", 200, `{"errors":[{"message":"Invalid credentials","extensions":{"code":"invalid-credentials","status":401}}]}`, true, false, `<header-component auth-role="anonymous" auth-enabled></header-component>`, true},
		{"authentication required", 200, `{"errors":[{"message":"Authentication required","extensions":{"code":"authentication-required","status":401}}]}`, true, false, `<header-component auth-role="anonymous" auth-enabled></header-component>`, true},
		{"service error", 200, `{"errors":[{"message":"Invalid credentials service unavailable","extensions":{"code":"service-unavailable","status":503}}]}`, true, false, `<header-component></header-component>`, true},
		{"forbidden", 403, `forbidden`, true, false, `<header-component></header-component>`, true},
		{"server error", 500, `unavailable`, true, false, `<header-component></header-component>`, true},
		{"network error", 0, ``, true, true, `<header-component></header-component>`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			enabled := ""
			if tt.enabled {
				enabled = "configured"
			}
			t.Setenv("GOOGLE_OAUTH_CLIENT_ID", enabled)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.Header.Get("Cookie"); got != "_oauth2_proxy=session" {
					t.Errorf("unexpected forwarded cookies: %q", got)
				}
				w.Header().Add("Set-Cookie", "_oauth2_proxy=; Max-Age=0")
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer upstream.Close()
			if tt.disconnect {
				upstream.Close()
			}
			var logs bytes.Buffer
			previous := log.Writer()
			log.SetOutput(&logs)
			defer log.SetOutput(previous)

			handler := newHandlerWithEndpoint(nil, nil, upstream.URL)
			request := httptest.NewRequest("GET", "/identity", nil)
			request.Header.Set("Cookie", "_oauth2_proxy=session; unrelated=ignored")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" ||
				strings.TrimSpace(response.Body.String()) != tt.want {
				t.Fatalf("unexpected identity response: %d %v %s", response.Code, response.Header(), response.Body.String())
			}
			if !tt.disconnect && len(response.Header().Values("Set-Cookie")) != 1 {
				t.Fatalf("upstream cookie not relayed: %v", response.Header())
			}
			if tt.failure && !strings.Contains(logs.String(), "failed to fetch browse identity") {
				t.Fatalf("identity failure not logged: %s", logs.String())
			}
			if tt.status == 401 && !strings.Contains(logs.String(), "upstream status 401") {
				t.Fatalf("upstream 401 not logged: %s", logs.String())
			}
		})
	}
}
