module LangParser2 (prelude, isPreludeLoc, isPreludeEId,
                    substOf, substStrOf, parseE,
                    freshen, substPlusOf) where

import String
import Dict
import Char
import Debug

import Lang exposing (..)
import OurParser2 exposing ((>>=),(>>>),(<$>),(+++),(<++))
import OurParser2 as P
import Utils as U
import PreludeGenerated as Prelude

------------------------------------------------------------------------------

(prelude, initK) = freshen_ 1 <| U.fromOk_ <| parseE_ identity Prelude.src

isPreludeLoc : Loc -> Bool
isPreludeLoc (k,_,_) = k < initK

isPreludeEId : EId -> Bool
isPreludeEId k = k < initK

------------------------------------------------------------------------------

-- these top-level freshen and substOf definitions are ugly...

-- reassigns eid's and locId's
freshen : Exp -> Exp
freshen e = fst (freshen_ initK e)

substPlusOf : Exp -> SubstPlus
substPlusOf e =
  let preludeSubst = substPlusOf_ Dict.empty prelude in
  substPlusOf_ preludeSubst e

substOf : Exp -> Subst
substOf = Dict.map (always .val) << substPlusOf

substStrOf : Exp -> SubstStr
substStrOf = Dict.map (always toString) << substOf

-- this will be done while parsing eventually...

freshen_ : Int -> Exp -> (Exp, Int)
freshen_ k e =
  (\(e__,k') ->
    let nextK =
      case e__ of
        EConst _ _ (kk, _, _) _ -> kk -- invariant: kk = k' - 1
        _                       -> k'
    in
    (P.WithInfo (Exp_ e__ nextK) e.start e.end, nextK + 1)) <|
 case e.val.e__ of
  -- EConst i l wd -> let (0,b,"") = l in (EConst i (k, b, "") wd, k + 1)
  -- freshen is now being called externally by Sync.inferDeleteUpdates
  EConst ws i l wd -> let (_,b,x) = l in (EConst ws i (k, b, x) wd, k + 1)
  EBase ws v    -> (EBase ws v, k)
  EVar ws x     -> (EVar ws x, k)
  EFun ws1 ps e ws2 -> let (e',k') = freshen_ k e in (EFun ws1 ps e' ws2, k')
  EApp ws1 f es ws2 ->
    let ((f',es'),k') = U.mapFst U.uncons <| freshenExps k (f::es) in
    (EApp ws1 f' es' ws2, k')
  EOp ws1 op es ws2 -> let (es',k') = freshenExps k es in (EOp ws1 op es' ws2, k')
  EList ws1 es ws2 m ws3 -> let (es',k') = freshenExps k es in
                case m of
                  Nothing -> (EList ws1 es' ws2 Nothing ws3, k')
                  Just e  -> let (e',k'') = freshen_ k' e in
                             (EList ws1 es' ws2 (Just e') ws3, k'')
  EIndList ws1 rs ws2-> let (rs', k') = freshenRanges k rs
                 in (EIndList ws1 rs' ws2, k')
  EIf ws1 e1 e2 e3 ws2 ->
    let ((e1',e2',e3'),k') = U.mapFst U.unwrap3 <| freshenExps k [e1,e2,e3] in
    (EIf ws1 e1' e2' e3' ws2, k')
  ELet ws1 kind b p e1 e2 ws2 ->
    let ((e1',e2'),k') = U.mapFst U.unwrap2 <| freshenExps k [e1,e2] in
    let e1'' = recordIdentifiers (p, e1') in
    (ELet ws1 kind b p e1'' e2' ws2, k')
  ECase ws1 e bs ws2 ->
    let bes = branchExps bs in
    let ((e',bes'), k') = U.mapFst U.uncons <| freshenExps k (e::bes) in
    let replaceBranch oldBranch newE =
      let (Branch_ bws1 pat oldE bws2) = oldBranch.val in
      { oldBranch | val = Branch_ bws1 pat newE bws2 }
    in
    (ECase ws1 e' (List.map2 replaceBranch bs bes') ws2, k')
  EComment ws s e1 ->
    let (e1',k') = freshen_ k e1 in
    (EComment ws s e1', k')
  EOption ws1 s1 ws2 s2 e1 ->
    let (e1',k') = freshen_ k e1 in
    (EOption ws1 s1 ws2 s2 e1', k')

freshenExps k es =
  List.foldr (\e (es',k') ->
    let (e1,k1) = freshen_ k' e in
    (e1::es', k1)) ([],k) es

freshenRanges : Int -> List Range -> (List Range, Int)
freshenRanges k rs =
  List.foldr (\r (rs',k') ->
    let (r_,k_) = case r.val of
      Point e ->
        let (e',k'') = freshen_ k' e in
        (Point e', k'')
      Interval e1 ws e2 ->
        let ((e1',e2'),k'') = U.mapFst U.unwrap2 <| freshenExps k' [e1,e2] in
        (Interval e1' ws e2', k'')
    in
    ({ r | val = r_ } :: rs', k_)
  ) ([],k) rs

-- Record the primary identifier in the EConsts' Locs, where appropriate.
recordIdentifiers (p,e) =
 let ret e__ = P.WithInfo (Exp_ e__ e.val.eid) e.start e.end in
 case (p.val, e.val.e__) of
  (PVar _ x _, EConst ws n (k, b, "") wd) -> ret <| EConst ws n (k, b, x) wd
  (PList _ ps _ mp _, EList ws1 es ws2 me ws3) ->
    case U.maybeZip ps es of
      Nothing  -> ret <| EList ws1 es ws2 me ws3
      Just pes -> let es' = List.map recordIdentifiers pes in
                  let me' =
                    case (mp, me) of
                      (Just p1, Just e1) -> Just (recordIdentifiers (p1,e1))
                      _                  -> me in
                  ret <| EList ws1 es' ws2 me' ws3
  (_, e_) -> ret e_

-- this will be done while parsing eventually...

substPlusOf_ : SubstPlus -> Exp -> SubstPlus
substPlusOf_ substPlus exp =
  let accumulator e s =
    case e.val.e__ of
      EConst _ n (locId,_,_) _ ->
        case Dict.get locId s of
          Nothing ->
            Dict.insert locId { e | val = n } s
          Just existing ->
            if n == existing.val then s else Debug.crash <| "substPlusOf_ Constant: " ++ (toString n)
      _ -> s
  in
  foldExp accumulator substPlus exp


------------------------------------------------------------------------------

-- single    x  =  [x]
-- unsingle [x] =  x

unwrapChars : P.WithInfo (List (P.WithInfo Char)) -> List Char
unwrapChars = List.map .val << .val

isAlpha c        = Char.isLower c || Char.isUpper c
isAlphaNumeric c = Char.isLower c || Char.isUpper c || Char.isDigit c
isWhitespace c   = c == ' ' || c == '\n' || c == '\t'
isIdentChar c    = isAlphaNumeric c || c == '_'
isDelimiter c    = String.any ((==) c) "[]{}()|"
isSymbol c       = not (isAlphaNumeric c || isWhitespace c || isDelimiter c)

parseInt : P.Parser Int
parseInt =
  P.some (P.satisfy Char.isDigit) >>= \cs ->
    let i =
      unwrapChars cs
        |> String.fromList
        |> String.toInt
        |> U.fromOk "Parser.parseInt"
    in
    P.returnWithInfo i cs.start cs.end

parseFloat : P.Parser Float
parseFloat =
  P.some (P.satisfy Char.isDigit) >>= \cs1 ->
  P.satisfy ((==) '.')            >>= \c   ->
  P.some (P.satisfy Char.isDigit) >>= \cs2 ->
    let n =
      unwrapChars cs1 ++ [c.val] ++ unwrapChars cs2
        |> String.fromList
        |> String.toFloat
        |> U.fromOk "Parser.parseFloat"
    in
    P.returnWithInfo n cs1.start cs2.end

parseSign =
  P.option 1 (P.char '-' >>= \c -> P.returnWithInfo (-1) c.start c.end)

parseFrozen =
  string_ frozen <++ string_ thawed <++ string_ assignOnlyOnce <++ string_ unann

string_ s = always s <$> P.token s

parseNum : P.Parser (Num, Frozen)
parseNum =
  parseSign                             >>= \i ->
  parseFloat <++ (toFloat <$> parseInt) >>= \n ->
  parseFrozen                           >>= \b ->
    P.returnWithInfo (i.val * n.val, b.val) i.start b.end

-- TODO allow '_', disambiguate from wildcard in parsePat
parseIdent : P.Parser String
parseIdent =
  P.satisfy isAlpha                 >>= \c ->
  P.many (P.satisfy isIdentChar)    >>= \cs ->
    let x = String.fromList (c.val :: unwrapChars cs) in
    P.returnWithInfo x c.start cs.end

parseStrLit =
  let pred c = isAlphaNumeric c || List.member c (String.toList "#., -():=%;[]") in
  P.between          -- NOTE: not calling delimit...
    (whiteToken "'") --   okay to chew up whitespace here,
    (P.token "'")    --   but _not_ here!
    ((String.fromList << List.map .val) <$> P.many (P.satisfy pred))

munchManySpaces : P.Parser ()
munchManySpaces = always () <$> P.munch isWhitespace

whitespace : P.Parser String
whitespace = P.munch isWhitespace

preWhite : P.Parser a -> P.Parser a
preWhite p = munchManySpaces >>> p

whiteToken = preWhite << P.token
saveToken  = preWhite << string_

-- Token followed by one space, space not munched.
whiteTokenOneWS token =
  P.lookafter (whiteToken token) (P.satisfy isWhitespace)

-- Token followed by one non-alphanumeric non-underscore, space not munched.
whiteTokenOneNonIdent token =
  P.lookafter (whiteToken token) (P.satisfy (not << isIdentChar))

-- Token followed by one non-symbol, space not munched.
whiteTokenOneNonSymbol token =
  P.lookafter (whiteToken token) (P.satisfy (not << isSymbol))

delimit a b = P.between (whiteToken a) (whiteToken b)
parens      = delimit "(" ")"

parseNumV = (\(n,b) -> vConst (n, dummyTrace_ b)) <$> parseNum

parseNumE =
  whitespace                   >>= \ws ->
  parseNum                     >>= \nb ->
  parseMaybeWidgetDecl Nothing >>= \wd ->
    let (n,b) = nb.val in
    -- see other comments about NoWidgetDecl
    case wd.val of
      NoWidgetDecl ->
        P.returnWithInfo (exp_ (EConst ws.val n (dummyLoc_ b) wd)) nb.start nb.end
      _ ->
        P.returnWithInfo (exp_ (EConst ws.val n (dummyLoc_ b) wd)) nb.start wd.end
{-
        let _ =
          if b == unann then ()
          else () -- could throw parse error here
        in
        P.returnWithInfo (EConst n (dummyLoc_ frozen) wd) nb.start wd.end
-}

    -- let end = case wd.val of {NoWidgetDecl -> nb.end ; _ -> wd.end} in
    -- P.returnWithInfo (EConst n (dummyLoc_ b) wd) nb.start end

-- merge conflict:
-- parseNumV = (\(n,b) -> vConst (n, dummyTrace_ b)) <$> parseNum*/
-- parseNumE = (\(n,b) -> exp_ (EConst n (dummyLoc_ b))) <$> parseNum

parseEBase =
  whitespace >>= \ws ->
      (always (exp_ (EBase ws.val (Bool True))) <$> P.token "true")
  <++ (always (exp_ (EBase ws.val (Bool False))) <$> P.token "false")
  <++ ((exp_ << EBase ws.val << String) <$> parseStrLit)

parseVBase =
      (always vTrue  <$> P.token "true")
  <++ (always vFalse <$> P.token "false")
  <++ (vStr <$> parseStrLit)

parsePBase =
  whitespace >>= \ws ->
        ((PConst ws.val << fst) <$> parseNum) -- allowing but ignoring frozen annotation
    <++ (always (PBase ws.val (Bool True)) <$> whiteTokenOneNonIdent "true")
    <++ (always (PBase ws.val (Bool False)) <$> whiteTokenOneNonIdent "false")
    <++ ((PBase ws.val << String) <$> parseStrLit)

-- parseList_
--    : (P.Parser a -> P.Parser sep -> P.Parser (List (P.WithInfo a)))
--   -> String -> P.Parser sep -> String -> P.Parser a -> (List (P.WithInfo a) -> b)
--   -> P.Parser b
-- parseList_ sepBy start sep end p f =
--   whiteToken start >>= \a ->
--   sepBy p sep      >>= \xs ->
--   whiteToken end   >>= \b ->
--     P.returnWithInfo (f xs.val) a.start b.end
--
-- parseList
--    : String -> P.Parser sep -> String -> P.Parser a -> (List (P.WithInfo a) -> b)
--   -> P.Parser b
--
-- parseList  = parseList_ P.sepBy
-- parseList1 = parseList_ P.sepBy1

parseListLiteral p constructor =
  whitespace  >>= \ws1 ->
  P.token "[" >>= \openBracket ->
  (P.many p)  >>= \xs ->
  whitespace  >>= \ws3 ->
  P.token "]" >>= \closeBracket ->
    let constructed =
      constructor ws1.val xs.val "" Nothing ws3.val
    in
    P.returnWithInfo constructed openBracket.start closeBracket.end

parseMultiCons p constructor =
  whitespace  >>= \ws1 ->
  P.token "[" >>= \openBracket ->
  (P.some p)  >>= \xs ->
  whitespace  >>= \ws2 ->
  P.token "|" >>>
  p           >>= \y ->
  whitespace  >>= \ws3 ->
  P.token "]" >>= \closeBracket ->
    let constructed =
      constructor ws1.val xs.val ws2.val (Just y) ws3.val
    in
    P.returnWithInfo constructed openBracket.start closeBracket.end

parseListLiteralOrMultiCons p constructor = P.recursively <| \_ ->
      (parseListLiteral p constructor)
  <++ (parseMultiCons p constructor)

parseE_ : (Exp -> Exp) -> String -> Result String Exp
parseE_ f = P.parse <|
  parseExp       >>= \e ->
  preWhite P.end >>>
    P.returnWithInfo (f e).val e.start e.end

parseE : String -> Result String Exp
parseE = parseE_ freshen

parseVar : P.Parser Exp_
parseVar =
  whitespace >>= \ws ->
    ((exp_ << EVar ws.val) <$> parseIdent)

parseExp : P.Parser Exp_
parseExp = P.recursively <| \_ ->
      parseNumE
  <++ parseEBase
  <++ parseVar
  <++ parseFun
  <++ parseConst -- (pi) etc...
  <++ parseUnop
  <++ parseBinop
  <++ parseIf
  <++ parseCase
  <++ parseExpList
  <++ parseExpIndList
  <++ parseLet
  <++ parseDef
  <++ parseApp
  <++ parseCommentExp
  <++ parseLangOption

parseFun =
  whitespace >>= \ws1 ->
  parens <|
    P.token "\\" >>>
    parsePats    >>= \ps ->
    parseExp     >>= \e ->
    whitespace   >>= \ws2 ->
      P.return (exp_ (EFun ws1.val ps.val e ws2.val))

parseWildcard : P.Parser Pat_
parseWildcard =
  whitespace  >>= \ws ->
  P.token "_" >>>
    P.return (PVar ws.val "_" noWidgetDecl)

parsePVar : P.Parser Pat_
parsePVar =
  whitespace >>= \ws ->
    (\ident -> PVar ws.val ident noWidgetDecl) <$> parseIdent

-- not using this feature downstream, so turning this off
{-
  preWhite parseIdent              >>= \x ->
  parseMaybeWidgetDecl (Just x) >>= \wd ->
    -- see other comments about NoWidgetDecl
    let end = case wd.val of {NoWidgetDecl -> x.end ; _ -> wd.end } in
    P.returnWithInfo (PVar x.val wd) x.start end
-}

parsePat : P.Parser Pat_
parsePat = P.recursively <| \_ ->
      parsePVar
  <++ parsePBase
  <++ parseWildcard
  <++ parsePatList

parsePatList : P.Parser Pat_
parsePatList =
  parseListLiteralOrMultiCons parsePat PList

parsePats : P.Parser (List Pat)
parsePats =
      (parsePat >>= \p -> P.returnWithInfo [p] p.start p.end)
  <++ (parens <| P.many parsePat)

parseMaybeWidgetDecl : Caption -> P.Parser WidgetDecl_
parseMaybeWidgetDecl cap = P.option NoWidgetDecl (parseWidgetDecl cap)
  -- this would be nicer if/when P.Parser is refactored so that
  -- it doesn't have to wrap everything with WithInfo

parseWidgetDecl : Caption -> P.Parser WidgetDecl_
parseWidgetDecl cap =
  P.token "{"       >>= \open ->  -- P.token, so no leading whitespace
  preWhite parseNum >>= \min ->
  saveToken "-"     >>= \tok ->
  preWhite parseNum >>= \max ->
  whiteToken "}"    >>= \close ->
  -- for now, not optionally parsing a caption here
    let a = { min | val = fst min.val } in
    let b = { max | val = fst max.val } in
    let wd =
      if List.all isInt [a.val, b.val] then
        let a' = { a | val = floor a.val } in
        let b' = { b | val = floor b.val } in
        IntSlider a' tok b' cap
      else
        NumSlider a tok b cap
    in
    P.returnWithInfo wd open.start close.end

isInt : Float -> Bool
isInt n = n == toFloat (floor n)

parseApp =
  whitespace >>= \ws1 ->
  parens <|
    parseExp     >>= \f ->
    parseExpArgs >>= \es ->
    whitespace   >>= \ws2 ->
      P.return (exp_ (EApp ws1.val f es.val ws2.val))

parseExpArgs = P.many parseExp

parseExpList =
  exp_ <$> parseListLiteralOrMultiCons parseExp EList

parseExpIndList =
  whitespace           >>= \ws1 ->
  P.token "[|"         >>= \opening ->
  (P.many parseERange) >>= \rs ->
  whitespace           >>= \ws2 ->
  P.token "|]"         >>= \closing ->
    P.returnWithInfo (exp_ <| EIndList ws1.val rs.val ws2.val) opening.start closing.end

parseERange =
  (parseInterval <++ parsePoint)

{-
parseNumEAndFreeze =
  (\(EConst n (i,_,x)) -> EConst n (i,frozen,x)) <$> parseNumE
-}

-- Toggle this to automatically freeze all range numbers
parseBound =
  parseNumE
  -- parseNumEAndFreeze

parsePoint : P.Parser Range_
parsePoint =
  parseBound >>= \e ->
    P.return (Point e)

parseInterval =
  parseBound   >>= \e1 ->
  whitespace   >>= \ws ->
  P.token ".." >>>
  parseBound   >>= \e2 ->
    P.return (Interval e1 ws.val e2)

parseRec =
      (always True  <$> whiteTokenOneWS "letrec")
  <++ (always False <$> whiteTokenOneWS "let")

parseLet =
  whitespace >>= \ws1 ->
  parens <|
    parseRec   >>= \b ->
    parsePat   >>= \p ->
    parseExp   >>= \e1 ->
    parseExp   >>= \e2 ->
    whitespace >>= \ws2 ->
      P.return (exp_ (ELet ws1.val Let b.val p e1 e2 ws2.val))

parseDefRec =
      (always True  <$> whiteTokenOneWS "defrec")
  <++ (always False <$> whiteTokenOneWS "def")

parseDef =
  whitespace >>= \ws1 ->
  parens (
      parseDefRec >>= \b ->
      parsePat    >>= \p ->
      parseExp    >>= \e1 ->
      whitespace  >>= \ws2 -> P.return (b,p,e1,ws2)
    )
           >>= \def ->
  parseExp >>= \e2 ->
    let (b,p,e1,ws2) = def.val in
    P.returnWithInfo (exp_ (ELet ws1.val Def b.val p e1 e2 ws2.val)) def.start def.end

parseBinop =
  whitespace >>= \ws1 ->
  parens <|
    parseBOp   >>= \op ->
    parseExp   >>= \e1 ->
    parseExp   >>= \e2 ->
    whitespace >>= \ws2 ->
      P.return (exp_ (EOp ws1.val op [e1,e2] ws2.val))

parseBOp =
      (always Plus    <$> whiteTokenOneNonSymbol "+")
  <++ (always Minus   <$> whiteTokenOneNonSymbol "-")
  <++ (always Mult    <$> whiteTokenOneNonSymbol "*")
  <++ (always Div     <$> whiteTokenOneNonSymbol "/")
  <++ (always Lt      <$> whiteTokenOneNonSymbol "<")
  <++ (always Eq      <$> whiteTokenOneNonSymbol "=")
  <++ (always Mod     <$> whiteTokenOneWS "mod")
  <++ (always Pow     <$> whiteTokenOneWS "pow")
  <++ (always ArcTan2 <$> whiteTokenOneWS "arctan2")

parseUnop =
  whitespace >>= \ws1 ->
  parens <|
    parseUOp   >>= \op ->
    parseExp   >>= \e1 ->
    whitespace >>= \ws2 ->
      P.return (exp_ (EOp ws1.val op [e1] ws2.val))

parseUOp =
      (always Cos     <$> whiteTokenOneWS "cos")
  <++ (always Sin     <$> whiteTokenOneWS "sin")
  <++ (always ArcCos  <$> whiteTokenOneWS "arccos")
  <++ (always ArcSin  <$> whiteTokenOneWS "arcsin")
  <++ (always Floor   <$> whiteTokenOneWS "floor")
  <++ (always Ceil    <$> whiteTokenOneWS "ceiling")
  <++ (always Round   <$> whiteTokenOneWS "round")
  <++ (always ToStr   <$> whiteTokenOneWS "toString")
  <++ (always Sqrt    <$> whiteTokenOneWS "sqrt")

-- Parse (pi) etc...
parseConst =
  whitespace >>= \ws1 ->
  parens <|
    parseNullOp >>= \op ->
    whitespace  >>= \ws2 ->
      P.return (exp_ (EOp ws1.val op [] ws2.val))

parseNullOp =
  always Pi <$> whiteTokenOneNonIdent "pi"

parseIf =
  whitespace >>= \ws1 ->
  parens <|
    whiteTokenOneWS "if" >>>
    parseExp        >>= \e1 ->
    parseExp        >>= \e2 ->
    parseExp        >>= \e3 ->
    whitespace      >>= \ws2 ->
      P.return (exp_ (EIf ws1.val e1 e2 e3 ws2.val))

parseCase =
  whitespace >>= \ws1 ->
  parens <|
    whiteTokenOneWS "case"    >>>
    parseExp             >>= \e ->
    (P.some parseBranch) >>= \bs ->
    whitespace           >>= \ws2 ->
      P.return (exp_ (ECase ws1.val e bs.val ws2.val))

parseBranch : P.Parser Branch_
parseBranch =
  whitespace >>= \ws1 ->
  parens <|
    parsePat   >>= \p ->
    parseExp   >>= \e ->
    whitespace >>= \ws2 ->
      P.return (Branch_ ws1.val p e ws2.val)

parseCommentExp =
  whitespace                     >>= \ws ->
  P.token ";"                    >>= \semi ->
  P.many (P.satisfy ((/=) '\n')) >>= \cs ->
  P.satisfy ((==) '\n')          >>= \newline ->
  parseExp                       >>= \e ->
    P.returnWithInfo
      (exp_ (EComment ws.val (String.fromList (unwrapChars cs)) e))
      semi.start e.end

parseLangOption =
  let p = preWhite (P.munch1 (\c -> c /= '\n' && c /= ' ' && c /= ':')) in
  whitespace                    >>= \ws1 ->
  P.token "#"                   >>= \pound ->
  p                             >>= \s1 ->
  whiteToken ":"                >>>
  whitespace                    >>= \ws2 ->
  p                             >>= \s2 ->
  P.many (P.satisfy ((==) ' ')) >>>
  P.satisfy ((==) '\n')         >>>
  parseExp                      >>= \e ->
    P.returnWithInfo (exp_ (EOption ws1.val s1 ws2.val s2 e)) pound.start e.end
