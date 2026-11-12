package main

import (
	"bytes"
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

	"frontend/page_metadata"
	"frontend/src/components"
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
	if strings.Count(body, "<header-component ") != 1 || strings.Count(body, "<main>") != 1 ||
		!strings.Contains(body, `<link rel="stylesheet" href="/design/styles.css">`) ||
		!strings.Contains(body, `<script src="/design/htmx.min.js"></script>`) ||
		!strings.Contains(body, "<title>"+title+"</title>") {
		t.Fatalf("incorrect styled error response body: %s", body)
	}
	if !strings.Contains(body, `<p class="feedback error">`+message+`</p>`) || strings.Contains(body, "<form") ||
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
		assertStyledErrorPage(t, response, http.StatusNotFound, "Seite nicht gefunden | RezeptDB", "Seite nicht gefunden.", method == "HEAD")
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

func TestOpenGraphMetadataEscapesValues(t *testing.T) {
	if got := absolutePublicURL("https://recipes.example.test", "/images/42"); got != "https://recipes.example.test/images/42" {
		t.Fatalf("relative image URL was not made absolute: %s", got)
	}
	if got := absolutePublicURL("https://recipes.example.test", "javascript:alert(1)"); got != "https://recipes.example.test/design/og-image.svg" {
		t.Fatalf("unsafe image URL did not use the fallback: %s", got)
	}

	var body bytes.Buffer
	metadata := pagemetadata.PageMetadata{
		DocumentTitle:  `<recipe> " &`,
		OpenGraphTitle: `<recipe> " &`,
		OpenGraphType:  "article",
		OpenGraphImage: "https://recipes.example.test/image.png?one=1&two=2",
		OpenGraphURL:   "https://recipes.example.test/recipe/42",
		Description:    `<description> &`,
	}
	ctx := pagemetadata.WithContext(context.Background(), metadata)
	if err := components.Layout().Render(ctx, &body); err != nil {
		t.Fatal(err)
	}
	rendered := body.String()
	for _, raw := range []string{"<recipe>", `<description>`, `?one=1&two=2`} {
		if strings.Contains(rendered, raw) {
			t.Errorf("Open Graph metadata was not escaped: %s", raw)
		}
	}
	for _, escaped := range []string{"&lt;recipe&gt;", "&lt;description&gt;", "?one=1&amp;two=2"} {
		if !strings.Contains(rendered, escaped) {
			t.Errorf("escaped Open Graph value missing %q: %s", escaped, rendered)
		}
	}
	if strings.Count(rendered, `content="&lt;description&gt; &amp;"`) != 2 {
		t.Errorf("description must populate both metadata tags: %s", rendered)
	}

	body.Reset()
	if err := components.Layout().Render(context.Background(), &body); err != nil {
		t.Fatalf("layout without metadata context failed: %v", err)
	}
	if !strings.Contains(body.String(), "<title></title>") ||
		strings.Contains(body.String(), "og:") ||
		strings.Contains(body.String(), `name="description"`) {
		t.Fatalf("layout without metadata context was not safely rendered: %s", body.String())
	}
}

func TestInstallMetadata(t *testing.T) {
	var body bytes.Buffer
	ctx := pagemetadata.WithContext(context.Background(), pagemetadata.PageMetadata{DocumentTitle: "Test"})
	if err := components.Layout().Render(ctx, &body); err != nil {
		t.Fatal(err)
	}

	for _, tag := range []string{
		`<link rel="manifest" href="/pwa/manifest.webmanifest">`,
		`<link rel="apple-touch-icon" href="/pwa/icons/apple-touch-icon.png">`,
		`<meta name="theme-color" content="#014463">`,
		`<link rel="icon" type="image/png" sizes="192x192" href="/pwa/icons/chef-hat-192.png">`,
	} {
		if !strings.Contains(body.String(), tag) {
			t.Errorf("install metadata missing %q: %s", tag, body.String())
		}
	}
}

func TestDetailHTTPAndLiveWidgets(t *testing.T) {
	const imageURL = "https://cdn.example.test/opaque/full-token.png?signature=abc&version=two"
	const thumbURL = "/assets/unrelated/thumb-token.png?rev=opaque&size=small"
	var recipeCalls atomic.Int32
	var version atomic.Int32
	var deleted, ratingsOffline, imagesOffline, editOnline atomic.Bool
	var hasImage atomic.Bool
	var tagsOffline atomic.Bool
	var inspirationsOnline, hasInspirations atomic.Bool
	var identityRole atomic.Value
	identityRole.Store("owner")
	var canRate atomic.Bool
	canRate.Store(true)
	hasImage.Store(true)
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
			data = map[string]any{"myCapabilities": map[string]any{"role": identityRole.Load()}}
		case "Overview":
			data = map[string]any{
				"recipes": []any{map[string]any{
					"id": "42", "name": "Original",
					"tags":  []any{},
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
				var image any
				if hasImage.Load() {
					image = map[string]any{"url": imageURL, "thumbUrl": thumbURL}
				}
				if imagesOffline.Load() {
					image = nil
				}
				name := "Original"
				if version.Load() > 0 {
					name = "Updated"
				}
				recipe = map[string]any{
					"id": "42", "name": name, "method": "Cook", "ingredients": []any{
						map[string]any{"name": "Rice", "amount": "200", "unit": "g"},
					},
					"tags":      []any{},
					"createdAt": "2020-01-01T00:00:00.123456Z", "updatedAt": "2020-01-01T00:00:00.123456Z",
					"rating": rating, "image": image,
				}
				if tagsOffline.Load() {
					recipe.(map[string]any)["tags"] = nil
				}
			}
			data = map[string]any{"recipe": recipe}
		case "RecipeControls":
			data = map[string]any{
				"myCapabilities":   map[string]any{"role": "owner", "canManageRecipes": editOnline.Load(), "canManageImages": false},
				"recipeEditOnline": editOnline.Load(), "imagesOnline": false, "imageEditOnline": false,
			}
		case "RatingCapabilities":
			data = map[string]any{
				"myCapabilities": map[string]any{"role": "member", "canRate": canRate.Load()},
				"rating":         map[string]any{"recipeId": "42", "average": 5, "count": 3},
			}
		case "RecipeRating":
			data = map[string]any{
				"myCapabilities": map[string]any{"role": "member", "canRate": true},
				"recipe":         map[string]any{"id": "42", "rating": map[string]any{"recipeId": "42", "average": 5, "count": 3, "myRating": 3}},
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
		response := map[string]any{"data": data}
		var errors []any
		if request.OperationName == "RecipeById" && ratingsOffline.Load() {
			errors = append(errors, map[string]any{
				"message": "ratings unavailable",
				"path":    []any{"recipe", "rating"},
				"extensions": map[string]any{
					"code": "service-unavailable", "status": 503, "service": "ratings",
				},
			})
		}
		if request.OperationName == "RecipeById" && imagesOffline.Load() {
			errors = append(errors, map[string]any{
				"message": "images unavailable",
				"path":    []any{"recipe", "image"},
				"extensions": map[string]any{
					"code": "service-unavailable", "status": 503, "service": "images",
				},
			})
		}
		if request.OperationName == "RecipeById" && tagsOffline.Load() {
			errors = append(errors, map[string]any{
				"message": "tags unavailable",
				"path":    []any{"recipe", "tags"},
				"extensions": map[string]any{
					"code": "service-unavailable", "status": 503, "service": "tags",
				},
			})
		}
		if len(errors) > 0 {
			response["errors"] = errors
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			t.Error(err)
		}
	}))
	defer upstream.Close()
	client := graphql.NewClient(upstream.URL, upstream.Client())
	t.Setenv("PUBLIC_ORIGIN", "https://recipes.example.test")
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
	overviewBody := overview.Body.String()
	if results := strings.Index(overviewBody, `id="browse-results"`); results < 0 ||
		strings.Index(overviewBody, `hx-get="/controls"`) < results {
		t.Fatal("add-recipe control placeholder must follow the recipe results")
	}
	if !strings.Contains(overviewBody, `<header-component hx-get="/identity"`) ||
		strings.Contains(overviewBody, "auth-role") || strings.Contains(overviewBody, `id="browse-identity"`) {
		t.Fatal("public layout must load identity into the header separately")
	}
	for _, role := range []string{"anonymous", "member", "owner"} {
		identityRole.Store(role)
		widget := request("GET", "/identity", "")
		if widget.Code != http.StatusOK || widget.Header().Get("Cache-Control") != "no-store" ||
			strings.TrimSpace(widget.Body.String()) != `<header-component auth-role="`+role+`"></header-component>` {
			t.Fatalf("identity must supply only the header auth state: %s", widget.Body.String())
		}
	}
	t.Setenv("GOOGLE_OAUTH_CLIENT_ID", "test.apps.googleusercontent.com")
	googleHandler := newHandlerWithEndpoint(client, c, upstream.URL)
	identity := httptest.NewRecorder()
	googleHandler.ServeHTTP(identity, httptest.NewRequest("GET", "/identity", nil))
	if got := strings.TrimSpace(identity.Body.String()); got != `<header-component auth-role="owner" auth-enabled></header-component>` {
		t.Fatalf("configured Google auth must be reflected in the identity header: %s", got)
	}
	first := request("GET", "/recipe/42?variant=1", "")
	if first.Code != 200 || !strings.Contains(first.Body.String(), "Original") {
		t.Fatalf("detail failed: %d %s", first.Code, first.Body.String())
	}
	pageHTML := first.Body.String()
	for _, markup := range []string{
		`itemscope itemtype="https://schema.org/Recipe"`,
		`<h1 itemprop="name">Original</h1>`,
		`itemprop="recipeIngredient"`,
		`Rice`,
		`itemprop="recipeInstructions"`,
		`Cook`,
		`itemprop="image"`,
		`itemtype="https://schema.org/AggregateRating"`,
		`itemprop="ratingValue" content="4"`,
		`itemprop="ratingCount" content="2"`,
		`url=https%3A%2F%2Frecipes.example.test%2Frecipe%2F42`,
	} {
		if !strings.Contains(pageHTML, markup) {
			t.Fatalf("anonymous server-rendered detail lacks recipe markup: %s", markup)
		}
	}
	if !strings.Contains(html.UnescapeString(pageHTML), `src="`+imageURL+`"`) {
		t.Fatal("detail did not preserve opaque backend image URL")
	}
	if !strings.Contains(pageHTML, "Zuletzt aktualisiert: vor langer Zeit") {
		t.Fatal("recipe update time must be displayed in German")
	}
	for _, markup := range []string{
		`<title>Original | RezeptDB</title>`,
		`property="og:title" content="Original"`,
		`property="og:type" content="article"`,
		`property="og:image" content="https://cdn.example.test/opaque/full-token.png?signature=abc&amp;version=two"`,
		`property="og:url" content="https://recipes.example.test/recipe/42"`,
		`property="og:description" content="` + siteDescription + `"`,
		`name="description" content="` + siteDescription + `"`,
	} {
		if !strings.Contains(pageHTML, markup) {
			t.Errorf("recipe Open Graph metadata missing %q", markup)
		}
	}
	if strings.Contains(pageHTML, "<h2>Inspirationen</h2>") {
		t.Fatal("shared page must not contain the lazy inspirations heading")
	}
	if !strings.Contains(pageHTML, "/recipe/42/controls") || !strings.Contains(pageHTML, "/recipe/42/inspirations") ||
		strings.Contains(pageHTML, "Rezept bearbeiten") || !strings.Contains(html.UnescapeString(pageHTML), imageURL) ||
		!strings.Contains(pageHTML, "aggregateRating") || strings.Contains(pageHTML, `value="test"`) {
		t.Fatal("shared page does not separate live content or contains user data")
	}
	if !strings.Contains(pageHTML, `hx-get="/recipe/42/tags"`) ||
		strings.Contains(pageHTML, "Tags bearbeiten") || strings.Contains(pageHTML, "data-tag-remove") ||
		strings.Contains(pageHTML, "hx-post") {
		t.Fatal("cached recipe HTML must contain only read-only tag markup and the live tag-fragment placeholder")
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
		widget := request("GET", "/controls", "")
		body := widget.Body.String()
		if widget.Code != 200 || strings.Contains(body, `data-add-recipe`) != online ||
			strings.Contains(body, `role="button"`) != online ||
			strings.Contains(body, `class="outline pointer-events-auto mr-2"`) != online ||
			!strings.Contains(body, `class="sticky bottom-0 z-10 flex justify-end pb-3 pointer-events-none"`) ||
			strings.Contains(body, "Rezept hinzufügen") != online ||
			widget.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("add-recipe control placement or permission gating is incorrect: %s", body)
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
	ratingWidget := request("GET", "/recipe/42/rating", "")
	if body := ratingWidget.Body.String(); ratingWidget.Code != http.StatusOK ||
		strings.Count(body, "<rating-component") != 1 ||
		!strings.Contains(body, `rating="5"`) || !strings.Contains(body, `my-rating="3"`) ||
		strings.Contains(body, "Deine Bewertung") ||
		!strings.Contains(body, `hx-target="#recipe-rating-42"`) {
		t.Fatalf("personalized rating must combine public and own values in one widget: %s", body)
	}
	canRate.Store(false)
	publicRating := request("GET", "/recipe/42/rating", "")
	if body := publicRating.Body.String(); publicRating.Code != http.StatusOK ||
		strings.Count(body, "<rating-component") != 1 || !strings.Contains(body, `rating="5"`) ||
		strings.Contains(body, "my-rating") || strings.Contains(body, "hx-post") {
		t.Fatalf("public rating must retain one non-editable aggregate widget: %s", body)
	}
	canRate.Store(true)
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
		if page.Code != http.StatusOK || page.Header().Get("Cache-Control") != "no-store" ||
			page.Header().Get("ETag") != "" || !strings.Contains(page.Body.String(), "Updated") {
			t.Fatalf("optional outage did not preserve uncached recipe data: %d %v %s", page.Code, page.Header(), page.Body.String())
		}
		head := request("HEAD", "/recipe/42", etag)
		if head.Code != http.StatusOK || head.Header().Get("Cache-Control") != "no-store" ||
			head.Header().Get("ETag") != "" || head.Body.Len() != 0 {
			t.Fatalf("optional outage HEAD response was not uncached: %d %v", head.Code, head.Header())
		}
		offline.Store(false)
		if page := request("GET", "/recipe/42", ""); page.Code != 200 {
			t.Fatal("recovery failed")
		}
	}
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	tagsOffline.Store(true)
	callsBeforeDegraded := recipeCalls.Load()
	degraded := request("GET", "/recipe/42", etag)
	if degraded.Code != http.StatusOK || degraded.Header().Get("Cache-Control") != "no-store" ||
		degraded.Header().Get("ETag") != "" || strings.Contains(degraded.Body.String(), "Tags nicht verfügbar") ||
		strings.Contains(degraded.Body.String(), "recipe-tag--") ||
		!strings.Contains(degraded.Body.String(), "Updated") || recipeCalls.Load() != callsBeforeDegraded+1 {
		t.Fatalf("partial tag failure did not preserve the detail without caching: %d %v %s", degraded.Code, degraded.Header(), degraded.Body.String())
	}
	if next := request("GET", "/recipe/42", ""); next.Code != http.StatusOK ||
		recipeCalls.Load() != callsBeforeDegraded+2 {
		t.Fatal("tag-degraded HTML was inserted into the shared cache")
	}
	tagsOffline.Store(false)
	if recovered := request("GET", "/recipe/42", ""); recovered.Code != http.StatusOK ||
		recovered.Header().Get("ETag") == "" || recipeCalls.Load() != callsBeforeDegraded+3 {
		t.Fatal("tag display did not recover to cacheable HTML")
	}
	hasImage.Store(false)
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	imageMissing := request("GET", "/recipe/42", "")
	if imageMissing.Code != http.StatusOK ||
		!strings.Contains(imageMissing.Body.String(), `property="og:image" content="https://recipes.example.test/design/og-image.svg"`) {
		t.Fatalf("missing recipe image did not use the site fallback: %s", imageMissing.Body.String())
	}
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	hasImage.Store(true)
	deleted.Store(true)
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{"GET", "HEAD"} {
		page := request(method, "/recipe/42", etag)
		assertStyledErrorPage(t, page, http.StatusNotFound, "Rezept nicht gefunden | RezeptDB", "Rezept nicht gefunden.", method == "HEAD")
	}
}
