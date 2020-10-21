-- GHC doesn't like the definition of 'toDynamicBuiltinMeaning'.
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE UndecidableInstances      #-}

module Language.PlutusCore.Constant.Meaning where

import           PlutusPrelude

import           Language.PlutusCore.Constant.Function
import           Language.PlutusCore.Constant.Typed
import           Language.PlutusCore.Core
import           Language.PlutusCore.Evaluation.Machine.Exception
import           Language.PlutusCore.Name

import           Control.Lens                                     (ix, (^?))
import           Control.Monad.Except
import           Data.Array
import qualified Data.Kind                                        as GHC
import           Data.Proxy
import           GHC.TypeLits

-- data family TyVarRepK (text :: Symbol) (unique :: Nat) (kind :: GHC.Type) :: kind
-- data family TyAppRepK (fun :: dom -> cod) (arg :: dom) :: cod

-- TODO: talk about costing.
{- Note [BuiltinMeaning]
We represent the meaning of a 'Builtin' as a 'TypeScheme' and a Haskell denotation.
We need both while evaluating a 'Builtin', because 'TypeScheme' is required for
well-typedness to avoid using 'unsafeCoerce' and similar junk, while the denotation is what
actually computes. We do not need denotations for type checking, nor strongly typed 'TypeScheme'
is required, however analogously to static built-ins, we compute the types of dynamic built-ins from
their 'TypeScheme's. This way we only define a 'TypeScheme', which we anyway need, and then compute
the corresponding 'Type' from it. And we can't go the other way around -- from untyped to typed --
of course. Therefore a typed thing has to go before the corresponding untyped thing and in the
final pipeline one has to supply a 'BuiltinMeaning' for each of the 'Builtin's.
-}

-- TODO: can we make it this?
--
--     data BuiltinMeaning uni dyn cost =
--         forall args res. BuiltinMeaning
--             (forall term. uni ~ UniOf term => TypeScheme term args res)
--             (dyn -> FoldArgs args res)
--             (cost -> FoldArgsEx args)

-- See Note [BuiltinMeaning].
-- | The meaning of a dynamic built-in name consists of its 'Type' represented as a 'TypeScheme'
-- and its Haskell denotation.
data BuiltinMeaning term dyn cost =
    forall args res. BuiltinMeaning
        (TypeScheme term args res)
        (dyn -> FoldArgs args res)
        (cost -> FoldArgsEx args)

data BuiltinRuntime term =
    forall args res. BuiltinRuntime
        (TypeScheme term args res)
        Arity
        (FoldArgs args res)
        (FoldArgsEx args)

newtype BuiltinsRuntime fun term = BuiltinsRuntime
    { unBuiltinRuntime :: Array fun (BuiltinRuntime term)
    }

toBuiltinRuntime :: dyn -> cost -> BuiltinMeaning term dyn cost -> BuiltinRuntime term
toBuiltinRuntime dyn cost (BuiltinMeaning sch f exF) =
    BuiltinRuntime sch (getArity sch) (f dyn) (exF cost)

class (Bounded fun, Enum fun, Ix fun) => ToBuiltinMeaning uni fun where
    type DynamicPart uni fun
    type CostingPart uni fun
    toBuiltinMeaning
        :: HasConstantIn uni term
        => fun -> BuiltinMeaning term (DynamicPart uni fun) (CostingPart uni fun)

typeOfBuiltinFunction :: ToBuiltinMeaning uni fun => fun -> Type TyName uni ()
typeOfBuiltinFunction fun = case toBuiltinMeaning @_ @_ @(Term TyName Name _ _ ()) fun of
    BuiltinMeaning sch _ _ -> typeSchemeToType sch

toBuiltinsRuntime
    :: ( dyn ~ DynamicPart uni fun, cost ~ CostingPart uni fun
       , HasConstantIn uni term, ToBuiltinMeaning uni fun
       )
    => dyn -> cost -> BuiltinsRuntime fun term
toBuiltinsRuntime dyn cost =
    BuiltinsRuntime . tabulate $ toBuiltinRuntime dyn cost . toBuiltinMeaning

lookupBuiltin
    :: (MonadError (ErrorWithCause err term) m, AsMachineError err internal fun term, Ix fun)
    => fun -> BuiltinsRuntime fun val -> m (BuiltinRuntime val)
-- @Data.Array@ doesn't seem to have a safe version of @(!)@, hence we use a prism.
lookupBuiltin fun (BuiltinsRuntime env) = case env ^? ix fun of
    Nothing  -> throwingWithCause _MachineError (UnknownBuiltin fun) Nothing
    Just bri -> pure bri

type family GetArgs a :: [GHC.Type] where
    GetArgs (a -> b) = a ': GetArgs b
    GetArgs _        = '[]

-- | A class that allows to derive a 'Monotype' for a builtin.
class KnownMonotype term args res a | args res -> a, a -> res where
    knownMonotype :: TypeScheme term args res

instance (res ~ res', KnownType term res) => KnownMonotype term '[] res res' where
    knownMonotype = TypeSchemeResult Proxy

-- | A class that allows to derive a 'Monotype' for a builtin.
instance (KnownType term arg, KnownMonotype term args res a) =>
            KnownMonotype term (arg ': args) res (arg -> a) where
    knownMonotype = Proxy `TypeSchemeArrow` knownMonotype

type family Delete x xs :: [a] where
    Delete _ '[]       = '[]
    Delete x (x ': xs) = Delete x xs
    Delete x (y ': xs) = y ': Delete y xs

type family Merge xs ys :: [a] where
    Merge '[]       ys = ys
    Merge (x ': xs) ys = x ': Delete x (Merge xs ys)

type family ToBinds (x :: a) :: [(Symbol, Nat)]

type instance ToBinds (TyVarRep name uniq) = '[ '(name, uniq) ]
type instance ToBinds (TyAppRep fun arg) = TypeError ('Text "Not supported yet")

type family ArgToBinds (a :: GHC.Type) :: [(Symbol, Nat)] where
    ArgToBinds (Opaque _ rep) = ToBinds rep
    ArgToBinds _              = '[]

type instance ToBinds '[]           = '[]
type instance ToBinds (arg ': args) = Merge (ArgToBinds arg) (ToBinds args)

-- | A class that allows to derive a 'Polytype' for a builtin.
class KnownPolytype (binds :: [(Symbol, Nat)]) term args res a | args res -> a, a -> res where
    knownPolytype :: Proxy binds -> TypeScheme term args res

instance KnownMonotype term args res a => KnownPolytype '[] term args res a where
    knownPolytype _ = knownMonotype

-- | A class that allows to derive a 'Polytype' for a builtin.
instance (KnownSymbol name, KnownNat uniq, KnownPolytype binds term args res a) =>
            KnownPolytype ('(name, uniq) ': binds) term args res a where
    knownPolytype _ = TypeSchemeAll @name @uniq Proxy (Type ()) $ \_ -> knownPolytype (Proxy @binds)

toDynamicBuiltinMeaning
    :: forall a term dyn cost binds args res.
       ( args ~ GetArgs a, a ~ FoldArgs args res, binds ~ ToBinds args
       , KnownPolytype binds term args res a
       )
    => (dyn -> a) -> (cost -> FoldArgsEx args) -> BuiltinMeaning term dyn cost
toDynamicBuiltinMeaning = BuiltinMeaning (knownPolytype (Proxy @binds) :: TypeScheme term args res)

toStaticBuiltinMeaning
    :: forall a term dyn cost binds args res.
       ( args ~ GetArgs a, a ~ FoldArgs args res, binds ~ ToBinds args
       , KnownPolytype binds term args res a
       )
    => a -> (cost -> FoldArgsEx args) -> BuiltinMeaning term dyn cost
toStaticBuiltinMeaning = toDynamicBuiltinMeaning . const
