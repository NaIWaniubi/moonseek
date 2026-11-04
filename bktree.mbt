///|
/// BK-tree: a metric tree for fast approximate string matching.
/// Each node holds a term; children are keyed by their edit distance to
/// the parent. Searching for terms within distance d of a query only
/// visits children whose edge distance is in [dist(query,node)-d,
/// dist(query,node)+d] — pruning most of the tree for small d.
/// This turns fuzzy matching from O(vocab) to O(vocab^0.5) typical.

///|
priv struct BkNode {
  term : String
  children : @hashmap.HashMap[Int32, BkNode]
}

///|
/// A BK-tree over a dictionary of terms.
pub struct BkTree {
  priv mut root : BkNode?
  priv mut size : Int32
}

///|
pub fn BkTree::new() -> BkTree {
  { root: None, size: 0, }
}

///|
/// Number of terms in the tree.
pub fn BkTree::len(self : BkTree) -> Int32 {
  self.size
}

///|
/// Insert a term. Duplicates are ignored.
pub fn BkTree::insert(self : BkTree, term : String) -> Unit {
  match self.root {
    None => {
      self.root = Some({ term, children: @hashmap.HashMap([]), })
      self.size += 1
    }
    Some(root) => {
      let mut node = root
      while true {
        let d = levenshtein(term, node.term)
        if d == 0 {
          return // duplicate
        }
        match node.children.get(d) {
          Some(child) => node = child
          None => {
            node.children.set(d, { term, children: @hashmap.HashMap([]), })
            self.size += 1
            return
          }
        }
      }
    }
  }
}

///|
/// Build a BK-tree from an array of terms.
pub fn BkTree::from_terms(terms : Array[String]) -> BkTree {
  let tree = BkTree::new()
  for term in terms {
    tree.insert(term)
  }
  tree
}

///|
/// Find all terms within `max_distance` edits of `query`.
/// Results are sorted by (distance, term).
pub fn BkTree::search(
  self : BkTree,
  query : String,
  max_distance~ : Int32 = 2,
) -> Array[FuzzyMatch] {
  let results : Array[FuzzyMatch] = []
  match self.root {
    None => return results
    Some(root) => {
      // Iterative DFS with explicit stack to avoid deep recursion.
      let stack : Array[BkNode] = [root]
      while stack.length() > 0 {
        let node = match stack.pop() {
          Some(n) => n
          None => break
        }
        let d = levenshtein(query, node.term)
        if d <= max_distance {
          results.push({ term: node.term, distance: d, })
        }
        // Only visit children whose edge distance could yield a match.
        let low = d - max_distance
        let high = d + max_distance
        for (edge_dist, child) in node.children.iter() {
          if edge_dist >= low && edge_dist <= high {
            stack.push(child)
          }
        }
      }
    }
  }
  results.sort_by(fn(a, b) {
    let cmp = a.distance.compare(b.distance)
    if cmp == 0 {
      a.term.compare(b.term)
    } else {
      cmp
    }
  })
  results
}

///|
/// Build a BK-tree from the index's vocabulary (all fields or one field).
/// The tree is cached inside the index and reused across calls until the
/// next `add`; building one per query costs more than a linear scan for
/// vocabularies under ~100k terms.
pub fn Index::bk_tree(self : Index, field~ : String? = None) -> BkTree {
  let key = match field {
    Some(f) => f
    None => "*"
  }
  match self.bk_trees.get(key) {
    Some(tree) => tree
    None => {
      let tree = BkTree::from_terms(self.fuzzy_vocabulary(field))
      self.bk_trees.set(key, tree)
      tree
    }
  }
}

///|
/// Fast fuzzy term lookup using a BK-tree. Same semantics as fuzzy_terms
/// but sub-linear for small distances on large vocabularies.
pub fn Index::fuzzy_terms_fast(
  self : Index,
  term : String,
  max_distance~ : Int32 = 2,
  field~ : String? = None,
) -> Array[FuzzyMatch] {
  let bound = clamp_max_distance(max_distance)
  let tree = self.bk_tree(field~)
  tree.search(term, max_distance=bound)
}
