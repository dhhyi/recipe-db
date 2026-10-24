package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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

func renderRecipe(ctx context.Context, client graphql.Client, id string) ([]byte, error) {
	resp, err := gql.RecipeById(ctx, client, id)
	if err != nil {
		return nil, err
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
	return html.Bytes(), nil
}

func newHandler(client graphql.Client, cache *pageCache) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", browseHandler(client))

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

		login := "test"
		resp, err := gql.RateRecipe(r.Context(), client, id, ratingInt, login)
		if err != nil {
			log.Printf("failed to rate recipe: %v", err)
			http.Error(w, "failed to rate recipe", http.StatusInternalServerError)
			return
		}
		if err := cache.invalidate(id); err != nil {
			log.Printf("failed to invalidate rated recipe: %v", err)
			http.Error(w, "rating saved but cache invalidation failed", http.StatusInternalServerError)
			return
		}
		templ.Handler(components.Rating(&resp.Rate, true, nil)).ServeHTTP(w, r)
	})

	mux.HandleFunc("/recipe/{id}/controls", func(w http.ResponseWriter, r *http.Request) {
		resp, err := gql.RecipeControls(r.Context(), client)
		if err != nil {
			log.Printf("failed to fetch recipe controls: %v", err)
			http.Error(w, "failed to fetch recipe controls", http.StatusInternalServerError)
			return
		}
		templ.Handler(components.RecipeControls(r.PathValue("id"), resp)).ServeHTTP(w, r)
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

	mux.HandleFunc("GET /recipe/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		w.Header().Set("Cache-Control", "private, no-cache")
		page, err := cache.get(r.Context(), id)
		if err != nil {
			log.Printf("failed to fetch recipe: %v", err)
			if errors.Is(err, errRecipeNotFound) {
				http.Error(w, "recipe not found", http.StatusNotFound)
				return
			}
			http.Error(w, "failed to fetch recipe", http.StatusInternalServerError)
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
	client := graphql.NewClient("http://traefik/graphql", &http.Client{Timeout: 10 * time.Second})
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
	server := &http.Server{Addr: ":3000", Handler: newHandler(client, cache), ReadHeaderTimeout: 5 * time.Second}
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
