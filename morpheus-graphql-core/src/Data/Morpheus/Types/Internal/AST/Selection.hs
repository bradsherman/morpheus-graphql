{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.Types.Internal.AST.Selection
  ( Selection (..),
    SelectionContent (..),
    SelectionSet,
    UnionTag (..),
    UnionSelection,
    Fragment (..),
    Fragments,
    Operation (..),
    Variable (..),
    VariableDefinitions,
    DefaultValue,
    getOperationName,
    getOperationDataType,
  )
where

import Data.Morpheus.Error.NameCollision
  ( NameCollision (..),
  )
import Data.Morpheus.Error.Operation
  ( mutationIsNotDefined,
    subscriptionIsNotDefined,
  )
import Data.Morpheus.Ext.MergeSet
  ( MergeSet,
  )
import Data.Morpheus.Ext.OrdMap
  ( OrdMap,
  )
import Data.Morpheus.Ext.SemigroupM (SemigroupM (..))
import Data.Morpheus.Internal.Utils
  ( Failure (..),
    KeyOf (..),
    elems,
  )
import Data.Morpheus.Rendering.RenderGQL
  ( RenderGQL (..),
    Rendering,
    newline,
    renderObject,
    space,
  )
import Data.Morpheus.Types.Internal.AST.Base
  ( FieldName,
    Message,
    Msg (..),
    OperationType (..),
    Position,
    Ref (..),
    TypeName (..),
    ValidationError (..),
    ValidationErrors,
    intercalateName,
    msg,
    msgValidation,
    readName,
  )
import Data.Morpheus.Types.Internal.AST.Fields
  ( Arguments,
    Directives,
    renderArgumentValues,
    renderDirectives,
  )
import Data.Morpheus.Types.Internal.AST.Stage
  ( RAW,
    Stage,
    VALID,
  )
import Data.Morpheus.Types.Internal.AST.TypeCategory
  ( OBJECT,
  )
import Data.Morpheus.Types.Internal.AST.TypeSystem
  ( Schema (..),
    TypeDefinition (..),
  )
import Data.Morpheus.Types.Internal.AST.Value
  ( ResolvedValue,
    Variable (..),
    VariableDefinitions,
  )
import Language.Haskell.TH.Syntax (Lift (..))
import Relude

data Fragment (stage :: Stage) = Fragment
  { fragmentName :: FieldName,
    fragmentType :: TypeName,
    fragmentPosition :: Position,
    fragmentSelection :: SelectionSet stage,
    fragmentDirectives :: Directives stage
  }
  deriving (Show, Eq, Lift)

-- ERRORs
instance NameCollision (Fragment s) where
  nameCollision Fragment {fragmentName, fragmentPosition} =
    ValidationError
      ("There can be only one fragment named " <> msg fragmentName <> ".")
      [fragmentPosition]

instance KeyOf FieldName (Fragment s) where
  keyOf = fragmentName

type Fragments (s :: Stage) = OrdMap FieldName (Fragment s)

data SelectionContent (s :: Stage) where
  SelectionField :: SelectionContent s
  SelectionSet :: SelectionSet s -> SelectionContent s
  UnionSelection :: UnionSelection VALID -> SelectionContent VALID

renderSelectionSet :: SelectionSet VALID -> Rendering
renderSelectionSet = renderObject . elems

instance RenderGQL (SelectionContent VALID) where
  render SelectionField = ""
  render (SelectionSet selSet) = renderSelectionSet selSet
  render (UnionSelection unionSets) = renderObject (elems unionSets)

instance
  ( Monad m,
    Failure ValidationErrors m,
    SemigroupM m (SelectionSet s)
  ) =>
  SemigroupM m (SelectionContent s)
  where
  mergeM path (SelectionSet s1) (SelectionSet s2) = SelectionSet <$> mergeM path s1 s2
  mergeM path (UnionSelection u1) (UnionSelection u2) = UnionSelection <$> mergeM path u1 u2
  mergeM path oldC currentC
    | oldC == currentC = pure oldC
    | otherwise =
      failure
        [ ValidationError
            { validationMessage = msg (intercalateName "." $ fmap refName path),
              validationLocations = fmap refPosition path
            }
        ]

deriving instance Show (SelectionContent a)

deriving instance Eq (SelectionContent a)

deriving instance Lift (SelectionContent a)

data UnionTag = UnionTag
  { unionTagName :: TypeName,
    unionTagSelection :: SelectionSet VALID
  }
  deriving (Show, Eq, Lift)

instance KeyOf TypeName UnionTag where
  keyOf = unionTagName

instance RenderGQL UnionTag where
  render UnionTag {unionTagName, unionTagSelection} =
    "... on "
      <> render unionTagName
      <> renderSelectionSet unionTagSelection

mergeConflict :: [Ref] -> ValidationError -> ValidationErrors
mergeConflict [] err = [err]
mergeConflict refs@(rootField : xs) err =
  [ ValidationError
      { validationMessage = renderSubfields <> validationMessage err,
        validationLocations = fmap refPosition refs <> validationLocations err
      }
  ]
  where
    fieldConflicts ref = msg (refName ref) <> " conflict because "
    renderSubfield ref txt = txt <> "subfields " <> fieldConflicts ref
    renderStart = "Fields " <> fieldConflicts rootField
    renderSubfields =
      foldr
        renderSubfield
        renderStart
        xs

instance (Monad m, Failure ValidationErrors m) => SemigroupM m UnionTag where
  mergeM path (UnionTag oldTag oldSel) (UnionTag _ currentSel) =
    UnionTag oldTag <$> mergeM path oldSel currentSel

type UnionSelection (s :: Stage) = MergeSet s TypeName UnionTag

type SelectionSet (s :: Stage) = MergeSet s FieldName (Selection s)

data Selection (s :: Stage) where
  Selection ::
    { selectionPosition :: Position,
      selectionAlias :: Maybe FieldName,
      selectionName :: FieldName,
      selectionArguments :: Arguments s,
      selectionDirectives :: Directives s,
      selectionContent :: SelectionContent s
    } ->
    Selection s
  InlineFragment :: Fragment RAW -> Selection RAW
  Spread :: Directives RAW -> Ref -> Selection RAW

instance RenderGQL (Selection VALID) where
  render
    Selection
      { ..
      } =
      render (fromMaybe selectionName selectionAlias)
        <> renderArgumentValues selectionArguments
        <> renderDirectives selectionDirectives
        <> render selectionContent

instance KeyOf FieldName (Selection s) where
  keyOf
    Selection
      { selectionName,
        selectionAlias
      } = fromMaybe selectionName selectionAlias
  keyOf _ = ""

useDifferentAliases :: Message
useDifferentAliases =
  "Use different aliases on the "
    <> "fields to fetch both if this was intentional."

instance
  ( Monad m,
    SemigroupM m (SelectionSet a),
    Failure ValidationErrors m
  ) =>
  SemigroupM m (Selection a)
  where
  mergeM
    path
    old@Selection {selectionPosition = pos1}
    current@Selection {selectionPosition = pos2} =
      do
        selectionName <- mergeName
        let currentPath = path <> [Ref selectionName pos1]
        selectionArguments <- mergeArguments currentPath
        selectionContent <- mergeM currentPath (selectionContent old) (selectionContent current)
        pure $
          Selection
            { selectionAlias = mergeAlias,
              selectionPosition = pos1,
              selectionDirectives = selectionDirectives old <> selectionDirectives current,
              ..
            }
      where
        -- passes if:

        --     user1: user
        --   }
        -- fails if:

        --     user1: product
        --   }
        mergeName
          | selectionName old == selectionName current = pure $ selectionName current
          | otherwise =
            failure $ mergeConflict path $
              ValidationError
                { validationMessage =
                    "" <> msg (selectionName old) <> " and " <> msg (selectionName current)
                      <> " are different fields. "
                      <> useDifferentAliases,
                  validationLocations = [pos1, pos2]
                }
        ---------------------
        -- alias name is relevant only if they collide by allies like:
        --   { user1: user
        --     user1: user
        --   }
        mergeAlias
          | all (isJust . selectionAlias) [old, current] = selectionAlias old
          | otherwise = Nothing
        --- arguments must be equal
        mergeArguments currentPath
          | selectionArguments old == selectionArguments current = pure $ selectionArguments current
          | otherwise =
            failure $ mergeConflict currentPath $
              ValidationError
                { validationMessage = "they have differing arguments. " <> useDifferentAliases,
                  validationLocations = [pos1, pos2]
                }
  mergeM path _ _ =
    failure $
      mergeConflict
        path
        ("INTERNAL: can't merge. " <> msgValidation useDifferentAliases :: ValidationError)

deriving instance Show (Selection a)

deriving instance Lift (Selection a)

deriving instance Eq (Selection a)

type DefaultValue = Maybe ResolvedValue

data Operation (s :: Stage) = Operation
  { operationPosition :: Position,
    operationType :: OperationType,
    operationName :: Maybe FieldName,
    operationArguments :: VariableDefinitions s,
    operationDirectives :: Directives s,
    operationSelection :: SelectionSet s
  }
  deriving (Show, Lift)

instance RenderGQL (Operation VALID) where
  render
    Operation
      { operationName,
        operationType,
        operationDirectives,
        operationSelection
      } =
      render operationType
        <> maybe "" ((space <>) . render) operationName
        <> renderDirectives operationDirectives
        <> renderSelectionSet operationSelection
        <> newline

getOperationName :: Maybe FieldName -> TypeName
getOperationName = maybe "AnonymousOperation" (TypeName . readName)

getOperationDataType :: Failure ValidationError m => Operation s -> Schema VALID -> m (TypeDefinition OBJECT VALID)
getOperationDataType Operation {operationType = Query} lib = pure (query lib)
getOperationDataType Operation {operationType = Mutation, operationPosition} lib =
  maybe (failure $ mutationIsNotDefined operationPosition) pure (mutation lib)
getOperationDataType Operation {operationType = Subscription, operationPosition} lib =
  maybe (failure $ subscriptionIsNotDefined operationPosition) pure (subscription lib)
