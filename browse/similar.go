package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"mime"
	"net/http"
	"strings"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"
	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"

	"frontend/src/components"
	gql "frontend/src/generated"
)

func validSimilarRecipeID(id string) bool {
	if id == "" {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func similarRecipeQueue(source string, ids []string) ([]string, error) {
	seen := map[string]bool{source: true}
	queue := make([]string, 0, len(ids))
	for _, id := range ids {
		if !validSimilarRecipeID(id) {
			return nil, fmt.Errorf("invalid similar recipe ID")
		}
		if !seen[id] {
			seen[id] = true
			queue = append(queue, id)
		}
	}
	return queue, nil
}

func inaccessibleSimilarRecipe(err error) bool {
	var list gqlerror.List
	if !errors.As(err, &list) || len(list) == 0 {
		return false
	}
	for _, item := range list {
		if item == nil || len(item.Path) != 1 || item.Path[0] != ast.PathName("recipe") {
			return false
		}
		switch item.Extensions["code"] {
		case "recipe-not-found", "forbidden":
		default:
			return false
		}
	}
	return true
}

// Work on a private cursor: an outage discards every card and leaves the
// caller's original queue intact for an atomic retry.
func hydrateSimilarRecipes(ctx context.Context, client graphql.Client, queue []string) ([]gql.RecipeStub, []string, error) {
	cards := make([]gql.RecipeStub, 0, 3)
	for len(queue) > 0 && len(cards) < 3 {
		id := queue[0]
		queue = queue[1:]
		response, err := gql.SimilarRecipeCard(ctx, client, id)
		if inaccessibleSimilarRecipe(err) {
			continue
		}
		if err != nil && !optionalServiceErrors(err) {
			return nil, nil, err
		}
		if response == nil {
			return nil, nil, errors.New("empty similar recipe response")
		}
		if response.Recipe == nil {
			if err != nil {
				return nil, nil, err
			}
			continue
		}
		if response.Recipe.Id != id || strings.TrimSpace(response.Recipe.Name) == "" {
			return nil, nil, errors.New("invalid similar recipe card")
		}
		cards = append(cards, *response.Recipe)
	}
	return cards, queue, nil
}

func similarRecipesHandler(endpoint string, more bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Del("ETag")
		id := r.PathValue("id")
		if !validSimilarRecipeID(id) || r.URL.RawQuery != "" {
			http.Error(w, "invalid similar recipe request", http.StatusBadRequest)
			return
		}
		var queue []string
		var err error
		if more {
			if !sameOriginRequest(r) {
				http.Error(w, "cross-origin request rejected", http.StatusForbidden)
				return
			}
			contentType, _, parseErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if parseErr != nil || contentType != "application/x-www-form-urlencoded" {
				http.Error(w, "invalid form content type", http.StatusBadRequest)
				return
			}
			// ParseForm retains net/http's existing 10 MiB URL-encoded body limit;
			// there is deliberately no candidate-count cap.
			if err := r.ParseForm(); err != nil {
				http.Error(w, "invalid similar recipe form", http.StatusBadRequest)
				return
			}
			if len(r.PostForm) != 1 || len(r.PostForm["remainingId"]) == 0 {
				http.Error(w, "missing remaining recipe IDs", http.StatusBadRequest)
				return
			}
			queue, err = similarRecipeQueue(id, r.PostForm["remainingId"])
			if err != nil {
				http.Error(w, "invalid remaining recipe IDs", http.StatusBadRequest)
				return
			}
		}
		client, _ := requestScopedClient(endpoint, r, w)
		if !more {
			response, fetchErr := gql.SimilarRecipeIds(r.Context(), client, id)
			err = fetchErr
			if err == nil {
				if response == nil || response.SimilarRecipeIds == nil {
					err = errors.New("empty similar recipe IDs response")
				} else {
					queue, err = similarRecipeQueue(id, response.SimilarRecipeIds)
				}
			}
		}
		var cards []gql.RecipeStub
		remaining := queue
		if err == nil {
			cards, remaining, err = hydrateSimilarRecipes(r.Context(), client, queue)
		}
		if err != nil {
			log.Printf("failed to load similar recipes: %v", err)
			cards, remaining = nil, queue
		}
		var component templ.Component
		if more {
			component = components.SimilarRecipesBatch(id, cards, remaining, err != nil)
		} else {
			component = components.SimilarRecipes(id, cards, remaining, err != nil)
		}
		var body bytes.Buffer
		if err := component.Render(r.Context(), &body); err != nil {
			http.Error(w, "failed to render similar recipes", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if r.Method != http.MethodHead {
			if _, err := w.Write(body.Bytes()); err != nil {
				log.Printf("failed to serve similar recipes: %v", err)
			}
		}
	}
}
