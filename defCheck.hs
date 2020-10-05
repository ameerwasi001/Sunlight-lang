module DefCheck where

import Data.Void
import Data.List
import Parser hiding (True, False)
import Debug.Trace
import Data.Hashable
import ReduceMethods
import EitherUtility
import Data.Maybe
import Scope
import qualified Data.Set as Set
import qualified Text.Megaparsec as P

-- Get a list of duplicates from a list of things
repeated :: Ord a => [a] -> [a]
repeated = repeatedBy (>1) where
    repeatedBy p = map head . filterByLength p
    filterByLength p = filter (p . length) . sg
    sg = group . sort

-- Define all top-level definitions
define :: [StringPos] -> Node -> [StringPos]
define ds (IdentifierNode id pos) = ds ++ [StringPos id pos]
define ds (DataNode id pos) = ds ++ [StringPos id pos]
define ds (TupleNode t _) = concatMap (define ds) t
define ds (ProgramNode ns _) = concatMap (define ds) ns
define ds (DeclNode lhs _ _) = define ds lhs
define ds (StructDefNode id _ (Just (DataNode o dtpos)) pos) = define ds id ++ [StringPos o dtpos]
define ds (StructDefNode id _ Nothing _) = define ds id
define ds (DeStructure dcs _) = concatMap (define ds) dcs
define ds (SumTypeNode (dc:dcs) pos) = 
    define ds dc ++ concatMap (define ds) (map (\(StructDefNode id args ov pos) -> StructDefNode id args Nothing pos) dcs)
define ds (SumTypeNode a _) = define ds (head a)
define ds (MethodNode id _ _) = define ds id 
define ds NewMethodNode{} = ds

-- Define function arguments and where clauses
define ds (FuncDefNode _ _ args _ _) = ds ++ concatMap (define ds) args
define ds (WhereNode _ dcs _) = ds ++ concatMap (define ds) dcs
define ds a = error(show a)

-- Run definition checker
runDefiner :: Either String Node -> Maybe Scope -> Either String (Node, Scope)
runDefiner le@(Left e) parent = Left e
runDefiner (Right n) parent = 
    case repeated defs of
        [] -> Right (n, Scope (Set.fromList defs) parent)
        ls -> Left $ intercalate "\n\n" $ map (\(StringPos str pos) -> "Duplicate definition " ++ str ++ "\n" ++ showPos pos) ls
    where
        defs = define [] n ++ 
            case parent of 
                Just _ -> []
                Nothing -> zipWith StringPos baseSymbols (map (const pos) baseSymbols)
        posFromProgram (ProgramNode _ pos) = pos
        pos = posFromProgram n
        baseSymbols = [
            "+", "-", "*", "/", 
            "and", "or", "not", "@", 
            "=", "/=", ">=", "<=", 
            "<", ">", "..", ".", 
            "head", "tail", "SltList", "SltNum",
            "SltString", "SltTuple", "SltBool", "SltFunc"
            ]

ioDefiner :: Either (P.ParseErrorBundle String Data.Void.Void) Node -> Maybe Scope -> IO ()
ioDefiner fa b =
        case runDefiner a b of
            Left e -> putStrLn e
            Right (_, a) -> print a 
        where 
            a :: Either String Node
            a = case fa of
                    Left e -> Left $ P.errorBundlePretty e
                    Right n -> Right n

-- Check every used variable is defined
isDefined :: Scope -> Node -> Either String ()
isDefined sc (ProgramNode dcs _) = verify $ map (isDefined sc) dcs
isDefined sc (DeclNode lhs rhs _) = isDefined sc rhs
isDefined sc (BinOpNode lhs op rhs pos) = 
    case op of
        "." -> isDefined sc lhs
        _ -> isDefined sc lhs |>> isDefined sc rhs
isDefined sc (IdentifierNode id pos) = StringPos id pos `exists` sc
isDefined sc n@(FuncDefNode mid _ args expr pos) = 
    expSc |>> 
        case mid of 
            Just id -> 
                isDefined sc id
            Nothing -> Right ()
    where
        expSc = 
            case runDefiner (Right n) $ Just sc of
                Left s -> Left s
                Right (_, nsc) -> isDefined nsc expr
isDefined sc n@(WhereNode expr ds pos) = 
    case runDefiner (Right n) $ Just sc of
        Left s -> Left s
        Right (_, nsc) -> isDefined nsc expr
isDefined sc (CallNode id args pos) = verify $ isDefined sc id : map (isDefined sc) args
isDefined sc (UnaryExpr _ e _) = isDefined sc e
isDefined sc (IfNode ce te ee _) = isDefined sc ce |>> isDefined sc te |>> 
    case ee of
        Just e -> isDefined sc e
        Nothing -> Right ()
isDefined sc (SequenceIfNode ns _) = verify $ map (isDefined sc) ns
isDefined sc (ListNode ns _) = verify $ map (isDefined sc) ns
isDefined sc (TupleNode ts _) = verify $ map (isDefined sc) ts
isDefined sc (StructInstanceNode id args _) = 
    isDefined sc id |>> verify (map (isDefined sc) args)
isDefined sc (StructDefNode id args mov _) = 
    case mov of
        Nothing -> Right ()
        Just ov -> isDefined sc ov
isDefined sc SumTypeNode{} = Right ()
isDefined sc DeStructure{} = Right ()
isDefined sc (DataNode id pos) = StringPos id pos `exists` sc
isDefined sc (NewMethodNode id _ _ _) = Left $ "Undefined open method " ++ show id
isDefined _ p = 
    case p of 
        NumNode _ _ -> Right ()
        StringNode _ _ -> Right ()
        BoolNode _ _ -> Right ()
        a -> Left $ show a

-- Run the definition checker
checkDefinitions :: Either String Node -> Maybe Scope -> Either String Node
checkDefinitions le parent =
    case runDefiner le parent of
        Left e -> Left e
        Right (n, sc) -> 
            case runMethodFun sc (Right n) of
                Left e -> Left e
                Right nn -> 
                    case isDefined sc rmn  of
                        Left s -> Left s
                        Right () -> 
                            case StringPos "out" (getStringPos nn) `exists` sc of 
                                Right () -> Right rmn
                                Left s -> Left "undefined entry point \"out\""
                    where 
                        rmn = removeNewMethods sc nn
                        getStringPos (ProgramNode _ pos) = pos

checkIODefinitions :: Either (P.ParseErrorBundle String Data.Void.Void) Node -> Maybe Scope -> IO ()
checkIODefinitions lf p =
    case checkDefinitions l p of 
        Left e -> putStrLn e
        Right _ -> putStrLn "All variables are defined"
    where l = case lf of
                Left e -> Left $ P.errorBundlePretty e
                Right n -> Right n


