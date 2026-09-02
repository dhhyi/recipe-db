package main

import (
	"log"
	"net/http"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"

	"frontend/src/components"
	gql "frontend/src/generated"
)

var client = graphql.NewClient("http://apollo:4000/graphql", http.DefaultClient)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp, err := gql.Overview(client)
		if err != nil {
			http.Error(w, "failed to fetch recipes", http.StatusInternalServerError)
			return
		}
		ctx := templ.WithChildren(r.Context(), components.Overview(resp))
		templ.Handler(components.Layout("RezeptDB - Alle Rezepte")).ServeHTTP(w, r.WithContext(ctx))
	})

	http.HandleFunc("/recipe/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		resp, err := gql.RecipeById(client, id)
		if err != nil {
			http.Error(w, "failed to fetch recipe", http.StatusInternalServerError)
			return
		}
		ctx := templ.WithChildren(r.Context(), components.Detail(resp))
		templ.Handler(components.Layout("RezeptDB - "+resp.Recipe.Name)).ServeHTTP(w, r.WithContext(ctx))
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Println("Listening on :3000")
	log.Fatal(http.ListenAndServe(":3000", nil))
}
