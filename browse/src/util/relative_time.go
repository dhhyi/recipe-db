package util

import (
	"fmt"
	"time"
)

func RelativeTimeInGerman(timestamp string) string {
	return relativeTimeInGerman(timestamp, time.Now())
}

func relativeTimeInGerman(timestamp string, now time.Time) string {
	updatedAt, err := time.Parse(time.RFC3339Nano, timestamp)
	if err != nil {
		return ""
	}

	elapsed := now.Sub(updatedAt)
	if elapsed < 0 || elapsed < time.Minute {
		return "gerade eben"
	}
	if elapsed < time.Hour {
		minutes := int(elapsed / time.Minute)
		if minutes == 1 {
			return "vor einer Minute"
		}
		return fmt.Sprintf("vor %d Minuten", minutes)
	}
	if elapsed < 24*time.Hour {
		hours := int(elapsed / time.Hour)
		if hours == 1 {
			return "vor einer Stunde"
		}
		return fmt.Sprintf("vor %d Stunden", hours)
	}
	if elapsed < 30*24*time.Hour {
		days := int(elapsed / (24 * time.Hour))
		if days == 1 {
			return "vor einem Tag"
		}
		return fmt.Sprintf("vor %d Tagen", days)
	}
	if elapsed < 90*24*time.Hour {
		months := int(elapsed / (30 * 24 * time.Hour))
		if months == 1 {
			return "vor einem Monat"
		}
		return fmt.Sprintf("vor %d Monaten", months)
	}
	if updatedAt.Before(now.AddDate(-2, 0, 0)) {
		return "vor langer Zeit"
	}
	if updatedAt.Year() == now.Year() {
		return "in diesem Jahr"
	}
	if updatedAt.Year() == now.Year()-1 {
		return "letztes Jahr"
	}
	return "vor zwei Jahren"
}
