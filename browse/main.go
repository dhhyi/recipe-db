package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"

	"frontend/src/components"
	gql "frontend/src/generated"
)

const graphqlEndpoint = "http://traefik/graphql"

var errTagsUnavailable = errors.New("recipe tags unavailable")

func renderRecipe(ctx context.Context, client graphql.Client, id string) ([]byte, error) {
	resp, err := gql.RecipeById(ctx, client, id)
	tagsOnly := tagErrorsOnly(err)
	if err != nil && !tagsOnly {
		return nil, err
	}
	if resp == nil {
		return nil, errors.New("empty recipe response")
	}
	if resp.Recipe == nil {
		return nil, errRecipeNotFound
	}
	if resp.Recipe.Rating == nil {
		return nil, errors.New("ratings service unavailable; refusing to cache incomplete recipe")
	}
	ctx = templ.WithChildren(ctx, components.Detail(resp))
	var html bytes.Buffer
	if err := components.Layout(resp.Recipe.Name+" | RezeptDB").Render(ctx, &html); err != nil {
		return nil, err
	}
	if resp.Recipe.Tags == nil || err != nil {
		return html.Bytes(), errTagsUnavailable
	}
	return html.Bytes(), nil
}

func writeErrorPage(w http.ResponseWriter, r *http.Request, status int, title, message string) {
	ctx := templ.WithChildren(r.Context(), components.ErrorContent(message))
	var body bytes.Buffer
	if err := components.Layout(title).Render(ctx, &body); err != nil {
		log.Printf("failed to render error page: %v", err)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Del("ETag")
		w.WriteHeader(http.StatusInternalServerError)
		if r.Method != http.MethodHead {
			if _, writeErr := io.WriteString(w, "failed to render error page\n"); writeErr != nil {
				log.Printf("failed to serve error rendering failure: %v", writeErr)
			}
		}
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Del("ETag")
	if r.Header.Get("HX-Boosted") == "true" || r.Header.Get("HX-History-Restore-Request") == "true" {
		w.Header().Set("X-Browse-Full-Page-Error", "true")
		w.Header().Set("HX-Retarget", "main")
		w.Header().Set("HX-Reswap", "innerHTML")
		w.Header().Set("HX-Reselect", "main > *")
	}
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		if _, err := w.Write(body.Bytes()); err != nil {
			log.Printf("failed to serve error page: %v", err)
		}
	}
}

func writeRatingDeniedPage(w http.ResponseWriter, r *http.Request, status int) {
	ctx := templ.WithChildren(r.Context(), components.RatingDeniedPage(status))
	var body bytes.Buffer
	if err := components.Layout("Bewertung nicht möglich | RezeptDB").Render(ctx, &body); err != nil {
		http.Error(w, "Bewertung nicht möglich", http.StatusForbidden)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Del("ETag")
	if r.Header.Get("HX-Request") == "true" || r.Header.Get("HX-Boosted") == "true" ||
		r.Header.Get("HX-History-Restore-Request") == "true" {
		w.Header().Set("X-Browse-Full-Page-Error", "true")
		w.Header().Set("HX-Retarget", "main")
		w.Header().Set("HX-Reswap", "innerHTML")
		w.Header().Set("HX-Reselect", "main > *")
	}
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		if _, err := w.Write(body.Bytes()); err != nil {
			log.Printf("failed to serve rating denial: %v", err)
		}
	}
}

func tagRouteAllowedMethods(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 3 || parts[0] != "recipe" || parts[1] == "" || parts[2] != "tags" {
		return ""
	}
	switch {
	case len(parts) == 3:
		return "GET, HEAD, POST"
	case len(parts) == 4 && parts[3] == "options":
		return "GET, HEAD"
	case len(parts) == 5 && parts[4] == "remove" && parts[3] != "":
		return "POST"
	default:
		return ""
	}
}

func ratingAuthorizationStatus(err error, upstreamStatus int) int {
	if upstreamStatus == http.StatusUnauthorized || upstreamStatus == http.StatusForbidden {
		return upstreamStatus
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "authentication required"),
		strings.Contains(message, "invalid credentials"):
		return http.StatusUnauthorized
	case strings.Contains(message, "forbidden"),
		strings.Contains(message, "cross-origin mutation rejected"):
		return http.StatusForbidden
	default:
		return 0
	}
}

func newHandler(client graphql.Client, cache *pageCache) http.Handler {
	return newHandlerWithEndpoint(client, cache, graphqlEndpoint)
}

func newHandlerWithEndpoint(client graphql.Client, cache *pageCache, endpoint string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", browseHandler(client))
	mux.HandleFunc("GET /recipe/{id}/tags", recipeTagsHandler(endpoint))
	mux.HandleFunc("GET /recipe/{id}/tags/options", recipeTagOptionsHandler(endpoint))
	mux.HandleFunc("POST /recipe/{id}/tags", recipeTagMutationHandler(endpoint, cache, false))
	mux.HandleFunc("POST /recipe/{id}/tags/{tagId}/remove", recipeTagMutationHandler(endpoint, cache, true))

	mux.HandleFunc("/recipe/{id}/rate", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOriginRequest(r) {
			http.Error(w, "cross-origin request rejected", http.StatusForbidden)
			return
		}
		rating := r.FormValue("rating")
		if rating == "" {
			http.Error(w, "missing rating", http.StatusBadRequest)
			return
		}
		ratingInt, err := strconv.Atoi(rating)
		if err != nil {
			http.Error(w, "invalid rating", http.StatusBadRequest)
			return
		}

		client, upstreamStatus := requestScopedClient(endpoint, r, w)
		resp, err := gql.RateRecipe(r.Context(), client, id, ratingInt)
		if err != nil {
			log.Printf("failed to rate recipe: %v", err)
			if status := ratingAuthorizationStatus(err, *upstreamStatus); status != 0 {
				writeRatingDeniedPage(w, r, status)
			} else {
				writeErrorPage(w, r, http.StatusBadGateway, "Bewertung nicht möglich | RezeptDB", "Die Bewertung konnte derzeit nicht gespeichert werden.")
			}
			return
		}
		if err := cache.invalidate(id); err != nil {
			log.Printf("failed to invalidate rated recipe: %v", err)
			http.Error(w, "rating saved but cache invalidation failed", http.StatusInternalServerError)
			return
		}
		templ.Handler(components.RecipeRatingWidget(id, &resp.Rate.Rating, true, resp.Rate.MyRating)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/recipe/{id}/controls", func(w http.ResponseWriter, r *http.Request) {
		client, _ := requestScopedClient(endpoint, r, w)
		resp, err := gql.RecipeControls(r.Context(), client)
		if err != nil {
			log.Printf("failed to fetch recipe controls: %v", err)
			w.WriteHeader(http.StatusOK)
			return
		}
		templ.Handler(components.RecipeControls(r.PathValue("id"), resp)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/recipe/{id}/rating", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		client, _ := requestScopedClient(endpoint, r, w)
		capabilities, err := gql.RatingCapabilities(r.Context(), client, id)
		if err != nil {
			log.Printf("failed to fetch rating capabilities: %v", err)
			templ.Handler(components.RecipeRatingUnavailable()).ServeHTTP(w, r)
			return
		}
		if !capabilities.MyCapabilities.CanRate {
			templ.Handler(components.RecipeRatingWidget(id, &capabilities.Rating, false, nil)).ServeHTTP(w, r)
			return
		}
		client, _ = requestScopedClient(endpoint, r, w)
		resp, err := gql.RecipeRating(r.Context(), client, id)
		if err != nil {
			log.Printf("failed to fetch own rating: %v", err)
			templ.Handler(components.RecipeRatingUnavailable()).ServeHTTP(w, r)
			return
		}
		templ.Handler(components.RecipeRatingControls(id, resp)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/recipe/{id}/inspirations", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		resp, err := gql.RecipeInspirations(r.Context(), client, id)
		if err != nil {
			log.Printf("failed to fetch recipe inspirations: %v", err)
			http.Error(w, "failed to fetch recipe inspirations", http.StatusInternalServerError)
			return
		}
		templ.Handler(components.InspirationsLazy(resp)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/controls", func(w http.ResponseWriter, r *http.Request) {
		client, _ := requestScopedClient(endpoint, r, w)
		resp, err := gql.BrowseControls(r.Context(), client)
		if err != nil {
			log.Printf("failed to fetch browse controls: %v", err)
			w.WriteHeader(http.StatusOK)
			return
		}
		templ.Handler(components.BrowseControls(resp)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/identity", func(w http.ResponseWriter, r *http.Request) {
		client, _ := requestScopedClient(endpoint, r, w)
		resp, err := gql.BrowseIdentity(r.Context(), client)
		if err != nil {
			log.Printf("failed to fetch browse identity: %v", err)
			templ.Handler(components.BrowseIdentityUnavailable()).ServeHTTP(w, r)
			return
		}
		templ.Handler(components.BrowseIdentity(resp)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /recipe/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		w.Header().Set("Cache-Control", "private, no-store")
		page, err := cache.get(r.Context(), id)
		if err != nil {
			if errors.Is(err, errTagsUnavailable) {
				w.Header().Set("Cache-Control", "no-store")
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.Header().Del("ETag")
				w.WriteHeader(http.StatusOK)
				if r.Method != http.MethodHead {
					if _, writeErr := w.Write(page.html); writeErr != nil {
						log.Printf("failed to serve degraded recipe: %v", writeErr)
					}
				}
				return
			}
			log.Printf("failed to fetch recipe: %v", err)
			if errors.Is(err, errRecipeNotFound) {
				writeErrorPage(w, r, http.StatusNotFound, "recipe not found | RezeptDB", "recipe not found")
				return
			}
			writeErrorPage(w, r, http.StatusInternalServerError, "failed to fetch recipe | RezeptDB", "failed to fetch recipe")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("ETag", page.etag)
		for _, tag := range strings.Split(r.Header.Get("If-None-Match"), ",") {
			tag = strings.TrimSpace(tag)
			if tag == "*" || strings.TrimPrefix(tag, "W/") == page.etag {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(page.html)))
		if r.Method != http.MethodHead {
			if _, err := w.Write(page.html); err != nil {
				log.Printf("failed to serve cached recipe: %v", err)
			}
		}
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if allowed := tagRouteAllowedMethods(r.URL.EscapedPath()); allowed != "" {
				w.Header().Set("Allow", allowed)
				http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
				return
			}
			id := strings.TrimPrefix(r.URL.Path, "/recipe/")
			if r.URL.Path == "/" || id != r.URL.Path && id != "" && !strings.Contains(id, "/") {
				w.Header().Set("Allow", "GET, HEAD")
				http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
				return
			}
			http.NotFound(w, r)
			return
		}
		writeErrorPage(w, r, http.StatusNotFound, "page not found | RezeptDB", "page not found")
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}

func run() error {
	url := os.Getenv("NATS_URL")
	if url == "" {
		return errors.New("NATS_URL environment variable not set")
	}
	client := graphql.NewClient(graphqlEndpoint, &http.Client{Timeout: 10 * time.Second})
	cache, err := newPageCache(cacheDir, cacheTTL, cacheMaxBytes, func(ctx context.Context, id string) ([]byte, error) {
		return renderRecipe(ctx, client, id)
	})
	if err != nil {
		return fmt.Errorf("initialize HTML cache: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	busDone := make(chan struct{})
	go func() {
		defer close(busDone)
		cache.watchEvents(ctx, url)
	}()
	server := &http.Server{Addr: ":3000", Handler: newHandlerWithEndpoint(client, cache, graphqlEndpoint), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("failed to shut down browse: %v", err)
		}
	}()
	log.Println("Listening on :3000")
	err = server.ListenAndServe()
	stop()
	<-busDone
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
