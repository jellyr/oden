{-# LANGUAGE QuasiQuotes, FlexibleContexts #-}
module Oden.Backend.Go where

import qualified Data.Set              as Set
import           Numeric
import           System.FilePath
import           Text.PrettyPrint
import           Text.Regex.PCRE.Heavy

import           Oden.Backend
import           Oden.Compiler.Monomorphization
import           Oden.Core
import           Oden.Core.Operator
import           Oden.Identifier
import qualified Oden.Type.Monomorphic as Mono

newtype GoBackend = GoBackend FilePath

block :: Doc -> Doc
block d = lbrace $+$ nest 4 d $+$ rbrace

funcArg :: Name -> Mono.Type -> Doc
funcArg name t = safeName name <+> codegenType t

func :: Doc -> Doc -> Doc -> Doc -> Doc
func name arg returnType body =
  text "func"
  <+> name
  <> parens arg
  <+> returnType
  <+> body

varWithType :: Name -> Mono.Type -> Expr Mono.Type -> Doc
varWithType name mt expr =
  text "var"
  <+> safeName name
  <+> codegenType mt
  <+> equals
  <+> codegenExpr expr

var :: Name -> Expr Mono.Type -> Doc
var name expr = varWithType name (typeOf expr) expr

return' :: Expr Mono.Type -> Doc
return' e@(Application f _ Mono.TUnit) =
  case typeOf f of
    Mono.TUncurriedFn{} -> codegenExpr e $+$ text "return struct{}{}"
    Mono.TVariadicFn{}  -> codegenExpr e $+$ text "return struct{}{}"
    _                   -> text "return" <+> codegenExpr e
return' e@(NoArgApplication f Mono.TUnit) =
  case typeOf f of
    Mono.TUncurriedFn{} -> codegenExpr e $+$ text "return struct{}{}"
    Mono.TVariadicFn{}  -> codegenExpr e $+$ text "return struct{}{}"
    _                   -> text "return" <+> codegenExpr e
return' e@(UncurriedFnApplication f _ Mono.TUnit) =
  case typeOf f of
    Mono.TUncurriedFn{} -> codegenExpr e $+$ text "return struct{}{}"
    Mono.TVariadicFn{}  -> codegenExpr e $+$ text "return struct{}{}"
    _                   -> text "return" <+> codegenExpr e
return' expr = text "return" <+> codegenExpr expr

replaceIdentifierPart :: Char -> String
replaceIdentifierPart '-' = "_DASH_"
replaceIdentifierPart '\'' = "_PRIM_"
replaceIdentifierPart '!' = "_BANG_"
replaceIdentifierPart '$' = "_DLLR_"
replaceIdentifierPart '&' = "_AMPR_"
replaceIdentifierPart '*' = "_STAR_"
replaceIdentifierPart '+' = "_PLUS_"
replaceIdentifierPart '<' = "_LT_"
replaceIdentifierPart '=' = "_EQ_"
replaceIdentifierPart '>' = "_GT_"
replaceIdentifierPart '?' = "_QST_"
replaceIdentifierPart '^' = "_CRCM_"
replaceIdentifierPart '|' = "_PIPE_"
replaceIdentifierPart '~' = "_TLDE_"
replaceIdentifierPart c = [c]

safeName :: Name -> Doc
safeName = text . concatMap replaceIdentifierPart

codegenIdentifier :: Identifier -> Doc
codegenIdentifier (Unqualified n) = safeName n
codegenIdentifier (Qualified pn n) = safeName pn <> text "." <> safeName n

codegenType :: Mono.Type -> Doc
codegenType Mono.TUnit = text "struct{}"
codegenType (Mono.TTuple f s r) =
  text "struct" <>
  braces (hcat (punctuate (text "; ") (zipWith codegenTupleField [0..] (f:s:r))))
  where
  codegenTupleField :: Int -> Mono.Type -> Doc
  codegenTupleField n t = text ("_" ++ show n) <+> codegenType t
codegenType Mono.TAny = text "interface{}"
codegenType (Mono.TCon n) = safeName n
codegenType (Mono.TNoArgFn f) =
  func empty empty (codegenType f) empty
codegenType (Mono.TFn d r) =
  func empty (codegenType d) (codegenType r) empty
codegenType (Mono.TSlice t) =
  text "[]" <> codegenType t
codegenType (Mono.TUncurriedFn as r) =
  func empty (hcat (punctuate (text ", ") (map codegenType as))) (codegenType r) empty
codegenType (Mono.TVariadicFn as v r) =
  func empty (hcat (punctuate (text ", ") (map codegenType as ++ [codegenType v <> text "..."]))) (codegenType r) empty

showGoString :: Show a => a -> String
showGoString s = gsub ([re|(\\)(\d+)|]) toHex (show s)
  where
  toHex (_:n:_) = "\\U" ++ pad 8 (showHex (read n :: Int) "")
  toHex (m:_) = m
  toHex [] = ""
  pad :: Int -> String -> String
  pad n s'
      | length s' < n  = replicate (n - length s') '0' ++ s'
      | otherwise      = s'

codegenOperator :: BinaryOperator -> Doc
codegenOperator Concat = text "+"
codegenOperator o = text (show o)

codegenExpr :: Expr Mono.Type -> Doc
codegenExpr (Symbol i _) =
  codegenIdentifier i
codegenExpr (Op o e1 e2 _) =
  parens (codegenExpr e1 <+> codegenOperator o <+> codegenExpr e2)
codegenExpr (Application (Symbol (Unqualified "not") _) e _) =
  text "!" <> codegenExpr e
codegenExpr (Application f p _) =
  codegenExpr f <> parens (codegenExpr p)
codegenExpr (UncurriedFnApplication f ps _) =
  case typeOf f of
    Mono.TVariadicFn{} ->
      let nonVariadicParams = init ps
          slice = last ps
      in codegenExpr f <> parens (hcat (punctuate (text ", ") (map codegenExpr nonVariadicParams ++ [codegenExpr slice <> text "..."])))
    _ ->
      codegenExpr f <> parens (hcat (punctuate (text ", ") (map codegenExpr ps)))
codegenExpr (NoArgApplication f _) =
  codegenExpr f <> parens empty
codegenExpr (Fn a body (Mono.TFn d r)) =
  func empty (funcArg a d) (codegenType r) (braces (return' body))
codegenExpr Fn{} = text "<invalid fn type>"
codegenExpr (NoArgFn body (Mono.TNoArgFn r)) =
  func empty empty (codegenType r) (braces (return' body))
codegenExpr (NoArgFn _ _) = text "<invalid no-arg fn type>"
codegenExpr (Let n expr body t) =
  parens (func empty empty (codegenType t) (braces (text "var" <+> safeName n <+> codegenType (typeOf expr)<+> equals <+> codegenExpr expr $+$ return' body)))
  <> parens empty
codegenExpr (Literal (Int n) _) = integer n
codegenExpr (Literal (Bool True) _) = text "true"
codegenExpr (Literal (Bool False) _) = text "false"
codegenExpr (Literal (String s) _) = text (showGoString s)
codegenExpr (Literal Unit _) = text "struct{}{}"
codegenExpr (Tuple f s r t) =
  codegenType t <> braces (hcat (punctuate (text ", ") (map codegenExpr (f:s:r))))
codegenExpr (If condExpr thenExpr elseExpr t) =
  parens
  (func empty empty (codegenType t) (braces (text "if" <+> codegenExpr condExpr <+> block (return' thenExpr) <+> text "else" <+> block (return' elseExpr))))
  <> parens empty
codegenExpr (Slice exprs t) = codegenType t
                            <> braces (hcat (punctuate (comma <+> space) (map codegenExpr exprs)))
codegenExpr (Block [] t) =
  parens
  (func empty empty (codegenType t) (braces empty))
  <> parens empty
codegenExpr (Block exprs t) =
  parens
  (func empty empty (codegenType t) (braces (vcat (map codegenExpr (init exprs) ++ [return' (last exprs)]))))
  <> parens empty

codegenTopLevel :: Name -> Mono.Type -> Expr Mono.Type -> Doc
codegenTopLevel "main" (Mono.TNoArgFn Mono.TUnit) (NoArgFn body _) =
  func (text "main") empty empty (braces (codegenExpr body))
codegenTopLevel name (Mono.TNoArgFn r) (NoArgFn body _) =
  func (safeName name) empty (codegenType r) (braces (return' body))
codegenTopLevel name _ (NoArgFn body (Mono.TNoArgFn r)) =
  func (safeName name) empty (codegenType r) (braces (return' body))
codegenTopLevel name (Mono.TFn d r) (Fn a body _) =
  func (safeName name) (funcArg a d) (codegenType r) (braces (return' body))
codegenTopLevel name _ (Fn a body (Mono.TFn d r)) =
  func (safeName name) (funcArg a d) (codegenType r) (braces (return' body))
codegenTopLevel name t expr =
  varWithType name t expr

codegenInstance :: InstantiatedDefinition -> Doc
codegenInstance (InstantiatedDefinition name expr) =
  codegenTopLevel name (typeOf expr) expr

codegenMonomorphed :: MonomorphedDefinition -> Doc
codegenMonomorphed (MonomorphedDefinition name mt expr) =
  codegenTopLevel name mt expr

codegenImport :: Import -> Doc
codegenImport (Import name) =
  text "import" <+> doubleQuotes (hcat (punctuate (text "/") (map text name)))

codegenPackage :: MonomorphedPackage -> Doc
codegenPackage (MonomorphedPackage name imports is ms) =
  text "package" <+> text (last name)
  $+$ vcat (map codegenImport imports)
  $+$ vcat (map codegenInstance (Set.toList is))
  $+$ vcat (map codegenMonomorphed (Set.toList ms))

toFilePath :: GoBackend -> PackageName -> Either CodegenError FilePath
toFilePath _ [] = Left (UnexpectedError "Package name cannot be empty")
toFilePath (GoBackend goPath) parts =
  let isMain = last parts == "main"
      dirParts = "src" : if isMain then init parts else parts
      dir = foldl (</>) goPath dirParts
      fileName = if isMain then "main.go" else last parts ++ ".go"
  in return (dir </> fileName)

instance Backend GoBackend where
  codegen backend pkg@(MonomorphedPackage name _ _ _) = do
    path <- toFilePath backend name
    return [CompiledFile path (render (codegenPackage pkg))]
