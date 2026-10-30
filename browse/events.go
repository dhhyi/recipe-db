package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	eventStream   = "RECIPE_EVENTS"
	eventSubject  = "recipes.events.v1"
	cacheConsumer = "browse-cache-v1"
)

type recipeEvent struct {
	Version    int     `json:"version"`
	EventID    string  `json:"eventId"`
	OccurredAt string  `json:"occurredAt"`
	RecipeID   *string `json:"recipeId"`
	Kind       string  `json:"kind"`
}

func (c *pageCache) applyEvent(data []byte) error {
	var event recipeEvent
	if err := json.Unmarshal(data, &event); err != nil {
		return err
	}
	if event.Version != 1 || event.EventID == "" {
		return errors.New("invalid recipe event envelope")
	}
	if _, err := uuid.Parse(event.EventID); err != nil {
		return fmt.Errorf("invalid eventId: %w", err)
	}
	if _, err := time.Parse(time.RFC3339Nano, event.OccurredAt); err != nil {
		return fmt.Errorf("invalid occurredAt: %w", err)
	}
	switch event.Kind {
	case "recipe.changed", "recipe.deleted", "rating.changed", "image.changed", "inspirations.changed", "tags.changed":
		if event.RecipeID == nil || *event.RecipeID == "" {
			return errors.New("recipe event is missing recipeId")
		}
		return c.invalidate(*event.RecipeID)
	default:
		return fmt.Errorf("unsupported recipe event kind: %q", event.Kind)
	}
}

func (c *pageCache) watchEvents(ctx context.Context, url string) {
	for ctx.Err() == nil {
		if err := c.consumeEvents(ctx, url); err != nil && ctx.Err() == nil {
			log.Printf("cache bus failure: %v; retrying in one second", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func (c *pageCache) consumeEvents(ctx context.Context, url string) error {
	nc, err := nats.Connect(url, nats.Timeout(time.Second), nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			log.Printf("cache bus disconnected: %v", err)
		}),
		nats.ReconnectHandler(func(_ *nats.Conn) { log.Print("cache bus reconnected") }),
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			log.Printf("cache bus error: %v", err)
		}))
	if err != nil {
		return err
	}
	defer nc.Close()
	js, err := jetstream.New(nc)
	if err != nil {
		return err
	}
	setupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	consumer, err := js.Consumer(setupCtx, eventStream, cacheConsumer)
	if err != nil {
		return err
	}
	config := consumer.CachedInfo().Config
	if config.Durable != cacheConsumer || config.FilterSubject != eventSubject || config.AckPolicy != jetstream.AckExplicitPolicy {
		return errors.New("browse consumer configuration differs from the message bus contract")
	}
	log.Print("cache bus consumer ready")
	for ctx.Err() == nil {
		batch, err := consumer.Fetch(1, jetstream.FetchMaxWait(time.Second))
		if err != nil {
			return err
		}
		for msg := range batch.Messages() {
			if err := c.applyEvent(msg.Data()); err != nil {
				log.Printf("cache event invalidation failed: %v", err)
				if err := msg.NakWithDelay(time.Second); err != nil {
					return fmt.Errorf("retry invalidation: %w", err)
				}
				continue
			}
			ackCtx, cancel := context.WithTimeout(ctx, time.Second)
			err := msg.DoubleAck(ackCtx)
			cancel()
			if err != nil {
				return fmt.Errorf("acknowledge invalidation: %w", err)
			}
		}
		if err := batch.Error(); err != nil && !errors.Is(err, nats.ErrTimeout) {
			return err
		}
	}
	return ctx.Err()
}
