package util

import (
	"testing"
	"time"
)

func TestRelativeTimeInGerman(t *testing.T) {
	now := time.Date(2026, time.October, 23, 13, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name      string
		updatedAt time.Time
		want      string
	}{
		{"minutes", now.Add(-5 * time.Minute), "vor 5 Minuten"},
		{"hours", now.Add(-5 * time.Hour), "vor 5 Stunden"},
		{"month", now.Add(-35 * 24 * time.Hour), "vor einem Monat"},
		{"this year", time.Date(2026, time.July, 1, 0, 0, 0, 0, time.UTC), "in diesem Jahr"},
		{"last year", time.Date(2025, time.July, 1, 0, 0, 0, 0, time.UTC), "letztes Jahr"},
		{"long ago", time.Date(2023, time.July, 1, 0, 0, 0, 0, time.UTC), "vor langer Zeit"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := relativeTimeInGerman(test.updatedAt.Format(time.RFC3339Nano), now)
			if got != test.want {
				t.Fatalf("relativeTimeInGerman() = %q, want %q", got, test.want)
			}
		})
	}
}
