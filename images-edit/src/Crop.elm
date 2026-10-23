module Crop exposing (Crop, Handle(..), Point, Size, centered, fromDisplay, handles, move, resize)


type alias Crop =
    { x : Int, y : Int, width : Int, height : Int }


type alias Size =
    { width : Int, height : Int }


type alias Point =
    { x : Float, y : Float }


type Handle
    = TopLeft
    | Top
    | TopRight
    | Right
    | BottomRight
    | Bottom
    | BottomLeft
    | Left


handles : List ( String, Handle )
handles =
    [ ( "nw", TopLeft ), ( "n", Top ), ( "ne", TopRight ), ( "e", Right ), ( "se", BottomRight ), ( "s", Bottom ), ( "sw", BottomLeft ), ( "w", Left ) ]


centered : Size -> Maybe Crop
centered size =
    let
        k : Int
        k =
            min (size.width // 4) (size.height // 3)
    in
    if k < 75 then
        Nothing

    else
        Just { x = (size.width - 4 * k) // 2, y = (size.height - 3 * k) // 2, width = 4 * k, height = 3 * k }


fromDisplay : Size -> { width : Float, height : Float } -> Point -> Point
fromDisplay size display point =
    { x = point.x * toFloat size.width / display.width
    , y = point.y * toFloat size.height / display.height
    }


move : Size -> Point -> Crop -> Crop
move size delta crop =
    { crop
        | x = clamp 0 (size.width - crop.width) (crop.x + round delta.x)
        , y = clamp 0 (size.height - crop.height) (crop.y + round delta.y)
    }


resize : Size -> Handle -> Point -> Crop -> Crop
resize size handle delta crop =
    let
        horizontal : Int
        horizontal =
            case handle of
                Top ->
                    0

                Bottom ->
                    0

                TopLeft ->
                    -1

                Left ->
                    -1

                BottomLeft ->
                    -1

                _ ->
                    1

        vertical : Int
        vertical =
            case handle of
                Left ->
                    0

                Right ->
                    0

                TopLeft ->
                    -1

                Top ->
                    -1

                TopRight ->
                    -1

                _ ->
                    1

        oldK : Int
        oldK =
            crop.width // 4

        anchorX : Float
        anchorX =
            if horizontal == -1 then
                toFloat (crop.x + crop.width)

            else if horizontal == 0 then
                toFloat crop.x + toFloat crop.width / 2

            else
                toFloat crop.x

        anchorY : Float
        anchorY =
            if vertical == -1 then
                toFloat (crop.y + crop.height)

            else if vertical == 0 then
                toFloat crop.y + toFloat crop.height / 2

            else
                toFloat crop.y

        limitX : Float
        limitX =
            if horizontal == 0 then
                min anchorX (toFloat size.width - anchorX) / 2

            else if horizontal == -1 then
                anchorX / 4

            else
                (toFloat size.width - anchorX) / 4

        limitY : Float
        limitY =
            if vertical == 0 then
                min anchorY (toFloat size.height - anchorY) / 1.5

            else if vertical == -1 then
                anchorY / 3

            else
                (toFloat size.height - anchorY) / 3

        change : Float
        change =
            if horizontal == 0 then
                toFloat vertical * delta.y / 3

            else if vertical == 0 then
                toFloat horizontal * delta.x / 4

            else
                (4 * toFloat horizontal * delta.x + 3 * toFloat vertical * delta.y) / 25

        -- Horizontal edges retain k's parity so the fixed vertical center
        -- and both origins remain exact integers, even for odd source sizes.
        step : Int
        step =
            if vertical == 0 then
                2

            else
                1

        minimum : Int
        minimum =
            if step == 2 && modBy 2 oldK == 0 then
                76

            else
                75

        maximum : Int
        maximum =
            floor (min limitX limitY)

        maxK : Int
        maxK =
            maximum - modBy step (maximum - oldK)

        k : Int
        k =
            clamp minimum maxK (oldK + step * round (change / toFloat step))

        x : Int
        x =
            if horizontal == -1 then
                round anchorX - 4 * k

            else if horizontal == 0 then
                round anchorX - 2 * k

            else
                round anchorX

        y : Int
        y =
            if vertical == -1 then
                round anchorY - 3 * k

            else if vertical == 0 then
                round (anchorY - 1.5 * toFloat k)

            else
                round anchorY
    in
    { x = x, y = y, width = 4 * k, height = 3 * k }
