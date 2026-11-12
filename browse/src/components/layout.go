package components

import "context"

type PageMetadata struct {
	DocumentTitle, OpenGraphTitle, OpenGraphType, OpenGraphImage, OpenGraphURL, Description string
}

type pageMetadataContextKey struct{}

func WithPageMetadata(ctx context.Context, metadata PageMetadata) context.Context {
	return context.WithValue(ctx, pageMetadataContextKey{}, metadata)
}

func pageMetadataFromContext(ctx context.Context) PageMetadata {
	metadata, _ := ctx.Value(pageMetadataContextKey{}).(PageMetadata)
	return metadata
}
