package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	c "github.com/ostafen/clover/v2"
	d "github.com/ostafen/clover/v2/document"
	q "github.com/ostafen/clover/v2/query"
)

func Logger(verbose bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		method := c.Request.Method
		path := c.Request.URL.Path

		if verbose {
			log.Printf("%s %s", method, path)
		}

		t := time.Now()

		c.Next()

		latency := time.Since(t)
		status := c.Writer.Status()

		if verbose || status >= 400 {
			log.Printf("%s %s %d %s", method, path, status, latency)
		}
	}
}

func findDBLocation() string {
	if val, set := os.LookupEnv("DATA_LOCATION"); set {
		return val
	} else {
		return "db"
	}
}

func initDB() *c.DB {
	location := findDBLocation()
	if _, err := os.Stat(location); os.IsNotExist(err) {
		log.Println("Creating db directory at " + location)
		os.MkdirAll(location, 0755)
	}
	db, error := c.Open(location)
	if error != nil {
		log.Fatal(error)
		os.Exit(1)
	}

	hasColl, error := db.HasCollection("recipes")
	if error != nil {
		log.Fatal(error)
		os.Exit(1)
	} else if !hasColl {
		log.Println("Creating recipes collection")
		db.CreateCollection("recipes")
	} else {
		count, _ := db.Count(q.NewQuery("recipes"))
		log.Printf("Recipes collection already exists with %d documents", count)
	}

	return db
}

type Recipe = map[string]interface{}

func docToRecipe(doc *d.Document) Recipe {
	recipe := Recipe{}
	doc.Unmarshal(&recipe)
	recipe["id"] = doc.ObjectId()
	return recipe
}

func getRecipe(db *c.DB, id string) (bool, Recipe) {
	doc, err := db.FindById("recipes", id)

	if doc == nil || err != nil {
		return false, Recipe{}
	} else {
		return true, docToRecipe(doc)
	}
}

func getAllRecipes(db *c.DB) *[]Recipe {
	docs, _ := db.FindAll(q.NewQuery("recipes"))
	recipes := []Recipe{}
	for _, doc := range docs {
		recipes = append(recipes, docToRecipe(doc))
	}
	return &recipes
}

func recipeSanityCheck(recipe Recipe) (bool, string) {
	if recipe["id"] != nil {
		return false, "Reserved field: id"
	}
	if recipe["name"] == "" {
		return false, "Missing field value for name"
	}
	json, _ := json.Marshal(recipe)
	if strings.Contains(string(json), "\"name\":null") {
		return false, "Missing field value for name"
	}
	return true, ""
}

func main() {

	r := gin.New()
	r.Use(Logger(os.Getenv("VERBOSE") == "true"))

	db := initDB()

	r.GET("/recipes/:id", func(c *gin.Context) {
		id := c.Param("id")
		found, recipe := getRecipe(db, id)
		if !found {
			c.JSON(404, gin.H{"message": "Recipe not found"})
			return
		}
		c.JSON(200, recipe)
	})

	if os.Getenv("TESTING") == "true" {
		r.DELETE("/recipes", func(c *gin.Context) {
			db.Delete(q.NewQuery("recipes"))
			c.Status(204)
		})
	}

	r.GET("/health", func(c *gin.Context) {
		c.Status(204)
	})

	r.GET("/recipes", func(c *gin.Context) {
		c.JSON(200, getAllRecipes(db))
	})

	r.POST("/recipes", func(c *gin.Context) {
		recipe := make(map[string]interface{})
		err := c.BindJSON(&recipe)
		if err != nil {
			c.JSON(400, gin.H{"message": "Invalid JSON"})
			log.Printf("Error: %s", err)
			return
		}
		if ok, msg := recipeSanityCheck(recipe); !ok {
			c.JSON(400, gin.H{"message": msg})
			return
		}

		doc := d.NewDocumentOf(recipe)
		id, _ := db.InsertOne("recipes", doc)

		_, recipe = getRecipe(db, id)
		c.JSON(201, recipe)
	})

	r.PATCH("/recipes/:id", func(c *gin.Context) {
		id := c.Param("id")
		found, _ := getRecipe(db, id)
		if !found {
			c.JSON(404, gin.H{"message": "Recipe not found"})
			return
		}
		recipe := make(map[string]interface{})
		err := c.BindJSON(&recipe)
		if err != nil {
			c.JSON(400, gin.H{"message": "Invalid JSON"})
			log.Printf("Error: %s", err)
			return
		}
		if ok, msg := recipeSanityCheck(recipe); !ok {
			c.JSON(400, gin.H{"message": msg})
			return
		}

		db.UpdateById("recipes", id, func(doc *d.Document) *d.Document {
			doc.SetAll(recipe)
			return doc
		})

		_, recipe = getRecipe(db, id)
		c.JSON(200, recipe)
	})

	r.DELETE("/recipes/:id", func(c *gin.Context) {
		id := c.Param("id")
		doc, _ := db.FindById("recipes", id)
		if doc == nil {
			c.JSON(404, gin.H{"message": "Recipe not found"})
			return
		}
		db.DeleteById("recipes", id)
		c.Status(204)
	})

	log.Println("Starting server on port 5000")

	if os.Getenv("TESTING") == "true" {
		log.Println("TESTING MODE")
	}

	r.Run("0.0.0.0:5000")
	defer db.Close()
}
