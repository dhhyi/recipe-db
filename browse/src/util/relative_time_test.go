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
		{"future", now.Add(time.Minute), "gerade eben"},
		{"just now", now, "gerade eben"},
		{"under one minute", now.Add(-59 * time.Second), "gerade eben"},
		{"one minute", now.Add(-time.Minute), "vor einer Minute"},
		{"minutes", now.Add(-5 * time.Minute), "vor 5 Minuten"},
		{"last minute", now.Add(-59 * time.Minute), "vor 59 Minuten"},
		{"one hour", now.Add(-time.Hour), "vor einer Stunde"},
		{"hours", now.Add(-5 * time.Hour), "vor 5 Stunden"},
		{"last hour", now.Add(-23 * time.Hour), "vor 23 Stunden"},
		{"one day", now.Add(-24 * time.Hour), "vor einem Tag"},
		{"days", now.Add(-7 * 24 * time.Hour), "vor 7 Tagen"},
		{"last day range", now.Add(-29 * 24 * time.Hour), "vor 29 Tagen"},
		{"one month", now.Add(-30 * 24 * time.Hour), "vor einem Monat"},
		{"month", now.Add(-35 * 24 * time.Hour), "vor einem Monat"},
		{"last month range", now.Add(-89 * 24 * time.Hour), "vor 2 Monaten"},
		{"year threshold", now.Add(-90 * 24 * time.Hour), "in diesem Jahr"},
		{"this year", time.Date(2026, time.July, 1, 0, 0, 0, 0, time.UTC), "in diesem Jahr"},
		{"last year", time.Date(2025, time.July, 1, 0, 0, 0, 0, time.UTC), "letztes Jahr"},
		{"two years", time.Date(2024, time.October, 23, 13, 0, 0, 0, time.UTC), "vor zwei Jahren"},
		{"over two years", time.Date(2024, time.October, 23, 12, 59, 59, 0, time.UTC), "vor langer Zeit"},
		{"long ago", time.Date(2023, time.July, 1, 0, 0, 0, 0, time.UTC), "vor langer Zeit"},
		{"invalid timestamp", time.Time{}, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			timestamp := test.updatedAt.Format(time.RFC3339Nano)
			if test.name == "invalid timestamp" {
				timestamp = "not a timestamp"
			}
			got := relativeTimeInGerman(timestamp, now)
			if got != test.want {
				t.Fatalf("relativeTimeInGerman() = %q, want %q", got, test.want)
			}
		})
	}
}
