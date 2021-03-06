{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module Pact.Analyze.Check
  ( verifyModule
  , verifyCheck
  , describeCheckFailure
  , describeCheckResult
  , describeParseFailure
  , showModel
  , CheckFailure(..)
  , CheckFailureNoLoc(..)
  , CheckSuccess(..)
  , CheckResult
  , ModuleChecks(..)
  , SmtFailure(..)
  , ParseFailure
  , VerificationFailure(..)
  ) where

import           Control.Exception         as E
import           Control.Lens              (ifoldrM, itraversed, ix, traversed,
                                            view, (<&>), (^.), (^?), (^@..),
                                            _1, _2, _Just)
import           Control.Monad             (join, void)
import           Control.Monad.Except      (ExceptT (ExceptT), MonadError,
                                            catchError, runExceptT, throwError,
                                            withExcept, withExceptT)
import           Control.Monad.Morph       (generalize, hoist)
import           Control.Monad.Reader      (runReaderT)
import           Control.Monad.Trans.Class (MonadTrans (lift))
import           Data.Either               (lefts, partitionEithers, rights)
import qualified Data.HashMap.Strict       as HM
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (mapMaybe)
import           Data.Monoid               ((<>))
import           Data.SBV                  (Symbolic)
import qualified Data.SBV                  as SBV
import qualified Data.SBV.Control          as SBV
import qualified Data.SBV.Internals        as SBVI
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Traversable          (for)
import           Prelude                   hiding (exp)

import           Pact.Typechecker          (typecheckTopLevel)
import           Pact.Types.Lang           (Code (Code), Info (Info), eParsed,
                                            mMetas, mName, renderInfo,
                                            renderParsed, tMeta)
import           Pact.Types.Runtime        (Exp, ModuleData, ModuleName,
                                            Ref (Ref),
                                            Term (TConst, TDef, TSchema,
                                            TTable), asString, tShow)
import qualified Pact.Types.Runtime        as Pact
import           Pact.Types.Typecheck      (AST,
                                            Fun (FDefun, _fArgs, _fBody, _fInfo),
                                            Named, Node, TcId (_tiInfo),
                                            TopLevel (TopFun, TopTable, _tlInfo),
                                            UserType (_utFields, _utName),
                                            runTC, tcFailures)
import qualified Pact.Types.Typecheck      as TC

import           Pact.Analyze.Errors
import           Pact.Analyze.Eval         hiding (invariants)
import           Pact.Analyze.Model        (allocArgs, allocModelTags,
                                            saturateModel, showModel)
import           Pact.Analyze.Parse        (expToCheck, expToInvariant)
import           Pact.Analyze.Translate
import           Pact.Analyze.Types
import           Pact.Analyze.Util

data CheckSuccess
  = SatisfiedProperty Model
  | ProvedTheorem
  deriving (Eq, Show)

type ParseFailure = (Exp, String)

data SmtFailure
  = Invalid Model
  | Unsatisfiable
  | Unknown SBV.SMTReasonUnknown
  | UnexpectedFailure SBV.SMTException
  deriving Show

instance Eq SmtFailure where
  Invalid m1    == Invalid m2    = m1 == m2
  Unsatisfiable == Unsatisfiable = True

  -- SMTReasonUnknown and SMTException don't provide instances of Eq, so we
  -- always return 'False' in these cases.
  _             ==             _ = False

data CheckFailureNoLoc
  = NotAFunction Text
  | TypecheckFailure (Set TC.Failure)
  | TranslateFailure' TranslateFailureNoLoc
  | AnalyzeFailure' AnalyzeFailureNoLoc
  | SmtFailure SmtFailure
  deriving (Eq, Show)

data CheckFailure = CheckFailure
  { _checkFailureParsed :: !Info
  , _checkFailure       :: !CheckFailureNoLoc
  } deriving (Eq, Show)

type CheckResult = Either CheckFailure CheckSuccess

data ModuleChecks = ModuleChecks
  { propertyChecks  :: HM.HashMap Text [CheckResult]
  , invariantChecks :: HM.HashMap Text (TableMap [CheckResult])
  } deriving (Eq, Show)

data VerificationFailure
  = ModuleParseFailures [ParseFailure]
  | ModuleCheckFailure CheckFailure
  | TypeTranslationFailure Text (Pact.Type TC.UserType)
  deriving Show

describeCheckSuccess :: CheckSuccess -> Text
describeCheckSuccess = \case
  SatisfiedProperty model -> "Property satisfied with model:\n"
                          <> showModel model
  ProvedTheorem           -> "Property proven valid"

describeParseFailure :: ParseFailure -> Text
describeParseFailure (exp, info)
  = T.pack (renderParsed (exp ^. eParsed))
  <> ": could not parse " <> tShow exp <> ": " <> T.pack info

describeSmtFailure :: SmtFailure -> Text
describeSmtFailure = \case
  Invalid model  -> "Invalidating model found:\n" <> showModel model
  Unsatisfiable  -> "This property is unsatisfiable"
  Unknown reason -> "The solver returned 'unknown':\n" <> tShow reason
  UnexpectedFailure smtE -> T.pack $ show smtE

describeCheckFailure :: CheckFailure -> Text
describeCheckFailure (CheckFailure info failure) =
  case failure of
    TypecheckFailure fails -> T.unlines $ map
      (\(TC.Failure ti s) -> T.pack (renderInfo (_tiInfo ti) ++ ":Warning: " ++ s))
      (Set.toList fails)

    _ ->
      let str = case failure of
            NotAFunction name     -> "No function named " <> name
            TypecheckFailure _    -> error "impossible (handled above)"
            TranslateFailure' err -> describeTranslateFailureNoLoc err
            AnalyzeFailure' err   -> describeAnalyzeFailureNoLoc err
            SmtFailure err        -> describeSmtFailure err
      in T.pack (renderParsed (infoToParsed info)) <> ":Warning: " <> str

describeCheckResult :: CheckResult -> Text
describeCheckResult = either describeCheckFailure describeCheckSuccess

-- TODO: don't throw out these Infos
translateToCheckFailure :: TranslateFailure -> CheckFailure
translateToCheckFailure (TranslateFailure info err)
  = CheckFailure info (TranslateFailure' err)

analyzeToCheckFailure :: AnalyzeFailure -> CheckFailure
analyzeToCheckFailure (AnalyzeFailure info err)
  = CheckFailure info (AnalyzeFailure' err)

smtToCheckFailure :: Info -> SmtFailure -> CheckFailure
smtToCheckFailure info = CheckFailure info . SmtFailure

--
-- TODO: implement machine-friendly JSON output for CheckResult
--

resultQuery
  :: Goal                                      -- ^ are we in sat or valid mode?
  -> Model                                     -- ^ unsaturated/symbolic model
  -> ExceptT SmtFailure SBV.Query CheckSuccess
resultQuery goal model0 = do
  satResult <- lift SBV.checkSat
  case goal of
    Validation ->
      case satResult of
        SBV.Sat   -> throwError . Invalid =<< lift (saturateModel model0)
        SBV.Unsat -> pure ProvedTheorem
        SBV.Unk   -> throwError . Unknown =<< lift SBV.getUnknownReason

    Satisfaction ->
      case satResult of
        SBV.Sat   -> SatisfiedProperty <$> lift (saturateModel model0)
        SBV.Unsat -> throwError Unsatisfiable
        SBV.Unk   -> throwError . Unknown =<< lift SBV.getUnknownReason

-- -- Assumes sat mode. It might be a decent idea for us to introduce an indexed
-- -- type to denote which things assume certain modes.
-- checkConstraintVacuity :: ExceptT SmtFailure SBV.Query ()
-- checkConstraintVacuity = do
--   prePropRes <- lift $ SBV.checkSat
--   case prePropRes of
--     SBV.Sat   -> pure ()
--     SBV.Unsat -> throwError VacuousConstraints
--     SBV.Unk   -> throwError . Unknown =<< lift SBV.getUnknownReason

-- SBV also provides 'inNewAssertionStack', but in 'Query'
inNewAssertionStack
  :: ExceptT a SBV.Query CheckSuccess
  -> ExceptT a SBV.Query CheckSuccess
inNewAssertionStack act = do
    push
    result <- act `catchError` \e -> pop *> throwError e
    pop
    pure result

  where
    push = lift $ SBV.push 1
    pop  = lift $ SBV.pop 1

-- Produces args for analysis from model args
analysisArgs :: Map VarId (Located (Text, TVal)) -> Map VarId AVal
analysisArgs = fmap (view (located._2._2))

verifyFunctionInvariants'
  :: Info
  -> [Table]
  -> [Named Node]
  -> [AST Node]
  -> IO (Either CheckFailure (TableMap [CheckResult]))
verifyFunctionInvariants' funInfo tables pactArgs body = runExceptT $ do
    (args, tm, tagAllocs) <- hoist generalize $
      withExcept translateToCheckFailure $ runTranslation funInfo pactArgs body

    ExceptT $ catchingExceptions $ runSymbolic $ runExceptT $ do
      modelArgs' <- lift $ allocArgs args
      tags <- lift $ allocModelTags (Located funInfo tm) tagAllocs
      resultsTable <- withExceptT analyzeToCheckFailure $
        runInvariantAnalysis tables (analysisArgs modelArgs') tm tags funInfo

      -- Iterate through each invariant in a single query so we can reuse our
      -- assertion stack.
      ExceptT $ fmap Right $
        SBV.query $
          for2 resultsTable $ \(Located info (AnalysisResult prop ksProvs)) -> do
            queryResult <- runExceptT $
              inNewAssertionStack $ do
                void $ lift $ SBV.constrain $ SBV.bnot prop
                resultQuery goal $ Model modelArgs' tags ksProvs

            -- Either SmtFailure CheckSuccess -> CheckResult
            pure $ case queryResult of
               Left smtFailure -> Left $
                 CheckFailure info (SmtFailure smtFailure)
               Right pass      -> Right pass

  where
    goal :: Goal
    goal = Validation

    config :: SBV.SMTConfig
    config = SBV.z3

    -- Discharges impure 'SMTException's from sbv.
    catchingExceptions
      :: IO (Either CheckFailure b)
      -> IO (Either CheckFailure b)
    catchingExceptions act = act `E.catch` \(e :: SBV.SMTException) ->
      pure $ Left $ CheckFailure funInfo $ SmtFailure $ UnexpectedFailure e

    runSymbolic :: Symbolic a -> IO a
    runSymbolic = SBV.runSMTWith config

verifyFunctionProperty
  :: Info
  -> [Table]
  -> [Named Node]
  -> [AST Node]
  -> Located Check
  -> IO (Either CheckFailure CheckSuccess)
verifyFunctionProperty funInfo tables pactArgs body (Located propInfo check) =
    runExceptT $ do
      (args, tm, tagAllocs) <- hoist generalize $
        withExcept translateToCheckFailure $
          runTranslation funInfo pactArgs body
      ExceptT $ catchingExceptions $ runSymbolic $ runExceptT $ do
        modelArgs' <- lift $ allocArgs args
        tags <- lift $ allocModelTags (Located funInfo tm) tagAllocs
        AnalysisResult prop ksProvs <- withExceptT analyzeToCheckFailure $
          runPropertyAnalysis check tables (analysisArgs modelArgs') tm tags funInfo
        void $ lift $ SBV.output prop
        hoist SBV.query $ withExceptT (smtToCheckFailure propInfo) $
          resultQuery goal $ Model modelArgs' tags ksProvs

  where
    goal :: Goal
    goal = checkGoal check

    config :: SBV.SMTConfig
    config = SBV.z3

    -- Discharges impure 'SMTException's from sbv.
    catchingExceptions
      :: IO (Either CheckFailure b)
      -> IO (Either CheckFailure b)
    catchingExceptions act = act `E.catch` \(e :: SBV.SMTException) ->
      pure $ Left $ smtToCheckFailure propInfo $ UnexpectedFailure e

    runSymbolic :: Symbolic a -> IO a
    runSymbolic = fmap fst .
      SBVI.runSymbolic (SBVI.SMTMode SBVI.ISetup (goal == Satisfaction) config)

moduleTables
  :: HM.HashMap ModuleName ModuleData -- ^ all loaded modules
  -> ModuleData                       -- ^ the module we're verifying
  -> ExceptT [ParseFailure] IO [Table]
moduleTables modules (_mod, modRefs) = ExceptT $ do
  -- All tables defined in this module, and imported by it. We're going to look
  -- through these for their schemas, which we'll look through for invariants.
  let tables = flip mapMaybe (modules ^@.. traversed . _2 . itraversed) $ \case
        (name, Ref (table@TTable {})) -> Just (name, table)
        _                             -> Nothing

  -- TODO: need mapMaybe for HashMap
  let schemas = HM.fromList $ flip mapMaybe (HM.toList modRefs) $ \case
        (name, Ref (schema@TSchema {})) -> Just (name, schema)
        _                               -> Nothing

  eitherTables <- for tables $ \(tabName, tab) -> do
      (TopTable _info _name (Pact.TyUser schema) _meta, _tcState)
        <- runTC 0 False $ typecheckTopLevel (Ref tab)

      let TC.Schema{_utName,_utFields} = schema
          schemaName = asString _utName

          invariants = schemas ^? ix schemaName.tMeta._Just.mMetas.ix "invariants"
          invariant  = schemas ^? ix schemaName.tMeta._Just.mMetas.ix "invariant"

          invInfo = runExpParserOver
            "invariants" invariants invariant $
            \meta -> runReaderT (expToInvariant TBool meta)
              (varIdArgs _utFields)

      pure $ Table tabName schema <$> invInfo

  let (failures, tables') = partitionEithers eitherTables
  pure $ if null failures then Right tables' else Left (concat failures)

-- Get the set (HashMap) of refs to functions in this module.
moduleTypecheckableRefs :: ModuleData -> HM.HashMap Text Ref
moduleTypecheckableRefs (_mod, modRefs) = flip HM.filter modRefs $ \case
  Ref (TDef {})   -> True
  Ref (TConst {}) -> True
  _               -> False

moduleFunChecks
  :: [Table]
  -> HM.HashMap Text (Ref, Pact.FunType TC.UserType)
  -> Either VerificationFailure
       (HM.HashMap Text (Ref, Either [ParseFailure] [Located Check]))
moduleFunChecks tables modTys = for modTys $
  \(ref@(Ref defn), Pact.FunType argTys resultTy) -> do

  let properties = defn ^? tMeta . _Just . mMetas . ix "properties"
      property   = defn ^? tMeta . _Just . mMetas . ix "property"

      -- TODO: Ideally we wouldn't have any ad-hoc VID generation, but we're
      --       not there yet:
      vids = VarId <$> [1..]

  -- TODO(joel): this relies on generating the same unique ids as
  -- @checkFunction@. We need to more carefully enforce this is true!
  argTys' <- for argTys $ \(Pact.Arg name ty _info) ->
    case maybeTranslateType ty of
      Just ety -> pure (name, ety)
      Nothing  -> throwError $
        TypeTranslationFailure "couldn't translate argument type" ty

  resultTy' <- case maybeTranslateType resultTy of
    Just ety -> pure ("result", 0, ety)
    Nothing  -> throwError $
      TypeTranslationFailure "couldn't translate result type" resultTy

  let env :: [(Text, VarId, EType)]
      env = resultTy' :
        ((\(vid, (text, ty)) -> (text, vid, ty)) <$> zip vids argTys')

      nameEnv :: Map Text VarId
      nameEnv = Map.fromList $ fmap (\(name, vid, _) -> (name, vid)) env

      idEnv :: Map VarId EType
      idEnv = Map.fromList $ fmap (\(_, vid, ty) -> (vid, ty)) env

      vidStart = VarId (length env)

      tableEnv = TableMap $ Map.fromList $
        tables <&> \Table { _tableName, _tableType } ->
          let fields = _utFields _tableType
              colMap = ColumnMap $ Map.fromList $ flip mapMaybe fields $
                \(Pact.Arg argName ty _) ->
                  (ColumnName (T.unpack argName),) <$> maybeTranslateType ty
          in (TableName (T.unpack _tableName), colMap)

      checks :: Either [ParseFailure] [Located Check]
      checks = runExpParserOver "properties" properties property
        (expToCheck tableEnv vidStart nameEnv idEnv)

  pure (ref, checks)

-- | For both properties and invariants you're allowed to use either the
-- singular ("property") or plural ("properties") name. This helper just
-- collects the properties / invariants in a list.
collectExps :: String -> Maybe Exp -> Maybe Exp -> Either [(Exp, String)] [Exp]
collectExps name multiExp singularExp = case multiExp of
  Just (Pact.ELitList exps') -> Right exps'
  Just exp -> Left [(exp, name ++ " must be a list")]
  Nothing -> case singularExp of
    Just exp -> Right [exp]
    Nothing  -> Right []

expToInfo :: Exp -> Info
expToInfo exp = Info (Just (Code (tShow exp), exp ^. eParsed))

-- | This runs a parser over a collection of 'Exp's, collecting the failures
-- or successes.
runExpParserOver
  :: forall t.
     String
  -> Maybe Exp
  -> Maybe Exp
  -> (Exp -> Either String t)
  -> Either [ParseFailure] [Located t]
runExpParserOver name multiExp singularExp parser =
  let
      exps = collectExps name multiExp singularExp
      parsedList :: Either [ParseFailure] [Either [ParseFailure] (Located t)]
      parsedList = exps <&&> \meta -> case parser meta of
        Left err   -> Left [(meta, err)]
        Right good -> Right (Located (expToInfo meta) good)

      parsedList' :: [Either [ParseFailure] (Located t)]
      parsedList' = join <$> sequence parsedList

      failures :: [ParseFailure]
      failures = join $ lefts parsedList'

  in if null failures then Right (rights parsedList') else Left failures

verifyFunctionProps :: [Table] -> Ref -> [Located Check] -> IO [CheckResult]
verifyFunctionProps tables ref props = do
  (fun, tcState) <- runTC 0 False $ typecheckTopLevel ref
  let failures = tcState ^. tcFailures

  case fun of
    TopFun (FDefun {_fInfo, _fArgs, _fBody}) _ ->
      if Set.null failures
      then for props $ verifyFunctionProperty _fInfo tables _fArgs _fBody
      else pure [Left (CheckFailure _fInfo (TypecheckFailure failures))]
    _ -> pure []

verifyFunctionInvariants
  :: [Table]
  -> Ref
  -> IO (Either CheckFailure (TableMap [CheckResult]))
verifyFunctionInvariants tables ref = do
  (fun, tcState) <- runTC 0 False $ typecheckTopLevel ref
  let failures = tcState ^. tcFailures

  case fun of
    TopFun (FDefun {_fInfo, _fArgs, _fBody}) _ ->
      if Set.null failures
      then verifyFunctionInvariants' _fInfo tables _fArgs _fBody
      else pure $ Left $ CheckFailure _fInfo (TypecheckFailure failures)
    other -> pure $ Left $ CheckFailure (_tlInfo other) (NotAFunction (tShow ref))

-- TODO: use from Control.Monad.Except when on mtl 2.2.2
liftEither :: MonadError e m => Either e a -> m a
liftEither = either throwError return

-- | Verifies properties on all functions, and that each function maintains all
-- invariants.
verifyModule
  :: HM.HashMap ModuleName ModuleData   -- ^ all loaded modules
  -> ModuleData                         -- ^ the module we're verifying
  -> IO (Either VerificationFailure ModuleChecks)
verifyModule modules moduleData = runExceptT $ do
  tables <- withExceptT ModuleParseFailures $ moduleTables modules moduleData

  let typecheckedRefs :: HM.HashMap Text Ref
      typecheckedRefs = moduleTypecheckableRefs moduleData

  -- For each ref, if it typechecks as a function (it'll be either a function
  -- or a constant), keep its signature.
  --
  (funTypes :: HM.HashMap Text (Ref, Pact.FunType TC.UserType)) <- ifoldrM
    (\name ref accum -> do
      maybeFun <- lift $ runTC 0 False $ typecheckTopLevel ref
      pure $ case maybeFun of
        (TopFun (FDefun _info _name funType _args _body) _meta, _tcState)
          -> HM.insert name (ref, funType) accum
        _ -> accum
    )
    HM.empty
    typecheckedRefs

  (funChecks :: HM.HashMap Text (Ref, Either [ParseFailure] [Located Check]))
    <- liftEither $ moduleFunChecks tables funTypes

  let funChecks' :: Either [ParseFailure] (HM.HashMap Text (Ref, [Located Check]))
      funChecks' = traverse sequence funChecks

      verifyFunProps :: (Ref, [Located Check]) -> IO [CheckResult]
      verifyFunProps = uncurry (verifyFunctionProps tables)

  funChecks'' <- case funChecks' of
    Left errs         -> throwError $ ModuleParseFailures errs
    Right funChecks'' -> pure funChecks''

  funChecks''' <- lift $ traverse verifyFunProps funChecks''
  invariantChecks <- for typecheckedRefs $ \ref -> do
    withExceptT ModuleCheckFailure $ ExceptT $
      verifyFunctionInvariants tables ref

  pure $ ModuleChecks funChecks''' invariantChecks

-- | Verifies a one-off 'Check' for a function.
verifyCheck
  :: ModuleData     -- ^ the module we're verifying
  -> Text           -- ^ the name of the function
  -> Check          -- ^ the check we're running
  -> ExceptT VerificationFailure IO CheckResult
verifyCheck moduleData funName check = do
  let info       = dummyInfo
      moduleName = moduleData ^. _1.mName
      modules    = HM.fromList [(moduleName, moduleData)]
      moduleFun :: ModuleData -> Text -> Maybe Ref
      moduleFun (_mod, modRefs) name = name `HM.lookup` modRefs

  tables <- withExceptT ModuleParseFailures $ moduleTables modules moduleData
  case moduleFun moduleData funName of
    Just funRef -> ExceptT $
      Right . head <$> verifyFunctionProps tables funRef [Located info check]
    Nothing -> pure $ Left $ CheckFailure info $ NotAFunction funName
