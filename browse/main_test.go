package main

import (
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Khan/genqlient/graphql"
)

func TestDetailHTTPAndLiveWidgets(t *testing.T) {
	const imageURL = "https://cdn.example.test/opaque/full-token.png?signature=abc&version=two"
	const thumbURL = "/assets/unrelated/thumb-token.png?rev=opaque&size=small"
	var recipeCalls atomic.Int32
	var version atomic.Int32
	var deleted, ratingsOffline, imagesOffline, editOnline atomic.Bool
	var inspirationsOnline, hasInspirations atomic.Bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct{ OperationName string }
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var data any
		switch request.OperationName {
		case "BrowseServices":
			data = map[string]any{"searchOnline": false, "recipeEditOnline": false, "ratingsOnline": false}
		case "Overview":
			data = map[string]any{
				"recipes": []any{map[string]any{
					"id": "42", "name": "Original",
					"image": map[string]any{"url": imageURL, "thumbUrl": thumbURL},
				}},
				"ratingsOnline": false, "recipeEditOnline": false,
			}
		case "RecipeById":
			recipeCalls.Add(1)
			var recipe any
			if !deleted.Load() {
				var rating any = map[string]any{"recipeId": "42", "average": 4, "count": 2}
				if ratingsOffline.Load() {
					rating = nil
				}
				name := "Original"
				if version.Load() > 0 {
					name = "Updated"
				}
				recipe = map[string]any{
					"id": "42", "name": name, "method": "Cook", "ingredients": []any{},
					"createdAt": "2020-01-01T00:00:00.123456Z", "updatedAt": "2020-01-01T00:00:00.123456Z",
					"rating": rating, "image": map[string]any{"url": imageURL, "thumbUrl": thumbURL},
				}
			}
			if imagesOffline.Load() {
				if err := json.NewEncoder(w).Encode(map[string]any{
					"errors": []any{map[string]any{"message": "images unavailable"}},
				}); err != nil {
					t.Error(err)
				}
				return
			}
			data = map[string]any{"recipe": recipe}
		case "RecipeControls":
			data = map[string]any{"recipeEditOnline": editOnline.Load(), "imagesOnline": false, "imageEditOnline": false}
		case "RecipeInspirations":
			var recipe any
			if !deleted.Load() {
				inspirations := []any{}
				if hasInspirations.Load() {
					inspirations = append(inspirations, map[string]any{"url": "https://example.com/recipe"})
				}
				recipe = map[string]any{"id": "42", "inspirations": inspirations}
			}
			data = map[string]any{"recipe": recipe, "inspirationsOnline": inspirationsOnline.Load()}
		case "RateRecipe":
			data = map[string]any{"rate": map[string]any{"recipeId": "42", "average": 5, "count": 3}}
			version.Add(1)
		default:
			t.Errorf("unexpected operation: %s", request.OperationName)
		}
		if err := json.NewEncoder(w).Encode(map[string]any{"data": data}); err != nil {
			t.Error(err)
		}
	}))
	defer upstream.Close()
	client := graphql.NewClient(upstream.URL, upstream.Client())
	c := testCache(t, func(ctx context.Context, id string) ([]byte, error) { return renderRecipe(ctx, client, id) })
	handler := newHandler(client, c)
	request := func(method, path, etag string) *httptest.ResponseRecorder {
		t.Helper()
		form := url.Values{"rating": {"5"}}.Encode()
		r := httptest.NewRequest(method, path, strings.NewReader(form))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("If-None-Match", etag)
		if strings.Contains(path, "variant=2") {
			r.Header.Set("HX-Request", "true")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	overview := request("GET", "/", "")
	if overview.Code != 200 || !strings.Contains(html.UnescapeString(overview.Body.String()), `src="`+thumbURL+`"`) {
		t.Fatalf("overview did not preserve opaque backend thumbnail URL: %d %s", overview.Code, overview.Body.String())
	}
	first := request("GET", "/recipe/42?variant=1", "")
	if first.Code != 200 || !strings.Contains(first.Body.String(), "Original") {
		t.Fatalf("detail failed: %d %s", first.Code, first.Body.String())
	}
	pageHTML := first.Body.String()
	if !strings.Contains(html.UnescapeString(pageHTML), `src="`+imageURL+`"`) {
		t.Fatal("detail did not preserve opaque backend image URL")
	}
	if !strings.Contains(pageHTML, "Zuletzt aktualisiert: vor langer Zeit") {
		t.Fatal("recipe update time must be displayed in German")
	}
	if strings.Contains(pageHTML, "Inspirationen") {
		t.Fatal("shared page must not contain the lazy inspirations heading")
	}
	if !strings.Contains(pageHTML, "/recipe/42/controls") || !strings.Contains(pageHTML, "/recipe/42/inspirations") ||
		strings.Contains(pageHTML, "Rezept bearbeiten") || !strings.Contains(html.UnescapeString(pageHTML), imageURL) ||
		!strings.Contains(pageHTML, "aggregateRating") || strings.Contains(pageHTML, `value="test"`) {
		t.Fatal("shared page does not separate live content or contains user data")
	}
	etag := first.Header().Get("ETag")
	if etag == "" || first.Header().Get("Cache-Control") != "private, no-cache" {
		t.Fatal("missing browser revalidation headers")
	}
	if second := request("GET", "/recipe/42?variant=2", "W/"+etag); second.Code != 304 || second.Body.Len() != 0 {
		t.Fatal("valid cached page did not revalidate")
	}
	if head := request("HEAD", "/recipe/42", ""); head.Code != 200 || head.Body.Len() != 0 {
		t.Fatal("HEAD response must not include HTML")
	}
	if recipeCalls.Load() != 1 {
		t.Fatal("cache hit queried GraphQL")
	}
	for _, online := range []bool{false, true, false} {
		editOnline.Store(online)
		widget := request("GET", "/recipe/42/controls", "")
		if widget.Code != 200 || strings.Contains(widget.Body.String(), "Rezept bearbeiten") != online ||
			widget.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("edit controls not live")
		}
	}
	for _, tc := range []struct {
		name                             string
		online, hasLinks, missing, shown bool
	}{
		{name: "offline without links"},
		{name: "online without links", online: true},
		{name: "online with links", online: true, hasLinks: true, shown: true},
		{name: "offline with links", hasLinks: true},
		{name: "missing recipe", online: true, hasLinks: true, missing: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			inspirationsOnline.Store(tc.online)
			hasInspirations.Store(tc.hasLinks)
			deleted.Store(tc.missing)
			widget := request("GET", "/recipe/42/inspirations", "")
			if widget.Code != 200 || widget.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("inspirations must stay uncached")
			}
			body := widget.Body.String()
			if tc.shown {
				if !strings.Contains(body, "<section>") || !strings.Contains(body, "<h2>Inspirationen</h2>") ||
					!strings.Contains(body, `href="https://example.com/recipe"`) {
					t.Fatalf("missing inspirations section or link: %s", body)
				}
			} else if strings.TrimSpace(body) != "" {
				t.Fatalf("hidden inspirations must return no section: %s", body)
			}
		})
	}
	deleted.Store(false)
	if health := request("GET", "/health", ""); health.Code != 200 || health.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("health check must stay uncached")
	}
	if rating := request("POST", "/recipe/42/rate", ""); rating.Code != 200 || rating.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("rating submission failed")
	}
	updated := request("GET", "/recipe/42", etag)
	if updated.Code != 200 || !strings.Contains(updated.Body.String(), "Updated") || updated.Header().Get("ETag") == etag ||
		recipeCalls.Load() != 2 {
		t.Fatal("local mutation did not invalidate detail variants")
	}
	for _, path := range []string{"/recipe/42?variant=1", "/recipe/42?variant=2"} {
		page := request("GET", path, etag)
		if page.Code != 200 || !strings.Contains(page.Body.String(), "Updated") || recipeCalls.Load() != 2 {
			t.Fatal("query/HTMX variant retained invalidated HTML")
		}
	}
	for _, offline := range []*atomic.Bool{&ratingsOffline, &imagesOffline} {
		if err := c.invalidate("42"); err != nil {
			t.Fatal(err)
		}
		offline.Store(true)
		if page := request("GET", "/recipe/42", etag); page.Code != 500 {
			t.Fatal("optional-service outage cached partial HTML or served stale page")
		}
		offline.Store(false)
		if page := request("GET", "/recipe/42", ""); page.Code != 200 {
			t.Fatal("recovery failed")
		}
	}
	deleted.Store(true)
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if page := request("GET", "/recipe/42", etag); page.Code != 404 {
			t.Fatal("confirmed deletion must return 404")
		}
	}
}
