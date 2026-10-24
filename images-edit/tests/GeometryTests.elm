port module GeometryTests exposing (main)

import Crop exposing (Crop, Handle(..), Point, Size)
import Editor.Bridge as Bridge
import Editor.Source as Source exposing (Problem(..))
import Editor.State
import Editor.Types as Editor exposing (Msg(..))
import Json.Decode as D
import Json.Encode as E
import Platform
import RecipeDB


port results : E.Value -> Cmd msg


main : Program () () Never
main =
    Platform.worker
        { init = \_ -> ( (), results (E.list encode tests) )
        , update = \message _ -> never message
        , subscriptions = \_ -> Sub.none
        }


encode : ( String, Bool ) -> E.Value
encode ( name, passed ) =
    E.object [ ( "name", E.string name ), ( "passed", E.bool passed ) ]


size : Size
size =
    { width = 1200, height = 900 }


initial : Crop
initial =
    { x = 200, y = 150, width = 800, height = 600 }


valid : Size -> Crop -> Bool
valid source crop =
    crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= source.width && crop.y + crop.height <= source.height && crop.width >= 300 && crop.height >= 225 && modBy 4 crop.width == 0 && crop.width * 3 == crop.height * 4


anchorPreserved : Handle -> Crop -> Crop -> Bool
anchorPreserved handle before after =
    let
        right : Crop -> Int
        right crop =
            crop.x + crop.width

        bottom : Crop -> Int
        bottom crop =
            crop.y + crop.height

        centerX : Crop -> Int
        centerX crop =
            2 * crop.x + crop.width

        centerY : Crop -> Int
        centerY crop =
            2 * crop.y + crop.height
    in
    case handle of
        TopLeft ->
            right before == right after && bottom before == bottom after

        Top ->
            bottom before == bottom after && centerX before == centerX after

        TopRight ->
            before.x == after.x && bottom before == bottom after

        Right ->
            before.x == after.x && centerY before == centerY after

        BottomRight ->
            before.x == after.x && before.y == after.y

        Bottom ->
            before.y == after.y && centerX before == centerX after

        BottomLeft ->
            right before == right after && before.y == after.y

        Left ->
            right before == right after && centerY before == centerY after


samples : List Point
samples =
    List.concatMap (\x -> List.map (\y -> { x = x, y = y }) [ -5000, -101.4, -1, 0, 1, 99.6, 5000 ]) [ -5000, -99.2, -1, 0, 1, 101.4, 5000 ]


tests : List ( String, Bool )
tests =
    [ ( "1200×900 default", Crop.centered size == Just { x = 0, y = 0, width = 1200, height = 900 } )
    , ( "portrait default", Crop.centered { width = 1200, height = 1600 } == Just { x = 0, y = 350, width = 1200, height = 900 } )
    , ( "landscape default", Crop.centered { width = 1600, height = 900 } == Just { x = 200, y = 0, width = 1200, height = 900 } )
    , ( "square default", Crop.centered { width = 900, height = 900 } == Just { x = 0, y = 112, width = 900, height = 675 } )
    , ( "minimum valid source", Crop.centered { width = 300, height = 225 } == Just { x = 0, y = 0, width = 300, height = 225 } )
    , ( "undersized width", Crop.centered { width = 299, height = 10000 } == Nothing )
    , ( "undersized height", Crop.centered { width = 10000, height = 224 } == Nothing )
    , ( "extreme wide", Crop.centered { width = 10000, height = 225 } == Just { x = 4850, y = 0, width = 300, height = 225 } )
    , ( "extreme tall", Crop.centered { width = 300, height = 10000 } == Just { x = 0, y = 4887, width = 300, height = 225 } )
    , ( "move clamps bottom right", Crop.move size { x = 5000, y = 5000 } initial == { initial | x = 400, y = 300 } )
    , ( "move clamps top left", Crop.move size { x = -5000, y = -5000 } initial == { initial | x = 0, y = 0 } )
    , ( "move quantization", Crop.move size { x = 1.4, y = 1.6 } initial == { initial | x = 201, y = 152 } )
    , ( "corner follows 4:3 diagonal", Crop.resize size BottomRight { x = 40, y = 30 } initial == { initial | width = 840, height = 630 } )
    , ( "right fixes vertical center", Crop.resize size Right { x = 40, y = 999 } initial == { initial | y = 135, width = 840, height = 630 } )
    , ( "top fixes horizontal center", Crop.resize size Top { x = 999, y = -30 } initial == { x = 180, y = 120, width = 840, height = 630 } )
    , ( "right boundary does not move anchor", Crop.resize size Right { x = 5000, y = 0 } initial == { x = 200, y = 75, width = 1000, height = 750 } )
    , ( "top boundary does not move center", Crop.resize size Top { x = 0, y = -5000 } initial == { x = 100, y = 0, width = 1000, height = 750 } )
    , ( "corner minimum", Crop.resize size BottomRight { x = -5000, y = -5000 } initial == { initial | width = 300, height = 225 } )
    , ( "display conversion independent of scale"
      , Crop.fromDisplay size { width = 600, height = 450 } { x = 100, y = 75 }
            == Crop.fromDisplay size { width = 300, height = 225 } { x = 50, y = 37.5 }
            && Crop.fromDisplay size { width = 600, height = 450 } { x = 100, y = 75 }
            == { x = 200, y = 150 }
      )
    , ( "upload metadata retains the returned immutable URL"
      , RecipeDB.decodeUpload """{"data":{"setImage":{"url":"/images/hash-new.png","thumbUrl":"/images/hash-new-thumb.png","size":123,"width":648,"height":486}}}"""
            == Ok { url = "/images/hash-new.png", thumbUrl = "/images/hash-new-thumb.png", size = 123, width = 648, height = 486 }
      )
    , ( "HTTP-200 GraphQL errors never count as successful save"
      , RecipeDB.decodeUpload """{"data":{"setImage":{"url":"/images/hash.png","thumbUrl":"/images/thumb.png","size":1,"width":648,"height":486}},"errors":[{"message":"failed"}]}"""
            |> Result.toMaybe
            |> (==) Nothing
      )
    , ( "malformed GraphQL errors never count as success"
      , RecipeDB.decodeUpload """{"data":{"setImage":{"url":"x","thumbUrl":"y","size":1,"width":648,"height":486}},"errors":null}"""
            |> Result.toMaybe
            |> (==) Nothing
      )
    , ( "invalid upload response rejected", RecipeDB.decodeUpload "not json" |> Result.toMaybe |> (==) Nothing )
    , ( "null upload metadata rejected", RecipeDB.decodeUpload """{"data":{"setImage":null}}""" |> Result.toMaybe |> (==) Nothing )
    , ( "structured crop and image errors provide German feedback"
      , List.all
            (\( code, message ) ->
                RecipeDB.decodeUpload ("{\"errors\":[{\"extensions\":{\"code\":\"" ++ code ++ "\"}}]}")
                    == Err message
            )
            [ ( "crop-out-of-bounds", "Der Zuschnitt liegt außerhalb des Bildes. Bitte den Zuschnitt anpassen und erneut speichern." )
            , ( "crop-too-small", "Der Zuschnitt ist zu klein. Mindestens 300 × 225 Pixel sind erforderlich." )
            , ( "invalid-crop-aspect-ratio", "Der Zuschnitt muss das Seitenverhältnis 4:3 haben. Bitte den Zuschnitt anpassen." )
            , ( "invalid-image", "Das Bild konnte nicht verarbeitet werden. Bitte eine unbeschädigte JPEG- oder PNG-Datei auswählen." )
            ]
      )
    ]
        ++ sourceTests
        ++ List.concatMap
            (\( name, handle ) ->
                [ ( name ++ ": bounds, exact ratio and fixed anchor for 49 pointer deltas"
                  , List.all
                        (\delta ->
                            let
                                crop : Crop
                                crop =
                                    Crop.resize size handle delta initial
                            in
                            valid size crop && anchorPreserved handle initial crop
                        )
                        samples
                  )
                , ( name ++ ": odd k and half-pixel centers stay exact"
                  , let
                        before : Crop
                        before =
                            { x = 201, y = 151, width = 796, height = 597 }
                    in
                    List.all
                        (\delta ->
                            let
                                crop : Crop
                                crop =
                                    Crop.resize size handle delta before
                            in
                            valid size crop && anchorPreserved handle before crop
                        )
                        samples
                  )
                , ( name ++ ": zero delta is invariant", Crop.resize size handle { x = 0, y = 0 } initial == initial )
                ]
            )
            Crop.handles


sourceTests : List ( String, Bool )
sourceTests =
    [ ( "JPEG at exactly 10 MiB is accepted", Source.file "image/jpeg" (10 * 1024 * 1024) == Ok () )
    , ( "PNG at exactly 10 MiB is accepted", Source.file "image/png" (10 * 1024 * 1024) == Ok () )
    , ( "one byte over limit is rejected", Source.file "image/png" (10 * 1024 * 1024 + 1) == Err TooManyBytes )
    , ( "unsupported MIME is rejected", Source.file "image/webp" 100 == Err Unreadable )
    , ( "empty MIME is rejected", Source.file "" 100 == Err Unreadable )
    , ( "MIME failure takes priority over byte limit", Source.file "image/gif" (11 * 1024 * 1024) == Err Unreadable )
    , ( "exactly 40 MP is accepted", Source.dimensions { width = 10000, height = 4000 } |> Result.toMaybe |> (/=) Nothing )
    , ( "over 40 MP is rejected before decode", Source.dimensions { width = 10000, height = 4001 } == Err TooManyPixels )
    , ( "pixel limit takes priority over minimum crop", Source.dimensions { width = 200000, height = 224 } == Err TooManyPixels )
    , ( "large PNG dimensions cannot overflow the pixel guard", Source.dimensions { width = 4294967295, height = 4294967295 } == Err TooManyPixels )
    , ( "exact minimum crop is accepted", Source.dimensions { width = 300, height = 225 } == Ok { x = 0, y = 0, width = 300, height = 225 } )
    , ( "short width is rejected", Source.dimensions { width = 299, height = 900 } == Err TooSmall )
    , ( "short height is rejected", Source.dimensions { width = 1200, height = 224 } == Err TooSmall )
    , ( "zero dimensions are unreadable", Source.dimensions { width = 0, height = 900 } == Err Unreadable )
    , ( "matching decoded dimensions produce the crop", Source.decoded size size == Source.dimensions size )
    , ( "unexpected native orientation is rejected", Source.decoded size { width = 900, height = 1200 } == Err OrientationMismatch )
    , ( "validation feedback remains German and specific"
      , List.map Source.message [ Unreadable, TooManyBytes, TooManyPixels, TooSmall, OrientationMismatch ]
            == [ "Das Bild konnte nicht gelesen werden. Bitte eine gültige JPEG- oder PNG-Datei auswählen."
               , "Die Datei ist zu groß. Erlaubt sind höchstens 10 MiB."
               , "Das Bild ist zu groß. Erlaubt sind höchstens 40 Millionen Pixel."
               , "Das Bild ist zu klein. Mindestens 300 × 225 Pixel im 4:3-Zuschnitt sind erforderlich."
               , "Die Bildausrichtung konnte nicht zuverlässig gelesen werden. Bitte ein anderes JPEG- oder PNG-Bild auswählen."
               ]
      )
    , ( "metadata decoder retains oriented dimensions"
      , D.decodeString Bridge.incoming """{"kind":"metadata","token":3,"width":900,"height":1200}"""
            == Ok (Bridge.Metadata 3 { width = 900, height = 1200 })
      )
    , ( "metadata decoder retains unsigned PNG dimensions for rejection"
      , D.decodeString Bridge.incoming """{"kind":"metadata","token":3,"width":4294967295,"height":4294967295}"""
            == Ok (Bridge.Metadata 3 { width = 4294967295, height = 4294967295 })
      )
    , ( "load decoder retains metadata and native dimensions"
      , D.decodeString Bridge.incoming """{"kind":"loaded","token":3,"url":"blob:source","width":900,"height":1200,"naturalWidth":1200,"naturalHeight":900}"""
            == Ok (Bridge.Loaded 3 "blob:source" { width = 900, height = 1200 } size)
      )
    , ( "stale metadata and failures cannot change the editor"
      , let
            model : Editor.Model
            model =
                Editor.init "recipe"
        in
        List.all
            (\event ->
                Editor.State.update (Bridge event) model |> Tuple.first |> (==) model
            )
            [ E.object [ ( "kind", E.string "metadata" ), ( "token", E.int -1 ), ( "width", E.int 1200 ), ( "height", E.int 900 ) ]
            , E.object [ ( "kind", E.string "failed" ), ( "token", E.int -1 ) ]
            ]
      )
    ]
