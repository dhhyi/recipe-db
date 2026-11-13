package components

import (
	"bytes"
	"net/url"
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

func TestTagSearchFilterEscapesIDsAndIdentifiesOnlyOneCanonicalTag(t *testing.T) {
	for _, id := range []string{"vegan", `tag"\\id`, "tag/+&? space"} {
		filter := TagSearchFilter(id)
		got, ok := TagSearchFilterID(filter)
		if !ok || got != id {
			t.Fatalf("tag filter did not round-trip %q: %q, %t", id, got, ok)
		}
		values := url.Values{"filter_by": {filter}}
		parsed, err := url.ParseQuery(values.Encode())
		if err != nil || parsed.Get("filter_by") != filter {
			t.Fatalf("filter URL did not preserve %q: %v, %v", filter, parsed, err)
		}
	}
	for _, filter := range []string{
		`tag_ids:="vegan" && tag_ids:="vegetarian"`,
		`category:="main course"`,
		`tag_ids:=vegan`,
	} {
		if _, ok := TagSearchFilterID(filter); ok {
			t.Fatalf("non-single-tag filter was classified as a tag label: %q", filter)
		}
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
			want:   []string{"Vegan", `aria-label="Ernährungsweise: Vegan"`, `href="/?filter_by=tag_ids%3A%3D%22vegan%22"`},
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
			want:   []string{`<section aria-label="Tag hinzufügen"`, `id="recipe-tag-search"`, `type="search"`, `name="q"`, `placeholder="Tag suchen"`, `aria-label="Tag suchen"`, `delay:300ms`, `compositionstart`, `aria-label="Verfügbare Tags werden geladen"`, `class="outline"`, `class="recipe-tag-remove"`, `Vegan entfernen`, "×", "Fertig", "aria-live"},
			unwant: []string{"recipe-editor", "Save", "Discard", `name="edit"`, "<details", "<summary", "data-tag-summary", "Tag-Zuordnung wird gespeichert", `<label for="recipe-tag-search">`, `id="recipe-tags" class="contents" hx-sync="this:replace" aria-busy`, `href="/?filter_by=`},
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

func TestRecipeTagFeedbackUsesSemanticFeedbackClasses(t *testing.T) {
	success := renderTagComponent(t, RecipeTagsWidget("42", nil, false, false, "Tags gespeichert.", false))
	if !strings.Contains(success, `class="feedback success"`) {
		t.Fatalf("successful tag feedback must use the success style: %s", success)
	}

	failure := renderTagComponent(t, RecipeTagsWidget("42", nil, false, false, "Tags konnten nicht gespeichert werden.", true))
	if !strings.Contains(failure, `class="feedback error"`) {
		t.Fatalf("failed tag feedback must use the error style: %s", failure)
	}

	retry := renderTagComponent(t, TagOptionsError("/recipe/42/tags/options", "Tag-Auswahl konnte nicht geladen werden."))
	if !strings.Contains(retry, `class="outline"`) || !strings.Contains(retry, `aria-busy`) {
		t.Fatalf("tag option retries must be outline buttons with a busy state: %s", retry)
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

func TestTagEditTransitionsUseSafeDistinctNames(t *testing.T) {
	tags := []gql.RecipeTag{
		{Id: "a", Category: gql.TagCategoryCuisine, Name: "A"},
		{Id: `a"; color: red`, Category: gql.TagCategoryCuisine, Name: "B"},
	}
	edit := renderTagComponent(t, RecipeTagsWidget("42", tags, true, true, "", false))
	if !strings.Contains(edit, "--tag-transition-name: recipe-tag-61") ||
		!strings.Contains(edit, "--tag-transition-name: recipe-tag-61223b20636f6c6f723a20726564") ||
		strings.Count(edit, `hx-swap="outerHTML transition:true"`) != len(tags) {
		t.Fatalf("editable tags need distinct, safe transition names: %s", edit)
	}
	read := renderTagComponent(t, RecipeTagsWidget("42", tags, true, false, "", false))
	if strings.Contains(read, "--tag-transition-name") || strings.Contains(read, "transition:true") {
		t.Fatalf("read-only tags must not use tag-edit transitions: %s", read)
	}
	options := renderTagComponent(t, TagOptions("42", "", tags))
	if strings.Count(options, `hx-swap="outerHTML transition:true"`) != len(tags) ||
		!strings.Contains(options, "--tag-transition-name: recipe-tag-option-61") ||
		!strings.Contains(options, "--tag-transition-name: recipe-tag-option-61223b20636f6c6f723a20726564") {
		t.Fatalf("tag additions need distinct transition names: %s", options)
	}
	if !strings.Contains(edit, `hx-swap="innerHTML transition:true"`) {
		t.Fatalf("tag searches must start a transition: %s", edit)
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
