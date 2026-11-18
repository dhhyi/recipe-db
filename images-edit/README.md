# Recipe Image Gallery

Owners use **Bilder bearbeiten** on a recipe to open its gallery. The first thumbnail is marked **Standardbild** and is the image used on the recipe and overview. To add an image, choose **Bild hinzufügen**, select one JPEG or PNG, adjust the crop, and save. Saving closes the crop editor and reloads the gallery. If the gallery cannot reload after a successful save, **Erneut laden** refreshes the gallery without uploading again. To change a saved crop, select the source file again and save a new image; there is no in-place recrop.

The gallery and crop editor are implemented in [Elm](https://elm-lang.org/) using [elm-graphql](https://github.com/dillonkearns/elm-graphql) for GraphQL integration.
