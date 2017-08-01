module Genetics.Browser.Cytoscape.Collection where

import Prelude
import Data.Argonaut (_Object, _String, (.?))
import Data.Argonaut.Core (JObject, JArray)
import Data.Either (Either(..))
import Data.Foldable (and)
import Data.Lens ((^?))
import Data.Lens.Index (ix)
import Data.Maybe (maybe)
import Data.Newtype (wrap)
import Data.Predicate (Predicate)
import Genetics.Browser.Cytoscape.Types (Cytoscape, Element, elementJObject)


foreign import data CyCollection :: Type -> Type
foreign import collectionJson :: forall e. CyCollection e -> JArray
foreign import collectionsEqual :: forall e. CyCollection e -> CyCollection e -> Boolean

instance eqCyCollection :: Eq (CyCollection e) where
  eq = collectionsEqual

foreign import union :: forall e. CyCollection e
                     -> CyCollection e
                     -> CyCollection e

instance semigroupCyCollection :: Semigroup (CyCollection e) where
  append = union

-- can't be made a monoid since an empty collection can only be created
-- in the context of an existing cytoscape instance
foreign import emptyCollection :: Cytoscape -> CyCollection Element

instance showCyCollection :: Show (CyCollection e) where
  show = show <<< collectionJson


foreign import size :: forall e. CyCollection e -> Int

foreign import contains :: forall e. CyCollection e -> CyCollection e -> Boolean

foreign import connectedEdges :: forall e. CyCollection e
                              -> CyCollection e

foreign import connectedNodes :: forall e. CyCollection e
                              -> CyCollection e

foreign import sourceNodes :: forall e. CyCollection e
                           -> CyCollection e

foreign import targetNodes :: forall e. CyCollection e
                           -> CyCollection e

foreign import filter :: forall e.
                         Predicate e
                      -> CyCollection e
                      -> CyCollection e

foreign import isNode :: Predicate Element
foreign import isEdge :: Predicate Element

evenEdges :: CyCollection Element -> CyCollection Element
evenEdges =
  let evenId = wrap $ \el -> case (elementJObject el) .? "id" of
        Left _  -> false
        Right i -> i `mod` 2 == 0
      -- get all nodes with even IDs
  in filter (conj isNode evenId)
      -- get the connected edges (discarding the nodes)
     >>> connectedEdges


evenEdgesWithNodes :: CyCollection Element -> CyCollection Element
evenEdgesWithNodes coll =
  let evenId = wrap $ \el -> case elementJObject el .? "id" of
        Left _  -> false
        Right i -> i `mod` 2 == 0
      edges = filter (and [isNode, evenId]) coll
  in coll `union` edges


evenEdgesWithNodes' :: CyCollection Element -> CyCollection Element
evenEdgesWithNodes' =
  let evenId = wrap $ \el -> case elementJObject el .? "id" of
        Left _  -> false
        Right i -> i `mod` 2 == 0
  in union <$> filter (and [isNode, evenId]) <*> connectedNodes


locPred :: String -> JObject -> Boolean
locPred chr obj = maybe false id $ do
  loc <- obj ^? ix "lrsLoc" <<< _Object
  chr' <- loc ^? ix "chr" <<< _String
  pure $ chr' == chr


edgesLoc :: String -> CyCollection Element -> CyCollection Element
edgesLoc chr = filter $ wrap $ locPred chr <<< elementJObject
