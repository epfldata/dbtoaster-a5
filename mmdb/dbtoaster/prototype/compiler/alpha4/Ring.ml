(* A module for representing expressions of a commutative
   ring with 1 (using the operations '+', unary '-', and '*')
   over a base type, and for simplifying expressions.
   The module contains a function for turning an
   expression into a polynomial and for computing a delta of an expression
   given a delta-function for atomic expressions (particularly, variables).
*)


(* The base type t over which we define the ring, plus its zero and one
   elements.
*) 
module type Base =
sig
  type t
  val  zero: t
  val  one:  t
end
;;


(* We build rings using the Make functor over the Base type.
   Examples are in RingTest.ml.
*)
module type Ring =
sig
   (* the type of base values. *)
   type leaf_t

   (* expression type. The implementation is hidden (abstract), so it
      can only be accessed through special access functions.

      Making expr_t abstract:
      Since the nesting structure of an expression in general matters to us,
      being flexible in the implementation may not be so necessary. However,
      we want the user to use mk_sum and m_prod to construct sums and
      products, rather than the Sum and Prod constructors from expr_t, because
      the mk-functions automatically eliminate certain redundancies on the
      fly that the implementations of other functions of Ring may
      depend upon. 
   *)
   type expr_t = Val  of leaf_t
               | Sum  of expr_t list
               | Prod of expr_t list
               | Neg  of expr_t
(* type expr_t *) (* currently not abstract, for debugging *)


   (* constant multiplicity represented by int; could be an arbitrary
      constant ring element. *)
   type mono_t = int * (leaf_t list)


   (* the zero- and one-elements of the ring *)
   val zero: expr_t
   val one:  expr_t


   (* constructing a (nested) expression using base values,
      sums, and products of expressions *)

   (* turns a value of type T.t into an expression (consisting just of
      that value) *)
   val mk_val: leaf_t -> expr_t

   (* turns a list l of expressions into \bigsum l and \bigprod l, resp. *)
   val mk_sum:  (expr_t list) -> expr_t
   val mk_prod: (expr_t list) -> expr_t
   val mk_neg:  expr_t -> expr_t

   (* accessing the contents of an expression *)
   exception NotAValException
   val get_val: expr_t -> leaf_t

   (* returns a list l of expressions such that (mk_sum l) resp. (mk_prod l)
      are equivalent to the input.

      Applied to a polynomial, sum_list returns the list of monomials.
      Applied to a monomial, prod_list returns the list of the constituent
      base values. But both functions can be applied to any expression. *)
   val  sum_list: expr_t -> (expr_t list)
   val prod_list: expr_t -> (expr_t list)


   (* some functions for constructing modified expressions *)

   (* (fold sum_f prod_f leaf_f e) folds the expression by proceeding
      bottom-up, applying
      sum_f  to the fold result of the constituents of sums;
      prod_f to the fold result of the constituents of products;
      neg_f to the fold result of e in an expression -e; and
      leaf_f to leaves.

      For example, (apply_to_leaves f e) below can be implemented as

      (fold (fun x -> mk_sum x) (fun x -> mk_prod x)
            (fun x -> mk_neg x) (fun x -> (f x)) e)
   *)
   val fold: ('b list -> 'b) -> ('b list -> 'b) -> ('b -> 'b) ->
             (leaf_t -> 'b) -> expr_t -> 'b


   (* (apply_to_leaves f e)  applies function f to each base value leaf of
      expression e, i.e., replaces the base value v by expression (f v) *)
   val apply_to_leaves: (leaf_t -> expr_t) -> expr_t -> expr_t

   (* returns the list of leaves of an expression in top-down left to right
      traversal order. *)
   val leaves: expr_t -> (leaf_t list)

   (* (substitute f e1 e2 e3) replaces each occurrence of e1 in e3 by e2. *)
   val substitute: expr_t -> (* replace_this *)
                   expr_t -> (* by_that *)
                   expr_t -> (* in_expr *)
                   expr_t    (* returns expr with substitutions applied *)

   (* make a set of substitutions given by a list of
     (replace_this by_that) pairs. The order in which the replacements are
     made is arbitrary, so you must not have dependent chain of replacements
     such as in (substitute_many [(a,b), (b,c)] e); you must not assume that
     this will replace a by c in e. There should not be any overlap between
     the domain and the image of the mapping specified by l.
   *)
   val substitute_many: ((expr_t * expr_t) list) -> expr_t -> expr_t

   (* (extract sum_combinator_f prod_combinator_f neg_f leaf_f expr);

      folds an expression into a pair of values, where the first is

      (fold sum_combinator_f prod_combinator_f neg_f
            (fun lf -> let (x, y) = leaf_f lf in x) expr)

      and the second is

      (apply_to_leaves (fun lf -> let (x, y) = leaf_f lf in y) expr)
   *)
   val extract: ('a list -> 'a) -> ('a list -> 'a) -> ('a -> 'a) ->
                (leaf_t -> ('a * expr_t)) -> expr_t -> ('a * expr_t)

   (* (delta f e) returns an expression such that

      mk_sum [e; (delta f e)]

      is equivalent to, but simpler than,

      (apply_to_leaves (fun x -> mk_sum [(mk_val x); f x]) e)

      by exploiting linearity and something related to
      the product rule of differentiation in calculus.

      That is, if (f x) expresses change to a leaf base value x of the
      expression e, then (delta f e) expresses the overall change to e.
   *)
   val delta: (leaf_t -> expr_t) -> expr_t -> expr_t

   (* a polynomial is a sum of monomials.
      A monomial is a (possibly negated) product of base values.
      turns an arbitrary expression into a polynomial represents as a list
      of monomials represented as mono_t values.
   *)
   val polynomial: expr_t -> (mono_t list)
   (* val polynomial: expr_t -> expr_t *)

   (* turns a monomial into a product expression *)
   val monomial_to_expr: mono_t -> expr_t

   (* turns the input expression into a sum of products. *)
   val polynomial_expr:  expr_t -> expr_t

   (* casts an expression to a monomial. If that is not possible
      (because of the presence of sums or zeros, an exception is thrown. *)
   val cast_to_monomial: expr_t -> (leaf_t list)
   exception CannotCastToMonomialException of expr_t

   (* simplifies expressions by unnesting sums of sums and products
      of products, and simplifies using ones and zeros.
      The only real difference to the function polynomial is that
      products of sums are not turned into sums of products using
      distributivity. Thus, while polynomial may create exponential-factor
      blow-up in the worst case, simplify is always polynomial-time.
   *)
   val simplify: expr_t -> expr_t
   
   (* cmp_exprs cmp_leaf expr_a expr_b accum -> accum
      
      Helper function for comparing expressions.  
      
      Performs a DFS in parallel over two expressions.  If any differences are
      encountered between the two expressions, cmp_exprs will immediately return
      None.  cmp_leaf will be invoked to determine whether two leaves are 
      equivalent.  
      
      A positive result (Some(x)) is guaranteed to be an equivalent expr, while
      a negative result (None) only indicates that we were not able to establish
      equivalence.  Among other things, form normalization, double-negation,
      and Product/Sum commutability are not handled properly (yet).
   *)
   val cmp_exprs: (leaf_t -> leaf_t -> 'a -> 'a option) ->
                  expr_t ->  expr_t -> 'a -> 'a option
end




(* For using Ring, there should be no need to read on below.
   The following code implements a ring with some standard operations
   on expressions; there is nothing specific to DBToaster in here.


   Representation invariant:
   * If the value of an expression is zero, it is syntactically represented
   as zero. (We automatically rewrite 0*x=x*0 to 0 and 0+x=x+0 to x.)

   We also always represent 1*x=x*1 as x.

   But we do not internally represent expressions as polynomials, because
   this transformation may produce exponential blow-up. So the function
   for conversion to a polynomial is not a dummy.
*)




module Make = functor (T : Base) ->
struct
   type leaf_t = T.t

   type expr_t = Val of leaf_t
               | Sum  of expr_t list
               | Prod of expr_t list
               | Neg  of expr_t

   type mono_t = int * (leaf_t list)

   let zero = Val(T.zero)  (* Sum [] *)
   let one  = Val(T.one)   (* Prod [] *)

   let  sum_list e = match e with  Sum(l) -> l | _ -> [e]
   let prod_list e = match e with Prod(l) -> l | _ -> [e]

   let mk_val a = Val(a)

   (* any construction of complex expressions is done with mk_sum and mk_prod,
      which enforce the representation invariant.
   *)
   let mk_sum  l =
      let l2 = (List.filter (fun x -> x <> zero) l) in
      if(l2 = []) then zero
      else if (List.tl l2) = [] then (List.hd l2)
      else Sum(List.flatten (List.map sum_list l2))

   let mk_prod l =
      let zeroes = (List.filter (fun x -> x = zero) l) in
      if (zeroes <> []) then zero
      else
         let l2 = (List.filter (fun x -> x <> one) l) in
         if (l2 = []) then one
         else if ((List.tl l2) = []) then List.hd l2
         else Prod(List.flatten (List.map prod_list l2))

   let mk_neg e = match e with Neg(e1) -> e1 | _ -> Neg(e)

   exception NotAValException
   let get_val e =
      match e with
         Val(x) -> x
       | _ -> raise NotAValException

   let rec fold ( sum_f: 'b list -> 'b)
                (prod_f: 'b list -> 'b)
                ( neg_f: 'b -> 'b)
                (leaf_f: leaf_t -> 'b)
                (e: expr_t) =
      match e with
         Sum(l)  ->  sum_f(List.map (fold sum_f prod_f neg_f leaf_f) l)
       | Prod(l) -> prod_f(List.map (fold sum_f prod_f neg_f leaf_f) l)
       | Neg(x)  -> neg_f(           fold sum_f prod_f neg_f leaf_f x)
       | Val(x)  -> leaf_f x

   let rec apply_to_leaves (f: leaf_t -> expr_t) (e: expr_t) =
      fold (fun x -> mk_sum x) (fun x -> mk_prod x) (fun x -> mk_neg x)
           (fun x -> (f x)) e

   let leaves (e: expr_t): (leaf_t list) =
      fold List.flatten List.flatten (fun x -> x) (fun x -> [x]) e

   let rec substitute replace_this by_that in_expr =
      match in_expr with
         x when (x = replace_this) -> by_that
       | Sum(l)  -> mk_sum (List.map (substitute replace_this by_that) l)
       | Prod(l) -> mk_prod(List.map (substitute replace_this by_that) l)
       | Neg(e)  -> mk_neg(substitute replace_this by_that e)
       | Val(x)  -> Val(x)

   let substitute_many l in_expr =
       List.fold_right (fun (x,y) -> (substitute x y)) l in_expr

   let extract (sum_combinator:  'a list -> 'a)
               (prod_combinator: 'a list -> 'a)
               (neg_f: 'a -> 'a)
               (leaf_f: leaf_t -> ('a * expr_t))
               (expr: expr_t): ('a * expr_t) =
      let f comb_f1 comb_f2 l =
         let (a, b) = List.split l in
         ((comb_f1 a), (comb_f2 b))
      in
      fold (f sum_combinator mk_sum) (f prod_combinator mk_prod)
           (fun ((x:'a),(y:expr_t)) -> ((neg_f x), (mk_neg y)))
           leaf_f expr

   let rec delta (lf_delta: leaf_t -> expr_t) (e: expr_t) =
      match e with
         Sum(l)     -> mk_sum(List.map (fun x -> delta lf_delta x) l)
       | Prod([])   -> zero
       | Prod(x::l) ->
         mk_sum([
            mk_prod((delta lf_delta x)::l);
            mk_prod([mk_sum[x; (delta lf_delta x)];
                     (delta lf_delta (mk_prod(l)))])
            (* this nesting makes sense because it renders the delta
               computation cheaper: delta for l is only computed once here;
               we can still distribute later if we need it. *)
         ])
       | Neg(x) -> Neg(delta lf_delta x)
       | Val(x) -> lf_delta x

   let rec polynomial (e: expr_t): mono_t list =
      match e with
         Val(x)  -> [(1,[x])]
       | Neg(x)  -> let l = (polynomial x) in
                    List.map (fun (c, v) -> (-c, v)) l
       | Sum(l)  -> List.flatten (List.map polynomial l)
       | Prod(l) -> let mono_prod ml =
                       let (a,b) = List.split ml in
                       let lmult l = List.fold_left (fun x y -> x*y) 1 l in
                       (lmult a, List.flatten b) in
                    (List.map mono_prod (Util.ListAsSet.distribute
                      (List.map polynomial l)))

   let monomial_to_expr ((m,l):mono_t) : expr_t =
      let list_to_prod l = mk_prod (List.map mk_val l)
      in
      if m = 1 then (list_to_prod l)
      else if m = -1 then mk_neg (list_to_prod l)
      else failwith
           "Ring.monomial_to_expr: general multiplicities not implemented"

   let polynomial_expr (e: expr_t): expr_t =
      mk_sum (List.map monomial_to_expr (polynomial e))

   exception CannotCastToMonomialException of expr_t

   let cast_to_monomial (e: expr_t): (leaf_t list) =
      let ms = polynomial e in
      match ms with
         ( 1, m)::[] -> m
       | (-1, m)::[] -> failwith "Ring.cast_to_monomial TODO"
       | _ -> raise (CannotCastToMonomialException e)

   let simplify (e: expr_t) =
      apply_to_leaves (fun x -> mk_val x) e
    
   let rec cmp_exprs (leaf_f: leaf_t -> leaf_t -> 'a -> 'a option)
                     (a: expr_t) (b: expr_t) 
                     (accum: 'a): 'a option =
      let do_recur (ae:expr_t list) (be:expr_t list) (accum:'a): 'a option = 
        if List.length ae <> List.length be then None
        else List.fold_right2 (fun curr_a curr_b curr_accum_opt ->
          match curr_accum_opt with 
            | None -> None
            | Some(curr_accum) -> 
                (cmp_exprs leaf_f curr_a curr_b curr_accum)
        ) ae be (Some(accum))
      in
      match (a,b) with
        (Val  xa, Val  xb) -> leaf_f xa xb accum
      | (Neg  ae, Neg  be) -> cmp_exprs leaf_f ae be accum
      | (Sum  ae, Sum  be) -> do_recur ae be accum
      | (Prod ae, Prod be) -> do_recur ae be accum
      | _ -> None
   
end



