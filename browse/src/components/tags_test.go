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
		{Id: "other", Category: gql.TagCategoryOther, Name: "General"},
	})
	ids := make([]string, len(tags))
	for i, tag := range tags {
		ids[i] = tag.Id
	}
	if want := []string{"a", "z", "dietary", "course", "other"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("unexpected stable tag order: %v", ids)
	}
}

func TestOtherTagUsesGrayClassAndAppearsInRecipeTagViews(t *testing.T) {
	tag := gql.RecipeTag{Id: "other", Category: gql.TagCategoryOther, Name: "General"}
	if got := tagClass(tag.Category); got != "recipe-tag recipe-tag--other" {
		t.Fatalf("OTHER tag must use its gray class, got %q", got)
	}
	if got := tagCategoryLabel(tag.Category); got != "Sonstiges" {
		t.Fatalf("unexpected OTHER category label: %q", got)
	}

	widget := renderTagComponent(t, RecipeTagsWidget("42", []gql.RecipeTag{tag}, true, true, "", false))
	if !strings.Contains(widget, `class="recipe-tag recipe-tag--other"`) ||
		!strings.Contains(widget, `aria-label="Sonstiges: General"`) {
		t.Fatalf("OTHER tag is not displayed accessibly in the recipe editor: %s", widget)
	}
	if !strings.Contains(widget, "Sonstiges") {
		t.Fatalf("OTHER category is missing from the recipe-tag legend: %s", widget)
	}

	options := renderTagComponent(t, TagOptions("42", "", []gql.RecipeTag{tag}))
	if !strings.Contains(options, `class="recipe-tag recipe-tag--other"`) {
		t.Fatalf("OTHER tag is not selectable in recipe-tag options: %s", options)
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
			want:   []string{"Tags bearbeiten", "Vegan", `command="show-modal"`, `commandfor="recipe-tags-dialog"`, `<dialog`, `closedby="any"`, `aria-label="Schließen"`, `command="close"`, `id="recipe-tag-search"`, `data-tag-options-section`, `hx-trigger="refresh-tags"`},
			unwant: []string{"Fertig", "hx-post"},
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
			want:   []string{`id="recipe-tag-assigned"`, `class="recipe-tag-remove"`, `Vegan entfernen`, "×", "aria-live"},
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

func TestMaintenanceTagOutagePreservesSnapshotAndShowsSeparateFeedback(t *testing.T) {
	tags := []gql.RecipeTag{{Id: "cuisine", Category: gql.TagCategoryCuisine, Name: "Apfelkuchen"}}
	initial := renderTagComponent(t, recipeDetailTags("42", tags))
	for _, text := range []string{
		"Apfelkuchen",
		"data-tag-feedback",
		"hx-on:tags-unavailable",
		"event.detail.message",
	} {
		if !strings.Contains(initial, text) {
			t.Errorf("initial tag fragment is missing %q: %s", text, initial)
		}
	}
	if strings.Contains(initial, "maintenance") || strings.Contains(initial, "Wartungsarbeiten") {
		t.Errorf("cached tag fragment must not contain maintenance state: %s", initial)
	}

	widget := renderTagComponent(t, RecipeTagsWidget("42", tags, true, false, "", false))
	for _, text := range []string{
		"data-detail-tag-feedback",
		"hx-on:tags-unavailable",
		"this.querySelector('[command=show-modal]')?.remove()",
		"event.detail.message",
	} {
		if !strings.Contains(widget, text) {
			t.Errorf("owner tag widget cannot safely enter maintenance mode; missing %q: %s", text, widget)
		}
	}
	if strings.Contains(widget, "maintenance") || strings.Contains(widget, "Wartungsarbeiten") {
		t.Errorf("cached tag widget must not contain maintenance state: %s", widget)
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
	if strings.Count(body, "<ul") != 1 || strings.Count(body, "<li") != len(tags) ||
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
	if strings.Contains(read, "--tag-transition-name") || strings.Contains(read, `<form `) {
		t.Fatalf("read-only tags must not use tag-edit transitions: %s", read)
	}
	options := renderTagComponent(t, TagOptions("42", "", tags))
	if strings.Count(options, `hx-swap="outerHTML transition:true"`) != len(tags) ||
		!strings.Contains(options, "--tag-transition-name: recipe-tag-option-61") ||
		!strings.Contains(options, "--tag-transition-name: recipe-tag-option-61223b20636f6c6f723a20726564") {
		t.Fatalf("tag additions need distinct transition names: %s", options)
	}
	if !strings.Contains(read, `hx-swap="innerHTML transition:true"`) {
		t.Fatalf("tag searches must start a transition: %s", edit)
	}
}

func TestTagDialogKeepsShellStableAndGuardsRequests(t *testing.T) {
	body := renderTagComponent(t, RecipeTagsWidget("42", nil, true, false, "", false)) +
		renderTagComponent(t, RecipeTagsWidget("42", []gql.RecipeTag{{Id: "a", Name: "A"}}, true, true, "", false))
	for _, text := range []string{
		`hx-target="#recipe-tag-assigned"`, `hx-target="#recipe-tag-options"`,
		`hx-trigger="load-editor"`, `refresh-options`, `compositionstart`,
		`dataset.query`, `this.dataset.clearSearch`, `buttons.length === 1`,
		`this.setAttribute('closedby', 'none')`,
		`this.setAttribute('closedby', 'any')`,
		`hx-on::after-settle`, `this.tagRequests`, `xhr.abort()`,
		`event.detail.requestConfig.parameters.q`, `!this.open`,
		`data-tag-retry`, `data-detail-tag-feedback`,
	} {
		if !strings.Contains(body, text) {
			t.Errorf("missing dialog safeguard %q", text)
		}
	}
}

func TestTagEditorReopensAndPreservesAssignmentsOnFailure(t *testing.T) {
	read := renderTagComponent(t, RecipeTagsWidget("42", nil, true, false, "", false))
	for _, text := range []string{
		`search.value = ''`, `dialog.dataset.loading = 'true'`,
		`dialog.querySelector('[data-tag-options-section]').hidden = true`,
		`this.dataset.denied`, `this.dataset.loading`, `event.detail.target?.id === 'recipe-tag-feedback'`,
		`retry.hidden = false`, `form[data-tag-mutation] button`, `this.dataset.uncertainty`,
		`feedback.textContent += ' ' + this.dataset.uncertainty`,
	} {
		if !strings.Contains(read, text) {
			t.Errorf("missing reopen or failure safeguard %q", text)
		}
	}
	for _, owner := range []bool{false, true} {
		assignments := renderTagComponent(t, RecipeTagAssignments("42", []gql.RecipeTag{{Id: "a", Name: "A"}}, owner, "", false))
		if !strings.Contains(assignments, `hx-get="/recipe/42/tags?edit=1"`) ||
			!strings.Contains(assignments, `hx-trigger="load-editor"`) ||
			!strings.Contains(assignments, `id="recipe-tag-feedback"`) ||
			(owner && (!strings.Contains(assignments, `data-assignment-retry`) || !strings.Contains(assignments, `hidden`))) {
			t.Fatalf("assignment fragment cannot reload safely (owner=%v): %s", owner, assignments)
		}
	}
}

func TestTagDialogHandlesUnmarkedAuthorizationFailuresWithoutSwapping(t *testing.T) {
	body := renderTagComponent(t, RecipeTagsWidget("42", nil, true, false, "", false))
	for _, text := range []string{
		`const replace = event.detail.xhr.getResponseHeader('X-Tag-Replace') === 'true'; event.detail.shouldSwap = replace`,
		`event.detail.isError = false; return`,
		`event.detail.xhr.status === 401 || event.detail.xhr.status === 403`,
		`this.dataset.denied = 'true'`,
		`status.textContent = 'Tags bearbeiten ist nicht erlaubt.'`,
		`this.querySelectorAll('form[data-tag-mutation] button').forEach(button => button.disabled = true)`,
		`this.setAttribute('closedby', 'any')`,
	} {
		if !strings.Contains(body, text) {
			t.Errorf("missing unmarked authorization failure safeguard %q", text)
		}
	}
	if strings.Contains(body, `|| event.detail.target?.id === 'recipe-tag-options'; event.detail.shouldSwap = replace`) {
		t.Fatal("an arbitrary options error response must not be swapped into the dialog")
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
