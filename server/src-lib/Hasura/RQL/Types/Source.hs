{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Hasura.RQL.Types.Source
  ( -- * Metadata
    SourceInfo (..),
    BackendSourceInfo,
    SourceCache,
    unsafeSourceConfiguration,
    unsafeSourceFunctions,
    unsafeSourceInfo,
    unsafeSourceName,
    unsafeSourceTables,
    siConfiguration,
    siCustomSQL,
    siFunctions,
    siName,
    siQueryTagsConfig,
    siTables,
    siCustomization,
    NativeQueryCache,
    _siNativeQueries,

    -- * Schema cache
    DBObjectsIntrospection (..),
    ScalarMap (..),

    -- * Source resolver
    SourceResolver,
    MonadResolveSource (..),
    MaintenanceModeVersion (..),

    -- * Health check
    SourceHealthCheckInfo (..),
    BackendSourceHealthCheckInfo,
    SourceHealthCheckCache,

    -- * Source pings
    SourcePingInfo (..),
    BackendSourcePingInfo,
    SourcePingCache,
  )
where

import Control.Lens hiding ((.=))
import Data.Aeson.Extended
import Data.HashMap.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as BS
import Database.PG.Query qualified as PG
import Hasura.Base.Error
import Hasura.CustomSQL (CustomSQLParameter (..), CustomSQLParameterName (..), CustomSQLParameterType (..))
import Hasura.Logging qualified as L
import Hasura.NativeQuery.Metadata (NativeQueryArgumentName (..), NativeQueryInfoImpl (..))
import Hasura.NativeQuery.Types (NativeQueryName (..))
import Hasura.Prelude
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Function
import Hasura.RQL.Types.HealthCheck
import Hasura.RQL.Types.Instances ()
import Hasura.RQL.Types.Metadata.Common (CustomSQLFields, CustomSQLMetadata (..))
import Hasura.RQL.Types.QueryTags
import Hasura.RQL.Types.SourceCustomization
import Hasura.RQL.Types.Table
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.SQL.Backend
import Hasura.SQL.Tag
import Hasura.Tracing qualified as Tracing
import Language.GraphQL.Draft.Syntax qualified as G
import Unsafe.Coerce (unsafeCoerce)

--------------------------------------------------------------------------------
-- Metadata (FIXME: this grouping is inaccurate)

data SourceInfo b = SourceInfo
  { _siName :: SourceName,
    _siTables :: TableCache b,
    _siFunctions :: FunctionCache b,
    _siCustomSQL :: CustomSQLFields b,
    _siConfiguration :: ~(SourceConfig b),
    _siQueryTagsConfig :: Maybe QueryTagsConfig,
    _siCustomization :: ResolvedSourceCustomization
  }

-- This function is a temporary integration between metadata and schema of the Native Queries MVP.
-- It is **not** representative of the code quality we strive for, and will be properly dealt with.
_siNativeQueries :: forall b. Backend b => CustomSQLFields b -> NativeQueryCache b
_siNativeQueries = foldMap toItem
  where
    toItem :: CustomSQLMetadata b -> HashMap NativeQueryName (NativeQueryInfo b)
    toItem csm = Map.fromList [(toNativeQueryName (_csmRootFieldName csm), toInfo csm)]

    toNativeQueryName :: G.Name -> NativeQueryName
    toNativeQueryName = NativeQueryName . G.unName

    toInfo :: CustomSQLMetadata b -> NativeQueryInfo b
    toInfo CustomSQLMetadata {..} =
      -- '_siNativeQueries' would have to be defined in some type class over
      -- 'b' in order to avoid this unsafeCoerce.
      -- But since this is a temporary stop-gap which we won't release it's fine.
      unsafeCoerce $ (NativeQueryInfoImpl {..} :: NativeQueryInfoImpl b)
      where
        nqiiName = toNativeQueryName _csmRootFieldName
        nqiiCode = _csmSql
        nqiiReturns = _csmReturns
        nqiiArgs = toArgs _csmParameters
        nqiiComment = "TBD"

    toArgs :: NonEmpty CustomSQLParameter -> HashMap NativeQueryArgumentName (ScalarType b)
    toArgs = foldMap toArg

    toArg :: CustomSQLParameter -> HashMap NativeQueryArgumentName (ScalarType b)
    toArg CustomSQLParameter {..} = Map.fromList [(toArgName cspName, toScalarType cspType)]

    toArgName :: CustomSQLParameterName -> NativeQueryArgumentName
    toArgName CustomSQLParameterName {..} = NativeQueryArgumentName cspnName

    -- This mismatch is the worst part.
    toScalarType :: CustomSQLParameterType -> ScalarType b
    toScalarType CustomSQLParameterType {..} = fromJust $ decode (BS.encodeUtf8 $ TL.fromStrict cspnType)

type NativeQueryCache b = HashMap NativeQueryName (NativeQueryInfo b)

$(makeLenses ''SourceInfo)

instance
  ( Backend b,
    ToJSON (TableCache b),
    ToJSON (FunctionCache b),
    ToJSON (QueryTagsConfig),
    ToJSON (SourceCustomization)
  ) =>
  ToJSON (SourceInfo b)
  where
  toJSON (SourceInfo {..}) =
    object
      [ "name" .= _siName,
        "tables" .= _siTables,
        "functions" .= _siFunctions,
        "configuration" .= _siConfiguration,
        "query_tags_config" .= _siQueryTagsConfig
      ]

type BackendSourceInfo = AB.AnyBackend SourceInfo

type SourceCache = HashMap SourceName BackendSourceInfo

-- Those functions cast the content of BackendSourceInfo in order to extract
-- a backend-specific SourceInfo. Ideally, those functions should NOT be used:
-- the rest of the code should be able to deal with any source, regardless of
-- backend, through usage of the appropriate typeclasses.
-- They are thus a temporary workaround as we work on generalizing code that
-- uses the schema cache.

unsafeSourceInfo :: forall b. HasTag b => BackendSourceInfo -> Maybe (SourceInfo b)
unsafeSourceInfo = AB.unpackAnyBackend

unsafeSourceName :: BackendSourceInfo -> SourceName
unsafeSourceName bsi = AB.dispatchAnyBackend @Backend bsi go
  where
    go (SourceInfo name _ _ _ _ _ _) = name

unsafeSourceTables :: forall b. HasTag b => BackendSourceInfo -> Maybe (TableCache b)
unsafeSourceTables = fmap _siTables . unsafeSourceInfo @b

unsafeSourceFunctions :: forall b. HasTag b => BackendSourceInfo -> Maybe (FunctionCache b)
unsafeSourceFunctions = fmap _siFunctions . unsafeSourceInfo @b

unsafeSourceConfiguration :: forall b. HasTag b => BackendSourceInfo -> Maybe (SourceConfig b)
unsafeSourceConfiguration = fmap _siConfiguration . unsafeSourceInfo @b

--------------------------------------------------------------------------------
-- Schema cache

-- | Contains metadata (introspection) from the database, used to build the
-- schema cache.  This type only contains results of introspecting DB objects,
-- i.e. the DB types specified by tables, functions, and scalars.  Notably, it
-- does not include the additional introspection that takes place on Postgres,
-- namely reading the contents of tables used as Enum Values -- see
-- @fetchAndValidateEnumValues@.
data DBObjectsIntrospection b = DBObjectsIntrospection
  { _rsTables :: DBTablesMetadata b,
    _rsFunctions :: DBFunctionsMetadata b,
    _rsScalars :: ScalarMap b
  }
  deriving (Eq, Generic)

instance Backend b => FromJSON (DBObjectsIntrospection b) where
  parseJSON = withObject "DBObjectsIntrospection" \o -> do
    tables <- o .: "tables"
    functions <- o .: "functions"
    scalars <- o .: "scalars"
    pure $ DBObjectsIntrospection (Map.fromList tables) (Map.fromList functions) (ScalarMap (Map.fromList scalars))

instance (L.ToEngineLog (DBObjectsIntrospection b) L.Hasura) where
  toEngineLog _ = (L.LevelDebug, L.ELTStartup, toJSON rsLog)
    where
      rsLog =
        object
          [ "kind" .= ("resolve_source" :: Text),
            "info" .= ("Successfully resolved source" :: Text)
          ]

-- | A map from GraphQL name to equivalent scalar type for a given backend.
newtype ScalarMap b = ScalarMap (HashMap G.Name (ScalarType b))
  deriving newtype (Semigroup, Monoid)

deriving stock instance Backend b => Eq (ScalarMap b)

--------------------------------------------------------------------------------
-- Source resolver

-- | FIXME: this should be either in 'BackendMetadata', or into a new dedicated
-- 'BackendResolve', instead of listing backends explicitly. It could also be
-- moved to the app level.
type SourceResolver b =
  SourceName -> SourceConnConfiguration b -> IO (Either QErr (SourceConfig b))

class (Monad m) => MonadResolveSource m where
  getPGSourceResolver :: m (SourceResolver ('Postgres 'Vanilla))
  getMSSQLSourceResolver :: m (SourceResolver 'MSSQL)

instance (MonadResolveSource m) => MonadResolveSource (ExceptT e m) where
  getPGSourceResolver = lift getPGSourceResolver
  getMSSQLSourceResolver = lift getMSSQLSourceResolver

instance (MonadResolveSource m) => MonadResolveSource (ReaderT r m) where
  getPGSourceResolver = lift getPGSourceResolver
  getMSSQLSourceResolver = lift getMSSQLSourceResolver

instance (MonadResolveSource m) => MonadResolveSource (Tracing.TraceT m) where
  getPGSourceResolver = lift getPGSourceResolver
  getMSSQLSourceResolver = lift getMSSQLSourceResolver

instance (MonadResolveSource m) => MonadResolveSource (PG.TxET QErr m) where
  getPGSourceResolver = lift getPGSourceResolver
  getMSSQLSourceResolver = lift getMSSQLSourceResolver

-- FIXME: why is this here?
data MaintenanceModeVersion
  = -- | should correspond to the source catalog version from which the user
    -- is migrating from
    PreviousMMVersion
  | -- | should correspond to the latest source catalog version
    CurrentMMVersion
  deriving (Show, Eq)

-------------------------------------------------------------------------------
-- Source health check

data SourceHealthCheckInfo b = SourceHealthCheckInfo
  { _shciName :: SourceName,
    _shciConnection :: SourceConnConfiguration b,
    _shciHealthCheck :: HealthCheckConfig b
  }

type BackendSourceHealthCheckInfo = AB.AnyBackend SourceHealthCheckInfo

type SourceHealthCheckCache = HashMap SourceName BackendSourceHealthCheckInfo

-------------------------------------------------------------------------------
-- Source pings

data SourcePingInfo b = SourcePingInfo
  { _spiName :: SourceName,
    _spiConnection :: SourceConnConfiguration b
  }

type BackendSourcePingInfo = AB.AnyBackend SourcePingInfo

type SourcePingCache = HashMap SourceName BackendSourcePingInfo
