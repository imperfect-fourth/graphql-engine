module Hasura.Backends.Postgres.Execute.Prepare
  ( PlanVariables
  , PrepArgMap
  , PlanningSt(..)
  , ExecutionPlan
  , ExecutionStep(..)
  , initPlanningSt
  , prepareWithPlan
  , prepareWithoutPlan
  , resolveUnpreparedValue
  , withUserVars
  ) where


import           Hasura.Prelude

import qualified Data.Aeson                                as J
import qualified Data.HashMap.Strict                       as Map
import qualified Data.IntMap                               as IntMap
import qualified Database.PG.Query                         as Q
import qualified Language.GraphQL.Draft.Syntax             as G

import           Data.Text.Extended

import qualified Hasura.Backends.Postgres.SQL.DML          as S

import           Hasura.Backends.Postgres.SQL.Value
import           Hasura.Backends.Postgres.Translate.Column
import           Hasura.Backends.Postgres.Types.Column
import           Hasura.Base.Error
import           Hasura.GraphQL.Execute.Backend
import           Hasura.GraphQL.Parser.Column
import           Hasura.GraphQL.Parser.Schema
import           Hasura.RQL.DML.Internal                   (fromCurrentSession, withTypeAnn)
import           Hasura.RQL.Types
import           Hasura.Session


type PlanVariables = Map.HashMap G.Name Int

-- | The value is (Q.PrepArg, PGScalarValue) because we want to log the human-readable value of the
-- prepared argument and not the binary encoding in PG format
type PrepArgMap = IntMap.IntMap (Q.PrepArg, PGScalarValue)


data PlanningSt
  = PlanningSt
  { _psArgNumber :: !Int
  , _psVariables :: !PlanVariables
  , _psPrepped   :: !PrepArgMap
  }

initPlanningSt :: PlanningSt
initPlanningSt = PlanningSt 2 Map.empty IntMap.empty

prepareWithPlan
  :: ( MonadState PlanningSt m
     , MonadError QErr m
     )
  => UserInfo
  -> UnpreparedValue ('Postgres pgKind)
  -> m S.SQLExp
prepareWithPlan userInfo = \case
  UVParameter varInfoM ColumnValue{..} -> do
    argNum <- maybe getNextArgNum (getVarArgNum . getName) varInfoM
    addPrepArg argNum (binEncoder cvValue, cvValue)
    return $ toPrepParam argNum (unsafePGColumnToBackend cvType)

  UVSessionVar ty sessVar -> do
    -- For queries, we need to make sure the session variables are passed. However,
    -- we want to keep them as variables in the resulting SQL in order to keep
    -- hitting query caching for similar queries.
    _ <- getSessionVariableValue sessVar (_uiSession userInfo)
          `onNothing`
            throw400 NotFound
              ("missing session variable: "  <>> sessionVariableToText sessVar)
    let sessVarVal = fromCurrentSession currentSessionExp sessVar
    pure $ withTypeAnn ty sessVarVal

  UVLiteral sqlExp -> pure sqlExp
  UVSession        -> pure currentSessionExp
  where
    currentSessionExp = S.SEPrep 1

prepareWithoutPlan
  :: (MonadError QErr m)
  => UserInfo
  -> UnpreparedValue ('Postgres pgKind)
  -> m S.SQLExp
prepareWithoutPlan userInfo = \case
  UVParameter _ cv        -> pure $ toTxtValue cv
  UVLiteral sqlExp        -> pure sqlExp
  UVSession               -> pure $ sessionInfoJsonExp $ _uiSession userInfo
  UVSessionVar ty sessVar -> do
    let maybeSessionVariableValue =
          getSessionVariableValue sessVar (_uiSession userInfo)
    sessionVariableValue <-
      fmap S.SELit
        <$> onNothing maybeSessionVariableValue
            $ throw400 NotFound
            $ "missing session variable: "  <>> sessionVariableToText sessVar
    pure $ withTypeAnn ty sessionVariableValue

resolveUnpreparedValue
  :: (MonadError QErr m)
  => UserInfo
  -> UnpreparedValue ('Postgres pgKind)
  -> m S.SQLExp
resolveUnpreparedValue userInfo = \case
  UVParameter _ cv      -> pure $ toTxtValue cv
  UVLiteral sqlExp      -> pure sqlExp
  UVSession             -> pure $ sessionInfoJsonExp $ _uiSession userInfo
  UVSessionVar ty sessionVariable -> do
    let maybeSessionVariableValue =
          getSessionVariableValue sessionVariable (_uiSession userInfo)
    sessionVariableValue <- fmap S.SELit <$>
      onNothing maybeSessionVariableValue $ throw400 UnexpectedPayload $ "missing required session variable for role " <> _uiRole userInfo <<> " : " <> sessionVariableToText sessionVariable
    pure $ withTypeAnn ty sessionVariableValue

withUserVars :: SessionVariables -> PrepArgMap -> PrepArgMap
withUserVars usrVars list =
  let usrVarsAsPgScalar = PGValJSON $ Q.JSON $ J.toJSON usrVars
      prepArg = Q.toPrepVal (Q.AltJ usrVars)
  in IntMap.insert 1 (prepArg, usrVarsAsPgScalar) list

getVarArgNum :: (MonadState PlanningSt m) => G.Name -> m Int
getVarArgNum var = do
  PlanningSt curArgNum vars prepped <- get
  Map.lookup var vars `onNothing` do
    put $ PlanningSt (curArgNum + 1) (Map.insert var curArgNum vars) prepped
    pure curArgNum

addPrepArg
  :: (MonadState PlanningSt m)
  => Int -> (Q.PrepArg, PGScalarValue) -> m ()
addPrepArg argNum arg = do
  prepped <- gets _psPrepped
  modify \x -> x {_psPrepped = IntMap.insert argNum arg prepped}

getNextArgNum :: (MonadState PlanningSt m) => m Int
getNextArgNum = do
  curArgNum <- gets _psArgNumber
  modify \x -> x {_psArgNumber = curArgNum + 1}
  return curArgNum
