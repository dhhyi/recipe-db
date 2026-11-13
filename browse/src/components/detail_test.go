package components

import (
	"encoding/json"
	"html"
	"net/url"
	"regexp"
	"strings"
	"testing"

	gql "frontend/src/generated"
)

func TestRecipeImagesShareUniqueCSSSafeTransitionNames(t *testing.T) {
	imageTag := regexp.MustCompile(`<img\b[^>]*>`)
	transitionStyle := regexp.MustCompile(`style="view-transition-name:\s*(recipe-image-[0-9a-f]+);?"`)
	seen := map[string]bool{}
	for _, id := range []string{"42", "recipe-42", "recipe_42", "ä/42", `42"; color: red; --x: "`} {
		tile := renderTagComponent(t, recipeTile(gql.RecipeStub{
			Id: id, Name: "Kuchen",
			Image: &gql.RecipeStubImageImageMetadata{ThumbUrl: "/thumb.png"},
		}, false))
		hero := renderTagComponent(t, image(&gql.RecipeDetail{
			Id: id, Name: "Kuchen",
			Image: &gql.RecipeDetailImageImageMetadata{Url: "/full.png"},
		}))
		thumbnailName := transitionStyle.FindStringSubmatch(imageTag.FindString(tile))
		heroName := transitionStyle.FindStringSubmatch(imageTag.FindString(hero))
		if len(thumbnailName) != 2 || len(heroName) != 2 || thumbnailName[1] != heroName[1] {
			t.Fatalf("recipe %q must match its thumbnail and hero with CSS-safe names: tile=%s hero=%s", id, tile, hero)
		}
		if seen[thumbnailName[1]] {
			t.Fatalf("different recipe IDs must not share transition name %q", thumbnailName[1])
		}
		seen[thumbnailName[1]] = true
	}

	withoutImage := renderTagComponent(t, recipeTile(gql.RecipeStub{Id: "42", Name: "Kuchen"}, false))
	if strings.Contains(withoutImage, "view-transition-name") {
		t.Fatal("an imageless tile must not claim an image transition")
	}
}

func TestRecipeRatingsKeepTransitionOutsideLiveWidget(t *testing.T) {
	ratingName := regexp.MustCompile(`view-transition-name:\s*(recipe-rating-[0-9a-f]+)`)
	seen := map[string]bool{}
	for _, id := range []string{"42", "recipe_42", `42"; color: red; --x: "`} {
		rating := &gql.Rating{RecipeId: id}
		tile := renderTagComponent(t, recipeTile(gql.RecipeStub{Id: id, Name: "Kuchen", Rating: rating}, true))
		detail := renderTagComponent(t, Detail(&gql.RecipeByIdResponse{
			Recipe: &gql.RecipeDetail{Id: id, Name: "Kuchen", Rating: rating},
		}, ""))
		widget := renderTagComponent(t, RecipeRatingWidget(id, rating, false, nil))
		tileName := ratingName.FindStringSubmatch(tile)
		detailName := ratingName.FindStringSubmatch(detail)
		if len(tileName) != 2 || len(detailName) != 2 || tileName[1] != detailName[1] {
			t.Fatalf("rating transition must pair tile and detail for %q", id)
		}
		if ratingName.MatchString(widget) {
			t.Fatal("live widget replacement must not remove or recreate the captured transition element")
		}
		stableWrapper := regexp.MustCompile(`style="view-transition-name:\s*` + detailName[1] + `;?"><div id="recipe-rating-`)
		if !stableWrapper.MatchString(detail) {
			t.Fatal("detail rating transition must wrap, not belong to, the live widget")
		}
		if seen[tileName[1]] {
			t.Fatalf("different recipes share rating transition name %q", tileName[1])
		}
		seen[tileName[1]] = true
	}
}

func TestRecipeTileTransitionIdentitiesSurviveReorderingAndFiltering(t *testing.T) {
	recipes := []gql.RecipeStub{
		{Id: "42"}, {Id: "recipe_42"}, {Id: `42"; color: red; --x: "`},
	}
	tileStyle := regexp.MustCompile(`data-recipe-id="([^"]*)" style="--recipe-tile-transition-name:\s*(recipe-tile-[0-9a-f]+);?"`)
	identities := map[string]string{}
	seen := map[string]bool{}
	for _, results := range [][]gql.RecipeStub{recipes, {recipes[2], recipes[0], recipes[1]}, {recipes[1]}} {
		body := renderTagComponent(t, BrowseResults(BrowseState{Recipes: results}, true))
		matches := tileStyle.FindAllStringSubmatch(body, -1)
		if len(matches) != len(results) {
			t.Fatal("every tile must provide a CSS-safe transition identity")
		}
		for _, match := range matches {
			id, name := html.UnescapeString(match[1]), match[2]
			if previous, ok := identities[id]; ok {
				if previous != name {
					t.Fatalf("recipe %q changed identity after reordering or filtering", id)
				}
			} else {
				if seen[name] {
					t.Fatalf("different recipes share tile transition name %q", name)
				}
				identities[id], seen[name] = name, true
			}
		}
	}
}

func TestBringIngredientFooter(t *testing.T) {
	var response gql.RecipeByIdResponse
	if err := json.Unmarshal([]byte(`{"recipe":{"id":"42","name":"Kuchen","ingredients":[
		{"amount":"200","unit":"g","name":"Mehl"},
		{"amount":"2","name":"Eier"},
		{"amount":"0,5","unit":"TL","name":"Salz & Pfeffer","optional":true}
	]}}`), &response); err != nil {
		t.Fatal(err)
	}
	publicURL := "https://recipes.example.test/recipe/42"
	body := renderTagComponent(t, Detail(&response, publicURL))
	if !strings.Contains(body, `class="grid grid-cols-1 gap-3 md:grid-cols-2"`) {
		t.Errorf("recipe detail with ingredients must use two columns from md onward: %s", body)
	}
	for _, markup := range []string{
		`</tbody><tfoot>`,
		`colspan="2"`,
		`class="flex justify-end pt-4"`,
		`Auf die Einkaufsliste</a>`,
	} {
		if !strings.Contains(body, markup) {
			t.Errorf("missing footer markup %q in %s", markup, body)
		}
	}
	for _, obsolete := range []string{"bring-import-component", "data-bring", "<iframe", `role="button"`, "widgets/import.js"} {
		if strings.Contains(body, obsolete) {
			t.Errorf("plain import link must not contain %q", obsolete)
		}
	}
	link := regexp.MustCompile(`<a href="(https://api.getbring.com/[^"]+)"`).FindStringSubmatch(body)
	if len(link) != 2 {
		t.Fatalf("missing no-JavaScript import link: %s", body)
	}
	deeplink, err := url.Parse(html.UnescapeString(link[1]))
	if err != nil {
		t.Fatal(err)
	}
	query := deeplink.Query()
	if deeplink.Path != "/rest/bringrecipes/deeplink" || query.Get("url") != publicURL ||
		query.Get("source") != "web" || query.Get("baseQuantity") != "4" || query.Get("requestedQuantity") != "4" {
		t.Fatalf("incorrect import destination or scaling: %s", deeplink)
	}
	rows := regexp.MustCompile(`(?s)<tr itemprop="recipeIngredient">(.*?)</tr>`).FindAllStringSubmatch(body, -1)
	if len(rows) != 3 {
		t.Fatalf("expected one structured row per ingredient: %s", body)
	}
	tags := regexp.MustCompile(`<[^>]+>`)
	for index, want := range []string{"200 g Mehl", "2 Eier", "0,5 TL (optional) Salz & Pfeffer"} {
		text := strings.Join(strings.Fields(html.UnescapeString(tags.ReplaceAllString(rows[index][1], " "))), " ")
		if text != want {
			t.Errorf("ingredient %d: got %q, want %q", index, text, want)
		}
	}
	if strings.Contains(body, "recipeYield") {
		t.Fatal("recipes without a yield must not invent one")
	}

	response.Recipe.Ingredients = nil
	empty := renderTagComponent(t, Detail(&response, publicURL))
	if strings.Contains(empty, "bring") || strings.Contains(empty, "<tfoot>") {
		t.Fatalf("empty recipe must not offer an import: %s", empty)
	}
}
