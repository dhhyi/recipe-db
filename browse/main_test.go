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

func assertStyledErrorPage(t *testing.T, response *httptest.ResponseRecorder, status int, title, message string, head bool) {
	t.Helper()
	body := response.Body.String()
	if response.Code != status || response.Header().Get("Content-Type") != "text/html; charset=utf-8" ||
		response.Header().Get("Cache-Control") != "no-store" || response.Header().Get("ETag") != "" {
		t.Fatalf("incorrect styled error response headers: status=%d headers=%v", response.Code, response.Header())
	}
	if head {
		if body != "" {
			t.Fatalf("HEAD error response has a body: %s", body)
		}
		return
	}
	if strings.Count(body, "<header-component>") != 1 || strings.Count(body, "<main>") != 1 ||
		!strings.Contains(body, `<link rel="stylesheet" href="/design/styles.css">`) ||
		!strings.Contains(body, `<script src="/design/htmx.min.js"></script>`) ||
		!strings.Contains(body, "<title>"+title+"</title>") {
		t.Fatalf("incorrect styled error response body: %s", body)
	}
	if !strings.Contains(body, "<p>"+message+"</p>") || strings.Contains(body, "<form") ||
		strings.Contains(body, "data-recipe-id") || strings.Contains(body, "<script>alert") {
		t.Fatalf("error page is not message-only or escaped: %s", body)
	}
}

func TestUnknownBrowseURLAndEscapedError(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		t.Error("unknown URL queried GraphQL")
	}))
	defer upstream.Close()
	handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)

	for _, method := range []string{"GET", "HEAD"} {
		request := httptest.NewRequest(method, "/does-not-exist", nil)
		request.Header.Set("If-None-Match", "*")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		assertStyledErrorPage(t, response, http.StatusNotFound, "page not found | RezeptDB", "page not found", method == "HEAD")
	}
	if calls.Load() != 0 {
		t.Fatal("unknown URL queried backend")
	}
	for _, testCase := range []struct {
		path string
		code int
	}{
		{path: "/does-not-exist", code: http.StatusNotFound},
		{path: "/recipe/42", code: http.StatusMethodNotAllowed},
	} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("POST", testCase.path, nil))
		if response.Code != testCase.code {
			t.Fatalf("unexpected POST response for %s: %d", testCase.path, response.Code)
		}
	}

	response := httptest.NewRecorder()
	writeErrorPage(response, httptest.NewRequest("GET", "/", nil), http.StatusBadRequest, "error | RezeptDB", `<script>alert(1)</script>`)
	assertStyledErrorPage(t, response, http.StatusBadRequest, "error | RezeptDB", "&lt;script&gt;alert(1)&lt;/script&gt;", false)
}

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
		case "BrowseControls":
			data = map[string]any{
				"myCapabilities":   map[string]any{"role": "owner", "canManageRecipes": editOnline.Load(), "canManageImages": false},
				"recipeEditOnline": editOnline.Load(),
			}
		case "BrowseIdentity":
			data = map[string]any{"myCapabilities": map[string]any{"role": "owner"}}
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
			data = map[string]any{
				"myCapabilities":   map[string]any{"role": "owner", "canManageRecipes": editOnline.Load(), "canManageImages": false},
				"recipeEditOnline": editOnline.Load(), "imagesOnline": false, "imageEditOnline": false,
			}
		case "RatingCapabilities":
			data = map[string]any{"myCapabilities": map[string]any{"role": "member", "canRate": true}}
		case "RecipeRating":
			data = map[string]any{
				"myCapabilities": map[string]any{"role": "member", "canRate": true},
				"recipe":         map[string]any{"id": "42", "rating": map[string]any{"recipeId": "42", "average": 5, "count": 3, "myRating": 5}},
			}
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
			data = map[string]any{"rate": map[string]any{"recipeId": "42", "average": 5, "count": 3, "myRating": 5}}
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
	handler := newHandlerWithEndpoint(client, c, upstream.URL)
	request := func(method, path, etag string) *httptest.ResponseRecorder {
		t.Helper()
		form := url.Values{"rating": {"5"}}.Encode()
		r := httptest.NewRequest(method, path, strings.NewReader(form))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("If-None-Match", etag)
		if method == "POST" {
			r.Header.Set("Origin", "http://example.com")
		}
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
	if etag == "" || first.Header().Get("Cache-Control") != "private, no-store" {
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
		page := request("GET", "/recipe/42", etag)
		assertStyledErrorPage(t, page, http.StatusInternalServerError, "failed to fetch recipe | RezeptDB", "failed to fetch recipe", false)
		head := request("HEAD", "/recipe/42", etag)
		assertStyledErrorPage(t, head, http.StatusInternalServerError, "failed to fetch recipe | RezeptDB", "failed to fetch recipe", true)
		if page.Header().Get("ETag") != "" {
			t.Fatal("failed recipe response retained a successful-page ETag")
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
	for _, method := range []string{"GET", "HEAD"} {
		page := request(method, "/recipe/42", etag)
		assertStyledErrorPage(t, page, http.StatusNotFound, "recipe not found | RezeptDB", "recipe not found", method == "HEAD")
	}
}
