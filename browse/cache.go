package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	cacheTTL      = time.Minute
	cacheMaxBytes = 32 * 1024 * 1024
	cacheDir      = "/tmp/recipe-db-browse-html"
)

var errRecipeNotFound = errors.New("recipe not found")

type cachedPage struct {
	html []byte
	etag string
}

type cacheEntry struct {
	fetched time.Time
	size    int64
	valid   bool
}

type renderFlight struct {
	done        chan struct{}
	invalidated bool
	page        cachedPage
	err         error
}

type pageCache struct {
	mu      sync.Mutex
	dir     string
	ttl     time.Duration
	limit   int64
	used    int64
	entries map[string]cacheEntry
	flights map[string]*renderFlight
	render  func(context.Context, string) ([]byte, error)
	now     func() time.Time
}

func newPageCache(dir string, ttl time.Duration, limit int64, render func(context.Context, string) ([]byte, error)) (*pageCache, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("cache path is not a directory: %s", dir)
	}
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	// This directory belongs exclusively to browse. Never recursively remove its parent.
	for _, file := range files {
		if err := os.Remove(filepath.Join(dir, file.Name())); err != nil {
			return nil, fmt.Errorf("clear cache: %w", err)
		}
	}
	return &pageCache{
		dir: dir, ttl: ttl, limit: limit, render: render, now: time.Now,
		entries: make(map[string]cacheEntry), flights: make(map[string]*renderFlight),
	}, nil
}

func (c *pageCache) path(id string) string {
	return filepath.Join(c.dir, fmt.Sprintf("%x.html", sha256.Sum256([]byte(id))))
}

func pageFromHTML(html []byte) cachedPage {
	return cachedPage{html: html, etag: fmt.Sprintf(`"%x"`, sha256.Sum256(html))}
}

func (c *pageCache) get(ctx context.Context, id string) (cachedPage, error) {
	for {
		if err := ctx.Err(); err != nil {
			return cachedPage{}, err
		}
		c.mu.Lock()
		if entry, ok := c.entries[id]; ok && entry.valid && c.now().Before(entry.fetched.Add(c.ttl)) {
			html, err := os.ReadFile(c.path(id))
			c.mu.Unlock()
			if err != nil {
				log.Printf("cache failure operation=read recipe=%q error=%v", id, err)
				return cachedPage{}, err
			}
			log.Printf("cache hit recipe=%q", id)
			return pageFromHTML(html), nil
		}
		flight, ok := c.flights[id]
		if !ok {
			flight = &renderFlight{done: make(chan struct{})}
			c.flights[id] = flight
			log.Printf("cache miss recipe=%q", id)
			go c.fill(id, flight)
		}
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return cachedPage{}, ctx.Err()
		case <-flight.done:
			if flight.invalidated {
				continue
			}
			return flight.page, flight.err
		}
	}
}

func (c *pageCache) fill(id string, flight *renderFlight) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	// Starting the clock before fetching is conservative, even for a slow upstream response.
	fetched := c.now()
	html, err := c.render(ctx, id)
	if err == nil {
		err = ctx.Err()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !flight.invalidated && err == nil {
		if !c.now().Before(fetched.Add(c.ttl)) {
			err = errors.New("recipe fetch exceeded cache TTL")
		} else {
			err = c.store(id, html, fetched)
		}
	}
	if err != nil {
		log.Printf("cache failure operation=render-store recipe=%q error=%v", id, err)
	}
	flight.page, flight.err = pageFromHTML(html), err
	delete(c.flights, id)
	close(flight.done)
}

// store and remove run under mu so invalidation cannot race an atomic publication.
func (c *pageCache) store(id string, html []byte, fetched time.Time) error {
	size := int64(len(html))
	if size > c.limit {
		return errors.New("rendered page exceeds cache storage limit")
	}
	if _, err := c.remove(id); err != nil {
		return err
	}
	for c.used+size > c.limit {
		var oldest string
		var oldestTime time.Time
		found := false
		for key, entry := range c.entries {
			if !found || entry.fetched.Before(oldestTime) {
				oldest, oldestTime, found = key, entry.fetched, true
			}
		}
		if !found {
			return errors.New("cache storage accounting is inconsistent")
		}
		if _, err := c.remove(oldest); err != nil {
			return err
		}
		log.Printf("cache eviction recipe=%q", oldest)
	}
	file, err := os.CreateTemp(c.dir, ".render-")
	if err != nil {
		return err
	}
	defer func() {
		if err := os.Remove(file.Name()); err != nil && !errors.Is(err, os.ErrNotExist) {
			log.Printf("cache failure operation=cleanup error=%v", err)
		}
	}()
	_, writeErr := file.Write(html)
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), c.path(id)); err != nil {
		return err
	}
	c.entries[id] = cacheEntry{fetched: fetched, size: size, valid: true}
	c.used += size
	return nil
}

func (c *pageCache) remove(id string) (bool, error) {
	entry, ok := c.entries[id]
	if !ok {
		return false, nil
	}
	entry.valid = false
	c.entries[id] = entry
	if err := os.Remove(c.path(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	delete(c.entries, id)
	c.used -= entry.size
	return true, nil
}

func (c *pageCache) invalidate(id string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if flight := c.flights[id]; flight != nil {
		flight.invalidated = true
	}
	removed, err := c.remove(id)
	if removed {
		log.Printf("cache invalidation recipe=%q error=%v", id, err)
	}
	return err
}
