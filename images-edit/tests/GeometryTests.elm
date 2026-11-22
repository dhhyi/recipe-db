module GeometryTests exposing (suite)

import Crop exposing (Crop, Handle(..), Point, Size)
import Editor.Bridge as Bridge
import Editor.Source as Source exposing (Problem(..))
import Editor.State
import Editor.Types as Editor exposing (Msg(..))
import Expect
import Json.Decode as D
import Json.Encode as E
import RecipeDB
import RemoteData
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Image editor"
        (geometryTests ++ List.map (\( name, passed ) -> test name (\_ -> Expect.equal True passed)) tests)


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


geometryTests : List Test
geometryTests =
    let
        equal : String -> a -> a -> Test
        equal name expected actual =
            test name (\_ -> Expect.equal expected actual)
    in
    [ equal "1200×900 default" (Just { x = 0, y = 0, width = 1200, height = 900 }) (Crop.centered size)
    , equal "portrait default" (Just { x = 0, y = 350, width = 1200, height = 900 }) (Crop.centered { width = 1200, height = 1600 })
    , equal "landscape default" (Just { x = 200, y = 0, width = 1200, height = 900 }) (Crop.centered { width = 1600, height = 900 })
    , equal "square default" (Just { x = 0, y = 112, width = 900, height = 675 }) (Crop.centered { width = 900, height = 900 })
    , equal "minimum valid source" (Just { x = 0, y = 0, width = 300, height = 225 }) (Crop.centered { width = 300, height = 225 })
    , equal "undersized width" Nothing (Crop.centered { width = 299, height = 10000 })
    , equal "undersized height" Nothing (Crop.centered { width = 10000, height = 224 })
    , equal "extreme wide" (Just { x = 4850, y = 0, width = 300, height = 225 }) (Crop.centered { width = 10000, height = 225 })
    , equal "extreme tall" (Just { x = 0, y = 4887, width = 300, height = 225 }) (Crop.centered { width = 300, height = 10000 })
    , equal "move clamps bottom right" { initial | x = 400, y = 300 } (Crop.move size { x = 5000, y = 5000 } initial)
    , equal "move clamps top left" { initial | x = 0, y = 0 } (Crop.move size { x = -5000, y = -5000 } initial)
    , equal "move quantization" { initial | x = 201, y = 152 } (Crop.move size { x = 1.4, y = 1.6 } initial)
    , equal "corner follows 4:3 diagonal" { initial | width = 840, height = 630 } (Crop.resize size BottomRight { x = 40, y = 30 } initial)
    , equal "right fixes vertical center" { initial | y = 135, width = 840, height = 630 } (Crop.resize size Right { x = 40, y = 999 } initial)
    , equal "top fixes horizontal center" { x = 180, y = 120, width = 840, height = 630 } (Crop.resize size Top { x = 999, y = -30 } initial)
    , equal "right boundary does not move anchor" { x = 200, y = 75, width = 1000, height = 750 } (Crop.resize size Right { x = 5000, y = 0 } initial)
    , equal "top boundary does not move center" { x = 100, y = 0, width = 1000, height = 750 } (Crop.resize size Top { x = 0, y = -5000 } initial)
    , equal "corner minimum" { initial | width = 300, height = 225 } (Crop.resize size BottomRight { x = -5000, y = -5000 } initial)
    , test "display conversion independent of scale" <|
        \_ ->
            Expect.all
                [ \_ -> Expect.equal { x = 200, y = 150 } (Crop.fromDisplay size { width = 600, height = 450 } { x = 100, y = 75 })
                , \_ -> Expect.equal { x = 200, y = 150 } (Crop.fromDisplay size { width = 300, height = 225 } { x = 50, y = 37.5 })
                ]
                ()
    ]


tests : List ( String, Bool )
tests =
    [ ( "upload metadata retains the returned immutable URL"
      , RecipeDB.decodeUpload """{"data":{"addImage":{"url":"/images/hash-new.png","thumbUrl":"/images/hash-new-thumb.png","size":123,"width":648,"height":486}}}"""
            == Ok { url = "/images/hash-new.png", thumbUrl = "/images/hash-new-thumb.png", size = 123, width = 648, height = 486 }
      )
    , ( "HTTP-200 GraphQL errors never count as successful save"
      , RecipeDB.decodeUpload """{"data":{"addImage":{"url":"/images/hash.png","thumbUrl":"/images/thumb.png","size":1,"width":648,"height":486}},"errors":[{"message":"failed"}]}"""
            |> Result.toMaybe
            |> (==) Nothing
      )
    , ( "malformed GraphQL errors never count as success"
      , RecipeDB.decodeUpload """{"data":{"addImage":{"url":"x","thumbUrl":"y","size":1,"width":648,"height":486}},"errors":null}"""
            |> Result.toMaybe
            |> (==) Nothing
      )
    , ( "invalid upload response rejected", RecipeDB.decodeUpload "not json" |> Result.toMaybe |> (==) Nothing )
    , ( "null upload metadata rejected", RecipeDB.decodeUpload """{"data":{"addImage":null}}""" |> Result.toMaybe |> (==) Nothing )
    , ( "delete mutation decodes true and confirmed absence"
      , RecipeDB.decodeDeleteImage """{"data":{"deleteImage":true}}"""
            == Ok True
            && RecipeDB.decodeDeleteImage """{"data":{"deleteImage":false}}"""
            == Ok False
      )
    , ( "delete mutation rejects GraphQL errors and malformed responses"
      , List.all ((==) Nothing << Result.toMaybe)
            [ RecipeDB.decodeDeleteImage """{"errors":[{"message":"forbidden","extensions":{"code":"forbidden"}}]}"""
            , RecipeDB.decodeDeleteImage """{"data":{"deleteImage":"true"}}"""
            , RecipeDB.decodeDeleteImage """{"data":{"deleteImage":true},"errors":null}"""
            , RecipeDB.decodeDeleteImage "not json"
            ]
      )
    , ( "structured crop and image errors provide German feedback"
      , List.all
            (\( code, message ) ->
                RecipeDB.decodeUpload ("{\"errors\":[{\"extensions\":{\"code\":\"" ++ code ++ "\"}}]}")
                    == Err message
            )
            [ ( "crop-out-of-bounds", "Der Zuschnitt liegt außerhalb des Bildes. Bitte den Zuschnitt anpassen und erneut speichern." )
            , ( "crop-too-small", "Der Zuschnitt ist zu klein. Mindestens 300 × 225 Pixel sind erforderlich." )
            , ( "invalid-crop-aspect-ratio", "Der Zuschnitt muss das Seitenverhältnis 4:3 haben. Bitte den Zuschnitt anpassen." )
            , ( "invalid-crop", "Der Zuschnitt wurde ungültig übertragen. Bitte den Zuschnitt anpassen und erneut speichern." )
            , ( "invalid-image", "Das Bild konnte nicht verarbeitet werden. Bitte eine unbeschädigte JPEG- oder PNG-Datei auswählen." )
            , ( "image-limit-reached", "Das Rezept hat bereits die maximal erlaubten zehn Bilder. Das Bild wurde nicht gespeichert." )
            ]
      )
    ]
        ++ sourceTests
        ++ reorderResponseTests
        ++ galleryTests
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


galleryTests : List ( String, Bool )
galleryTests =
    let
        init : Editor.Model
        init =
            Editor.init "recipe"

        authorized : Editor.Model
        authorized =
            apply (GotCapabilities (RemoteData.Success { role = "owner", canManageImages = True })) init

        loaded : Maybe (List RecipeDB.GalleryImage) -> Editor.Model
        loaded images =
            apply (GotRecipe 0 (RemoteData.Success (Just { name = "Testrezept", images = images }))) authorized

        entries : Int -> List RecipeDB.GalleryImage
        entries count =
            List.range 1 count
                |> List.map (\index -> { id = "opaque/" ++ String.fromInt index, thumbUrl = "/thumb" })

        apply : Msg -> Editor.Model -> Editor.Model
        apply msg =
            Editor.State.update msg >> Tuple.first

        unavailable : Editor.Model
        unavailable =
            loaded Nothing

        retrying : Editor.Model
        retrying =
            apply RetryGallery { unavailable | savedFeedback = True }

        lateUpload : Msg
        lateUpload =
            Uploaded 1 (RemoteData.Success { url = "/full", thumbUrl = "/thumb", size = 1, width = 648, height = 486 })

        first : Editor.Model
        first =
            loaded (Just (entries 2))

        threeImages : Editor.Model
        threeImages =
            loaded (Just (entries 3))

        pendingMove : Editor.Model
        pendingMove =
            apply (MoveImage "opaque/2" Editor.MoveUp) threeImages

        dragEvent : String -> List ( String, E.Value ) -> Msg
        dragEvent kind fields =
            Bridge (E.object (( "kind", E.string kind ) :: fields))

        dragStart : Editor.Model
        dragStart =
            apply (dragEvent "gallery-drag-start" [ ( "imageId", E.string "opaque/2" ) ]) threeImages

        dragPreview : Editor.Model
        dragPreview =
            apply (dragEvent "gallery-drag-move" [ ( "index", E.int 0 ) ]) dragStart

        dragDrop : Editor.Model
        dragDrop =
            apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ]) dragPreview

        dragRejected : Editor.Model
        dragRejected =
            apply (Reordered dragDrop.mutationToken (RemoteData.Success (RecipeDB.ReorderRejected "Konflikt"))) dragDrop

        dragUnknown : Editor.Model
        dragUnknown =
            apply (Reordered dragDrop.mutationToken (RemoteData.Failure "Ungewiss")) dragDrop

        firstDrag : Editor.Model
        firstDrag =
            apply (dragEvent "gallery-drag-start" [ ( "imageId", E.string "opaque/1" ) ]) threeImages
                |> apply (dragEvent "gallery-drag-move" [ ( "index", E.int 2 ) ])
                |> apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ])

        firstDragSuccess : Editor.Model
        firstDragSuccess =
            apply (Reordered firstDrag.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed)) firstDrag

        differentRead : RecipeDB.RecipeModel
        differentRead =
            RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/3", thumbUrl = "/thumb" }, { id = "opaque/1", thumbUrl = "/thumb" }, { id = "opaque/2", thumbUrl = "/thumb" } ] })

        firstDragReady : Editor.Model
        firstDragReady =
            apply (GotRecipe firstDragSuccess.galleryToken differentRead) firstDragSuccess

        firstDragReconciled : Editor.Model
        firstDragReconciled =
            apply (ApplyGallery firstDragReady.galleryToken) firstDragReady

        nonDefaultDrag : Editor.Model
        nonDefaultDrag =
            apply (dragEvent "gallery-drag-move" [ ( "index", E.int 2 ) ]) dragStart
                |> apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ])

        nonDefaultWritten : Editor.Model
        nonDefaultWritten =
            apply (Reordered nonDefaultDrag.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed)) nonDefaultDrag

        concurrentRead : RecipeDB.RecipeModel
        concurrentRead =
            RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/3", thumbUrl = "/thumb" }, { id = "opaque/1", thumbUrl = "/thumb" }, { id = "opaque/2", thumbUrl = "/thumb" } ] })

        nonDefaultReady : Editor.Model
        nonDefaultReady =
            apply (GotRecipe nonDefaultWritten.galleryToken concurrentRead) nonDefaultWritten

        nonDefaultReconciled : Editor.Model
        nonDefaultReconciled =
            apply (ApplyGallery nonDefaultReady.galleryToken) nonDefaultReady

        unknownFirstDrag : Editor.Model
        unknownFirstDrag =
            apply (Reordered firstDrag.mutationToken (RemoteData.Failure "Ungewiss")) firstDrag

        unknownCommitted : Editor.Model
        unknownCommitted =
            apply
                (GotRecipe unknownFirstDrag.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/2", thumbUrl = "/thumb" }, { id = "opaque/3", thumbUrl = "/thumb" }, { id = "opaque/1", thumbUrl = "/thumb" } ] })))
                unknownFirstDrag

        dragFailedRead : Editor.Model -> Editor.Model
        dragFailedRead model =
            apply (GotRecipe model.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Nothing }))) model

        middleDownMove : Editor.Model
        middleDownMove =
            apply (MoveImage "opaque/2" Editor.MoveDown) threeImages

        middleDownWriteCompleted : Editor.Model
        middleDownWriteCompleted =
            apply (Reordered middleDownMove.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed)) middleDownMove

        middleDownReady : Editor.Model
        middleDownReady =
            apply
                (GotRecipe middleDownWriteCompleted.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/1", thumbUrl = "/thumb" }, { id = "opaque/3", thumbUrl = "/thumb" }, { id = "opaque/2", thumbUrl = "/thumb" } ] })))
                middleDownWriteCompleted

        middleDownReconciled : Editor.Model
        middleDownReconciled =
            apply (ApplyGallery middleDownReady.galleryToken) middleDownReady

        moveWriteCompleted : Editor.Model
        moveWriteCompleted =
            apply (Reordered pendingMove.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed)) pendingMove

        movedReady : Editor.Model
        movedReady =
            apply
                (GotRecipe moveWriteCompleted.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/2", thumbUrl = "/thumb" }, { id = "opaque/1", thumbUrl = "/thumb" }, { id = "opaque/3", thumbUrl = "/thumb" } ] })))
                moveWriteCompleted

        movedReconciled : Editor.Model
        movedReconciled =
            apply (ApplyGallery movedReady.galleryToken) movedReady

        rejectedMove : Editor.Model
        rejectedMove =
            apply
                (Reordered pendingMove.mutationToken (RemoteData.Success (RecipeDB.ReorderRejected "Die Bildreihenfolge wurde zwischenzeitlich geändert.")))
                pendingMove

        failedMoveRefresh : Editor.Model
        failedMoveRefresh =
            apply
                (GotRecipe rejectedMove.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Nothing })))
                rejectedMove

        retriedMoveRefresh : Editor.Model
        retriedMoveRefresh =
            apply RetryGallery failedMoveRefresh

        recoveredMoveRefresh : Editor.Model
        recoveredMoveRefresh =
            apply
                (GotRecipe retriedMoveRefresh.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/1", thumbUrl = "/thumb" }, { id = "opaque/2", thumbUrl = "/thumb" }, { id = "opaque/3", thumbUrl = "/thumb" } ] })))
                retriedMoveRefresh

        pendingDelete : Editor.Model
        pendingDelete =
            apply (DeleteImage "opaque/1") first

        acceptedDelete : Editor.Model
        acceptedDelete =
            apply (DeleteConfirmed "opaque/1" 0 True) pendingDelete

        writeCompleted : Editor.Model
        writeCompleted =
            apply (Deleted acceptedDelete.mutationToken (RemoteData.Success True)) acceptedDelete

        deletionReady : Editor.Model
        deletionReady =
            apply
                (GotRecipe writeCompleted.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/2", thumbUrl = "/thumb" } ] })))
                writeCompleted

        unchangedAfterDelete : Editor.Model
        unchangedAfterDelete =
            apply
                (GotRecipe writeCompleted.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just (entries 2) })))
                writeCompleted

        failedConfirmedDeleteRefresh : Editor.Model
        failedConfirmedDeleteRefresh =
            apply
                (GotRecipe writeCompleted.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Nothing })))
                writeCompleted

        retriedConfirmedDelete : Editor.Model
        retriedConfirmedDelete =
            apply RetryGallery failedConfirmedDeleteRefresh

        retriedDeletionReady : Editor.Model
        retriedDeletionReady =
            apply
                (GotRecipe retriedConfirmedDelete.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [ { id = "opaque/2", thumbUrl = "/thumb" } ] })))
                retriedConfirmedDelete

        reconciled : Editor.Model
        reconciled =
            apply (ApplyGallery deletionReady.galleryToken) deletionReady

        rejectedWrite : Editor.Model
        rejectedWrite =
            apply (Deleted acceptedDelete.mutationToken (RemoteData.Success False)) acceptedDelete

        failedRefresh : Editor.Model
        failedRefresh =
            apply
                (GotRecipe rejectedWrite.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Nothing })))
                rejectedWrite

        retriedRefresh : Editor.Model
        retriedRefresh =
            apply RetryGallery failedRefresh

        recoveredRefresh : Editor.Model
        recoveredRefresh =
            apply
                (GotRecipe retriedRefresh.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just [] })))
                retriedRefresh

        failedWrite : Editor.Model
        failedWrite =
            apply (Deleted acceptedDelete.mutationToken (RemoteData.Failure "unknown outcome")) acceptedDelete

        atLimit : Editor.Model
        atLimit =
            loaded (Just (entries 10))

        atLimitDelete : Editor.Model
        atLimitDelete =
            apply (DeleteImage "opaque/1") atLimit

        atLimitAccepted : Editor.Model
        atLimitAccepted =
            apply (DeleteConfirmed "opaque/1" 0 True) atLimitDelete

        atLimitWritten : Editor.Model
        atLimitWritten =
            apply (Deleted atLimitAccepted.mutationToken (RemoteData.Success True)) atLimitAccepted

        atNineReady : Editor.Model
        atNineReady =
            apply
                (GotRecipe atLimitWritten.galleryToken (RemoteData.Success (Just { name = "Testrezept", images = Just (List.drop 1 (entries 10)) })))
                atLimitWritten

        atNine : Editor.Model
        atNine =
            apply (ApplyGallery atNineReady.galleryToken) atNineReady
    in
    [ ( "unconfirmed gallery or capabilities never enable Add"
      , not (Editor.canAdd authorized)
            && not (Editor.canAdd unavailable)
            && not (Editor.canAdd (apply (GotRecipe 0 (RemoteData.Success Nothing)) authorized))
            && not (Editor.canAdd (apply (GotCapabilities (RemoteData.Success { role = "member", canManageImages = False })) (loaded (Just []))))
      )
    , ( "only loaded collections below capacity enable Add"
      , Editor.canAdd (loaded (Just [])) && Editor.canAdd (loaded (Just (entries 9))) && not (Editor.canAdd (loaded (Just (entries 10))))
      )
    , ( "Add is restored after authoritative deletion reduces a full gallery"
      , not (Editor.canAdd atLimit)
            && Editor.canAdd atNine
            && List.length (currentIds atNine)
            == 9
      )
    , ( "capacity warning appears at ten, not at nine or unknown count"
      , Editor.capacityWarning (Just (entries 10))
            == Just "Dieses Rezept hat bereits die maximal erlaubten zehn Bilder."
            && Editor.capacityWarning (Just (entries 9))
            == Nothing
            && Editor.capacityWarning Nothing
            == Nothing
      )
    , ( "gallery retry clears the previous count without discarding upload confirmation"
      , retrying.recipe == RemoteData.Loading && retrying.savedFeedback && retrying.galleryRefreshing && not (Editor.canAdd retrying)
      )
    , ( "late upload and preview results cannot reopen the gallery's released session"
      , List.all (\msg -> apply msg retrying == retrying) [ lateUpload, PreviewReady 1, PreviewFailed 1, Save, Close ]
      )
    , ( "delete is gated by loaded opaque identity and image-management capability"
      , Editor.canDelete first "opaque/1"
            && not (Editor.canDelete first "/thumb")
            && not (Editor.canDelete (apply (GotCapabilities (RemoteData.Success { role = "member", canManageImages = False })) first) "opaque/1")
      )
    , ( "movement controls respect boundaries, collection size and capability"
      , not (Editor.canMove threeImages "opaque/1" Editor.MoveUp)
            && Editor.canMove threeImages "opaque/1" Editor.MoveDown
            && Editor.canMove threeImages "opaque/2" Editor.MoveUp
            && Editor.canMove threeImages "opaque/2" Editor.MoveDown
            && not (Editor.canMove threeImages "opaque/3" Editor.MoveDown)
            && not (Editor.canMove (loaded (Just (entries 1))) "opaque/1" Editor.MoveUp)
            && not (Editor.canMove (loaded (Just [])) "opaque/1" Editor.MoveDown)
            && not (Editor.canMove (apply (GotCapabilities (RemoteData.Success { role = "member", canManageImages = False })) threeImages) "opaque/2" Editor.MoveUp)
      )
    , ( "pending move keeps the confirmed order and gates all gallery mutations"
      , currentIds pendingMove
            == [ "opaque/1", "opaque/2", "opaque/3" ]
            && Maybe.map .imageId pendingMove.galleryMutation
            == Just "opaque/2"
            && Maybe.map (.movement >> Maybe.map .toIndex) pendingMove.galleryMutation
            == Just (Just 0)
            && Maybe.map .writing pendingMove.galleryMutation
            == Just True
            && not (Editor.canAdd pendingMove)
            && not (Editor.canDelete pendingMove "opaque/1")
            && not (Editor.canMove pendingMove "opaque/2" Editor.MoveDown)
      )
    , ( "drag preview keeps confirmed IDs separately and disables mutations"
      , currentIds dragPreview
            == [ "opaque/1", "opaque/2", "opaque/3" ]
            && Maybe.map (List.map .id) dragPreview.galleryPreview
            == Just [ "opaque/2", "opaque/1", "opaque/3" ]
            && not (Editor.canAdd dragPreview)
            && not (Editor.canDelete dragPreview "opaque/1")
            && not (Editor.canMove dragPreview "opaque/2" Editor.MoveUp)
            && apply (MoveImage "opaque/2" Editor.MoveUp) dragPreview
            == dragPreview
      )
    , ( "drop starts one optimistic write; cancel and no-op do not write"
      , dragDrop.galleryMutation
            /= Nothing
            && dragDrop.mutationToken
            == 1
            && dragDrop.galleryPreview
            == dragPreview.galleryPreview
            && (apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool True ) ]) dragPreview).galleryPreview
            == Nothing
            && (apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ]) dragStart).mutationToken
            == 0
            && apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ]) dragDrop
            == dragDrop
      )
    , ( "cancel and no-op retain prior mutation error; a new write clears it"
      , let
            withPriorError : Editor.Model
            withPriorError =
                { threeImages | galleryFeedback = Just { kind = Editor.ReorderingRejected, message = "Konflikt" } }

            priorErrorDrag : Editor.Model
            priorErrorDrag =
                apply (dragEvent "gallery-drag-start" [ ( "imageId", E.string "opaque/2" ) ]) withPriorError

            cancel : Editor.Model
            cancel =
                apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool True ) ]) priorErrorDrag

            noOp : Editor.Model
            noOp =
                apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ]) priorErrorDrag

            dropped : Editor.Model
            dropped =
                apply (dragEvent "gallery-drag-move" [ ( "index", E.int 0 ) ]) priorErrorDrag
                    |> apply (dragEvent "gallery-drag-end" [ ( "cancelled", E.bool False ) ])
        in
        priorErrorDrag.galleryFeedback
            == withPriorError.galleryFeedback
            && cancel.galleryFeedback
            == withPriorError.galleryFeedback
            && noOp.galleryFeedback
            == withPriorError.galleryFeedback
            && dropped.galleryFeedback
            == Nothing
      )
    , ( "failed or unknown writes discard preview and keep last confirmed order on failed read"
      , List.all
            (\model ->
                model.galleryPreview
                    == Nothing
                    && currentIds (dragFailedRead model)
                    == [ "opaque/1", "opaque/2", "opaque/3" ]
                    && not (Editor.canAdd (dragFailedRead model))
            )
            [ dragRejected, dragUnknown ]
      )
    , ( "successful drag with failed read retains optimistic order and retry only reads"
      , let
            dragSuccess : Editor.Model
            dragSuccess =
                apply (Reordered dragDrop.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed)) dragDrop

            failed : Editor.Model
            failed =
                dragFailedRead dragSuccess

            retried : Editor.Model
            retried =
                apply RetryGallery failed
        in
        Maybe.map (List.map .id) failed.galleryPreview
            == Just [ "opaque/2", "opaque/1", "opaque/3" ]
            && currentIds failed
            == [ "opaque/1", "opaque/2", "opaque/3" ]
            && Maybe.map .kind failed.galleryFeedback
            == Just Editor.ReorderingSucceeded
            && not (Editor.canAdd failed)
            && retried.mutationToken
            == failed.mutationToken
            && retried.galleryToken
            == failed.galleryToken
            + 1
      )
    , ( "nonadjacent drag preserves other opaque IDs and reconciles a different authoritative default"
      , Maybe.map (List.map .id) firstDrag.galleryPreview
            == Just [ "opaque/2", "opaque/3", "opaque/1" ]
            && currentIds firstDragReconciled
            == [ "opaque/3", "opaque/1", "opaque/2" ]
            && firstDragReconciled.galleryPreview
            == Nothing
            && Maybe.map .message firstDragReconciled.galleryFeedback
            == Just "Bild an Position 2 verschoben. Bild an Position 1 ist jetzt das Standardbild."
      )
    , ( "non-default drag announces a concurrent authoritative default change"
      , currentIds nonDefaultReconciled
            == [ "opaque/3", "opaque/1", "opaque/2" ]
            && Maybe.map .message nonDefaultReconciled.galleryFeedback
            == Just "Bild an Position 3 verschoben. Bild an Position 1 ist jetzt das Standardbild."
      )
    , ( "unknown write that committed uses the authoritative collection without retry"
      , currentIds unknownCommitted
            == [ "opaque/2", "opaque/3", "opaque/1" ]
            && unknownCommitted.galleryPreview
            == Nothing
            && Maybe.map .kind unknownCommitted.galleryFeedback
            == Just Editor.ReorderingUnconfirmed
            && unknownCommitted.mutationToken
            == 1
      )
    , ( "middle Down swaps only its adjacent neighbor and preserves membership"
      , currentIds middleDownReconciled
            == [ "opaque/1", "opaque/3", "opaque/2" ]
            && middleDownReconciled.galleryMutation
            == Nothing
      )
    , ( "confirmed order waits for the transition callback and ignores stale callbacks"
      , currentIds movedReady
            == [ "opaque/1", "opaque/2", "opaque/3" ]
            && movedReady.galleryRefreshing
            && apply (ApplyGallery (movedReady.galleryToken + 1)) movedReady
            == movedReady
      )
    , ( "confirmed move reloads authoritative order and announces default change"
      , currentIds movedReconciled
            == [ "opaque/2", "opaque/1", "opaque/3" ]
            && movedReconciled.galleryMutation
            == Nothing
            && Maybe.map .kind movedReconciled.galleryFeedback
            == Just Editor.ReorderingSucceeded
            && Maybe.map .message movedReconciled.galleryFeedback
            == Just "Bild an Position 1 verschoben und als Standardbild festgelegt."
      )
    , ( "rejected move preserves explicit error and Retry only reads"
      , currentIds failedMoveRefresh
            == [ "opaque/1", "opaque/2", "opaque/3" ]
            && failedMoveRefresh.galleryError
            /= Nothing
            && failedMoveRefresh.galleryMutation
            /= Nothing
            && Maybe.map .message failedMoveRefresh.galleryFeedback
            == Just "Die Bildreihenfolge wurde zwischenzeitlich geändert."
            && not (Editor.canAdd failedMoveRefresh)
            && not (Editor.canDelete failedMoveRefresh "opaque/1")
            && not (Editor.canMove failedMoveRefresh "opaque/2" Editor.MoveUp)
            && retriedMoveRefresh.mutationToken
            == failedMoveRefresh.mutationToken
            && retriedMoveRefresh.galleryToken
            == failedMoveRefresh.galleryToken
            + 1
            && recoveredMoveRefresh.galleryMutation
            == Nothing
            && currentIds recoveredMoveRefresh
            == [ "opaque/1", "opaque/2", "opaque/3" ]
      )
    , ( "duplicate reorder callbacks cannot start a second reconciliation"
      , apply
            (Reordered pendingMove.mutationToken (RemoteData.Success RecipeDB.ReorderConfirmed))
            failedMoveRefresh
            == failedMoveRefresh
      )
    , ( "confirmation cancel preserves the collection and starts no mutation"
      , let
            cancelled : Editor.Model
            cancelled =
                apply (DeleteConfirmed "opaque/1" 0 False) pendingDelete
        in
        cancelled.galleryMutation
            == Nothing
            && cancelled.galleryConfirmation
            == Nothing
            && currentIds cancelled
            == [ "opaque/1", "opaque/2" ]
            && Editor.canAdd cancelled
      )
    , ( "accepted deletion keeps confirmed order visible and gates all controls"
      , Maybe.map .imageId acceptedDelete.galleryMutation
            == Just "opaque/1"
            && Maybe.map .index acceptedDelete.galleryMutation
            == Just 0
            && currentIds acceptedDelete
            == [ "opaque/1", "opaque/2" ]
            && not (Editor.canAdd acceptedDelete)
            && not (Editor.canDelete acceptedDelete "opaque/2")
      )
    , ( "confirmed deletion waits for transition and ignores stale callbacks"
      , currentIds deletionReady
            == [ "opaque/1", "opaque/2" ]
            && deletionReady.galleryRefreshing
            && not (Editor.canDelete deletionReady "opaque/2")
            && apply (ApplyGallery (deletionReady.galleryToken + 1)) deletionReady
            == deletionReady
      )
    , ( "unchanged deletion refresh applies without a transition"
      , unchangedAfterDelete.galleryMutation
            == Nothing
            && unchangedAfterDelete.pendingGallery
            == Nothing
            && currentIds unchangedAfterDelete
            == [ "opaque/1", "opaque/2" ]
      )
    , ( "failed deletion refresh preserves the gallery and retry animates the confirmed result"
      , failedConfirmedDeleteRefresh.galleryError
            /= Nothing
            && failedConfirmedDeleteRefresh.pendingGallery
            == Nothing
            && currentIds failedConfirmedDeleteRefresh
            == [ "opaque/1", "opaque/2" ]
            && retriedDeletionReady.pendingGallery
            /= Nothing
            && currentIds (apply (ApplyGallery retriedDeletionReady.galleryToken) retriedDeletionReady)
            == [ "opaque/2" ]
      )
    , ( "confirmed success reconciles order and clears pending state"
      , not reconciled.galleryRefreshing
            && reconciled.galleryMutation
            == Nothing
            && currentIds reconciled
            == [ "opaque/2" ]
            && Maybe.map .kind reconciled.galleryFeedback
            == Just Editor.DeletionSucceeded
      )
    , ( "false response is neutral and refresh failure keeps controls disabled"
      , Maybe.map .kind rejectedWrite.galleryFeedback
            == Just Editor.ImageAlreadyAbsent
            && currentIds rejectedWrite
            == [ "opaque/1", "opaque/2" ]
            && failedRefresh.galleryError
            /= Nothing
            && failedRefresh.galleryMutation
            /= Nothing
            && currentIds failedRefresh
            == [ "opaque/1", "opaque/2" ]
            && not (Editor.canDelete failedRefresh "opaque/1")
            && not (Editor.canAdd failedRefresh)
      )
    , ( "retry after a failed deletion read is read-only and restores capability only after success"
      , retriedRefresh.galleryToken
            == failedRefresh.galleryToken
            + 1
            && retriedRefresh.galleryMutation
            /= Nothing
            && retriedRefresh.galleryRefreshing
            && not (Editor.canAdd retriedRefresh)
            && not (Editor.canDelete retriedRefresh "opaque/1")
      )
    , ( "mutation error triggers reconciliation and keeps an explicit outcome"
      , Maybe.map .kind failedWrite.galleryFeedback
            == Just Editor.DeletionUnconfirmed
            && failedWrite.galleryRefreshing
      )
    , ( "successful read retry clears mutation and load error"
      , recoveredRefresh.galleryMutation == Nothing && recoveredRefresh.galleryError == Nothing
      )
    , ( "successful read retry restores Add capability"
      , Editor.canAdd recoveredRefresh
      )
    , ( "successful read retry preserves the already-absent result"
      , Maybe.map .kind recoveredRefresh.galleryFeedback == Just Editor.ImageAlreadyAbsent
      )
    , ( "stale confirmation and duplicate mutation callbacks cannot target a later gallery"
      , let
            stale : Editor.Model
            stale =
                apply (DeleteConfirmed "opaque/1" 0 True) (apply RetryGallery pendingDelete)

            duplicate : Editor.Model
            duplicate =
                apply (Deleted acceptedDelete.mutationToken (RemoteData.Success True)) reconciled

            repeatedConfirmation : Editor.Model
            repeatedConfirmation =
                apply (DeleteConfirmed "opaque/1" 0 True) acceptedDelete
        in
        stale.galleryMutation
            == Nothing
            && stale.galleryConfirmation
            == Nothing
            && duplicate
            == reconciled
            && repeatedConfirmation
            == acceptedDelete
            && apply (DeleteImage "opaque/1") pendingDelete
            == pendingDelete
      )
    , ( "gallery IDs remain exact opaque strings", currentIds first == [ "opaque/1", "opaque/2" ] )
    ]


currentIds : Editor.Model -> List String
currentIds model =
    case model.recipe of
        RemoteData.Success (Just recipe) ->
            recipe.images |> Maybe.withDefault [] |> List.map .id

        _ ->
            []


reorderResponseTests : List ( String, Bool )
reorderResponseTests =
    [ ( "complete reorder metadata confirms the write"
      , RecipeDB.decodeReorderImages [ "opaque/id" ] """{"data":{"reorderImages":[{"id":"opaque/id","url":"/full","thumbUrl":"/thumb","size":12,"width":648,"height":486}]}}"""
            == Ok RecipeDB.ReorderConfirmed
      )
    , ( "backend membership conflict remains an explicit rejection"
      , RecipeDB.decodeReorderImages [ "opaque/id" ] """{"errors":[{"message":"Image collection changed","extensions":{"code":"image-order-conflict"}}]}"""
            == Ok (RecipeDB.ReorderRejected "Die Bildreihenfolge wurde zwischenzeitlich geändert. Der aktuelle Stand wird neu geladen.")
      )
    , ( "malformed reorder response cannot confirm success"
      , case RecipeDB.decodeReorderImages [ "opaque/id" ] """{"data":{"reorderImages":[{"id":"opaque/id"}]}}""" of
            Err _ ->
                True

            _ ->
                False
      )
    , ( "empty reorder response cannot confirm a non-empty request"
      , case RecipeDB.decodeReorderImages [ "opaque/1", "opaque/2" ] """{"data":{"reorderImages":[]}}""" of
            Err _ ->
                True

            _ ->
                False
      )
    , ( "reorder response must preserve the requested order of opaque IDs"
      , case RecipeDB.decodeReorderImages [ "opaque/1", "opaque/2" ] """{"data":{"reorderImages":[{"id":"opaque/2","url":"/full","thumbUrl":"/thumb","size":12,"width":648,"height":486},{"id":"opaque/1","url":"/full","thumbUrl":"/thumb","size":12,"width":648,"height":486}]}}""" of
            Err _ ->
                True

            _ ->
                False
      )
    , ( "malformed GraphQL errors cannot confirm a reorder response"
      , case RecipeDB.decodeReorderImages [ "opaque/id" ] """{"errors":null,"data":{"reorderImages":[{"id":"opaque/id","url":"/full","thumbUrl":"/thumb","size":12,"width":648,"height":486}]}}""" of
            Err _ ->
                True

            _ ->
                False
      )
    ]


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
    , ( "delete confirmation decoder preserves opaque identity and gallery session"
      , D.decodeString Bridge.incoming """{"kind":"delete-confirmation","imageId":"opaque/id?with#reserved","session":7,"accepted":true}"""
            == Ok (Bridge.DeleteConfirmation "opaque/id?with#reserved" 7 True)
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
