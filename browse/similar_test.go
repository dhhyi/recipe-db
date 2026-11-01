package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"

	"frontend/src/components"
	gql "frontend/src/generated"
)

type similarTestBackend struct {
	mu       sync.Mutex
	ids      []string
	calls    []string
	headers  []http.Header
	missing  map[string]bool
	fail     string
	tagError string
	denied   string
}

func similarTestHandler(t *testing.T, backend *similarTestBackend) http.Handler {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			OperationName string            `json:"operationName"`
			Variables     map[string]string `json:"variables"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		backend.mu.Lock()
		defer backend.mu.Unlock()
		backend.headers = append(backend.headers, r.Header.Clone())
		w.Header().Set("Content-Type", "application/json")
		var result any
		switch request.OperationName {
		case "SimilarRecipeIds":
			backend.calls = append(backend.calls, "ids")
			if request.Variables["recipeId"] != "source" {
				t.Errorf("wrong source: %v", request.Variables)
			}
			result = map[string]any{"data": map[string]any{"similarRecipeIds": backend.ids}}
			if backend.fail == "ids" {
				result = map[string]any{"errors": []any{map[string]any{"message": "search unavailable"}}}
			}
		case "SimilarRecipeCard":
			id := request.Variables["id"]
			backend.calls = append(backend.calls, id)
			var recipe any
			if !backend.missing[id] {
				recipe = map[string]any{
					"id": id, "name": "Recipe " + id,
					"tags": []any{}, "image": map[string]any{"url": "/image", "thumbUrl": "/thumb"},
					"rating": map[string]any{"recipeId": id, "average": 4.5, "count": 2},
				}
			}
			response := map[string]any{"data": map[string]any{"recipe": recipe}}
			switch id {
			case backend.fail:
				response["errors"] = []any{map[string]any{
					"message": "recipes unavailable", "path": []string{"recipe"},
					"extensions": map[string]any{"code": "service-unavailable", "status": 503, "service": "recipes"},
				}}
			case backend.tagError:
				recipe.(map[string]any)["tags"] = nil
				response["errors"] = []any{map[string]any{
					"message": "tags unavailable", "path": []string{"recipe", "tags"},
					"extensions": map[string]any{"code": "service-unavailable", "status": 503, "service": "tags"},
				}}
			case backend.denied:
				response["data"] = map[string]any{"recipe": nil}
				response["errors"] = []any{map[string]any{
					"message": "not permitted", "path": []string{"recipe"},
					"extensions": map[string]any{"code": "forbidden", "status": 403},
				}}
			}
			result = response
		default:
			t.Errorf("unexpected operation: %s", request.OperationName)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if err := json.NewEncoder(w).Encode(result); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(server.Close)
	return newHandlerWithEndpoint(nil, nil, server.URL)
}

func similarRequest(handler http.Handler, more bool, ids []string) *httptest.ResponseRecorder {
	path, method := "/recipe/source/similar", http.MethodGet
	form := url.Values{}
	if more {
		path, method = path+"/more", http.MethodPost
		form["remainingId"] = ids
	}
	request := httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "http://example.com")
	request.Header.Set("HX-Request", "true")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

var similarQueuePattern = regexp.MustCompile(`name="remainingId" value="([^"]*)"`)
var similarCardPattern = regexp.MustCompile(`data-recipe-id="([^"]*)"`)

func similarMatches(pattern *regexp.Regexp, body string) []string {
	result := []string{}
	for _, match := range pattern.FindAllStringSubmatch(body, -1) {
		result = append(result, html.UnescapeString(match[1]))
	}
	return result
}

func assertSimilarResponse(t *testing.T, response *httptest.ResponseRecorder) {
	t.Helper()
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" ||
		response.Header().Get("ETag") != "" || !strings.Contains(response.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("bad fragment response: %d %v %s", response.Code, response.Header(), response.Body.String())
	}
	for _, key := range []string{"HX-Push-Url", "HX-Replace-Url"} {
		if response.Header().Get(key) != "" {
			t.Fatalf("fragment changes navigation: %v", response.Header())
		}
	}
	for _, forbidden := range []string{"intersect", "revealed", "hx-trigger=\"load\"", "<title", "hx-swap-oob"} {
		if strings.Contains(response.Body.String(), forbidden) {
			t.Fatalf("unexpected automatic loading/navigation %q: %s", forbidden, response.Body.String())
		}
	}
}

func TestSimilarRecipesBatchCountsAndFixedQueue(t *testing.T) {
	for _, count := range []int{0, 1, 3, 4, 9, 10, 11, 137} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			ids := []string{}
			for i := 0; i < count; i++ {
				ids = append(ids, fmt.Sprintf("r%d", i))
			}
			backend := &similarTestBackend{ids: ids}
			handler := similarTestHandler(t, backend)
			response := similarRequest(handler, false, nil)
			shown := []string{}
			for {
				assertSimilarResponse(t, response)
				cards := similarMatches(similarCardPattern, response.Body.String())
				wantCount := min(3, count-len(shown))
				if len(cards) != wantCount {
					t.Fatalf("got %d cards, want %d: %s", len(cards), wantCount, response.Body.String())
				}
				shown = append(shown, cards...)
				queue := similarMatches(similarQueuePattern, response.Body.String())
				if !reflect.DeepEqual(queue, ids[len(shown):]) {
					t.Fatalf("queue changed order: %v want %v", queue, ids[len(shown):])
				}
				if len(queue) == 0 {
					if strings.Contains(response.Body.String(), "<form") {
						t.Fatal("exhausted queue retained form")
					}
					break
				}
				for _, control := range []string{`hx-post="/recipe/source/similar/more"`, `hx-target="this"`, `hx-swap="outerHTML"`, `hx-sync="this:drop"`, `hx-disabled-elt="find button"`, `hx-push-url="false"`, `hx-replace-url="false"`, `hx-on::send-error=`, `hx-on::response-error=`, `hx-on::timeout=`, `hx-on:similar-error=`, `data-similar-error hidden`, `>Mehr anzeigen</button>`} {
					if !strings.Contains(response.Body.String(), control) {
						t.Errorf("missing control %s", control)
					}
				}
				if strings.Count(response.Body.String(), "<form") != 1 {
					t.Fatal("expected exactly one continuation form")
				}
				backend.mu.Lock()
				if len(backend.calls) != len(shown)+1 {
					t.Errorf("eager hydration: %v", backend.calls)
				}
				// Changing similarity after the first response cannot change its queue.
				backend.ids = []string{"new-neighbor"}
				backend.mu.Unlock()
				response = similarRequest(handler, true, queue)
			}
			if !reflect.DeepEqual(shown, ids) {
				t.Fatalf("cards lost or reordered: %v", shown)
			}
			backend.mu.Lock()
			defer backend.mu.Unlock()
			if !reflect.DeepEqual(backend.calls, append([]string{"ids"}, ids...)) {
				t.Fatalf("unexpected calls: %v", backend.calls)
			}
			if count == 0 && strings.Contains(response.Body.String(), "<section") {
				t.Fatal("empty results should hide section")
			}
		})
	}
}

func TestSimilarRecipesMissingDuplicatesAndSource(t *testing.T) {
	backend := &similarTestBackend{
		ids:     []string{"source", "a", "missing", "a", "denied", "b", "c", "d", "source", "d"},
		missing: map[string]bool{"missing": true}, denied: "denied",
	}
	response := similarRequest(similarTestHandler(t, backend), false, nil)
	assertSimilarResponse(t, response)
	if !reflect.DeepEqual(similarMatches(similarCardPattern, response.Body.String()), []string{"a", "b", "c"}) ||
		!reflect.DeepEqual(similarMatches(similarQueuePattern, response.Body.String()), []string{"d"}) {
		t.Fatalf("incorrect usable batch: %s", response.Body.String())
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if !reflect.DeepEqual(backend.calls, []string{"ids", "a", "missing", "denied", "b", "c"}) {
		t.Fatalf("wrong hydration order: %v", backend.calls)
	}
}

func TestSimilarRecipesFailureIsAtomicAndRetryable(t *testing.T) {
	for _, initial := range []bool{false, true} {
		t.Run(strconv.FormatBool(initial), func(t *testing.T) {
			backend := &similarTestBackend{ids: []string{"a", "b", "c", "d", "e", "f", "g"}}
			handler := similarTestHandler(t, backend)
			queue := backend.ids
			if !initial {
				first := similarRequest(handler, false, nil)
				queue = similarMatches(similarQueuePattern, first.Body.String())
			}
			backend.mu.Lock()
			backend.fail = queue[1]
			backend.mu.Unlock()
			response := similarRequest(handler, !initial, queue)
			assertSimilarResponse(t, response)
			if len(similarMatches(similarCardPattern, response.Body.String())) != 0 ||
				!strings.Contains(response.Body.String(), "Ähnliche Rezepte konnten nicht geladen werden") ||
				!strings.Contains(response.Body.String(), "Erneut versuchen") {
				t.Fatalf("failed batch exposed partial cards or has no retry: %s", response.Body.String())
			}
			if !reflect.DeepEqual(similarMatches(similarQueuePattern, response.Body.String()), queue) ||
				strings.Contains(response.Body.String(), `hx-get="/recipe/source/similar"`) {
				t.Fatalf("failed batch consumed original queue: %s", response.Body.String())
			}
			backend.mu.Lock()
			backend.fail = ""
			backend.mu.Unlock()
			retry := similarRequest(handler, true, queue)
			if !reflect.DeepEqual(similarMatches(similarCardPattern, retry.Body.String()), queue[:3]) {
				t.Fatalf("retry lost cards: %s", retry.Body.String())
			}
			backend.mu.Lock()
			defer backend.mu.Unlock()
			if strings.Count(strings.Join(backend.calls, ","), "ids") != 1 {
				t.Fatalf("load-more re-ran similarity: %v", backend.calls)
			}
		})
	}
}

func TestSimilarRecipesInitialSearchFailureAndTagsDegradation(t *testing.T) {
	backend := &similarTestBackend{ids: []string{"a"}, fail: "ids"}
	handler := similarTestHandler(t, backend)
	response := similarRequest(handler, false, nil)
	assertSimilarResponse(t, response)
	if !strings.Contains(response.Body.String(), `hx-get="/recipe/source/similar"`) ||
		!strings.Contains(response.Body.String(), "Erneut versuchen") {
		t.Fatalf("missing explicit initial retry: %s", response.Body.String())
	}
	backend.mu.Lock()
	backend.fail, backend.tagError = "", "a"
	backend.mu.Unlock()
	response = similarRequest(handler, false, nil)
	assertSimilarResponse(t, response)
	if !reflect.DeepEqual(similarMatches(similarCardPattern, response.Body.String()), []string{"a"}) ||
		strings.Contains(response.Body.String(), "konnten nicht") || strings.Contains(response.Body.String(), "Tags nicht verfügbar") ||
		!strings.Contains(response.Body.String(), "recipe-tile-component") ||
		!strings.Contains(response.Body.String(), `src="/thumb"`) {
		t.Fatalf("tag-only error failed shared card: %s", response.Body.String())
	}
}

func TestSimilarRecipesCardsAllowBoostedNavigation(t *testing.T) {
	backend := &similarTestBackend{ids: []string{"a", "b", "c", "d"}}
	response := similarRequest(similarTestHandler(t, backend), false, nil)
	assertSimilarResponse(t, response)
	section := regexp.MustCompile(`<section id="similar-recipes"[^>]*>`).FindString(response.Body.String())
	if section == "" || strings.Contains(section, "hx-push-url") || strings.Contains(section, "hx-replace-url") {
		t.Fatalf("similarity container must not suppress boosted card navigation: %s", section)
	}
	card := regexp.MustCompile(`<a href="/recipe/a"[^>]*>`).FindString(response.Body.String())
	if !strings.Contains(card, `hx-boost="true"`) || strings.Contains(card, "hx-push-url") || strings.Contains(card, "hx-replace-url") {
		t.Fatalf("shared card must retain normal boosted navigation: %s", card)
	}
	if !strings.Contains(response.Body.String(), `hx-push-url="false"`) ||
		!strings.Contains(response.Body.String(), `hx-replace-url="false"`) {
		t.Fatal("continuation form must still avoid history/URL changes")
	}
}

func TestSimilarRecipesNullIDsRequireRetry(t *testing.T) {
	backend := &similarTestBackend{}
	response := similarRequest(similarTestHandler(t, backend), false, nil)
	assertSimilarResponse(t, response)
	if !strings.Contains(response.Body.String(), "Ähnliche Rezepte konnten nicht geladen werden") ||
		!strings.Contains(response.Body.String(), "Erneut versuchen") ||
		strings.Contains(response.Body.String(), `id="similar-recipes" hidden`) {
		t.Fatalf("null IDs must not masquerade as confirmed empty results: %s", response.Body.String())
	}
}

func TestSimilarRecipesAllMissingHidesInitialSection(t *testing.T) {
	backend := &similarTestBackend{ids: []string{"a", "b"}, missing: map[string]bool{"a": true, "b": true}}
	response := similarRequest(similarTestHandler(t, backend), false, nil)
	assertSimilarResponse(t, response)
	if strings.Contains(response.Body.String(), "<section") || strings.Contains(response.Body.String(), "<form") {
		t.Fatalf("missing recipes left an empty section: %s", response.Body.String())
	}
}

func TestSimilarRecipesRejectsUntrustedInput(t *testing.T) {
	backend := &similarTestBackend{}
	handler := similarTestHandler(t, backend)
	for _, tc := range []struct {
		name, path, body, origin, contentType string
		status                                int
	}{
		{"missing", "/recipe/source/similar/more", "", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"unsafe", "/recipe/source/similar/more", "remainingId=..%2Fprivate", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"empty ID", "/recipe/source/similar/more", "remainingId=", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"unknown key", "/recipe/source/similar/more", "remainingId=a&options=untrusted", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"query queue", "/recipe/source/similar/more?remainingId=a", "remainingId=b", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"bad source", "/recipe/source%20id/similar/more", "remainingId=a", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"wrong origin", "/recipe/source/similar/more", "remainingId=a", "http://attacker.example", "application/x-www-form-urlencoded", 403},
		{"no origin", "/recipe/source/similar/more", "remainingId=a", "", "application/x-www-form-urlencoded", 403},
		{"wrong type", "/recipe/source/similar/more", "remainingId=a", "http://example.com", "application/json", 400},
		{"malformed form", "/recipe/source/similar/more", "remainingId=%zz", "http://example.com", "application/x-www-form-urlencoded", 400},
		{"body limit", "/recipe/source/similar/more", "remainingId=" + strings.Repeat("a", 10<<20), "http://example.com", "application/x-www-form-urlencoded", 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			request.Header.Set("Origin", tc.origin)
			request.Header.Set("Content-Type", tc.contentType)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != tc.status || response.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("bad invalid request response: %d %s", response.Code, response.Body.String())
			}
		})
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if len(backend.calls) != 0 {
		t.Fatalf("invalid input reached GraphQL: %v", backend.calls)
	}
}

func TestSimilarRecipesPostedQueueIsDeduplicated(t *testing.T) {
	backend := &similarTestBackend{}
	response := similarRequest(similarTestHandler(t, backend), true, []string{"source", "a", "a", "b", "source", "c", "d", "d"})
	assertSimilarResponse(t, response)
	if !reflect.DeepEqual(similarMatches(similarCardPattern, response.Body.String()), []string{"a", "b", "c"}) ||
		!reflect.DeepEqual(similarMatches(similarQueuePattern, response.Body.String()), []string{"d"}) {
		t.Fatalf("posted queue was not sanitized: %s", response.Body.String())
	}
}

func TestSimilarRecipesPlaceholderIsLazyAndStable(t *testing.T) {
	response := &gql.RecipeByIdResponse{Recipe: &gql.RecipeDetail{Id: "source", Name: "Source"}}
	var body bytes.Buffer
	if err := components.Detail(response).Render(context.Background(), &body); err != nil {
		t.Fatal(err)
	}

	rendered := body.String()
	for _, control := range []string{`id="similar-recipes"`, `hx-get="/recipe/source/similar"`, `hx-trigger="intersect once"`, `hx-sync="this:drop"`, `hx-history="false"`, `hx-on::send-error=`, `hx-on::response-error=`, `hx-on::timeout=`, `hx-on:similar-error=`, `data-similar-error hidden`} {
		if !strings.Contains(rendered, control) {
			t.Errorf("missing lazy detail control %s", control)
		}
	}
	if strings.Index(rendered, `id="similar-recipes"`) < strings.Index(rendered, "Zur Startseite") ||
		strings.Contains(rendered, "recipe-tile-component") {
		t.Fatalf("similar cards must load only at the bottom, not in initial HTML: %s", rendered)
	}
}

func TestSimilarRecipesRequestScopedPublicRead(t *testing.T) {
	backend := &similarTestBackend{ids: []string{"a"}}
	handler := similarTestHandler(t, backend)
	for _, authorization := range []string{"test-reader-one", "test-reader-two", ""} {
		request := httptest.NewRequest(http.MethodGet, "/recipe/source/similar", nil)
		if authorization != "" {
			request.Header.Set("Authorization", authorization)
		}
		request.Header.Set("Cookie", "_oauth2_proxy=session; private=not-forwarded")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		assertSimilarResponse(t, response)
		if len(similarMatches(similarCardPattern, response.Body.String())) != 1 {
			t.Fatalf("public reader was denied: %s", response.Body.String())
		}
		backend.mu.Lock()
		for _, headers := range backend.headers[len(backend.headers)-2:] {
			if headers.Get("Authorization") != authorization || headers.Get("Origin") != "http://traefik" {
				t.Errorf("wrong request-scoped authorization: %v", headers)
			}
			expectedCookie := ""
			if authorization == "" {
				expectedCookie = "_oauth2_proxy=session"
			}
			if headers.Get("Cookie") != expectedCookie {
				t.Errorf("unexpected forwarded cookies: %v", headers)
			}
		}
		backend.mu.Unlock()
	}
}

func TestSimilarRecipesSkipsOnlyConfirmedAbsence(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		skip bool
	}{
		{"nil", nil, false},
		{"outage", fmt.Errorf("recipe not found: upstream unavailable"), false},
		{"unknown 404", gqlerror.List{&gqlerror.Error{Path: ast.Path{ast.PathName("recipe")}, Extensions: map[string]any{"status": 404}}}, false},
		{"confirmed missing", gqlerror.List{&gqlerror.Error{Path: ast.Path{ast.PathName("recipe")}, Extensions: map[string]any{"code": "recipe-not-found", "status": 404}}}, true},
		{"confirmed forbidden", gqlerror.List{&gqlerror.Error{Path: ast.Path{ast.PathName("recipe")}, Extensions: map[string]any{"code": "forbidden", "status": 403}}}, true},
		{"nested forbidden", gqlerror.List{&gqlerror.Error{Path: ast.Path{ast.PathName("recipe"), ast.PathName("rating")}, Extensions: map[string]any{"code": "forbidden"}}}, false},
		{"mixed failure", gqlerror.List{
			&gqlerror.Error{Path: ast.Path{ast.PathName("recipe")}, Extensions: map[string]any{"code": "recipe-not-found"}},
			&gqlerror.Error{Message: "backend unavailable"},
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := inaccessibleSimilarRecipe(tc.err); got != tc.skip {
				t.Fatalf("skip=%v, want %v", got, tc.skip)
			}
		})
	}
}
