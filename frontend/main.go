package main

import (
	"log"
	"net/http"
	"strconv"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"

	"frontend/src/components"
	gql "frontend/src/generated"
)

var client = graphql.NewClient("http://traefik/graphql", http.DefaultClient)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp, err := gql.Overview(client)
		if err != nil {
			log.Printf("failed to fetch overview: %v", err)
			http.Error(w, "failed to fetch recipes", http.StatusInternalServerError)
			return
		}
		ctx := templ.WithChildren(r.Context(), components.Overview(resp))
		templ.Handler(components.Layout("Alle Rezepte | RezeptDB")).ServeHTTP(w, r.WithContext(ctx))
	})

	http.HandleFunc("/recipe/{id}/rate", func(w http.ResponseWriter, r *http.Request) {
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
		resp, err := gql.RateRecipe(client, id, ratingInt, login)
		if err != nil {
			log.Printf("failed to rate recipe: %v", err)
			http.Error(w, "failed to rate recipe", http.StatusInternalServerError)
			return
		}
		templ.Handler(components.Rating(resp.Rate, true)).ServeHTTP(w, r)
	})

	http.HandleFunc("/recipe/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		resp, err := gql.RecipeById(client, id)
		if err != nil {
			log.Printf("failed to fetch recipe: %v", err)
			http.Error(w, "failed to fetch recipe", http.StatusInternalServerError)
			return
		}
		ctx := templ.WithChildren(r.Context(), components.Detail(resp))
		templ.Handler(components.Layout(resp.Recipe.Name+" | RezeptDB")).ServeHTTP(w, r.WithContext(ctx))
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Println("Listening on :3000")
	log.Fatal(http.ListenAndServe(":3000", nil))
}
