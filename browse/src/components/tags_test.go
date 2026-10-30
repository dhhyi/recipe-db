package components

import (
	"reflect"
	"testing"

	gql "frontend/src/generated"
)

func TestOrderedTagsUsesCategoryFoldedNameAndID(t *testing.T) {
	tags := orderedTags([]recipeTag{
		{ID: "course", Category: gql.TagCategoryCourse, Name: "Dessert"},
		{ID: "z", Category: gql.TagCategoryCuisine, Name: "ÉCLAIR"},
		{ID: "dietary", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
		{ID: "a", Category: gql.TagCategoryCuisine, Name: "e\u0301clair"},
	})
	ids := make([]string, len(tags))
	for i, tag := range tags {
		ids[i] = tag.ID
	}
	if want := []string{"a", "z", "dietary", "course"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("unexpected stable tag order: %v", ids)
	}
}
