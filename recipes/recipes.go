package main

import (
	"log"
	"os"
	"time"

	"github.com/gin-gonic/gin"
)

func Logger() gin.HandlerFunc {
	return func(c *gin.Context) {
		method := c.Request.Method
		path := c.Request.URL.Path
		log.Printf("%s %s", method, path)

		t := time.Now()

		c.Next()

		latency := time.Since(t)
		status := c.Writer.Status()

		log.Printf("%s %s %d %s", method, path, status, latency)
	}
}

type Recipe struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func getRecipe(id string) (bool, Recipe) {
	switch id {
	case "1":
		return true, Recipe{ID: "1", Name: "Rice Pudding"}
	case "2":
		return true, Recipe{ID: "2", Name: "Beetroot Soup"}
	case "3":
		return true, Recipe{ID: "3", Name: "Bean Stew"}
	}
	return false, Recipe{}
}

func main() {
	r := gin.New()
	r.Use(Logger())

	r.GET("/recipes/:id", func(c *gin.Context) {
		id := c.Param("id")
		found, recipe := getRecipe(id)
		if !found {
			c.JSON(404, gin.H{"message": "Recipe not found"})
			return
		}
		c.JSON(200, recipe)
	})

	r.GET("/recipes", func(c *gin.Context) {
		_, x1 := getRecipe("1")
		_, x2 := getRecipe("2")
		_, x3 := getRecipe("3")
		recipes := []Recipe{x1, x2, x3}
		c.JSON(200, recipes)
	})

	log.Println("Starting server on port 5000")

	if os.Getenv("TESTING") == "true" {
		log.Println("TESTING MODE")
	}

	r.Run("0.0.0.0:5000")
}
