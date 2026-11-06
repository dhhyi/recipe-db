package components

import (
	"net/url"
	"strconv"
	"strings"
)

func TagSearchFilter(id string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(id)
	return `tag_ids:="` + escaped + `"`
}

func TagSearchFilterID(filter string) (string, bool) {
	const prefix = `tag_ids:="`
	if !strings.HasPrefix(filter, prefix) || !strings.HasSuffix(filter, `"`) {
		return "", false
	}
	literal := `"` + strings.TrimSuffix(strings.TrimPrefix(filter, prefix), `"`) + `"`
	id, err := strconv.Unquote(literal)
	if err != nil || TagSearchFilter(id) != filter {
		return "", false
	}
	return id, true
}

func tagSearchURL(id string) string {
	values := url.Values{}
	values.Set("filter_by", TagSearchFilter(id))
	return "/?" + values.Encode()
}
