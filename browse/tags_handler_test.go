package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/Khan/genqlient/graphql"
)

type testTag struct {
	id       string
	category string
	name     string
}

type tagHandlerState struct {
	mu              sync.Mutex
	assigned        []testTag
	inventory       []testTag
	operations      []string
	inventoryFailed bool
	inventoryDenied bool
	mutationFailed  bool
	failNextTags    bool
	failConfirm     bool
}

func (state *tagHandlerState) graphqlHandler(w http.ResponseWriter, r *http.Request) {
	var request struct {
		OperationName string                     `json:"operationName"`
		Variables     map[string]json.RawMessage `json:"variables"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, "invalid graphql request", http.StatusBadRequest)
		return
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	state.operations = append(state.operations, request.OperationName)
	owner := r.Header.Get("Authorization") == "******"
	capabilities := map[string]any{"role": "member", "canManageRecipes": false}
	if owner {
		capabilities = map[string]any{"role": "owner", "canManageRecipes": true}
	}
	var data map[string]any
	var response map[string]any
	switch request.OperationName {
	case "RecipeTags":
		if state.failNextTags {
			state.failNextTags = false
			response = map[string]any{
				"data": map[string]any{
					"myCapabilities": capabilities,
					"recipe":         map[string]any{"id": "42", "tags": nil},
				},
				"errors": []any{map[string]any{"message": "tags unavailable", "path": []any{"recipe", "tags"}}},
			}
		} else {
			data = map[string]any{
				"myCapabilities": capabilities,
				"recipe":         map[string]any{"id": "42", "tags": testTagsJSON(state.assigned)},
			}
		}
	case "TagInventory":
		if state.inventoryDenied {
			response = map[string]any{
				"data":   map[string]any{"tags": nil},
				"errors": []any{map[string]any{"message": "authentication required", "path": []any{"tags"}}},
			}
		} else if state.inventoryFailed {
			response = map[string]any{
				"data":   map[string]any{"tags": nil},
				"errors": []any{map[string]any{"message": "tags unavailable", "path": []any{"tags"}}},
			}
		} else {
			data = map[string]any{"tags": testTagsJSON(state.inventory)}
		}
	case "AddRecipeTag":
		if state.mutationFailed {
			response = map[string]any{
				"data":   map[string]any{"addRecipeTag": nil},
				"errors": []any{map[string]any{"message": "assignment unavailable", "path": []any{"addRecipeTag"}}},
			}
			break
		}
		var tagID string
		if err := json.Unmarshal(request.Variables["tagId"], &tagID); err != nil {
			http.Error(w, "invalid tag id", http.StatusBadRequest)
			return
		}
		for _, tag := range state.inventory {
			if tag.id == tagID {
				state.assigned = append(state.assigned, tag)
				break
			}
		}
		if state.failConfirm {
			state.failConfirm = false
			state.failNextTags = true
		}
		data = map[string]any{"addRecipeTag": true}
	case "RemoveRecipeTag":
		var tagID string
		if err := json.Unmarshal(request.Variables["tagId"], &tagID); err != nil {
			http.Error(w, "invalid tag id", http.StatusBadRequest)
			return
		}
		remaining := state.assigned[:0]
		for _, tag := range state.assigned {
			if tag.id != tagID {
				remaining = append(remaining, tag)
			}
		}
		state.assigned = remaining
		data = map[string]any{"removeRecipeTag": true}
	default:
		http.Error(w, "unexpected graphql operation: "+request.OperationName, http.StatusBadRequest)
		return
	}
	if response == nil {
		response = map[string]any{"data": data}
	}
	_ = json.NewEncoder(w).Encode(response)
}

func testTagsJSON(tags []testTag) []any {
	result := make([]any, len(tags))
	for index, tag := range tags {
		result[index] = map[string]any{"id": tag.id, "category": tag.category, "name": tag.name}
	}
	return result
}

func newTagHandlerTest(t *testing.T, state *tagHandlerState, cache *pageCache) (http.Handler, *httptest.Server) {
	t.Helper()
	upstream := httptest.NewServer(http.HandlerFunc(state.graphqlHandler))
	t.Cleanup(upstream.Close)
	return newHandlerWithEndpoint(graphql.NewClient(upstream.URL, upstream.Client()), cache, upstream.URL), upstream
}

func tagRequest(handler http.Handler, method, path, body string, owner bool) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://recipes.example"+path, strings.NewReader(body))
	request.Host = "recipes.example"
	if owner {
		request.Header.Set("Authorization", "******")
	}
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		request.Header.Set("Origin", "http://recipes.example")
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func TestRecipeTagFragmentsEnforceOwnerCapabilityAndSearchInventory(t *testing.T) {
	state := &tagHandlerState{
		assigned: []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory: []testTag{
			{id: "course", category: "COURSE", name: "Dessert"},
			{id: "vegan", category: "DIETARY_STYLE", name: "Vegan"},
			{id: "assigned", category: "CUISINE", name: "Apfelkuchen"},
			{id: "cuisine", category: "CUISINE", name: "Ägyptisch"},
		},
	}
	handler, _ := newTagHandlerTest(t, state, nil)

	for _, testCase := range []struct {
		name   string
		owner  bool
		path   string
		status int
		want   []string
		unwant []string
	}{
		{
			name:   "public read fragment",
			path:   "/recipe/42/tags",
			status: http.StatusOK,
			want:   []string{"Apfelkuchen", "Kategorisierte Tags"},
			unwant: []string{"Tags bearbeiten", "Tag hinzufügen", "entfernen"},
		},
		{
			name:   "owner read fragment",
			owner:  true,
			path:   "/recipe/42/tags",
			status: http.StatusOK,
			want:   []string{"Tags bearbeiten", "Apfelkuchen"},
			unwant: []string{"Tag hinzufügen", "entfernen"},
		},
		{
			name:   "owner edit fragment",
			owner:  true,
			path:   "/recipe/42/tags?edit=1",
			status: http.StatusOK,
			want:   []string{"Fertig", "Tag hinzufügen", "Apfelkuchen entfernen", `name="q"`},
			unwant: []string{"Tags bearbeiten"},
		},
		{
			name:   "non-owner edit denied",
			path:   "/recipe/42/tags?edit=1",
			status: http.StatusForbidden,
			want:   []string{"Tags bearbeiten ist nicht erlaubt."},
			unwant: []string{"Tag hinzufügen", "entfernen"},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			response := tagRequest(handler, http.MethodGet, testCase.path, "", testCase.owner)
			body := response.Body.String()
			if response.Code != testCase.status || response.Header().Get("Cache-Control") != "no-store" ||
				response.Header().Get("ETag") != "" {
				t.Fatalf("unexpected fragment response: status=%d headers=%v body=%s", response.Code, response.Header(), body)
			}
			for _, text := range testCase.want {
				if !strings.Contains(body, text) {
					t.Errorf("missing %q: %s", text, body)
				}
			}
			for _, text := range testCase.unwant {
				if strings.Contains(body, text) {
					t.Errorf("unexpected %q: %s", text, body)
				}
			}
		})
	}

	options := tagRequest(handler, http.MethodGet, "/recipe/42/tags/options?q=VEG", "", true)
	if options.Code != http.StatusOK || strings.Contains(options.Body.String(), "Apfelkuchen") ||
		!strings.Contains(options.Body.String(), "Vegan") {
		t.Fatalf("search should return only matching unassigned tags: %d %s", options.Code, options.Body.String())
	}
	matchesNone := tagRequest(handler, http.MethodGet, "/recipe/42/tags/options?q=not-found", "", true)
	if matchesNone.Code != http.StatusOK || !strings.Contains(matchesNone.Body.String(), "Keine passenden Tags gefunden.") {
		t.Fatalf("no matches must be distinct from inventory failure: %d %s", matchesNone.Code, matchesNone.Body.String())
	}
	state.mu.Lock()
	before := strings.Count(strings.Join(state.operations, ","), "TagInventory")
	state.mu.Unlock()
	denied := tagRequest(handler, http.MethodGet, "/recipe/42/tags/options?q=veg", "", false)
	state.mu.Lock()
	after := strings.Count(strings.Join(state.operations, ","), "TagInventory")
	state.mu.Unlock()
	if denied.Code != http.StatusForbidden || strings.Contains(denied.Body.String(), "Vegan") || before != after {
		t.Fatalf("non-owner inventory access was not denied before inventory fetch: %d %s", denied.Code, denied.Body.String())
	}
	state.mu.Lock()
	state.inventoryFailed = true
	state.mu.Unlock()
	failed := tagRequest(handler, http.MethodGet, "/recipe/42/tags/options?q=veg", "", true)
	if failed.Code != http.StatusBadGateway || !strings.Contains(failed.Body.String(), "Tag-Auswahl konnte nicht geladen werden.") ||
		!strings.Contains(failed.Body.String(), "Erneut versuchen") {
		t.Fatalf("inventory dependency failure must be explicit and retryable: %d %s", failed.Code, failed.Body.String())
	}
	state.mu.Lock()
	state.inventoryFailed = false
	state.inventoryDenied = true
	state.mu.Unlock()
	deniedInventory := tagRequest(handler, http.MethodGet, "/recipe/42/tags/options?q=veg", "", true)
	if deniedInventory.Code != http.StatusUnauthorized || !strings.Contains(deniedInventory.Body.String(), "Tags bearbeiten ist nicht erlaubt.") ||
		strings.Contains(deniedInventory.Body.String(), "Tag hinzufügen") ||
		deniedInventory.Header().Get("HX-Retarget") != "#recipe-tags" {
		t.Fatalf("expired inventory credentials must remove edit controls with an explicit denial: %d %v %s", deniedInventory.Code, deniedInventory.Header(), deniedInventory.Body.String())
	}

	mutationDenied := &tagHandlerState{
		assigned:        []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory:       []testTag{{id: "new", category: "COURSE", name: "Dessert"}},
		inventoryDenied: true,
	}
	mutationHandler, _ := newTagHandlerTest(t, mutationDenied, nil)
	deniedAdd := tagRequest(mutationHandler, http.MethodPost, "/recipe/42/tags", url.Values{"tagId": {"new"}}.Encode(), true)
	if deniedAdd.Code != http.StatusUnauthorized || !strings.Contains(deniedAdd.Body.String(), "Tags bearbeiten ist nicht erlaubt.") ||
		strings.Contains(deniedAdd.Body.String(), "Tag hinzufügen") {
		t.Fatalf("inventory authorization failure must not leave the editor active: %d %s", deniedAdd.Code, deniedAdd.Body.String())
	}
}

func TestRecipeTagMutationsUseDedicatedGraphQLAndRefreshCache(t *testing.T) {
	state := &tagHandlerState{
		assigned: []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory: []testTag{
			{id: "assigned", category: "CUISINE", name: "Apfelkuchen"},
			{id: "dessert", category: "COURSE", name: "Dessert"},
		},
	}
	var renders int
	cache := testCache(t, func(context.Context, string) ([]byte, error) {
		renders++
		return []byte(fmt.Sprintf("render %d", renders)), nil
	})
	getPage(t, cache, "42")
	handler, _ := newTagHandlerTest(t, state, cache)

	add := tagRequest(handler, http.MethodPost, "/recipe/42/tags", url.Values{"tagId": {"dessert"}}.Encode(), true)
	if add.Code != http.StatusOK || !strings.Contains(add.Body.String(), "Dessert") ||
		add.Header().Get("HX-Trigger-After-Swap") == "" ||
		strings.Contains(add.Body.String(), `<details class="dropdown" open`) {
		t.Fatalf("tag addition was not confirmed in returned panel: %d %v %s", add.Code, add.Header(), add.Body.String())
	}
	cache.mu.Lock()
	_, cached := cache.entries["42"]
	cache.mu.Unlock()
	if cached {
		t.Fatal("successful tag addition did not invalidate recipe HTML")
	}
	if refreshed := getPage(t, cache, "42"); renders != 2 || string(refreshed.html) != "render 2" {
		t.Fatalf("invalidated recipe page was not rendered again: %d %s", renders, refreshed.html)
	}

	remove := tagRequest(handler, http.MethodPost, "/recipe/42/tags/assigned/remove", "", true)
	if remove.Code != http.StatusOK || !strings.Contains(remove.Body.String(), "Dessert") ||
		!strings.Contains(remove.Header().Get("HX-Trigger-After-Swap"), "recipe-tag-removed") {
		t.Fatalf("tag removal did not return refreshed assignments: %d %v %s", remove.Code, remove.Header(), remove.Body.String())
	}
	removeLast := tagRequest(handler, http.MethodPost, "/recipe/42/tags/dessert/remove", "", true)
	if removeLast.Code != http.StatusOK || strings.Contains(removeLast.Body.String(), "recipe-tags-detail") ||
		!strings.Contains(removeLast.Body.String(), "Tag hinzufügen") {
		t.Fatalf("removing the final assignment must leave the empty owner editor: %d %s", removeLast.Code, removeLast.Body.String())
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	for _, operation := range state.operations {
		if operation == "ChangeRecipeTags" {
			t.Fatal("UI must not use the bulk tag mutation")
		}
	}
}

func TestRecipeTagMutationFailuresRetainConfirmedAssignments(t *testing.T) {
	state := &tagHandlerState{
		assigned:       []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory:      []testTag{{id: "new", category: "COURSE", name: "Dessert"}},
		mutationFailed: true,
	}
	cache := testCache(t, func(context.Context, string) ([]byte, error) { return []byte("page"), nil })
	getPage(t, cache, "42")
	handler, _ := newTagHandlerTest(t, state, cache)
	response := tagRequest(handler, http.MethodPost, "/recipe/42/tags", url.Values{"tagId": {"new"}}.Encode(), true)
	body := response.Body.String()
	if response.Code != http.StatusBadGateway || !strings.Contains(body, "Apfelkuchen") ||
		strings.Contains(body, "Dessert") || !strings.Contains(body, "Änderung konnte nicht bestätigt werden") ||
		!strings.Contains(body, "Tags neu laden") || response.Header().Get("X-Tag-Replace") != "true" {
		t.Fatalf("failed write lost the last confirmed state or omitted retry: %d %v %s", response.Code, response.Header(), body)
	}
	cache.mu.Lock()
	_, cached := cache.entries["42"]
	cache.mu.Unlock()
	if cached {
		t.Fatal("uncertain mutation response left potentially stale recipe HTML cached")
	}
}

func TestRecipeTagRefreshFailureDoesNotClaimMutationSuccess(t *testing.T) {
	state := &tagHandlerState{
		assigned:    []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory:   []testTag{{id: "new", category: "COURSE", name: "Dessert"}},
		failConfirm: true,
	}
	handler, _ := newTagHandlerTest(t, state, nil)
	response := tagRequest(handler, http.MethodPost, "/recipe/42/tags", url.Values{"tagId": {"new"}}.Encode(), true)
	body := response.Body.String()
	if response.Code != http.StatusBadGateway || !strings.Contains(body, "Apfelkuchen") ||
		strings.Contains(body, "Dessert") || !strings.Contains(body, "möglicherweise gespeichert") ||
		response.Header().Get("HX-Trigger-After-Swap") != "" || response.Header().Get("X-Tag-Replace") != "true" {
		t.Fatalf("failed refresh must preserve the last confirmed assignment without claiming success: %d %v %s", response.Code, response.Header(), body)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if len(state.assigned) != 2 {
		t.Fatal("test setup expected the backend write to have committed before confirmation failed")
	}
}

func TestRecipeTagMutationsRejectMalformedAndCrossOriginRequests(t *testing.T) {
	state := &tagHandlerState{
		assigned:  []testTag{{id: "assigned", category: "CUISINE", name: "Apfelkuchen"}},
		inventory: []testTag{{id: "new", category: "COURSE", name: "Dessert"}},
	}
	handler, _ := newTagHandlerTest(t, state, nil)

	invalid := tagRequest(handler, http.MethodPost, "/recipe/42/tags", "", true)
	if invalid.Code != http.StatusBadRequest || !strings.Contains(invalid.Body.String(), "Ungültige Tags-Anfrage.") {
		t.Fatalf("missing tagId was not explicitly rejected: %d %s", invalid.Code, invalid.Body.String())
	}
	crossOrigin := httptest.NewRequest(http.MethodPost, "http://recipes.example/recipe/42/tags", strings.NewReader("tagId=new"))
	crossOrigin.Host = "recipes.example"
	crossOrigin.Header.Set("Authorization", "******")
	crossOrigin.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	crossOrigin.Header.Set("Origin", "http://attacker.example")
	if sameOriginRequest(crossOrigin) {
		t.Fatal("cross-origin test request unexpectedly passed origin validation")
	}
	crossOriginResponse := httptest.NewRecorder()
	handler.ServeHTTP(crossOriginResponse, crossOrigin)
	if crossOriginResponse.Code != http.StatusForbidden {
		t.Fatalf("cross-origin write was not rejected: %d %s", crossOriginResponse.Code, crossOriginResponse.Body.String())
	}
	member := tagRequest(handler, http.MethodPost, "/recipe/42/tags", url.Values{"tagId": {"new"}}.Encode(), false)
	if member.Code != http.StatusForbidden || strings.Contains(member.Body.String(), "Tag hinzufügen") ||
		strings.Contains(member.Body.String(), "hx-post") {
		t.Fatalf("non-owner write was not denied: %d %s", member.Code, member.Body.String())
	}

	method := tagRequest(handler, http.MethodPut, "/recipe/42/tags", "", true)
	if method.Code != http.StatusMethodNotAllowed {
		t.Fatalf("unsupported method was not rejected: %d", method.Code)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	for _, operation := range state.operations {
		if operation == "AddRecipeTag" || operation == "RemoveRecipeTag" {
			t.Fatal("invalid or cross-origin write reached GraphQL")
		}
	}
}

func TestParseTagIDReadsSingleFormValue(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "http://recipes.example/recipe/42/tags", strings.NewReader("tagId=dessert"))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	tagID, err := parseTagID(httptest.NewRecorder(), request)
	if err != nil || tagID != "dessert" {
		t.Fatalf("single tagId was rejected: %q %v post=%v", tagID, err, request.PostForm)
	}
}
