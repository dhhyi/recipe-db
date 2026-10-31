package components

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	gql "frontend/src/generated"
	"github.com/a-h/templ"
)

func TestOrderedTagsUsesCategoryFoldedNameAndID(t *testing.T) {
	tags := orderedTags([]gql.RecipeTag{
		{Id: "course", Category: gql.TagCategoryCourse, Name: "Dessert"},
		{Id: "z", Category: gql.TagCategoryCuisine, Name: "ÉCLAIR"},
		{Id: "dietary", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
		{Id: "a", Category: gql.TagCategoryCuisine, Name: "e\u0301clair"},
	})
	ids := make([]string, len(tags))
	for i, tag := range tags {
		ids[i] = tag.Id
	}
	if want := []string{"a", "z", "dietary", "course"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("unexpected stable tag order: %v", ids)
	}
}

func renderTagComponent(t *testing.T, component templ.Component) string {
	t.Helper()
	var body bytes.Buffer
	if err := component.Render(t.Context(), &body); err != nil {
		t.Fatal(err)
	}
	return body.String()
}

func TestRecipeTagsWidgetPermissionAndKeyboardMarkup(t *testing.T) {
	tags := []gql.RecipeTag{{Id: "vegan", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"}}
	for _, testCase := range []struct {
		name               string
		owner, edit, empty bool
		want               []string
		unwant             []string
	}{
		{
			name:   "public",
			want:   []string{"Vegan", `aria-label="Ernährungsweise: Vegan"`},
			unwant: []string{"Tags bearbeiten", "Tag hinzufügen", "entfernen", "hx-post"},
		},
		{
			name:   "owner read mode",
			owner:  true,
			want:   []string{"Tags bearbeiten", "Vegan"},
			unwant: []string{"Tag hinzufügen", "hx-post"},
		},
		{
			name:   "empty owner read mode",
			owner:  true,
			empty:  true,
			want:   []string{"Tags bearbeiten"},
			unwant: []string{"Kategorisierte Tags", "Tag-Kategorien", "recipe-tags-detail"},
		},
		{
			name:   "owner edit mode",
			owner:  true,
			edit:   true,
			want:   []string{`<section aria-label="Tag hinzufügen"`, `for="recipe-tag-search"`, `type="search"`, `name="q"`, `delay:300ms`, `compositionstart`, `class="recipe-tag-remove"`, `Vegan entfernen`, "×", "Fertig", "Tag-Zuordnung wird gespeichert", "aria-live"},
			unwant: []string{"recipe-editor", "Save", "Discard", `name="edit"`, "<details", "<summary", "data-tag-summary"},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			widgetTags := tags
			if testCase.empty {
				widgetTags = nil
			}
			body := renderTagComponent(t, RecipeTagsWidget("42", widgetTags, testCase.owner, testCase.edit, "", false))
			for _, text := range testCase.want {
				if !strings.Contains(body, text) {
					t.Errorf("missing %q in %s", text, body)
				}
			}
			for _, text := range testCase.unwant {
				if strings.Contains(body, text) {
					t.Errorf("unexpected %q in %s", text, body)
				}
			}
		})
	}
}

func TestTagOptionsUseOneContinuousListAndEmptyInventoryIsExplicit(t *testing.T) {
	tags := []gql.RecipeTag{
		{Id: "course", Category: gql.TagCategoryCourse, Name: "Suppe"},
		{Id: "cuisine", Category: gql.TagCategoryCuisine, Name: "Ägyptisch"},
		{Id: "dietary", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
	}
	body := renderTagComponent(t, TagOptions("42", "", tags))
	if strings.Count(body, "<ul") != 1 || strings.Count(body, "<li>") != len(tags) ||
		strings.Contains(body, "<fieldset") || strings.Contains(body, "<legend") ||
		strings.Contains(body, "Küche") || strings.Contains(body, "Ernährungsweise") || strings.Contains(body, "Gang") {
		t.Fatalf("options must use one continuous list without category headings: %s", body)
	}
	if cuisine, dietary, course := strings.Index(body, "Ägyptisch"), strings.Index(body, "Vegan"), strings.Index(body, "Suppe"); !(cuisine < dietary && dietary < course) {
		t.Fatalf("options must preserve stable tag order: %s", body)
	}
	if strings.Contains(renderTagComponent(t, TagOptions("42", "", nil)), "Tag-Auswahl konnte") ||
		!strings.Contains(renderTagComponent(t, TagOptions("42", "", nil)), "Keine passenden Tags gefunden.") {
		t.Fatal("an empty search result must be distinct from an inventory failure")
	}
}

func TestTagOptionsPreserveAndEscapeSearchForEnterGuard(t *testing.T) {
	body := renderTagComponent(t, TagOptions("42", ` Vegan "& `, []gql.RecipeTag{
		{Id: "vegan", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
	}))
	if !strings.Contains(body, `data-query=" Vegan &#34;&amp; "`) {
		t.Fatalf("the Enter guard must receive the escaped, untrimmed search: %s", body)
	}
}

func TestRecipeDetailTagsStayReadOnlyAndLoadPermissionAwareFragment(t *testing.T) {
	body := renderTagComponent(t, recipeDetailTags("42", []gql.RecipeTag{
		{Id: "vegan", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
	}))
	if !strings.Contains(body, `hx-get="/recipe/42/tags"`) ||
		!strings.Contains(body, `aria-label="Ernährungsweise: Vegan"`) ||
		strings.Contains(body, "Tags bearbeiten") || strings.Contains(body, "data-tag-remove") ||
		strings.Contains(body, "hx-post") {
		t.Fatalf("cached detail tags must stay read-only and refresh through the tags fragment: %s", body)
	}
}
