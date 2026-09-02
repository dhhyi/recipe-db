package util

import (
	"io"
	"strconv"

	"github.com/gomarkdown/markdown"
	"github.com/gomarkdown/markdown/ast"
	"github.com/gomarkdown/markdown/html"
)

func myRenderHook(w io.Writer, node ast.Node, entering bool) (ast.WalkStatus, bool) {
	if _, ok := node.(*ast.Paragraph); ok {
		if entering {
			io.WriteString(w, "<p class=\"text-justify\">")
		} else {
			io.WriteString(w, "</p>")
		}
		return ast.GoToNext, true
	} else if head, ok := node.(*ast.Heading); ok {
		newLevel := strconv.Itoa(head.Level + 3)
		if entering {
			io.WriteString(w, "<h"+newLevel+">")
		} else {
			io.WriteString(w, "</h"+newLevel+">")
		}
		return ast.GoToNext, true
	}
	return ast.GoToNext, false
}

func newCustomizedRender() *html.Renderer {
	opts := html.RendererOptions{
		Flags:          html.CommonFlags,
		RenderNodeHook: myRenderHook,
	}
	return html.NewRenderer(opts)
}

func ToMarkDown(in string) string {
	md := []byte(in)
	html := markdown.ToHTML(md, nil, newCustomizedRender())
	return string(html)
}
