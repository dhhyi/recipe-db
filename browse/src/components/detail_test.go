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
	if !strings.Contains(empty, `class="grid grid-cols-1 gap-3"`) || strings.Contains(empty, "md:grid-cols-2") {
		t.Errorf("recipe detail without ingredients must not create an empty second column: %s", empty)
	}
}
