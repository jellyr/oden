{-# LANGUAGE LambdaCase #-}
module Oden.Compiler.ResolutionSpec where

import           Oden.Compiler.Resolution

import           Oden.Core.Expr
import           Oden.Core.ProtocolImplementation
import           Oden.Core.Typed

import           Oden.Identifier
import           Oden.Predefined
import           Oden.Metadata
import           Oden.QualifiedName
import           Oden.SourceInfo
import           Oden.Type.Polymorphic

import qualified Data.Set as Set
import           Data.Set (Set)

import           Test.Hspec

import           Oden.Assertions

missing :: Metadata SourceInfo
missing = Metadata Missing

predefined :: Metadata SourceInfo
predefined = Metadata Predefined

tvA = TV "a"

tvarA = TVar predefined tvA
symbol s = Symbol missing (Identifier s)

boolToBool = TFn predefined typeBool typeBool
aToBool = TFn predefined tvarA typeBool

one = Literal missing (Int 1) typeInt

rowWithResultField =
  rowFromList [(Identifier "result", typeBool)] (REmpty missing)

rowWithResultAndMessageField =
  rowFromList [ (Identifier "result", typeBool)
              , (Identifier "message", typeString)] (REmpty missing)

unresolved protocol method =
  MethodReference missing (Unresolved protocol method)

resolved protocol method implMethod =
  MethodReference missing (Resolved protocol method implMethod)

testableProtocolName = FQN [] (Identifier "Testable")
testableMethodName = Identifier "test"

testableProtocol =
  Protocol
  predefined
  testableProtocolName
  (TVar predefined tvA)
  [testableProtocolMethod]

testableProtocolMethod =
  ProtocolMethod
  predefined
  testableMethodName
  (Forall predefined [] Set.empty (TFn predefined tvarA typeBool))

testableMethodImplementation :: String -> Type -> MethodImplementation TypedExpr
testableMethodImplementation identifier t =
  MethodImplementation
  missing
  testableMethodName
  (symbol identifier (TFn missing t typeBool))

testableImplementation :: String -> Type -> ProtocolImplementation TypedExpr
testableImplementation identifier t =
  ProtocolImplementation
  missing
  testableProtocolName
  t
  [testableMethodImplementation identifier t]

implementationsAsSet :: Either ResolutionError a
                     -> Set (ProtocolImplementation TypedExpr)
implementationsAsSet = \case
  Left (MultipleMatchingImplementationsInScope _ impls) -> Set.fromList impls
  _ -> Set.empty

spec :: Spec
spec =
  describe "resolveInExpr" $ do

    it "throws error if there's no matching implementation" $
      shouldFail $
        resolveInExpr
        Set.empty
        (unresolved
         testableProtocolName
         testableMethodName
         aToBool)

    it "resolves a single matching implementation" $
      resolveInExpr
      (Set.singleton (testableImplementation "foo" typeBool))
      (unresolved
       testableProtocolName
       testableMethodName
       boolToBool)
      `shouldSucceedWith`
      resolved
      testableProtocolName
      testableMethodName
      (testableMethodImplementation "foo" typeBool)
      boolToBool

    it "resolves a single matching implementation for a record type" $
      resolveInExpr
      (Set.singleton (testableImplementation "foo" rowWithResultField))
      (Application
       missing
       (unresolved
        testableProtocolName
        testableMethodName
        (TFn missing rowWithResultField typeBool))
       (symbol "recordValue" rowWithResultField)
       typeBool)
      `shouldSucceedWith`
      Application
      missing
      (resolved
       testableProtocolName
       testableMethodName
       (testableMethodImplementation "foo" rowWithResultField)
       (TFn missing rowWithResultField typeBool))
      (symbol "recordValue" rowWithResultField)
      typeBool

    it "resolves the correct matching implementation for a record type" $
      resolveInExpr
      (Set.fromList [ testableImplementation "foo" rowWithResultField
                    , testableImplementation "bar" rowWithResultAndMessageField ])
      (Application
       missing
       (unresolved
        testableProtocolName
        testableMethodName
        (TFn missing rowWithResultField typeBool))
       (symbol "recordValue" rowWithResultField)
       typeBool)
      `shouldSucceedWith`
      Application
      missing
      (resolved
       testableProtocolName
       testableMethodName
       (testableMethodImplementation "foo" rowWithResultField)
       (TFn missing rowWithResultField typeBool))
      (symbol "recordValue" rowWithResultField)
      typeBool

    it "throws error if there's multiple matching implementations" $
      implementationsAsSet
      (resolveInExpr
       (Set.fromList [ testableImplementation "foo" typeBool
                     , testableImplementation "bar" typeBool
                     ])
       (unresolved
        testableProtocolName
        testableMethodName
        boolToBool))
      `shouldBe`
      Set.fromList [ testableImplementation "bar" typeBool
                   , testableImplementation "foo" typeBool
                   ]
