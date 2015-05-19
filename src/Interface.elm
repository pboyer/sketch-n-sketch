-- Interface.elm
-- This defines and renders an interactive interface for editing the
-- program and output of the language as defined in int-trees.

--Import the little language and its parsing utilities
import Lang exposing (..) --For access to what makes up the Vals
import LangParser exposing (parseE, parseV)
import Sync exposing (sync)
import Eval exposing (run)
import MainSvg
import Utils
import MicroTests
import InterfaceUtils exposing (..)
import LangSvg
import VirtualDom

import List 
import Dict
import String 
import Graphics.Element as GE 
import Graphics.Collage as GC

import Mouse 
import Window 
import Html 
import Html.Attributes as Attr
import Html.Events as Events

import Svg
import Svg.Attributes
import Svg.Events
import Svg.Lazy

import Debug

-- Model --
--Fields:
-- code            - Text currently in the textbox
--inputExp         - input Expression
-- objects         - The workingVal translated to manipulable SVGs
-- movingObj       - If an object is being moved, which one
-- inputVal        - The last code input parsed into a Val
--                   (changes only after picking an output of sync)
-- workingVal      - The inputVal after applying the manipulations performed on
--                   the graphics side (done on the fly)
-- possibleChanges - The possible new expressions and their associated Vals, 
--                   as from the output of sync
-- syncMode        - True if state should be non-manipulatable/sync selecting
type alias Model = { code : String
                   , inputExp : Maybe Exp
                   , objects : List Object
                   , movingObj : Maybe (LangSvg.NodeId, Float, Float)
                   , inputVal : Val
                   , workingVal : Val
                   , workingSlate : LangSvg.IndexedTree
                   , possibleChanges : List ((Exp, Val), Float)
                   , syncMode : Bool
                   }

--An Object is composed of an svg, list of attribute key/values
type alias Object = (Svg.Svg, List (String, String))

--Just as in microTests
tempTestCode = 
    "(let [x0 y0 xsep ysep] [10 28 30 30]
       (map (\\[i j] (square_ (+ x0 (mult i xsep)) (+ y0 (mult j ysep)) 20))
            (cartProd [0 1 2] [0 1])))"

tempTest = MicroTests.test27 ()

sampleModel = { code      = tempTestCode
              , inputExp  = Just (parseE tempTestCode)
              , objects   = buildVisual <| LangSvg.valToIndexedTree tempTest.v 
              , movingObj = Nothing
              , inputVal = tempTest.v
              , workingVal = tempTest.v
              , workingSlate = LangSvg.valToIndexedTree tempTest.v
              , possibleChanges = []
              , syncMode = False
              }

type Event = CodeUpdate String
           | OutputUpdate String
           | SelectObject Int String
           | DeselectObject Int
           | MouseDown (Int, Int)
           | Sync
           | SelectOption ((Exp, Val), Float)
           | Render

events : Signal.Mailbox Event
events = Signal.mailbox <| CodeUpdate ""

-- Update --
upstate : Event -> Model -> Model
upstate evt old = case Debug.log "Event" evt of
    Render -> case Debug.log "run" <| Eval.run <| parseE old.code of
        bare -> let vals = VList [VBase (String "svg"), VList [], bare] in 
            { old | objects      <- buildVisual 
                                    <| LangSvg.valToIndexedTree vals
                  , inputVal     <- vals
                  , workingVal   <- vals
                  , workingSlate <- LangSvg.valToIndexedTree vals
            }
    CodeUpdate newcode -> { old | code <- newcode }
    MouseDown (mx, my) -> case old.movingObj of
        Nothing                  -> old
        Just (objid, xdist, ydist) -> if
            | xdist == -1.0 || ydist == -1.0 -> 
                case Dict.get objid old.workingSlate of 
                    Just node ->
                        case buildSvg (objid, node) of
                            (svg, attrs) -> 
                                let xpos = case String.toFloat <| find attrs "x" of
                                        Ok a -> a
                                    ypos = case String.toFloat <| find attrs "y" of
                                        Ok a -> a
                                in { old | movingObj <- Just (objid 
                                            , xpos - Basics.toFloat mx
                                            , ypos - Basics.toFloat my) 
                                   }
            | otherwise -> 
                let newpos = [ ("x", toString <| Basics.toFloat mx + xdist)
                             , ("y", toString <| Basics.toFloat my + ydist) ]
                    newSlate = List.foldr (updateSlate objid)
                                old.workingSlate
                                [ ("x", toString <| Basics.toFloat mx + xdist)
                                , ("y", toString <| Basics.toFloat my + ydist)
                                ]
                    newobjs = buildVisual newSlate
                in  { old | objects <- newobjs 
                          , workingSlate <- newSlate
                    }
    SelectObject id zonetype -> { old | movingObj <- Just (id, -1.0, -1.0) }

    DeselectObject x -> { old | movingObj <- Nothing }
    Sync -> 
        case old.inputExp of
            Just ip -> 
                let inputval = Eval.run ip
                    newval = indexedTreeToVal old.workingSlate
                in case (Result.toMaybe <| sync ip inputval newval) of
                    Just ls -> { old | possibleChanges <- ls
                                     , syncMode <- True 
                               }
                    Nothing -> old
            _       -> old
    SelectOption ((e,v), f) -> { old | possibleChanges <- []
                                     , inputVal <- v
                                     , workingVal <- v
                                     , inputExp <- Just e
                                     , syncMode <- False 
                               }
    _ -> old
 
--TODO: fix object tracking issue

updateObj : List (String, String) -> Object -> Object -> Object
updateObj newattrs (o1, a1) (o2, a2) = case Debug.log "index" (find a1 "index") of
  a ->
    if | ((find a1 "index") == (find a2 "index")) ->
                let updatedattrs = updateAttrStrs newattrs a1
                    svgattrs = List.map (\(x,y) -> attr x <| y) (List.drop 2 updatedattrs)
                    shape = svg (find a1 "shape")
                in ((shape svgattrs []), updatedattrs) 
       | otherwise -> (o2, a2)


-- View --
codeBox : String -> Bool -> Html.Html
codeBox code switch =
    let
        event = case switch of
            True -> []
            False ->  [(Events.on "input" Events.targetValue
                (Signal.message events.address << CodeUpdate))]
    in
        Html.textarea
            ([ Attr.id "codeBox"
            , Attr.style
                [ ("height", "100%")
                , ("width",  "100%")
                , ("resize", "none")
                , ("overflow", "scroll")
                ]
            , Attr.value code
            ]
            ++
            event)
            []

visualsBox : List Object -> Float -> Bool -> Html.Html
visualsBox objects dim switch =
    Svg.svg [ Attr.style
                [ ("width", "100%")
                , ("height", "100%")
                ]
            ] <| List.map (\(f,g) -> f) objects

buildVisual : LangSvg.IndexedTree -> List (Svg.Svg, List (String, String))
buildVisual valDict = List.map buildSvg (Dict.toList valDict)

buildSvg : (LangSvg.NodeId, LangSvg.IndexedTreeNode) -> (Svg.Svg, List (String, String))
buildSvg (nodeID, node) = case node of
    LangSvg.TextNode text -> (VirtualDom.text text, [("shape", "TEXT"), ("text", text)])
    LangSvg.SvgNode shape attrs childrenids ->
       let attrstrs = getAttrs attrs
           zones = makeZones shape nodeID attrstrs
           mainshape = (LangSvg.svg shape <| LangSvg.valsToAttrs attrs) []
       in (Svg.svg [] (mainshape :: zones), attrstrs)
                
makeZones : String -> LangSvg.NodeId -> List (String, String) -> List Svg.Svg
makeZones shape nodeID attrstrs = case shape of
        "rect" ->
            let xcent = LangSvg.attr "x" <| toString
                        <| (case String.toFloat <| find attrstrs "x" of
                                Ok z -> 
                                    case String.toFloat <| find attrstrs "width" of
                                        Ok k -> z + k * 0.125)
                ycent = LangSvg.attr "y" <| toString
                        <| (case String.toFloat <| find attrstrs "y" of
                                Ok z -> 
                                    case String.toFloat <| find attrstrs "height"
                                    of
                                        Ok k -> round <| z + k * 0.125)
                wcent = LangSvg.attr "width" <| toString <| (\x -> x * 0.75) 
                        <| (case String.toFloat <| find attrstrs "width" of
                                Ok z -> z)
                hcent = LangSvg.attr "height" <| toString <| (\x -> x * 0.75) 
                        <| (case String.toFloat <| find attrstrs "height" of
                                Ok z -> z)
                fill = LangSvg.attr "fill" "#FF0000"
                firstattrs = [xcent, ycent, wcent, hcent, fill]
                attrs = List.append firstattrs
                    [ Svg.Events.onMouseDown (Signal.message events.address
                        (SelectObject nodeID "center"))
                    , Svg.Events.onMouseUp (Signal.message events.address
                        (DeselectObject nodeID))
                    ]
                centBox = Svg.rect attrs []
            in [centBox]
        _ -> []

view : (Int, Int) -> Model -> Html.Html
view (w,h) model = 
    let
        dim = (Basics.toFloat (Basics.min w h)) / 2
    in
        case model.syncMode of
            False -> Html.div
                    [ Attr.style
                        [ ("width", toString w)
                        , ("height", toString h)
                        ]
                    ]
                    [renderView (w,h) model
                    , Html.button
                        [ Attr.style
                            [ ("position", "absolute")
                            , ("left", String.append (toString <| w // 6) "px")
                            , ("top", String.append (toString <| h - 40) "px")
                            , ("type", "button")
                            , ("width", "100px")
                            , ("height", "40px")
                            ]
                        , Events.onClick events.address Render
                        , Attr.value "Render"
                        , Attr.name "Render the Code"
                        ]
                        [Html.text "render"]
                    , Html.button
                        [ Attr.style
                            [ ("position", "absolute")
                            , ("left", String.append (toString <| w // 4) "px")
                            , ("top", String.append (toString <| h - 40) "px")
                            , ("type", "button")
                            , ("width", "100px")
                            , ("height", "40px")
                            ]
                        , Events.onClick events.address Sync
                        , Attr.value "Sync"
                        , Attr.name "Sync the code to the canvas"
                        ]
                        [Html.text "sync"]
                    ]
            True -> syncView (w,h) model

renderView : (Int, Int) -> Model -> Html.Html
renderView (w,h) model = 
    let
        dim = (Basics.toFloat (Basics.min w h)) / 2
    in
        Html.div
            [ Attr.style
                [ ("width", toString w)
                , ("height", toString h)
                ]
            ]
            [ Html.div 
                [ Attr.style
                    [ ("width", String.append (toString <| w // 2 - 1) "px")
                    , ("height", String.append (toString <| h - 60) "px")
                    , ("margin", "0")
                    , ("position", "absolute")
                    , ("left", "0px")
                    , ("top", "0px")
                    ]
                ]
                [codeBox model.code model.syncMode]
            , Html.div
                [ Attr.style
                    [ ("width", String.append (toString <| w // 2 - 1) "px")
                    , ("height", String.append (toString h) "px")
                    , ("margin", "0")
                    , ("position", "absolute")
                    , ("left", String.append (toString <| w // 2) "px")
                    , ("top", "0px")
                    ]
                ]    
                [visualsBox model.objects dim model.syncMode]
            ]

syncView : (Int, Int) -> Model -> Html.Html
syncView (w,h) model = 
    let
        dim = (Basics.toFloat (Basics.min w h)) / 2
    in
        Html.div
        []
        (renderOption (w, h // 4) (Utils.mapi (\x -> x) model.possibleChanges) model dim)
            

renderOption : (Int, Int) -> List (Int, ((Exp, Val), Float)) -> Model -> Float -> List Html.Html
renderOption (w,h) possiblechanges model dim =
    case possiblechanges of
        (i, ((e,v), f))::ps -> 
            (Html.div
                [ Attr.style
                    [ ("width", toString w)
                    , ("height", toString h)
                    , ("top", String.append (toString <| h * (i-1)) "px")
                    , ("position", "absolute")
                    ]
                ]
                [ Html.div 
                    [ Attr.style
                        [ ("width", String.append (toString <| w // 2 - 30) "px")
                        , ("height", String.append (toString <| h) "px")
                        , ("margin", "0")
                        , ("position", "absolute")
                        , ("left", "0px")
                        , ("top", "0px") -- String.append (toString <| h * (i-1)) "px")
                        ]
                    ]
                    [codeBox (sExpK 1 e) model.syncMode]
                , Html.div
                    [ Attr.style
                        [ ("width", String.append (toString <| w // 2 - 50) "px")
                        , ("height", String.append (toString h) "px")
                        , ("margin", "0")
                        , ("position", "absolute")
                        , ("left", String.append (toString <| w // 2) "px")
                        , ("top", "0px") --String.append (toString <| h * (i-1)) "px")
                        ]
                    ]    
                    [visualsBox (buildVisual <| LangSvg.valToIndexedTree v) dim model.syncMode] --TODO: parse val to svgs
--                , Html.button
--                    [ Attr.style
--                        [ ("position", "absolute")
--                        , ("left", String.append (toString <| w // 4) "px")
--                        , ("top", "0px) --String.append (toString <| h - 40) "px")
--                        , ("type", "button")
--                        , ("width", "100px")
--                        , ("height", "40px")
--                        ]
--                    , Events.onClick events.address (SelectOption ((e,v), f))
--                    , Attr.value "Select"
--                    , Attr.name "Select this codebox and visualbox"
--                    ]
--                    [Html.text "select"]
                ]) :: renderOption (w,h) ps model dim
        [] -> []


-- Main --
main : Signal Html.Html
main = let sigModel = Signal.foldp upstate sampleModel
                        <| Signal.mergeMany
                            [ events.signal
                            , Signal.map2 (,) Mouse.isDown Mouse.position
                                |> Signal.filter (\(x,y) -> x) (False, (0,0))
                                |> Signal.map (\(x,y) -> y)
                                |> Signal.map2 adjustCoords Window.dimensions
                                |> Signal.map MouseDown
                            ]
       in Signal.map2 view Window.dimensions sigModel
