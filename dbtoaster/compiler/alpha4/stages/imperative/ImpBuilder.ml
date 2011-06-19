open M3
open K3.SR

module AnnotatedK3 =
struct
  open Imperative
  module K = K3.SR
  module T = K3Typechecker
  type op_t = Add | Mult | Eq | Neq | Lt | Leq | If0

  type arg_t = K.arg_t
  type expr_t = K.expr_t

  type ir_tag_t = Decorated of node_tag_t | Undecorated of expr_t
  and node_tag_t =
    (* No consts or vars, since these are always undecorated leaves *)
   | Op of op_t
   | Tuple
   | Projection of int list
   | Singleton
   | Combine
   | Lambda of arg_t
   | AssocLambda of arg_t * arg_t 
   | Apply

   | Block  
   | Iterate
   | IfThenElse

   | Map
   | Aggregate
   | GroupByAggregate
   | Flatten

   | Member
   | Lookup
   | Slice  of int list

   | PCUpdate
   | PCValueUpdate 
 

  type 'a ir_t =
      Leaf of 'a * ir_tag_t
    | Node of 'a * ir_tag_t * 'a ir_t list

  type 'a linear_code_t = ('a * (ir_tag_t * ('a list))) list

  (* Helpers *)
  let sym_counter = ref 0
  let gensym () = incr sym_counter; "__v"^(string_of_int (!sym_counter))
  let tag_of_ir ir = match ir with | Leaf(_,t) -> t | Node (_,t,_) -> t 
  let meta_of_ir ir = match ir with | Leaf(m,_) -> m | Node (m,_,_) -> m
end

module Common =
struct
  open Imperative
  open AnnotatedK3

  type 'ext_type decl_t = id_t * 'ext_type type_t
  type 'ext_type imp_metadata = TypedSym of 'ext_type decl_t

  (* Metadata helpers *)
  let mk_meta sym ty = TypedSym (sym, ty)
  let sym_of_meta meta = match meta with | TypedSym s -> fst s
  let type_of_meta meta = match meta with | TypedSym (_,t) -> t 

  let k3_var_of_meta meta =
    K.Var(sym_of_meta meta, host_type (type_of_meta meta))

  let push_meta meta cmeta = match meta, cmeta with
    | TypedSym (s,_), TypedSym (_,t) -> TypedSym(s,t)

  let decl_of_meta force meta =
    Some(force, sym_of_meta meta, type_of_meta meta)

  let meta_of_arg arg meta =
    begin match arg with
    | AVar(arg_sym, ty) ->
        (mk_meta arg_sym (Host ty)), [], Some(true, arg_sym, (Host ty))
    | _ -> meta, [arg], (decl_of_meta true meta)
    end

  (* assumes meta has the same type as arg2, as in aggregation *)    
  let meta_of_assoc_arg arg1 arg2 meta =
    begin match arg2 with
    | AVar(arg2_sym, ty) ->
        let m = mk_meta arg2_sym (Host ty)
        in [m; m], [arg1], [decl_of_meta true m; decl_of_meta true m]
    | _ ->
        let d = decl_of_meta true meta
        in [meta; meta], [arg1; arg2], [d; d]
    end


  (* IR construction helpers *)
  (* returns:
   * flat list of triples for undecorated nodes
   * flat list of exprs for all nodes
   * flat list of children from all nodes *) 
  let undecorated_of_list cl =
    (* ull = list of sym, expr, children triples for undecorated nodes
     * ecl = list of expr, children pairs for all nodes *)
    let ull, ecl = List.split (List.map
      (function Leaf(meta, Undecorated(f)) -> [meta, f, []], [f, []]
       | Leaf(meta, Decorated _) -> [], [k3_var_of_meta meta, []] 
       | Node(meta, Undecorated(f), cir) -> [meta, f, cir], [f, cir]
       | Node(meta, Decorated _, cir) as n -> [], [k3_var_of_meta meta, [n]]) cl)
    in
    let el, cll = List.split (List.flatten ecl) in
    List.flatten ull, el, List.flatten cll 

  let k3op_of_op_t op l r = match op with
    | Add  -> K.Add(l,r)
    | Mult -> K.Mult(l,r)
    | Eq   -> K.Eq(l,r)
    | Neq  -> K.Neq(l,r)
    | Lt   -> K.Lt(l,r)
    | Leq  -> K.Leq(l,r)
    | If0  -> K.IfThenElse0(l,r)

  let slice_of_map mapc keyse indices =
    begin match mapc with
    | Leaf(_, Undecorated(mape)) ->
      let schema = match mape with
        | K.InPC(_, ins, _) -> ins
        | K.OutPC(_, outs, _) -> outs
        | K.PC(_, _, outs, _) -> outs
        | K.Lookup(K.PC(_, _, outs, _), _) -> outs
        | _ -> failwith "invalid map for slicing"
      in
      let fields = List.combine
        (List.map (fun i -> fst (List.nth schema i)) indices) keyse
      in K.Slice(mape, schema, fields)
    | _ -> failwith "invalid map code"
    end

  let build_code irl undec_f dec_f =
    let ul, el, cl = undecorated_of_list irl in
    if (List.length ul) <> (List.length irl) then dec_f el cl
    else
      let x,y = List.split (List.map (fun (x,y,z) -> (x,y),z) ul)
      in undec_f x (List.flatten y)

  let tag_of_undecorated metadata e cir = match cir with
    | [] -> Leaf(metadata, Undecorated(e))
    | _ -> Node(metadata, Undecorated(e), cir)

  (* IR constructors *)
  let undecorated_ir metadata e = Leaf(metadata, Undecorated(e))

  let tuple_ir metadata sub_ir =
    build_code sub_ir
      (fun fieldse cir ->
        let e = K3.SR.Tuple(List.map snd fieldse)
        in tag_of_undecorated metadata e cir)
      (fun ce cir ->
        let e = K3.SR.Tuple(ce)
        in Node(metadata, Undecorated(e), cir))

  let project_ir metadata projections sub_ir =
    build_code sub_ir
      (fun tu cir -> match tu with
        | [sym, te] ->
          let e = K3.SR.Project(te, projections)
          in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid tuple expression")
      (fun ce cir ->
        let e = K3.SR.Project(List.hd ce, projections)
        in Node(metadata, Undecorated(e), cir))

  let singleton_ir metadata sub_ir =
    build_code sub_ir
      (fun eu cir -> match eu with
        | [sym, elem] ->
          let e = K3.SR.Singleton(elem)
          in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid singleton element expression")
      (fun ce cir -> 
        let e = K3.SR.Singleton(List.hd ce)
        in Node(metadata, Undecorated(e), cir))
        
  let combine_ir metadata sub_ir =
    build_code sub_ir
      (fun lru cir -> match lru with
        | [(sym1, le); (_, re)] ->
          let e = K3.SR.Combine(le,re) in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid combine expressions")
      (fun ce cir -> match ce with
        | [le; re] ->
          let e = K3.SR.Combine(le,re)
          in Node(metadata, Undecorated(e), cir)
        | _ -> failwith "invalid combine expressions")

  let op_ir metadata o sub_ir =
    build_code sub_ir
      (fun lru cir -> match lru with
        | [(sym1, le); (_, re)] ->
          let e = k3op_of_op_t o le re in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid binop expressions")
      (fun ce cir -> match ce with
        | [le; re] ->
          let e = k3op_of_op_t o le re
          in Node(metadata, Undecorated(e), cir)
        | _ -> failwith "invalid binop expressions")

  let ifthenelse_ir metadata sub_ir =
    Node(metadata, Decorated(IfThenElse), sub_ir)
  
  let block_ir metadata sub_ir =
    build_code sub_ir
      (fun ucl cir ->
        let e = K3.SR.Block (List.map snd ucl)
        in tag_of_undecorated metadata e cir)
      (fun _ _ -> Node(metadata, Decorated(Block), sub_ir))
  
  let iterate_ir metadata sub_ir =
    build_code sub_ir
      (fun fcu cir -> match fcu with
        | [(sym, fe); (_, ce)] ->
          let e = K3.SR.Iterate(fe, ce) in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid iterate expressions")
      (fun _ _ -> Node(metadata, Decorated(Iterate), sub_ir))

  let lambda_ir metadata arg sub_ir =
    build_code sub_ir
      (fun bu cir -> match bu with
        | [(sym, be)] ->
          let e = K3.SR.Lambda(arg, be) in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid lambda body")
      (fun _ _ -> Node(metadata, Decorated(Lambda(arg)), sub_ir))

  let assoc_lambda_ir metadata arg1 arg2 sub_ir =
    build_code sub_ir
      (fun bu cir -> match bu with
        | [(sym, be)] ->
          let e = K3.SR.AssocLambda(arg1, arg2, be)
          in tag_of_undecorated metadata e cir
       | _ -> failwith "invalid assoc lambda body")
      (fun _ _ -> Node(metadata, Decorated(AssocLambda(arg1, arg2)), sub_ir))

  let apply_ir metadata sub_ir = Node(metadata, Decorated(Apply), sub_ir)

  let map_ir metadata sub_ir = Node(metadata, Decorated(Map), sub_ir)

  let aggregate_ir metadata sub_ir =
    Node(metadata, Decorated(Aggregate), sub_ir)

  let gb_aggregate_ir metadata sub_ir =
    Node(metadata, Decorated(GroupByAggregate), sub_ir)

  let flatten_ir metadata sub_ir =
    Node(metadata, Decorated(Flatten), sub_ir)

  let member_ir metadata sub_ir =
    build_code sub_ir
      (fun mku cir -> match mku with
        | mape::keyse ->
          let e = K3.SR.Member(snd mape, List.map snd keyse)
          in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid member expressions")
      (fun _ _ -> Node(metadata, Decorated(Member), sub_ir))
    
  let lookup_ir metadata sub_ir = 
    build_code sub_ir
      (fun mku cir -> match mku with
        | mape::keyse ->
          let e = K3.SR.Lookup(snd mape, List.map snd keyse)
          in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid lookup expressions")
      (fun _ _ -> Node(metadata, Decorated(Lookup), sub_ir))

  let slice_ir metadata indices sub_ir =
    build_code sub_ir
      (fun mku cir -> match mku with
        | mape::keyse ->
          let e = slice_of_map (List.hd sub_ir) (List.map snd keyse) indices
          in tag_of_undecorated metadata e cir
        | _ -> failwith "invalid slice expressions")
      (fun _ _ -> Node(metadata, Decorated(Slice(indices)), sub_ir))

  let update_ir metadata m_e m_ty sub_ir =
    let r id = Node(metadata, Decorated(PCUpdate), sub_ir) in
    begin match m_e with
    | SingletonPC _ -> failwith "invalid bulk update of value"
    | OutPC(id,_,_)  | InPC(id,_,_)  | PC(id,_,_,_) -> r id
    | _ -> failwith "invalid map to bulk update"
    end

  let update_value_ir metadata m_e m_ty sub_ir =
    let r id = Node(metadata, Decorated(PCValueUpdate), sub_ir) in
    begin match m_e with
    | SingletonPC (id,_) | OutPC(id,_,_)  | InPC(id,_,_)  | PC(id,_,_,_) -> r id
    | _ -> failwith "invalid map value to update"
    end

end



module DirectIRBuilder =
struct
  open Common
  open Imperative
  open AnnotatedK3

  let ir_of_expr e : ('exp_type imp_metadata) ir_t =
    let dummy_init =
      Leaf(mk_meta "" (Host TInt), Undecorated(K.Const(CFloat(0.0)))) in
    let fold_f _ parts e =
      let metadata = mk_meta (gensym()) (Host (T.typecheck_expr e)) in
      let fst () = List.hd parts in
      let snd () = List.nth parts 1 in
      let thd () = List.nth parts 2 in
      let fth () = List.nth parts 3 in
      let sfst () = List.hd (fst()) in
      let ssnd () = List.hd (snd()) in
      let sthd () = List.hd (thd()) in
      let sfth () = List.hd (fth()) in
      match e with
      | K.Const _  | K.Var _ -> undecorated_ir metadata e

      | K.Tuple _   -> tuple_ir metadata (List.flatten parts)
      | K.Project (_, p) -> project_ir metadata p [sfst()]
            
      | K.Singleton _ -> singleton_ir metadata [sfst()]
      | K.Combine _   -> combine_ir metadata [sfst();ssnd()]
      | K.Add _       -> op_ir metadata Add [sfst(); ssnd()]
      | K.Mult _      -> op_ir metadata Mult [sfst(); ssnd()]
      | K.Eq _        -> op_ir metadata Eq [sfst(); ssnd()]
      | K.Neq _       -> op_ir metadata Neq [sfst(); ssnd()]
      | K.Lt _        -> op_ir metadata Lt [sfst(); ssnd()]
      | K.Leq _       -> op_ir metadata Leq [sfst(); ssnd()]
      | K.IfThenElse0 _ -> op_ir metadata If0 [sfst(); ssnd()]

      | K.Block l      -> block_ir metadata (fst())

      | K.Iterate _    -> iterate_ir metadata [sfst(); ssnd()]
      | K.IfThenElse _ -> ifthenelse_ir metadata [sfst(); ssnd(); sthd()]

      | K.Lambda (arg,_) -> lambda_ir metadata arg [sfst()]
      | K.AssocLambda (arg1,arg2,_) -> assoc_lambda_ir metadata arg1 arg2 [sfst()]

      | K.Apply _  -> apply_ir metadata [sfst();ssnd()]
      | K.Map _ -> map_ir metadata [sfst();ssnd()]

      | K.Aggregate _ -> aggregate_ir metadata [sfst(); ssnd(); sthd()]

      | K.GroupByAggregate _ ->
        gb_aggregate_ir metadata [sfst();ssnd();sthd();sfth()] 
      
      | K.Flatten _ -> flatten_ir metadata [sfst()]

      | K.Member _ -> member_ir metadata ([sfst()]@snd())  
      | K.Lookup _ -> lookup_ir metadata ([sfst()]@snd())
      | K.Slice (_,sch,idk_l)      ->
        let index l e =
          let (pos,found) = List.fold_left (fun (c,f) x ->
            if f then (c,f) else if x = e then (c,true) else (c+1,false))
            (0, false) l
          in if not(found) then raise Not_found else pos
        in
        let v_l, _ = List.split idk_l in
        let idx_l = List.map (index (List.map (fun (x,y) -> x) sch)) v_l
        in slice_ir metadata idx_l ([sfst()]@snd())

      | K.SingletonPC _ | K.OutPC _ | K.InPC _ | K.PC _ -> undecorated_ir metadata e

      | K.PCUpdate (m_e,_,_) -> 
        update_ir metadata m_e (T.typecheck_expr m_e) ([sfst()]@snd()@[sthd()])

      | K.PCValueUpdate (m_e,_,_,_) -> 
        update_value_ir metadata
          m_e (T.typecheck_expr m_e) ([sfst()]@snd()@thd()@[sfth()])

    in K.fold_expr fold_f (fun x _ -> x) None dummy_init e
end


module Imp =
struct
  open AnnotatedK3
  open Imperative
  open Common
  module AK = AnnotatedK3
  module K = K3.SR
  module KT = K3Typechecker

  (* Helpers *)

  let arg_of_lambda leaf_tag = match leaf_tag with
    | Decorated(Lambda(x)) -> x
    | Undecorated(K.Lambda(x,_)) -> x
    | _ -> failwith "invalid lambda"

  let arg_of_assoc_lambda leaf_tag = match leaf_tag with
    | Decorated(AssocLambda(x,y)) -> (x,y)
    | Undecorated(K.AssocLambda(x,y,_)) -> (x,y)
    | _ -> failwith "invalid assoc lambda"

  let bind_arg arg expr =
    match arg with
    | AVar(id,ty) -> [Decl(None, (id, (Host ty)), Some(expr))]
    | ATuple(id_ty_l) ->
      begin match expr with
      | Tuple(_, e_l) ->
        List.map2 (fun (id,ty) e ->
          Decl(None, (id, (Host ty)), Some(e))) id_ty_l e_l
    
      | Var(tty, tvar) ->
        snd (List.fold_left (fun (i,acc) (id,ty) ->
            let t_access = Fn(None, TupleElement(i), [Var(tty, tvar)]) in
            (i+1, acc@[Decl(None, (id, (Host ty)), Some(t_access))]))
          (0,[]) id_ty_l) 
    
      | _ -> failwith "invalid tuple apply" 
      end

  let linearize_ir c =
    let get_meta = function Leaf(meta,_) -> meta | Node(meta,_,_) -> meta in
    let rec aux acc c = match c with
      | Leaf(meta, l) -> [meta, (l,[])]@acc
      | Node(meta, tag, children) ->
        (List.fold_left aux acc children)@
        [meta, (tag, List.map get_meta children)] 
    in aux [] c

  let imp_of_ir (map_typing_f : K3.SR.expr_t -> 'ext_type type_t)
                 ir : ('a option, 'ext_type, 'ext_fn) imp_t list =
    let flat_ir = linearize_ir ir in
    let gc_op op = match op with
      | AK.Add -> Add | AK.Mult -> Mult | AK.Eq -> Eq | AK.Neq -> Neq
      | AK.Lt -> Lt | AK.Leq -> Leq | AK.If0 -> If0
    in
    let rec gc_binop meta op l r = BinOp(meta, op, gc_expr l, gc_expr r)
    and gc_expr e : ('a option, 'ext_type, 'ext_fn) expr_t =
      let meta = (*Host(KT.typecheck_expr e)*) None in
      match e with
      | K.Const c          -> Const (meta, c)
      | K.Var (v,t)        -> Var (meta,(v,Host t))
      | K.Tuple fields     -> Tuple(meta, List.map gc_expr fields)
      | K.Add(l,r)         -> gc_binop meta Add  l r
      | K.Mult(l,r)        -> gc_binop meta Mult l r
      | K.Eq(l,r)          -> gc_binop meta Eq   l r
      | K.Neq(l,r)         -> gc_binop meta Neq  l r
      | K.Lt(l,r)          -> gc_binop meta Lt   l r
      | K.Leq(l,r)         -> gc_binop meta Leq  l r
      | K.IfThenElse0(l,r) -> gc_binop meta If0  l r
      | K.Project(e,idx)   -> Fn (meta, Projection(idx), [gc_expr e])
      | K.Singleton(e)     -> Fn (meta, Singleton, [gc_expr e])
      | K.Combine(l,r)     -> Fn (meta, Combine, List.map gc_expr [l;r])
      
      | K.Member(m,k)      -> Fn (meta, Member, List.map gc_expr (m::k))
      | K.Lookup(m,k)      -> Fn (meta, Lookup, List.map gc_expr (m::k))
      | K.Slice(m,sch,fe)  ->
         let pos l e =
            let idx = ref (-1) in
            let rec aux l = match l with
              |  [] -> -1
              | h::t ->
                incr idx;
                if h = e then raise Not_found else aux t
            in try aux l with Not_found -> !idx
         in
         let idx = List.map (pos (List.map fst sch)) (List.map fst fe)
         in Fn (meta, Slice(idx), List.map gc_expr (m::(List.map snd fe)))

      | K.SingletonPC(id,_) 
      | K.OutPC(id,_,_) | K3.SR.InPC(id,_,_) | K3.SR.PC(id,_,_,_) ->
        Var(meta, (id, map_typing_f e))

      (* Lambdas assume caller has performed arg binding *)
      | K.Lambda(arg, body) -> gc_expr body
      | K.AssocLambda(arg1, arg2, body) -> gc_expr body

      | _ -> failwith ("invalid imperative expression: "^(K.string_of_expr e))
    in

    (* Code generation for tagged nodes *)
    let rec gc_tag meta t cmeta =
      (* Helpers *)

      let cmetai i = List.nth cmeta i in
      let ciri i = List.assoc (cmetai i) flat_ir in
      let ctag i = fst (ciri i) in
      
      (* Symbol pushdown/reuse semantics *)
      (* possible_decl : force * id * type option
       * -- possible_decl should be None if the symbol should not be defined
       *    locally (i.e. any pushdowns should not be defined)
       * -- force indicates whether to force declaration of the symbol, given
       *    that the tag cg will bind to the symbol
       *)  
      let child_meta, args_to_bind, possible_decls =
        let last = (List.length cmeta) - 1 in
        let pushi i = push_meta meta (cmetai i) in
        let decl_f = decl_of_meta in 
        let arg_f = meta_of_arg in
        let assoc_arg_f = meta_of_assoc_arg in
        match t with
        
        (* Lambdas push down their symbol to the function body *)
        | Lambda _ | AssocLambda _ -> [pushi 0], [], [None]
        
        (* Apply always pushes down the return symbol to the function, and
         * in the case of single args, push down the arg symbol *)
        (* TODO: multi-arg pushdown/binding *)
        | Apply ->
          let arg = arg_of_lambda (ctag 0) in
          let arg_meta, rem_bindings, arg_decl = arg_f arg (cmetai 1)
          in [pushi 0; arg_meta], rem_bindings, [None; arg_decl]
        
        (* Blocks push down the symbol to the last element *)    
        | AK.Block ->
          let r = (List.rev (List.tl (List.rev cmeta)))@[pushi last]
          in r, [], List.map (fun x -> None) r
        
        (* Conditionals push down the symbol to both branches *)
        | AK.IfThenElse ->
          [cmetai 0; pushi 1; pushi 2], [], [decl_f false (cmetai 0); None; None]

        (* Iterate needs a child symbol, but this should not be used since
         * the return type is unit. Maps yield the new collection as the symbol
         * thus do not pass it on to any children. *)
        | Iterate | Map ->
            cmeta, [arg_of_lambda (ctag 0)], [None; decl_f false (cmetai 1)]

        | Aggregate ->
            let arg1, arg2 = arg_of_assoc_lambda (ctag 0) in
            let coll_meta = cmetai 2 in
            let assoc_arg_meta, rem_bindings, arg_decls =
                assoc_arg_f arg1 arg2 (cmetai 1)
            in (assoc_arg_meta@[coll_meta]), rem_bindings,
                 (arg_decls@[decl_f false coll_meta])

        (*
         * -- 4 syms: agg fn return, init return, gb return, collection return
         * -- Node sym should not be passed down, it is a new map. Map should
         *    be assigned to after agg body runs.
         * -- collection sym is unchanged
         * -- group-by arg can be made element, group-by sym is used to bind
         *    agg fn state arg via map member/lookup
         * -- init val sym is used to bind agg fn state arg on first run
         * -- agg fn elem arg must be bound to element, could be avoided if
         *    gb arg is same as agg fn elem arg
         * -- agg fn state arg must be bound to map lookup/init val sym. if
         *    state is a single var, we can push to init code
         * -- summary:
         *   ++ push single gb arg to elem (not here, in cg body)
         *   ++ avoid binding agg fn elem arg if same as gb arg (in body)
         *   ++ push single agg fn state var to init return sym (and map lookup
         *      sym in cg body), otherwise use new sym. skip binding if pushed.
         *) 
        | GroupByAggregate ->
            let arg1, arg2 = arg_of_assoc_lambda (ctag 0) in
            let arg3 = arg_of_lambda (ctag 2) in
            let arg2_binding, init_meta = match arg2 with
              | AVar(id,ty) -> [], mk_meta id (Host ty)
              | _ -> let m = cmetai 1 in [arg2], m 
            in
            let x = mk_meta (sym_of_meta (cmetai 0)) (type_of_meta init_meta) in
            let y =
              let gb_t = match type_of_meta (cmetai 2) with
                | Host(K.Fn(_,rt)) -> Host rt
                | Host(K.TInt) -> Host K.TInt (* let this through for untyped compilation *)
                | _ -> failwith "invalid group by function type"
              in mk_meta (sym_of_meta (cmetai 2)) gb_t
            in
            let z = cmetai 3 in
            let dx, dy, dz = decl_f false x, decl_f true y, decl_f false z in  
              ([x; init_meta; y; z],
                ([arg1]@arg2_binding@[arg3]), [dx; decl_f true init_meta; dy; dz])
  
        | _ -> cmeta, [], List.map (fun m -> decl_f false m) cmeta
      in

      (* Recursive call to generate child imperative or expression code *)
      let cuie = List.map2 (fun cmeta meta_to_use ->
        let (ctag, ccm) = List.assoc cmeta flat_ir in
        gc_meta (meta_to_use, (ctag, ccm))) cmeta child_meta
      in

      let unique l = List.fold_left
        (fun acc e -> if List.mem e acc then acc else acc@[e]) [] l
      in
      let child_decls = unique (List.flatten (List.map2
        (fun (used,i,e) decl_opt ->
          match i,e, decl_opt with
          | Some _, None, Some(force,id,ty) ->
            if force || used then [Decl(None, (id,ty), None)] else []
          | None, Some _, Some(true, id,ty) -> [Decl(None, (id,ty), None)]
          | _,_,_ -> []) cuie possible_decls))
      in
    
      let cie = List.map (fun (_,x,y) -> x,y) cuie in

      (* Imp construction helpers *) 
      let imp_of_list l =
        if List.length l = 1 then List.hd l else Block(None, l) in
      let unwrap x = match x with Some(y) -> y | _ -> failwith "invalid value" in
      let list_i l = function 0 -> List.hd l | i -> List.nth l i in

      let match_ie_pair ie error_str f_i f_e = match ie with
        | Some(i), None -> f_i i
        | None, Some(e) -> f_e e
        | _,_ -> failwith error_str
      in
      
      let cimps, cexprs = List.split cie in
      let cvals = List.map2 (fun meta iep ->
        match_ie_pair iep "invalid child value"
          (fun i -> Var (None, (sym_of_meta meta, type_of_meta meta)))
          (fun e -> e))
          child_meta cie
      in
      
      let cimpo, cexpro = list_i cimps, list_i cexprs in
      let cdecli i =
        let m = list_i child_meta i in
        Var (None, (sym_of_meta m, type_of_meta m)) in
      let cexpri = list_i cvals in
      let cused i = let (x,_,_) = list_i cuie i in x in

      let match_ie idx = match_ie_pair (cimpo idx, cexpro idx) in
      let assign_if_expr idx error_str = match_ie idx error_str
        (fun i -> i)
        (fun e -> [Expr(None, BinOp(None, Assign, cdecli idx, e))])
      in

      let meta_sym, meta_ty = sym_of_meta meta, type_of_meta meta in

      let expr =
        match t with
        | AK.Op(op)    -> Some(BinOp(None, gc_op op, cexpri 0, cexpri 1))

        | AK.Tuple           -> Some(Tuple(None, cvals))
        | AK.Projection(idx) -> Some(Fn(None, Projection(idx), [cexpri 0]))

        | AK.Singleton  -> Some(Fn(None, Singleton, [cexpri 0]))
        | AK.Combine    -> Some(Fn(None, Combine, [cexpri 0; cexpri 1]))     
        | AK.Member     -> Some(Fn(None, Member, cvals))
        | AK.Lookup     -> Some(Fn(None, Lookup, cvals))
        | AK.Slice(idx) -> Some(Fn(None, Slice(idx), cvals))
        | _ -> None
      in

      let imp, imp_meta_used = match t with 
      | Lambda _ | AssocLambda _ ->
        (* lambdas have no expression form, they must use their arg bindings
           and assign result value to their indicated symbol *)
        begin match cimpo 0, cexpro 0 with
          | Some(i), None -> Some(i), (cused 0)
          | _, _ -> failwith "invalid tagged function body"
        end

      | Apply ->
        let decls = match cimpo 1, cexpro 1 with
          | Some(i), None -> 
            if args_to_bind = [] then i
            else i@(bind_arg (List.hd args_to_bind) (cdecli 1))
          | None, Some(e) ->
            if args_to_bind = [] then
               [Expr(None, BinOp(None, Assign, cdecli 1, e))]
            else bind_arg (List.hd args_to_bind) e
          | _, _ -> failwith "invalid apply argument"
        in
        let used = match_ie 0 "invalid apply function"
          (fun _ -> cused 0) (fun _ -> true) in
        let body = assign_if_expr 0 "invalid apply function"
        in Some(decls@body), used

      | AK.Block -> 
        let rest, last =
          let x = List.rev (List.combine cimps cexprs)
          in List.rev (List.tl x), List.hd x
        in
        let imp_of_pair ieo_pair = match ieo_pair with
          | Some(i), None -> i
          | _,_ -> failwith "invalid block element"
        in
        let li, meta_used = match last with
          | Some(i), None -> i, (cused ((List.length cmeta)-1))
          | None, Some(e) ->
            [Expr(None, BinOp(None, Assign,
                                Var(None, (meta_sym, meta_ty)), e))],
            true
          | _, _ -> failwith "invalid block return"
        in Some((List.flatten (List.map imp_of_pair rest))@li), meta_used

      | AK.IfThenElse ->
        let branch i = imp_of_list
          (assign_if_expr i "invalid condition branch code") in
        let branch_used i = match_ie i "invalid condition branch"
          (fun _ -> cused i) (fun _ -> true) in
        let meta_used = branch_used 1 || branch_used 2 in
        Some(match_ie 0 "invalid condition code"
            (fun i -> i@[IfThenElse(None, cdecli 0, branch 1, branch 2)])
            (fun e -> [IfThenElse(None, e, branch 1, branch 2)])),
          meta_used

      | Iterate ->
        let arg = List.hd args_to_bind in
        let elem, elem_ty, elem_f, decls = match arg with
            | AVar(id,ty) -> id, (Host ty), true, []
            | ATuple(it_l) ->
              let t = Host(K.TTuple(List.map snd it_l)) in 
              let x = gensym() in x, t, false, bind_arg arg (Var(None,(x,t)))
        in
        let fn_body = match cimpo 0, cexpro 0 with
          | Some(i), None -> i
          | _,_ -> failwith "invalid iterate function" 
        in
        let loop_body = imp_of_list (decls@fn_body) in
          Some(match_ie 1 "invalid iterate collection"
            (fun i -> i@[For(None, ((elem, elem_ty), elem_f), cdecli 1, loop_body)])
            (fun e -> [For(None, ((elem, elem_ty), elem_f), e, loop_body)])), false

      | Map ->
        (* TODO: in-loop multi-var bindings from collections of tuples *)
        let arg = List.hd args_to_bind in
        let elem, elem_ty, elem_f, decls = match arg with
            | AVar(id,ty) -> id, Host(ty), true, []
            | ATuple(it_l) ->
              let t = Host(K.TTuple(List.map snd it_l)) in 
              let x = gensym() in x, t, false, bind_arg arg (Var (None,(x,t)))
        in
        let mk_body e = Expr(None,
          Fn(None, MapAppend, [Var (None, (meta_sym, meta_ty)); e])) in
        let fn_body = match_ie 0 "invalid map function"
          (fun i -> i@[mk_body (cdecli 0)]) (fun e -> [mk_body e])
        in
        let loop_body = imp_of_list (decls@fn_body) in
        let mk_loop e = For(None, ((elem, elem_ty), elem_f), e, loop_body) in
          Some(match_ie 1 "invalid map collection"
             (fun i -> i@[mk_loop (cdecli 1)]) (fun e -> [mk_loop e])),
          true

      | Aggregate -> 
        let elem, elem_ty, elem_f, decls = match args_to_bind with
          | [AVar(id,ty)] -> id, (Host ty), true, []
          | [ATuple(it_l) as arg1] ->
            let t = Host(K.TTuple(List.map snd it_l)) in 
            let x = gensym() in x, t, false, bind_arg arg1 (Var (None,(x,t)))
          | [AVar(id,ty); arg2] -> id, (Host ty), true, bind_arg arg2 (cdecli 1)
          | [ATuple(it_l) as arg1; arg2] ->
            let t = Host(K.TTuple(List.map snd it_l)) in
            let x = gensym() in
              x, t, false, (bind_arg arg1 (Var (None,(x,t))))@(bind_arg arg2 (cdecli 1))
          | _ -> failwith "invalid aggregate args"
        in     
        let fn_body = assign_if_expr 0 "invalid aggregate function" in
        let loop_body = imp_of_list (decls@fn_body) in
        let pre, ce =
          let init_pre = assign_if_expr 1 "invalid agg init code" in
          let collection_pre, collection_e =
            match_ie 2 "invalid agg collection"
              (fun i -> i, (cdecli 2)) (fun e -> [], e) 
           in (collection_pre@init_pre), collection_e in
        let post = [Expr(None,
          BinOp(None, Assign, Var(None,(meta_sym, meta_ty)), cdecli 0))]
        in
        Some(pre@[For(None, ((elem, elem_ty), elem_f), ce, loop_body)]@post), true
      
      | GroupByAggregate ->
        let get_elem arg = match arg with
          | AVar(id, ty) -> id, (Host ty), true, []
          | ATuple(it_l) ->
            let t = Host(K.TTuple(List.map snd it_l)) in 
            let x = gensym() in x, t, false, bind_arg arg (Var (None, (x,t)))
        in
        let eg_decls elem_arg g_arg =
          let e, e_ty, e_f, edecls = get_elem g_arg in
          let eadecls =
            if elem_arg <> g_arg then bind_arg elem_arg (Var (None, (e,e_ty))) else []
          in e, e_ty, e_f, edecls, eadecls
        in
        let (elem, elem_ty, elem_f, edecls, eadecls), sdecls =
          match args_to_bind with
          | [elem_arg; g_arg] -> (eg_decls elem_arg g_arg), []
          | [elem_arg; state_arg; g_arg] -> 
            (eg_decls elem_arg g_arg), (bind_arg state_arg (cdecli 1))
          | _ -> failwith "invalid group by aggregate arguments"
        in
        (* Invoke gb function *)
        let gb_body = edecls@(assign_if_expr 2 "invalid group by function") in
        (* Retrieve group state or initialize if needed *)
        let pre_fn_body = 
          let state_init = assign_if_expr 1 "invalid gb agg init" in
            [IfThenElse(None,
               Fn(None, Member, [Var (None, (meta_sym, meta_ty)); cdecli 2]),
               Expr(None, BinOp(None, Assign, cdecli 1,
                 Fn(None, Lookup, [Var (None, (meta_sym, meta_ty)); cdecli 2]))),
               imp_of_list (state_init))] 
        in
        (* Bind agg fn decls, invoke agg fn, and assign to result map *)
        let mk_body e = Expr(None, Fn(None,
          MapValueUpdate, [Var (None,(meta_sym, meta_ty)); cdecli 2; e])) in
        let fn_body = eadecls@sdecls@(match_ie 0 "invalid gb agg function"
          (fun i -> i@[mk_body (cdecli 0)]) (fun e -> [mk_body e]))
        in
        let loop_body = imp_of_list (gb_body@pre_fn_body@fn_body) in
        let pre, ce =
          match_ie 3 "invalid gb agg collection"
            (fun i -> i, (cdecli 3)) (fun e -> [], e) 
        in Some(pre@[For(None, ((elem, elem_ty), elem_f), ce, loop_body)]), true
      
      | Flatten -> failwith "flatten not yet supported"
        (* get all child collections *)
        (* traverse children to get all grandchild collections *)
        (* for each grandchild collection element, append into sym. *)

      | AK.PCUpdate ->
        let pre = List.map unwrap (List.filter (fun i -> i <> None) cimps) in
          Some((List.flatten pre)@
            [Expr(None, Fn(None, MapUpdate, cvals))]), false
      
      | AK.PCValueUpdate ->
        let pre = List.map unwrap (List.filter (fun i -> i <> None) cimps) in
          Some((List.flatten pre)@
           [Expr(None, Fn(None, MapValueUpdate, cvals))]), false

      | _ -> None, false
    
      in 
      begin match imp, expr with
        | None, Some(e) -> 
          let pre = List.map unwrap (List.filter (fun i -> i <> None) cimps) in
          let b = (List.flatten pre)@
            [Expr(None, BinOp(None, Assign, Var (None, (meta_sym, meta_ty)), e))]
          in
          if List.length b = 1 then (false, None, Some(e))
          else (true, Some(b), None)
        
        | Some(i), None -> 
            let ro = Some(
              if child_decls = [] then i else [Block(None, child_decls@i)]) 
            in imp_meta_used, ro, expr
        | _, _ -> failwith "invalid tag compilation"
      end
    and gc_meta (meta, (tag, cmeta))
          : (bool * (('a option, 'ext_type, 'ext_fn) imp_t list) option 
                  * (('a option, 'ext_type, 'ext_fn) expr_t) option) =
      match tag with
      | Decorated t -> gc_tag meta t cmeta
      | Undecorated e -> 
        begin match cmeta with
          | [] -> false, None, Some(gc_expr e)
          | _ ->
            (* Recursive call to generate child imperative or expression code *)
            let cimp = List.flatten (List.map (fun m -> 
              let (ctag, ccm) = List.assoc m flat_ir in
              let (used,io,eo) = gc_meta (m, (ctag, ccm)) in
              let decl = Decl(None, (sym_of_meta m, type_of_meta m), None) in
              begin match io,eo with
                | Some(i), None -> if used then [decl]@i else i
                | None, Some(e) ->
                  [decl; Expr(None, BinOp(None, Assign,
                                Var (None, (sym_of_meta m, type_of_meta m)), e))]
                | _,_ -> failwith "invalid child code"
              end) cmeta)
            in
            let r = [Expr(None, BinOp(None, Assign,
                     Var (None, (sym_of_meta meta, type_of_meta meta)), gc_expr e))]
            in true, Some(cimp@r), None
        end 
    in
    (* Top-down code generation *)
    let root_meta, root_tc = List.nth flat_ir ((List.length flat_ir)-1) in
    let root_decl =
      let decl_meta = None in
      Decl(decl_meta, (sym_of_meta root_meta, type_of_meta root_meta), None) in
    begin match gc_meta (root_meta, root_tc) with
      | meta_used, Some(i), None ->
        (if meta_used then [root_decl] else [])@i
      | _, None, Some(e) ->
        [root_decl; Expr(None, BinOp(None, Assign,
            Var (None, (sym_of_meta root_meta, type_of_meta root_meta)), e))]
      | _, _, _ -> failwith "invalid code"   
    end

end