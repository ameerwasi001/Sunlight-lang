module Parser where

import Control.Applicative as Applicative
import Control.Monad
import Data.Char
import Nodes
import Data.List
import Data.Void
import EitherUtility
import Text.Megaparsec as P
import Text.Megaparsec.Char
import MergeDefs
import qualified Text.Megaparsec.Char.Lexer as L

import Debug.Trace

lower = oneOf "abcdefghijklmnopqrstuvwxyz" :: Parser Char
upper = oneOf "ABCDEFGHIJKLMNOPQRSTUVWXYZ" :: Parser Char
digit = oneOf "1234567890" :: Parser Char
newline = oneOf "\n;" :: Parser Char
newlines = P.many Parser.newline
space = char ' '
spaces = P.many Parser.space
mspaces = Parser.space *> Parser.spaces
keyword k = Text.Megaparsec.Char.string (showL k) :: Parser String

notKeyword = try $ notFollowedBy $ choice keywords *> Text.Megaparsec.Char.string " " where
    keywords = map (Text.Megaparsec.Char.string . showL) [Parser.If ..]

showL k = map toLower (show k)

data Keyword =
    If
    | Then
    | Else
    | True
    | False
    | Class
    | End
    | Where
    | Include
    | Open
    | Mod
    | Lib
    | Def
    | External
    deriving(Show, Eq, Enum)

type Parser = Parsec Void String

eofString :: Parser String
eofString = "" <$ eof

string :: Char -> Parser Node
string c =
    do
        pos <- getSourcePos
        str <- (char c *> manyTill L.charLiteral (char c)) :: Parser String
        return $ StringNode str pos

number :: Parser Node
number =
    do
        pos <- getSourcePos
        fs <- digit :: Parser Char
        str <- P.many digit :: Parser String
        return $ NumNode (fs : str) pos

fractional :: Parser Node
fractional =
    do
        pos <- getSourcePos
        dec <- number
        Text.Megaparsec.Char.string "." :: Parser String
        frac <- number
        return $ NumNode (extractString dec ++ "." ++ extractString frac) pos

identifier :: Bool -> Parser Node
identifier sQuote = 
    do
        pos <- getSourcePos
        notKeyword
        a <- Text.Megaparsec.Char.string "$" <|> Text.Megaparsec.Char.string ""
        fc <- lower
        l <- if sQuote then P.many allowedPs <* char '\'' else P.many allowedPs
        let el = (a ++ [fc]) ++ l
        return $ IdentifierNode el pos
    <|> (
        (\pos str -> IdentifierNode ("{" ++ str ++ "}") pos) 
        <$> getSourcePos 
        <*> if sQuote then allSyms <* char '\'' else allSyms
        )
    <|> nsAccess
    where

        allSyms = Text.Megaparsec.Char.string "{" *> manyTill L.charLiteral (char '}')

        allowedPs = lower <|> upper <|> digit <|> undersore

        undersore = (
            (char '_' :: Parser Char) 
                <* notFollowedBy (char '_' :: Parser Char)
            ) :: Parser Char
        nsAccess =
            do
                t1 <- dataName
                termSuffix t1       
        termSuffix t1 = try $ unTrySuffix t1
        unTrySuffix t1 =
            do
                s <- singleSuffix t1
                loop s
        singleSuffix t1 =
            do
                pos <- getSourcePos
                op <- Text.Megaparsec.Char.string "::"
                t2 <- dataName <|> identifier Prelude.False
                loop $ IdentifierNode (extractString t1 ++ "__" ++ extractString t2) pos
        loop t = (unTrySuffix t <|> return t) :: Parser Node

undersoreIdentifier :: Parser Node
undersoreIdentifier = (flip IdentifierNode <$> getSourcePos <*> Text.Megaparsec.Char.string "_") <|> identifier Prelude.False

dataName :: Parser Node
dataName =
    try nsDataAccess <|> dataNameFormula
    where
        dataNameFormula =
            do
                pos <- getSourcePos
                a <- Text.Megaparsec.Char.string "$" <|> Text.Megaparsec.Char.string ""
                fc <- upper
                l <- P.many (lower <|> upper <|> digit)
                return $ DataNode ((a ++ [fc]) ++ l) pos
        nsDataAccess =
            do
                t1 <- dataNameFormula
                termSuffix Nothing t1      
            where 
                termSuffix stp t1 = try $ unTrySuffix stp t1
                unTrySuffix stp t1 =
                    do
                        s <- singleSuffix stp t1
                        loop stp s
                singleSuffix stp t1 =
                    do
                        pos <- getSourcePos
                        op <- Text.Megaparsec.Char.string "::"
                        t2 <- dataNameFormula
                        x stp t1 t2 pos

                loop :: Maybe Node -> Node -> Parser Node
                loop stp t = case stp of
                    Just a -> return a
                    Nothing -> unTrySuffix Nothing t <|> return t :: Parser Node

                x stp t1 t2 pos =
                    (
                        lookAhead (Text.Megaparsec.Char.string "::" :: Parser String) *> 
                            loop stp v
                    ) <|> loop (Just v) v where
                        v = DataNode (extractString t1 ++ "__" ++ extractString t2) pos

structInstanceExpr :: Parser Node
structInstanceExpr = 
    do
        pos <- getSourcePos
        id <- dataName
        try (
            do
                Text.Megaparsec.Char.string "{"
                ls <- spaces *> seqInstance <* spaces
                Text.Megaparsec.Char.string "}"
                return $ StructInstanceNode id ls Prelude.False pos
            ) <|> return (StructInstanceNode id [] Prelude.False pos)
    where
        seqInstance :: Parser [Node]
        seqInstance = commaSep seqPair

        seqPair :: Parser Node
        seqPair =
            do
                id <- identifier Prelude.False
                spaces
                Text.Megaparsec.Char.string "::"
                spaces
                pos <- getSourcePos
                thing <- expr
                return $ DeclNode id thing pos

commaSep p  = p `sepBy` (try (spaces *> Text.Megaparsec.Char.string ", " <* spaces) :: Parser String)

list :: Parser Node
list = 
    do
        pos <- getSourcePos
        Text.Megaparsec.Char.string "["
        spaces
        ls <- commaSep Parser.expr
        spaces
        Text.Megaparsec.Char.string "]"
        return $ ListNode ls pos

tuple :: Parser Node
tuple =
    do
        pos <- getSourcePos
        Text.Megaparsec.Char.string "("
        spaces
        ls <- commaSep Parser.expr
        spaces
        Text.Megaparsec.Char.string ")"
        return $ TupleNode ls pos
    where
        commaSep p  = 
            try (p `endBy` (spaces *> Text.Megaparsec.Char.string "," <* spaces :: Parser String))
            <|> p `sepBy` (spaces *> Text.Megaparsec.Char.string "," <* spaces :: Parser String)

prefix = choice $ map try [
            Parser.ifExpr,
            Parser.lambdaExpr,
            Parser.parens,
            accessFuncExpr,
            Parser.negExpr,
            Parser.boolean,
            Parser.tuple,
            Parser.caseExpr,
            Parser.list,
            Parser.string '"', 
            Parser.fractional, 
            Parser.number,
            Parser.containerFunction "(" ")" "," TupleNode,
            Parser.containerFunction "[" "]" "," ListNode,
            Parser.structInstanceExpr <* notFollowedBy (Text.Megaparsec.Char.string "::"),
            Parser.identifier Prelude.False
            ]

atom = 
    do
        pos <- getSourcePos
        pre <- prefix
        try
            $ do 
                xId <- identifier Prelude.False
                return $ CallNode xId [pre] pos
                <|> (pre <$ Text.Megaparsec.Char.string "")

containerFunction :: String -> String -> String -> ([Node] -> P.SourcePos -> Node) -> Parser Node
containerFunction strt end sep f =
    do
        pos <- getSourcePos
        Text.Megaparsec.Char.string strt
        fstComma <- comma
        commas <- P.many comma
        Text.Megaparsec.Char.string end
        let args = map (flip IdentifierNode pos . (\a -> "x" ++ show a)) [1 .. length commas + 2]
        return $ FuncDefNode Nothing args (f args pos) Prelude.False pos
    where comma = spaces *> Text.Megaparsec.Char.string sep <* spaces

typeRef =
    do
        pos <- getSourcePos
        spaces
        Text.Megaparsec.Char.string "&"
        spaces
        e <- dataName
        spaces
        return $ TypeRefNode e pos

lambdaExpr =
    do
        pos <- getSourcePos
        hashes <- explicitHash Prelude.True
        Text.Megaparsec.Char.string "\\"
        spaces
        try (fullLamba hashes pos) <|> basicLambda hashes pos
    where
        fullLamba h pos =
            do
                args <- undersoreIdentifier `sepBy1` (Text.Megaparsec.Char.string "," <* spaces)
                spaces
                Text.Megaparsec.Char.string "->"
                spaces
                e <- logicalExpr
                return $ FuncDefNode Nothing args e h pos
        
        basicLambda h pos =
            do
                e <- logicalExpr
                return $ FuncDefNode Nothing [IdentifierNode "x" pos] e h pos

boolean =
    do
        pos <- getSourcePos
        b <- keyword Parser.True <|> keyword Parser.False
        return $ BoolNode b pos

parens =
    do
        Text.Megaparsec.Char.string "("
        newlines
        spaces
        newlines
        spaces
        e <- whereExpr
        newlines
        spaces
        newlines
        spaces
        char ')'
        return e

rBinOp :: Parser Node -> Parser String ->  Parser Node -> (Node -> String -> Node -> SourcePos -> Node) -> Parser Node
rBinOp fa ops fb ret =
    do
        pos <- getSourcePos
        spaces
        a <- fa
        try (
            do
                spaces
                op <- ops
                spaces
                b <- fb
                return $ ret a op b pos
            ) <|> return a

binOp f ops ret = do
  t1 <- f
  loop t1
  where termSuffix t1 = try (do
          pos <- getSourcePos
          spaces
          op <- ops
          spaces
          t2 <- f
          loop (ret t1 op t2 pos))
        loop t = termSuffix t <|> return t

lhs =
    do
        id <- mainLhs
        spaces
        Text.Megaparsec.Char.string "<-"
        return id
    where
        mainLhs = try fDef 
            <|> identifier Prelude.False 
            <|> flip TupleNode <$> getSourcePos <*> (
                Text.Megaparsec.Char.string "(" *> spaces *>
                    undersoreIdentifier `sepBy` (Text.Megaparsec.Char.string "," <* spaces)
                    <* spaces <* Text.Megaparsec.Char.string ")"
            )
            <|> destructureExpr

        destructureExpr = 
            do
                pos <- getSourcePos
                ls <- Text.Megaparsec.Char.string "{" *> spaces *>
                        undersoreIdentifier `sepBy1` (Text.Megaparsec.Char.string "," <* spaces) 
                    <* spaces <* Text.Megaparsec.Char.string "}"
                return $ DeStructure ls pos

        fDef =
            do
                pos <- getSourcePos
                callee <- identifier Prelude.False
                spaces *> Text.Megaparsec.Char.string ":" <* spaces
                args <- undersoreIdentifier `sepBy1` (Text.Megaparsec.Char.string "," <* spaces)
                spaces
                return $ CallNode callee args pos

structDef =
    do
        pos <- getSourcePos
        id <- dataName
        spaces
        Text.Megaparsec.Char.string "<-"
        spaces
        try (structs id) <|> fields id pos
    where
        structs overarch =
            do
                pos <- getSourcePos
                sts <- structInstanceExpr `sepBy1` 
                    try (spaces *> newlines *> spaces *> Text.Megaparsec.Char.string "|" <* spaces <* newlines <* spaces)
                let ls = zip3 (map extractMId sts) (map extractIds sts) (map extractStrict sts)
                let defs = map (\(id, xs, stct) -> StructDefNode id xs stct (Just overarch) pos) ls
                let fdefs = map makeFun defs
                return $ MultipleDefinitionNode $ SumTypeNode defs pos : fdefs

        lowId (DataNode id pos) = IdentifierNode (toLower (head id) : tail id) pos
        lowId (IdentifierNode id pos) = IdentifierNode (map toLower id) pos
        makeFun strct@(StructDefNode id xs _ _ pos) = 
            if null xs then 
                FromStruct $ DeclNode (lowId id) (instantiate xs strct) pos
            else
                FromStruct $ DeclNode (lowId id) (FuncDefNode (Just $ lowId id) xs (instantiate xs strct) Prelude.False pos) pos

        instantiate rhss (StructDefNode id lhss b _ pos) = StructInstanceNode id (zipWith (\a b -> DeclNode a b pos) rhss lhss) b pos 

        extractIds strct@(StructInstanceNode _ ls _ _) = snd (extractStructInstance strct)

        extractMId strct@(StructInstanceNode id _ _ _) = id

        extractStrict strct@(StructInstanceNode _ _ stct _) = stct

        fields id pos =
            do
                a <- (Text.Megaparsec.Char.string "!" <* spaces) <|> Text.Megaparsec.Char.string ""
                ls <- Text.Megaparsec.Char.string "{" *> commaSep (identifier Prelude.False) <* Text.Megaparsec.Char.string "}"
                let stDef = StructDefNode id ls (a /= "") Nothing pos
                let fDef = makeFun stDef
                return $ MultipleDefinitionNode $ stDef : [fDef]

        structInstanceExpr = 
            se <|> e where 
                se =
                    do
                        pos <- getSourcePos
                        Text.Megaparsec.Char.string "!" <* spaces 
                        ins <- structInstanceExpr
                        return $ StructInstanceNode (extractMId ins) (extractIds ins) Prelude.True pos
                e =
                    do
                        pos <- getSourcePos
                        id <- dataName
                        try (
                            do
                                Text.Megaparsec.Char.string "{"
                                ls <- seqInstance
                                Text.Megaparsec.Char.string "}"
                                return $ StructInstanceNode id ls Prelude.False pos
                            ) <|> return (StructInstanceNode id [] Prelude.False pos)
                seqInstance = commaSep seqPair
                seqPair = do 
                    id <- identifier Prelude.False
                    IdentifierNode (extractString id) <$> getSourcePos

explicitHash :: Bool -> Parser Bool
explicitHash def = f <$> (Text.Megaparsec.Char.string "!" <|> Text.Megaparsec.Char.string "~" <|> Text.Megaparsec.Char.string "") where
    f "!" = Prelude.True
    f "~" = Prelude.False
    f "" = def

decl =
    do
        pos <- getSourcePos
        hashes <- explicitHash Prelude.False
        id <- lhs
        new_id <- 
            case id of
                (CallNode c arg _) -> return c
                _ -> return id
        spaces
        e <- whereExpr
        new_e <- 
            case id of
                (CallNode c arg _) -> return $ FuncDefNode (Just c) arg e hashes pos
                _ -> return e
        return $ DeclNode new_id new_e pos

includes iType =
    do
        pos <- getSourcePos
        P.many Parser.newline
        is <- include `sepBy` try (spaces *> newlines *> spaces *> lookAhead include <* spaces <* newlines <* spaces) 
        return $ ListNode is pos
    where
        include :: Parser Node
        include =
            do
                pos <- getSourcePos
                keyword iType
                mspaces
                Parser.string '"'

modStmnt =
    do
        pos <- getSourcePos
        mname <- keyword Mod *> spaces *> dataName <* newlines <* spaces
        ds <- (spaces *> newlines *> spaces *> (try mewMethod <|> try methodDecl <|> try classStmnt <|> try structDef <|> decl )) 
            `sepBy1` notFollowedBy (newlines *> spaces *> newlines *> (keyword End <|> eofString))
        newlines *> spaces *> newlines *> (keyword End <|> eofString)
        let tds = map (differLhs mname) ds
        let flist = map (getDollar $ extractString mname) tds
        return $ MultipleDefinitionNode flist
    where
        differLhs :: Node -> Node -> Node
        differLhs mn (IdentifierNode id pos) = IdentifierNode (extractString mn ++ "__" ++ id) pos
        differLhs mn (DataNode id pos) = DataNode (extractString mn ++ "__" ++ id) pos
        differLhs mn (TupleNode ts pos) = TupleNode (map (differLhs mn) ts) pos
        differLhs mn (DeclNode lhs rhs pos) = DeclNode (differLhs mn lhs) (changeFun mn rhs) pos
        differLhs mn (StructDefNode id x st (Just o) pos) = StructDefNode (differLhs mn id) x st (Just $ differLhs mn o) pos
        differLhs mn (StructDefNode id x stct Nothing pos) = StructDefNode (differLhs mn id) x stct Nothing pos
        differLhs mn (DeStructure ids pos) = DeStructure (map (differLhs mn) ids) pos
        differLhs mn (SumTypeNode ds pos) = SumTypeNode (map (differLhs mn) ds) pos
        differLhs mn (MethodNode id args pos) = MethodNode (differLhs mn id) args pos
        differLhs mn (MultipleDefinitionNode ds) = MultipleDefinitionNode $ map (differLhs mn) ds
        differLhs mn (FromStruct (DeclNode lhs (FuncDefNode (Just id) args (StructInstanceNode sid sargs b spos) h pos) dpos)) =
            FromStruct $ 
                DeclNode (differLhs mn lhs) 
                (FuncDefNode (Just $ differLhs mn id) args (StructInstanceNode (differLhs mn sid) sargs b spos) h pos) 
                dpos
        differLhs mn (FromStruct (DeclNode lhs (StructInstanceNode sid sargs b spos) pos)) =
            FromStruct $ 
                DeclNode (differLhs mn lhs) 
                (StructInstanceNode (differLhs mn sid) sargs b spos)
                pos
        differLhs mn nm@NewMethodNode{} = nm
        differLhs _ a = error(show a ++ "\n")

        changeFun mn (FuncDefNode (Just id) args e h pos) = FuncDefNode (Just $ differLhs mn id) args e h pos
        changeFun mn n = n

externals = 
    do
        pos <- getSourcePos
        keyword External
        libName <- spaces *> Parser.string '"' <* spaces
        exts <- Text.Megaparsec.Char.string "{" *> spaces *> commaSep (identifier Prelude.False) <* spaces <* Text.Megaparsec.Char.string "}"
        return $ ExternalNode libName exts pos

decls xs =
    do
        pos <- getSourcePos
        P.many Parser.newline
        a <- includes Lib
        P.many Parser.newline
        b <- includes Mod
        exts <- newlines *> spaces *> P.many (externals <* spaces <* newlines)
        P.many Parser.newline
        spaces
        dcs <- 
             (++ exts) <$>
                (pref *>
                    (try mewMethod <|> try methodDecl <|> try classStmnt <|> try structDef <|> decl <|> modStmnt))
                    `endBy` (eofString <|> (spaces *> Parser.newline *> P.many Parser.newline <* spaces :: Parser String))
        return $ ProgramNode (concatLists dcs $ getLists xs) pos
    where
        pref = 
            P.many (Text.Megaparsec.Char.string "--" *> manyTill (L.charLiteral <|> char '\\') (char '\n' :: Parser Char) *> P.many (Text.Megaparsec.Char.string "\n")) 
                <|> ((\a -> [[a]]) <$> Text.Megaparsec.Char.string "")
        getLists ns = map extractList ns

        concatLists dcs [] = dcs
        concatLists dcs xs = Data.List.concat xs ++ dcs

whereExpr =
    do 
        rns <- expr
        try (
                do
                    pos <- getSourcePos
                    mspaces
                    keyword Where
                    spaces
                    ds <- (newlines *> spaces *> (try classStmnt <|> try decl)) `sepBy1` notFollowedBy (spacificSpaces *> keyword End)
                    spacificSpaces *> keyword End
                    return $ WhereNode rns ds pos
            ) <|> return rns
    where
        spacificSpaces = (spaces *> newlines *> spaces) <|> (spaces *> Parser.newline *> newlines *> spaces)

expr =
    do 
        pos <- getSourcePos
        xs pos  
    where
        spacificSpaces = (spaces *> newlines *> spaces) <|> (Parser.newline *> newlines *> spaces)
        xs :: SourcePos -> Parser Node
        xs pos = backExpr `sepBy1` try (spaces *> Text.Megaparsec.Char.string "|>" <* spaces) >>= \l -> return $ foldr (\a b -> CallNode a [b] pos) (head l) (reverse $ tail l)

backExpr =
    do
        pos <- getSourcePos
        bs pos 
    where
        bs :: SourcePos -> Parser Node
        bs pos = 
            do
                logicalExpr `sepBy1` try (spaces *> Text.Megaparsec.Char.string "<|" <* spaces) >>=
                    \xs -> let (l:ls) = reverse xs in return $ foldl (\a b -> CallNode b [a] pos) l ls

logicalExpr = binOp compExpr (Text.Megaparsec.Char.string "&" <|> Text.Megaparsec.Char.string "|") BinOpNode

compExpr = binOp typeExpr ops BinOpNode where
    ops =
        (
        Text.Megaparsec.Char.string "=" 
        <|> Text.Megaparsec.Char.string "/="
        <|> Text.Megaparsec.Char.string ">="
        <|> Text.Megaparsec.Char.string ">"
        <|> Text.Megaparsec.Char.string "<="
        <|> Text.Megaparsec.Char.string "<"
        ) :: Parser String

typeExpr = rBinOp arithExpr (Text.Megaparsec.Char.string "@") (dataName <|> arithExpr) BinOpNode

arithExpr = binOp term (Text.Megaparsec.Char.string "+" <|> Text.Megaparsec.Char.string "-") BinOpNode

term = binOp Parser.concat (Text.Megaparsec.Char.string "*" <|> Text.Megaparsec.Char.string "/") BinOpNode

concat = binOp infixOp (Text.Megaparsec.Char.string "..") BinOpNode

infixOp = rBinOp infixLOp op infixOp (\a op b pos -> CallNode (IdentifierNode op pos) [a, b] pos) where
    op = do extractString <$> identifier Prelude.False

infixLOp = binOp application op (\a op b pos -> CallNode (IdentifierNode op pos) [a, b] pos) where
    op = do extractString <$> identifier Prelude.True

application =
    do
        pos <- getSourcePos
        callee <- index
        try (
            do
                m <- mid
                let args = arr m where arr(ListNode arr _) = arr
                return $ CallNode callee args pos
            ) <|> return callee
        where
            mid = 
                do
                    pos <- getSourcePos
                    spaces *> Text.Megaparsec.Char.string ":" <* spaces
                    args <- (typeRef <|> logicalExpr) `sepEndBy1` (Text.Megaparsec.Char.string "," <* spaces)
                    return $ ListNode args pos

index = 
    do
        pos <- getSourcePos
        og <- access
        ls <- P.many tIndex
        return $ case last $ Just og : ls of 
            Just _ -> folded og ls pos
            Nothing -> FuncDefNode Nothing [IdentifierNode "elwegot" pos] (folded og ls pos) Prelude.True pos
    where
        folded og ls pos = foldr (makeCall pos) og (reverse ls)

        makeCall pos fa b = case fa of
            Just a -> CallNode (IdentifierNode "access" pos) [a, b] pos
            Nothing -> CallNode (IdentifierNode "access" pos) [b, IdentifierNode "elwegot" pos] pos
        tIndex =
            try (do
                    Text.Megaparsec.Char.string "["
                    e <- expr
                    Text.Megaparsec.Char.string "]"
                    return $ Just e)
            <|> 
            do
                Text.Megaparsec.Char.string "["
                Text.Megaparsec.Char.string "]"
                return Nothing

access =  
    do
        pos <- getSourcePos
        l <- atom `sepBy1` try (spaces *> Text.Megaparsec.Char.string "." <* notFollowedBy (Text.Megaparsec.Char.string ".") <* spaces)
        let mpl = map makeBin (tail l)
        return $ foldl' (\a b -> BinOpNode a "." b pos) (head l) mpl
    where
        makeBin :: Node -> Node
        makeBin n@(BinOpNode a op b pos) = BinOpNode a op (makeBin b) pos
        makeBin n@(IdentifierNode s pos) = StringNode s pos
        makeBin n = n

methodDecl = 
    do
        pos <- getSourcePos
        keyword Open
        spaces
        id <- identifier Prelude.False
        spaces *> Text.Megaparsec.Char.string ":" <* spaces
        args <- identifier Prelude.False `sepBy1` (Text.Megaparsec.Char.string "," <* spaces)
        return $ MethodNode id args pos

mewMethod =
    do
        pos <- getSourcePos
        id <-  identifier Prelude.False
        spaces *> Text.Megaparsec.Char.string "?" <* spaces
        cond <- (IdentifierNode "def" pos <$ try (keyword Def)) <|> expr
        spaces
        Text.Megaparsec.Char.string "->"
        spaces
        exp <- expr
        return $ NewMethodNode id cond exp pos

classStmnt =
    do
        pos <- getSourcePos
        keyword Class
        spaces
        id <- identifier Prelude.False
        spaces *> Text.Megaparsec.Char.string ":" <* spaces
        args <- identifier Prelude.False `sepBy1` (Text.Megaparsec.Char.string "," <* spaces)
        newlines
        seqPos <- getSourcePos
        allCases <- cases `sepBy1` 
            notFollowedBy (try 
                (P.many Parser.newline *> spaces *> (
                    eof *> (StringNode "" <$> getSourcePos)
                    <|> keyword Class *> (StringNode "" <$> getSourcePos)
                    <|> keyword Open *> (StringNode "" <$> getSourcePos)
                    <|> keyword End *> (StringNode "" <$> getSourcePos)
                    <|> try decl 
                    <|> structDef
                    <|> mewMethod)))
        return $ DeclNode id (FuncDefNode (Just id) args (SequenceIfNode allCases seqPos) Prelude.True seqPos) pos
    where
        cases = do
            newlines
            spaces
            pos <- getSourcePos
            spaces
            cond <- expr
            spaces
            Text.Megaparsec.Char.string "->"
            spaces
            thenExpr <- expr
            return $ IfNode cond thenExpr Nothing pos
        mnewlines = Parser.newline *> newlines

prefixExpr pref expT resf construct = 
    do
        pos <- getSourcePos
        prefT <- pref
        Parser.spaces
        expr <- expT
        return $ construct (resf prefT) expr pos

negExpr = prefixExpr (Text.Megaparsec.Char.string "-") compExpr (const "-") UnaryExpr

accessFuncExpr :: Parser Node
accessFuncExpr = prefixExpr 
    (Text.Megaparsec.Char.string ".")
    (identifier Prelude.False)
    id
    (\_ (IdentifierNode id ipos) pos -> 
        FuncDefNode 
            Nothing 
            [IdentifierNode "x" ipos] 
            (BinOpNode (IdentifierNode "x" ipos) "." (StringNode id ipos) pos)
            Prelude.False
            pos
        )

ifExpr =
    do
        pos <- getSourcePos
        keyword If
        mspaces
        c <- expr
        mspaces
        keyword Then
        mspaces
        te <- expr
        mspaces
        keyword Else
        mspaces
        ee <- expr
        return $ IfNode c te (Just ee) pos

caseExpr =
    do
        pos <- getSourcePos
        Text.Megaparsec.Char.string "|"
        spaces
        fls <- p `sepBy` (spaces *> Text.Megaparsec.Char.string "|" <* spaces :: Parser String)
        return $ SequenceIfNode fls pos 
    where 
        p = 
            do
                pos <- getSourcePos                
                ce <- expr
                spaces
                Text.Megaparsec.Char.string "->"
                spaces
                te <- expr
                return $ IfNode ce te Nothing pos

parse xs = decls xs <* eof
