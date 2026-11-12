package pagemetadata

import "context"

type PageMetadata struct {
	DocumentTitle, OpenGraphTitle, OpenGraphType, OpenGraphImage, OpenGraphURL, Description string
}

type contextKey struct{}

func WithContext(ctx context.Context, metadata PageMetadata) context.Context {
	return context.WithValue(ctx, contextKey{}, metadata)
}

func FromContext(ctx context.Context) PageMetadata {
	metadata, _ := ctx.Value(contextKey{}).(PageMetadata)
	return metadata
}
