open Util
open M3
open K3.SR
open Values
open Database
open Sources
open Sources.Adaptors


(*
module CG : K3Codegen.CG with type db_t = NamedK3Database.db_t =
struct
    open K3Value

    module Env = K3Valuation
    module MC  = K3ValuationMap
    module DB  = NamedK3Database

    type value_t = K3Value.t
    type env_t   = K3Valuation.t
    type db_t    = DB.db_t

    type code_t  = env_t -> db_t -> value_t 
    type op_t    = value_t -> value_t -> value_t

    (* Helpers *)
    let back l = let x = List.rev l in (List.hd x, List.rev (List.tl x))

    let rec apply_list fv l =
        match fv,l with
        | (Fun _, []) -> fv
        | (v, []) -> v
        | (Fun (f,_), h::t) -> apply_list (f h) t
        | (_,_) -> failwith "invalid schema application"

    (* Map/aggregate tuple+multivariate function evaluation helpers.
     * uses fields of a tuple to evaluate a multivariate function if the
     * function is a schema application.
     *)
    
    (* returns the value yielded by the mvf. *)
    let apply_mv_map_fn_lc fn v =
        match fn, v with
        | Fun (f,true), Tuple(t_v) -> apply_list fn t_v
        | Fun (f,false), _ -> f v
        | _ -> failwith "invalid map function" 

    (* returns the a k-v pair corresponding to a MapCollection entry *)
    let apply_mv_map_fn_mc fn k v =
        let aux rv = match rv with
            | Tuple(t_v) -> let nv,nk = back t_v in (nk,nv)
            | _ -> failwith "invalid map collection entry"
        in
        match fn with
        | Fun (f,true) -> aux (apply_list fn (k@[v]))
        | Fun (f,false) -> aux (f (Tuple(k@[v])))
        | _ -> failwith "invalid map function"

    (* assumes the accumulator is the last argument, preceded by the tuple.
     * returns the value yielded by the mvf. *)
    let apply_mv_agg_fn_lc fn acc v =
        match fn, v with
        | Fun (f,true), Tuple(t_v) -> apply_list fn (t_v@[acc])
        | Fun (f,false), _ -> apply_list fn [v;acc]
        | _,_ -> failwith "invalid aggregation function"
    
    (* assumes the accumulator is the last argument, preceded by the tuple.
     * returns the value yielded by the mvf. *)
    let apply_mv_agg_fn_mc fn k v acc =
        match fn with
        | Fun (f,true) -> apply_list fn (k@[v;acc])
        | Fun (f,false) -> apply_list fn [Tuple(k@[v]);acc]
        | _ -> failwith "invalid aggregation function"


    let apply_fn_list th db l = List.map (fun f -> f th db) l
    
    let mc_to_lc m = MC.fold (fun k v acc -> (Tuple(k@[v]))::acc) [] m

    let match_kv_tuple k_v t_v =
        try fst (List.fold_left (fun (run,rem) v -> match run, rem with
            | (true,[]) -> (run, rem) (* could terminate early on success *)
            | (false, _) -> raise Not_found (* early termination for failure *)
            | (_,_) -> (run && (List.hd rem) = v, List.tl rem))
            (true,k_v) t_v)
        with Not_found -> false

    let tuple_fields t_v idx = snd (List.fold_left (fun (cur,acc) v ->
        (cur+1, if List.mem cur idx then acc@[v] else acc)) (0,[]) t_v)

    (* Operators *)
    let promote_op f_op i_op x y =
        match x,y with
        | (Float f, Int i) -> Float(f_op f (float_of_int i))
        | (Int i, Float f) -> Float(f_op (float_of_int i) f)
        | (Float f1, Float f2) -> Float(f_op f1 f2)
        | (Int i1, Int i2) -> Int(i_op i1 i2)
        | (_,_) -> failwith "invalid arithmetic operands" 
	
    (* Comparisons:
     * -- supports base types, tuples and lists. Tuple and list comparison
     *    works as with standard OCaml semantics (structural comparisons) *)
    (* TODO:
     * -- collections have list semantics here, e.g. element order matters.
     *    Generalize to support set/bag semantics as needed. *)
    let int_op op x y =
        match (x,y) with
        | Unit,_ | _,Unit -> failwith "invalid comparison to unit"
        | _ -> if (op x y) then Int(1) else Int(0)
	
	let add_op  = promote_op (+.) (+)
	let mult_op = promote_op ( *. ) ( * )
	let lt_op   = (int_op (< ))
	let leq_op  = (int_op (<=))
	let eq_op   = (int_op (= ))
	
	let ifthenelse0_op cond v = match cond with
        | Int(bcond) ->
            if bcond <> 0 then v
            else (match v with Int _ -> Int(0) | Float _ -> Float(0.0)
                    | _ -> failwith "invalid then clause value")
        | _ -> failwith "invalid predicate value"


    (* Terminals *)
    let const k = fun th db -> match k with CFloat(x) -> Float(x)
    let var v = fun th db -> 
        if (Env.bound v th) then Env.value v th
        else failwith ("Var("^v^"): theta="^(Env.to_string th))

    (* Tuples *)
    let tuple field_l = fun th db -> Tuple(apply_fn_list th db field_l)
    let project tuple idx = fun th db -> match tuple th db with
        | Tuple(t_v) -> Tuple(tuple_fields t_v idx)
        | _ -> failwith "invalid tuple for projection"

    (* Native collections *)
    let singleton el = fun th db -> ListCollection([el th db])
    
    (* combines two collections.
     * -- promotes map collections to list collections *)
    let combine c1 c2 = fun th db ->
        begin match (c1 th db, c2 th db) with
        | (ListCollection(c1), ListCollection(c2)) -> ListCollection(c1@c2)
        | ListCollection l, MapCollection m -> ListCollection(l@(mc_to_lc m))
        | MapCollection m, ListCollection l -> ListCollection((mc_to_lc m)@l)
        | MapCollection m1, MapCollection m2 -> MapCollection(MC.union m1 m2)
        | _,_ -> failwith "invalid collections to combine"
        end

    (* Arithmetic, comparision operators *)
    (* op type, lhs, rhs -> op *)
    let op op_fn l r = fun th db -> op_fn (l th db) (r th db)

    (* Control flow *)
    (* predicate, then clause, else clause -> condition *)
    (* TODO: support empty and singleton as true/false values *) 
    let ifthenelse pred t e = fun th db ->
        let valid = match (pred th db) with
	        | Float x -> x <> 0.0 | Int x -> x <> 0
	        | _ -> failwith "invalid predicate value"
        in if valid then t th db else e th db

    (* statements -> block *)    
    let block stmts =
        let idx = List.length stmts - 1 in
        (fun th db -> let rvs = apply_fn_list th db stmts in List.nth rvs idx)
 
    (* Functions *)
    (* arg, schema application, body -> fn *)
    let lambda v schema_app body = fun th db ->
        let fn value = body (Env.add th v value) db
        in Fun(fn, schema_app)
    
    (* arg1, type, arg2, type, body -> assoc fn *)
    let assoc_lambda v1 v2 body = fun th db ->
        let fn1 vl1 = Fun((fun vl2 ->
            body (Env.add (Env.add th v1 vl1) v2 vl2) db), false)
        in Fun(fn1, false)

    (* fn, arg -> evaluated fn *)
    let apply fn arg = fun th db -> match fn th db with
        | Fun (f,false) -> f (arg th db)
        | _ -> failwith "invalid function for function application"
    
    (* Structural recursion operations *)
    (* map fn, collection -> map *)
    let map map_fn collection = fun th db ->
        match map_fn th db, collection th db with
        | (Fun (f,sa), ListCollection l) ->
            ListCollection(List.map (apply_mv_map_fn_lc (Fun(f,sa))) l)
        | (Fun (f,sa), MapCollection m) ->
            MapCollection(MC.mapi (apply_mv_map_fn_mc (Fun (f,sa))) m)
        | (_,_) -> failwith "invalid map function/collection"
    
    (* agg fn, initial agg, collection -> agg *)
    (* Note: accumulator is the last arg to agg_fn *)
    let aggregate agg_fn init_agg collection = fun th db ->
        match agg_fn th db, collection th db with
        | (Fun (f,sa), ListCollection l) ->
            List.fold_left (apply_mv_agg_fn_lc (Fun(f,sa))) (init_agg th db) l
        | (Fun (f,sa), MapCollection m) ->
            MC.fold (apply_mv_agg_fn_mc (Fun (f,sa))) (init_agg th db) m
        | (_,_) -> failwith "invalid agg function/collection"
    
    (* agg fn, initial agg, grouping fn, collection -> agg *)
    (* Perform group-by aggregation by using a temporary MapCollection,
     * which currently is a hash table, thus we have hash-based aggregation. *)
    let group_by_aggregate agg_fn init_agg gb_fn collection =
        let gb init_v gb_acc agg_f gb_key =
            let gb_agg = if MC.mem gb_key gb_acc
                         then MC.find gb_key gb_acc else init_v in
            let new_gb_agg = agg_f gb_agg
            in MC.add gb_key new_gb_agg gb_acc
        in
        let lc_gb init_v f g mc v =
            let gb_key = match g v with Tuple(t_v) -> t_v | x -> [x]
            in gb init_v mc (fun a -> f a v) gb_key
        in
        let mc_gb init_v f g k v mc =
            let gb_key = let x,y = (g k v) in x@[y]
            in gb init_v mc (f k v) gb_key
        in
        (fun th db ->
        let init_v = init_agg th db in
        match agg_fn th db, gb_fn th db, collection th db with
        | Fun (f,fsa), Fun (g,gsa), ListCollection l ->
            ListCollection(mc_to_lc
            (List.fold_left (lc_gb init_v
                (apply_mv_agg_fn_lc (Fun(f,fsa)))
                (apply_mv_map_fn_lc (Fun(g,gsa)))) (MC.empty_map()) l))
        
        | Fun (f,fsa), Fun (g,gsa), MapCollection m ->
            MapCollection(
            MC.fold (mc_gb init_v
                (apply_mv_agg_fn_mc (Fun(f,fsa)))
                (apply_mv_map_fn_mc (Fun(g,gsa)))) (MC.empty_map()) m)
        
        | _,_,_ -> failwith "invalid group by aggregation")
    
    (* nested collection -> flatten *)
    (* Note: this only works for ListCollections, since MapCollections are
     * collections of tuples, thus can never be nested simply (i.e. C(C(V)) ). 
     *)
    let flatten nested_collection = fun th db ->
        match nested_collection th db with
        | ListCollection(nl) ->
            let r = List.fold_left (fun acc l_v -> match l_v with
                | ListCollection(l) -> acc@l
                | MapCollection(m) -> acc@(mc_to_lc m)
                | _ -> failwith "invalid nested collection") [] nl
            in ListCollection(r)

        | _ -> failwith "invalid flatten on non-collection"

    (* Tuple collection operators *)
    (* TODO: write documentation on datatypes + implementation requirements
     * for these methods *)
    let tcollection_op lc_f mc_f tcollection key_l = fun th db ->
        let k_v = apply_fn_list th db key_l in
        match tcollection th db with
        | ListCollection l -> lc_f l k_v
        | MapCollection m -> mc_f m k_v
        | _ -> failwith "invalid tuple collection"

    (* map, key -> bool/float *)
    let exists tcollection key_l =
        let lc_f l k_v =
	        let r = List.exists (fun v -> match v with
	            | Tuple(t_v) -> match_kv_tuple k_v t_v
	            | _ -> failwith "invalid tuple collection") l
	        in if r then Int(1) else Int(0)
        in
        let mc_f m k_v = if MC.mem k_v m then Int(1) else Int(0)
        in tcollection_op lc_f mc_f tcollection key_l

    (* map, key -> map value *)
    let lookup tcollection key_l =
        let idx = List.length key_l in
        (* returns the unnamed value (i.e. the last value) from the tuple *)        
        let rv v = match v with 
            | Tuple(t_v) -> List.nth t_v idx
            | _ -> failwith "invalid tuple collection"
        in
        let lc_f l k_v =
            (* return the first value found for a matching key *)
            rv (List.find (fun v -> match v with
                | Tuple(t_v) -> match_kv_tuple k_v t_v
                | _ -> failwith "invalid tuple collection") l)
        in
        let mc_f m k_v = MC.find k_v m
        in tcollection_op lc_f mc_f tcollection key_l
    
    (* map, partial key, pattern -> slice *)
    (* Note: converts slices to lists, to ensure expression evaluation is
     * done on list collections. *)
    let slice tcollection pkey_l pattern =
        let lc_f l pk_v = ListCollection(List.filter (fun v -> match v with
            | Tuple(t_v) -> match_kv_tuple pk_v (tuple_fields t_v pattern)
            | _ -> failwith "invalid tuple collection") l)
        in
        let mc_f m pk_v = ListCollection(mc_to_lc (MC.slice pattern pk_v m))
        in tcollection_op lc_f mc_f tcollection pkey_l


    (* Persistent collections *)

    (* Database retrieval methods *)
    let get_value id db   = DB.get_value id db
    let get_in_map id db  = DB.get_value id db
    let get_out_map id db = DB.get_value id db
    let get_map id db     = DB.get_value id db

    (* Database update methods *)
    let get_kv x = match x with
        | Tuple(l) -> let x = List.rev l in (List.rev (List.tl x), List.hd x)
        | _ -> failwith "invalid tuple"

    let get_update_map c pats = match c with
        | ListCollection(l) ->
            MapCollection(MC.from_list (List.map get_kv l) pats)
        | MapCollection(m) ->
            MapCollection(List.fold_left MC.add_secondary_index m pats) 
        | _ -> failwith "invalid single_map_t" 

    (* Database retrieval methods *)
    let get_value id   = fun th db -> DB.get_value id db
    let get_in_map id  = fun th db -> DB.get_value id db
    let get_out_map id = fun th db -> DB.get_value id db
    let get_map id     = fun th db -> DB.get_value id db

    (* Database udpate methods *)

    (* persistent collection id, value -> update *)
    let update_value id value =
        fun th db -> DB.update_value id (value th db) db; Unit
    
    (* persistent collection id, in key, value -> update *)
    let update_in_map_value id in_kl value = fun th db ->
        DB.update_map id
            (apply_fn_list th db in_kl) (value th db) db; Unit
    
    (* persistent collection id, out key, value -> update *)
    let update_out_map_value id out_kl value = fun th db ->
        DB.update_map id
            (apply_fn_list th db out_kl) (value th db) db; Unit
    
    (* persistent collection id, in key, out key, value -> update *)
    let update_map_value id in_kl out_kl value = fun th db ->
        DB.update_io_map id
            (apply_fn_list th db in_kl) (apply_fn_list th db out_kl)
            (value th db) db;
        Unit

    (* persistent collection id, update collection -> update *)
    let update_in_map id collection = fun th db ->
        let in_pats = DB.get_in_patterns id db
        in DB.update_value id (get_update_map (collection th db) in_pats) db; Unit
    
    let update_out_map id collection = fun th db ->
        let out_pats = DB.get_out_patterns id db
        in DB.update_value id (get_update_map (collection th db) out_pats) db; Unit

    (* persistent collection id, key, update collection -> update *)
    let update_map id in_kl collection = fun th db ->
        let out_pats = DB.get_out_patterns id db in
        DB.update_map id (apply_fn_list th db in_kl)
           (get_update_map (collection th db) out_pats) db;
        Unit

    (* fn id -> code
     * -- code generator should be able to hooks to implementations of
     *    external functions, e.g. invoke function call *)
    let ext_fn fn_id = failwith "external functions not yet supported"



    (* TODO: statement codegen *)
end
*)










module MK3CG : K3Codegen.CG with type db_t = NamedM3Database.db_t =
struct

    module Env = M3Valuation
    module MC  = M3ValuationMap
    module DB  = NamedM3Database
    module RT  = Runtime.Make(DB)
    
    open RT

    type single_map_t = DB.single_map_t
    type map_t        = DB.map_t

    type value_t = 
        | Unit
        | Float          of float
        | Int            of int
        | Tuple          of value_t list
        | Fun            of (value_t -> value_t) 

        (* Persistent collection values, these are yielded on accessing
         * the persistent store. *)
        | SingleMap      of single_map_t
        | DoubleMap      of map_t

        (* Core internal collections used during processing.
         * -- these are flat collections, i.e. value_t is expected to
         *    be a base type, such as float/int for lists, and
         *    tuple(float/int) for tuplelists
         * -- SingleMaps and DoubleMaps are converted to these internal types
         *    by tuple collection accessors (mem/lookup/slice) *)
        | List           of value_t list
        | TupleList      of value_t list
         
        (* slicing a double map yields a SingleMapList of key * smap entries *)
        | SingleMapList  of (value_t list * single_map_t) list
          

    type slice_env_t = (string * value_t) list
    
    type env_t       = M3Valuation.t * slice_env_t 
    type db_t        = DB.db_t

    type eval_t      = env_t -> db_t -> value_t
    type code_t      =
          Eval of eval_t
        | Trigger of M3.pm_t * M3.rel_id_t * (const_t list -> db_t -> unit)
        | Main of (unit -> unit) 

    type op_t        = value_t -> value_t -> value_t

    (* Slice environment *)
    let is_env_value v (_,th) = List.mem_assoc v th
    let get_env_value v (_,th) = List.assoc v th

    (* Helpers *)
    let rec string_of_value v = match v with
      | Unit -> "unit"
      | Float(f) -> string_of_float f
      | Int(i) -> string_of_int i
      | Tuple(fl) -> "("^(String.concat "," (List.map string_of_value fl))^")"
      | Fun(f) -> "<fun>"
      | List(fl) ->
          "["^(String.concat ";" (List.map string_of_value fl))^"]"
      
      | TupleList(kvl) ->
          "["^(String.concat ";" (List.map string_of_value kvl))^"]"

      | SingleMap(sm) -> "SingleMap("^(DB.smap_to_string sm)^")"
      | DoubleMap(dm) -> "DoubleMap("^(DB.map_to_string dm)^")"
      | SingleMapList(sml) ->
          ("["^(List.fold_left (fun acc (k,m) ->
                (if acc = "" then "" else acc^";")^
                (string_of_value (Tuple k))^","^
                (string_of_value (SingleMap m)))
               "" sml)^"]") 

    let get_expr expr_opt = match expr_opt with
        | None -> ""
        | Some(e) -> " at code: "^(string_of_expr e)

    let get_eval e = match e with
        | Eval(e) -> e
        | _ -> failwith "unable to eval expr"

    let get_trigger e = match e with
        | Trigger(x,y,z) -> (x,y,z)
        | _ -> failwith "unable to eval trigger"

    let value_of_float x = Float(x)
    let value_of_const_t x = match x with CFloat(y) -> Float(y)
    
    let float_of_value x = match x with
        | Float f -> f | Int i -> float_of_int i
        | _ -> failwith ("invalid float: "^(string_of_value x))

    let float_of_const_t x = match x with CFloat(f) -> f 
    
    let const_t_of_value x = match x with
        | Float f -> CFloat f | Int i -> CFloat (float_of_int i)
        | _ -> failwith ("invalid const_t: "^(string_of_value x))

    let const_t_of_float x = CFloat(x)

    let value_of_tuple x = Tuple(x)
    let tuple_of_value x = match x with
        | Tuple(y) -> y
        | _ -> failwith ("invalid tuple: "^(string_of_value x))

    let pop_back l =
        let x,y = List.fold_left
            (fun (acc,rem) v -> match rem with 
                | [] -> (acc, [v]) | _ -> (acc@[v], List.tl rem)) 
            ([], List.tl l) l
        in x, List.hd y

    (*
    let tuple_of_kv (k,v) = Tuple(k@[v])

    let kv_of_tuple t = match t with
        | Tuple(t_v) -> pop_back t_v 
        | _ -> failwith ("invalid tuple: "^(string_of_value t))
    *)

    (*
    let rec apply_list fv l =
        match fv,l with
        | (Fun _, []) -> fv
        | (v, []) -> v
        | (Fun (f,_), h::t) -> apply_list (f h) t
        | (_,_) -> failwith "invalid schema application"
    *)

    let rec apply_list fv l =
        match fv,l with
        | (Fun _, []) -> fv
        | (v, []) -> v
        | (Fun f, h::t) -> apply_list (f h) t
        | (_,_) -> failwith "invalid schema application"

    (* Map/aggregate tuple+multivariate function evaluation helpers.
     * uses fields of a tuple to evaluate a multivariate function if the
     * function is a schema application.
     *)
    
    (* returns the value yielded by the mvf. *)
    (*
    let apply_mv_map_fn_lc fn v =
        match fn, v with
        | Fun (f,true), Tuple(t_v) ->
            apply_list fn (List.map value_of_float t_v)
        | Fun (f,false), _ -> f v
        | Fun _ , _ -> failwith "invalid map fn argument"
        | _ -> failwith "invalid map function"
    *) 

    (* assumes the accumulator is the last argument, preceded by the tuple.
     * returns the value yielded by the mvf. *)
    (*
    let apply_mv_agg_fn_lc fn acc v =
        match fn, v with
        | Fun (f,true), Tuple(t_v) ->
            apply_list fn ((List.map value_of_float t_v)@[acc])
        | Fun (f,false), _ -> apply_list fn [v;acc]
        | _,_ -> failwith "invalid aggregation function"

    let apply_mv_map_fn_smlc fn (v,mv) =
        match fn, v, mv with
        | Fun (f,true), Tuple(t_v), SingleMap(m) ->
            apply_list fn ((List.map value_of_float t_v)@[mv])
        | Fun (f,false), _, SingleMap(m) -> apply_list fn [v;mv]
        | Fun _, _, _ -> failwith "invalid single map argument" 
        | _ -> failwith "invalid map function"
    *)

    let apply_fn_list th db l = List.map (fun f -> (get_eval f) th db) l

    let mc_to_tlc m = MC.fold (fun k v acc ->
        let t_v = List.map value_of_const_t (k@[v])
        in (value_of_tuple t_v)::acc) [] m
        
    let mc_to_smlc m = MC.fold (fun k v acc ->
        (List.map value_of_const_t k, v)::acc) [] m

    let match_key_prefix prefix k =
        try fst (List.fold_left (fun (run,rem) v -> match run, rem with
            | (true,[]) -> (run, rem) (* could terminate early on success *)
            | (false, _) -> raise Not_found (* early termination for failure *)
            | (_,_) -> (run && (List.hd rem) = v, List.tl rem))
            (true,prefix) k)
        with Not_found -> false

    let tuple_fields t_v idx = snd (List.fold_left (fun (cur,acc) v ->
        (cur+1, if List.mem cur idx then acc@[v] else acc)) (0,[]) t_v)


    (* Operators *)
    let promote_op f_op i_op x y =
        match x,y with
        | (Float f, Int i) -> Float(f_op f (float_of_int i))
        | (Int i, Float f) -> Float(f_op (float_of_int i) f)
        | (Float f1, Float f2) -> Float(f_op f1 f2)
        | (Int i1, Int i2) -> Int(i_op i1 i2)
        | (_,_) -> failwith "invalid arithmetic operands" 
    
    (* Comparisons:
     * -- supports base types, tuples and lists. Tuple and list comparison
     *    works as with standard OCaml semantics (structural comparisons) *)
    (* TODO:
     * -- collections have list semantics here, e.g. element order matters.
     *    Generalize to support set/bag semantics as needed. *)
    let int_op (op : 'a -> 'a -> bool) x y =
        match (x,y) with
        | Unit,_ | _,Unit -> failwith "invalid comparison to unit"
        | _,_ -> if op x y then Int(1) else Int(0) 
    
    let add_op  = promote_op (+.) (+)
    let mult_op = promote_op ( *. ) ( * )
    let lt_op   = (int_op (< ))
    let leq_op  = (int_op (<=))
    let eq_op   = (int_op (= ))
    let neq_op  = (int_op (<>))
    
    let ifthenelse0_op cond v = 
        let aux v = match v with
            | Int _ -> Int(0) | Float _ -> Float(0.0)
            | _ -> failwith "invalid then clause value"
        in match cond with
        | Float(bcond) -> if bcond <> 0.0 then v else aux v
        | Int(bcond) -> if bcond <> 0 then v else aux v
        | _ -> failwith "invalid predicate value"


    (* Terminals *)
    let const ?(expr = None) k = Eval(fun th db -> value_of_const_t k)
    let var ?(expr = None) v = Eval(fun th db -> 
        if (Env.bound v (fst th)) then value_of_const_t (Env.value v (fst th))
        else if is_env_value v th then get_env_value v th 
        else failwith ("Var("^v^"): theta="^(Env.to_string (fst th))))

    (* Tuples *)
    let tuple ?(expr = None) field_l = Eval(fun th db ->
        Tuple(apply_fn_list th db field_l))

    let project ?(expr = None) tuple idx = Eval(fun th db ->
        match (get_eval tuple) th db with
        | Tuple(t_v) -> Tuple(tuple_fields t_v idx)
        | _ -> failwith ("invalid tuple for projection"^(get_expr expr)))

    (* Native collections *)
    
    (* assumes numeric non-tuple element
     * -- note no nested collections for now. *)
    let singleton ?(expr = None) el = Eval(fun th db ->
        match (get_eval el) th db with
        | Tuple(t_v) as t -> TupleList([t])
        | Float _ as x -> List([x])
        | Int _ as x -> List([x])
        | v -> failwith ("invalid singleton value: "^
                         (string_of_value v)^(get_expr expr)))
    
    (* combines two collections.
     * -- applies only to lists and tuple lists, requiring map conversion
     * -- no nested collections for now *)
    let combine ?(expr = None) c1 c2 = Eval(fun th db ->
        begin match ((get_eval c1) th db, (get_eval c2) th db) with
        | (List(c1), List(c2)) -> List(c1@c2)
        | (TupleList(c1), TupleList(c2)) -> TupleList(c1@c2)
        | _,_ -> failwith ("invalid collections to combine"^(get_expr expr))
        end)

    (* Arithmetic, comparision operators *)
    (* op type, lhs, rhs -> op *)
    let op ?(expr = None) op_fn l r = Eval(fun th db ->
        op_fn ((get_eval l) th db) ((get_eval r) th db))

    (* Control flow *)
    (* predicate, then clause, else clause -> condition *) 
    let ifthenelse ?(expr = None) pred t e = Eval(fun th db ->
        let valid = match ((get_eval pred) th db) with
            | Float x -> x <> 0.0 | Int x -> x <> 0
            | _ -> failwith ("invalid predicate value"^(get_expr expr))
        in if valid then (get_eval t) th db else (get_eval e) th db)

    (* statements -> block *)    
    let block ?(expr = None) stmts =
        let idx = List.length stmts - 1 in
        Eval(fun th db ->
          let rvs = apply_fn_list th db stmts in List.nth rvs idx)
 
    (* iter fn, collection -> iteration *)
    let iterate ?(expr = None) iter_fn collection = Eval(fun th db ->
        let rv c = (c; Unit) in
        let aux fn vf_opt =
            List.iter (fun v -> match fn v with
                | Unit -> ()
                | _ -> failwith ("invalid iteration"^(get_expr expr)))
        in
        begin match (get_eval iter_fn) th db, (get_eval collection) th db with
        | (Fun f, List l) -> rv (aux f None l)
        | (Fun f, TupleList l) -> rv (aux f None l)
        | (Fun f, SingleMapList l) -> rv (List.iter (fun (k,m) ->
            match apply_list (Fun f) [Tuple k; SingleMap m] with
            | Unit -> ()
            | _ -> failwith ("invalid iteration"^(get_expr expr))))
        | (Fun _, _) -> failwith ("invalid iterate collection"^(get_expr expr))
        | _ -> failwith ("invalid iterate function"^(get_expr expr))
        end)

    (* Functions *)
    let bind_float expr arg th f = match arg with
        | AVar(var,_) -> Env.add (fst th) var (CFloat f), snd th
        | ATuple(vt_l) -> 
            failwith ("cannot bind a float to a tuple"^(get_expr expr))

    let bind_tuple expr arg th t = match arg with
        | AVar(v,vt) ->
            begin match vt with
            | TTuple(_) -> fst th, (v,value_of_tuple t)::(snd th)
            | _ -> failwith ("cannot bind tuple to "^v^(get_expr expr))
            end
        | ATuple(vt_l) ->
            begin try 
            (List.fold_left2 (fun acc (v,_) tf ->
                Env.add acc v (CFloat (float_of_value tf)))
                (fst th) vt_l t, snd th)
            with Invalid_argument _ ->
                failwith ("could not bind tuple arg to value: "^
                          (string_of_value (value_of_tuple t))^(get_expr expr))
            end

    let bind_map expr arg th m = match arg with
        | AVar(var,_) -> fst th, (var,m)::(snd th)
        | ATuple(vt_l) ->
            failwith ("cannot bind a map to a tuple"^(get_expr expr))

    (* no binding to functions, and non-persistent collections for now *)
    let bind_value expr arg th v = match v with
        | Float x -> bind_float expr arg th x
        | Int x -> bind_float expr arg th (float_of_int x)
        | Tuple t -> bind_tuple expr arg th t
        (* We bind map vars during map accesses, so need to
         * support adding single/double maps to environments *)
        | SingleMap(m) -> bind_map expr arg th v
        | DoubleMap(m) -> bind_map expr arg th v
        | _ -> failwith ("invalid fn arg: "^(string_of_value v)^(get_expr expr))

    (* arg, schema application, body -> fn *)
    let lambda ?(expr = None) arg body = Eval(fun th db ->
        let fn v = (get_eval body) (bind_value expr arg th v) db
        in Fun fn)
    
    (* arg1, type, arg2, type, body -> assoc fn *)
    (* M3 assoc functions should never need to use slices *)
    let assoc_lambda ?(expr = None) arg1 arg2 body = Eval(fun th db ->
        let aux vl1 vl2 =
            let new_th = bind_value expr arg2
                (bind_value expr arg1 th vl1) vl2 
            in (get_eval body) new_th db
        in let fn1 vl1 = Fun(fun vl2 -> aux vl1 vl2)
        in Fun fn1)

    (* fn, arg -> evaluated fn *)
    let apply ?(expr = None) fn arg = Eval(fun th db ->
        match (get_eval fn) th db, (get_eval arg) th db with
        | Fun f, x -> f x
        | _ -> failwith ("invalid function for fn app"^(get_expr expr)))
    
    (* Collection operations *)
    
    (* map fn, collection -> map *)
    (* TODO: fix typechecker inconsistency:
     * -- this is a very restricted map, yielding the same type of output
     *    as input. The return collection should be based on the map fn rv type
     *)
    let map ?(expr = None) map_fn collection = Eval(fun th db ->
        let aux fn  = List.map (fun v -> fn v) in
        match (get_eval map_fn) th db, (get_eval collection) th db with
        | (Fun f, List l) -> List(aux f l)
        | (Fun f, TupleList l) -> TupleList(aux f l)
        | (Fun _, x) -> failwith ("invalid map collection: "^
                                  (string_of_value x)^(get_expr expr))
        | _ -> failwith ("invalid map function"^(get_expr expr)))
    
    (* agg fn, initial agg, collection -> agg *)
    (* Note: accumulator is the last arg to agg_fn *)
    let aggregate ?(expr = None) agg_fn init_agg collection = Eval(fun th db ->
        let aux fn l = List.fold_left
            (fun acc v -> apply_list fn [v;acc]) 
            ((get_eval init_agg) th db) l
        in
        match (get_eval agg_fn) th db, (get_eval collection) th db with
        | (Fun f, List l) -> aux (Fun f) l
        | (Fun f, TupleList l) -> aux (Fun f) l
        | (Fun _, v) -> failwith ("invalid agg collection: "^
                                  (string_of_value v)^(get_expr expr))        
        | _ -> failwith ("invalid agg function"^(get_expr expr)))

    (* agg fn, initial agg, grouping fn, collection -> agg *)
    (* Perform group-by aggregation by using a temporary MapCollection,
     * which currently is a hash table, thus we have hash-based aggregation. *)
    let group_by_aggregate ?(expr = None) agg_fn init_agg gb_fn collection =
        let gb init_v gb_acc agg_f gb_key =
            let gb_agg = if MC.mem gb_key gb_acc
                 then (value_of_const_t (MC.find gb_key gb_acc)) else init_v in
            let new_gb_agg = agg_f gb_agg
            in MC.add gb_key (const_t_of_value new_gb_agg) gb_acc
        in
        let lc_gb init_v f g mc t =
            let gb_key = List.map const_t_of_value
	            (match g t with | Tuple(t_v) -> t_v | x -> [x])
            in gb init_v mc (fun a -> f [t; a]) gb_key
        in
        Eval(fun th db ->
        let init_v = (get_eval init_agg) th db in
        match (get_eval agg_fn) th db,
              (get_eval gb_fn) th db,
              (get_eval collection) th db
        with
        | Fun f, Fun g, TupleList l -> TupleList(mc_to_tlc
            (List.fold_left (lc_gb
                init_v (apply_list (Fun f)) g) (MC.empty_map()) l))

        | Fun _, Fun _, v -> failwith ("invalid gb-agg collection: "^
            (string_of_value v)^(get_expr expr))
        
        | Fun _, gb, _ -> failwith ("invalid group-by function: "^
            (string_of_value gb)^(get_expr expr))
        
        | f,_,_ -> failwith ("invalid group by agg fn: "^
            (string_of_value f)^(get_expr expr)))
    
    (* nested collection -> flatten *)
    (* TODO *)
    let flatten ?(expr = None) nested_collection =
        failwith ("flatten not yet implemented"^(get_expr expr))
        

    (* Tuple collection operators *)
    (* TODO: write documentation on datatypes + implementation requirements
     * for these methods *)
    let tcollection_op expr ex_s lc_f smc_f dmc_f tcollection key_l =
        Eval(fun th db ->
        let k = apply_fn_list th db key_l in
        try begin match (get_eval tcollection) th db with
            | TupleList l -> lc_f l k
            | SingleMap m -> smc_f m (List.map const_t_of_value k)
            | DoubleMap m -> dmc_f m (List.map const_t_of_value k)
            | v -> failwith ("invalid tuple collection: "^(string_of_value v))
            end
        with Not_found ->
            failwith ("collection operation failed: "^ex_s^(get_expr expr)))

    (* map, key -> bool/float *)
    let exists ?(expr = None) tcollection key_l =
        let lc_f l k =
            let r = List.exists (fun t ->
                match_key_prefix k (tuple_of_value t)) l
            in if r then Int(1) else Int(0)
        in
        let mc_f m k_v = if MC.mem k_v m then Int(1) else Int(0)
        in tcollection_op expr "exists" lc_f mc_f mc_f tcollection key_l

    (* map, key -> map value *)
    let lookup ?(expr = None) tcollection key_l =
        (* returns the (unnamed) value from the first tuple with a matching key *)
        let lc_f l k =
            let r = List.find (fun t ->
                match_key_prefix k (tuple_of_value t)) l in
            let r_t = tuple_of_value r in
            let r_len = List.length r_t 
            in List.nth r_t (r_len-1)
        in
        let smc_f m k_v = value_of_const_t (MC.find k_v m) in
        let dmc_f m k_v = SingleMap(MC.find k_v m) in
        tcollection_op expr "lookup" lc_f smc_f dmc_f tcollection key_l
    
    (* map, partial key, pattern -> slice *)
    (* Note: converts slices to lists, to ensure expression evaluation is
     * done on list collections. *)
    let slice ?(expr = None) tcollection pkey_l pattern =
        let lc_f l pk = TupleList(List.filter (fun t ->
            match_key_prefix pk (tuple_fields (tuple_of_value t) pattern)) l)
        in
        let smc_f m pk = TupleList(mc_to_tlc (MC.slice pattern pk m)) in
        let dmc_f m pk = SingleMapList(mc_to_smlc (MC.slice pattern pk m))
        in tcollection_op expr "slice" lc_f smc_f dmc_f tcollection pkey_l


    (* Database retrieval methods *)
    let get_value ?(expr = None) id = Eval(fun th db ->
        match DB.get_value id db with
        | Some(x) -> value_of_const_t x | None -> Float(0.0))

    let get_in_map ?(expr = None) id =
        Eval(fun th db -> SingleMap(DB.get_in_map id db))
    
    let get_out_map ?(expr = None) id =
        Eval(fun th db -> SingleMap(DB.get_out_map id db))
    
    let get_map ?(expr = None) id =
        Eval(fun th db -> DoubleMap(DB.get_map id db))

    (* Database udpate methods *)
    let const_t_kv_of_tuple t =
        pop_back (List.map const_t_of_value (tuple_of_value t))

    let get_update_value th db v = const_t_of_value ((get_eval v) th db)
    let get_update_key th db kl =
        List.map const_t_of_value (apply_fn_list th db kl)

    let get_update_map c pats = match c with
        | TupleList(l) -> MC.from_list (List.map const_t_kv_of_tuple l) pats
        | SingleMap(m) -> List.fold_left MC.add_secondary_index m pats
        | _ -> failwith "invalid single_map_t" 

    (* persistent collection id, value -> update *)
    let update_value ?(expr = None) id value = Eval(fun th db ->
        DB.update_value id (get_update_value th db value) db; Unit)
    
    (* persistent collection id, in key, value -> update *)
    let update_in_map_value ?(expr = None) id in_kl value = Eval(fun th db ->
        DB.update_in_map_value id
            (get_update_key th db in_kl)
            (get_update_value th db value) db;
        Unit)
    
    (* persistent collection id, out key, value -> update *)
    let update_out_map_value ?(expr = None) id out_kl value = Eval(fun th db ->
        DB.update_out_map_value id
            (get_update_key th db out_kl)
            (get_update_value th db value) db;
        Unit)
    
    (* persistent collection id, in key, out key, value -> update *)
    let update_map_value ?(expr = None) id in_kl out_kl value = Eval(fun th db ->
        DB.update_map_value id
            (get_update_key th db in_kl)
            (get_update_key th db out_kl)
            (get_update_value th db value) db;
        Unit)

    (* persistent collection id, update collection -> update *)
    let update_in_map ?(expr = None) id collection = Eval(fun th db ->
        let in_pats = DB.get_in_patterns id db
        in DB.update_in_map id
             (get_update_map ((get_eval collection) th db) in_pats) db;
        Unit)
    
    let update_out_map ?(expr = None) id collection = Eval(fun th db ->
        let out_pats = DB.get_out_patterns id db
        in DB.update_out_map id
             (get_update_map ((get_eval collection) th db) out_pats) db;
        Unit)

    (* persistent collection id, key, update collection -> update *)
    let update_map ?(expr = None) id in_kl collection = Eval(fun th db ->
        let out_pats = DB.get_out_patterns id db in
        DB.update_map id (get_update_key th db in_kl)
           (get_update_map ((get_eval collection) th db) out_pats) db;
        Unit)
    
    (*
    let ext_fn fn_id = failwith "External functions not yet supported"
    *)
    
    (* Top level code generation *)
    let trigger event rel trig_args stmt_block =
      Trigger (event, rel, (fun tuple db ->
        let theta = Env.make trig_args tuple, [] in
          List.iter (fun cstmt -> match (get_eval cstmt) theta db with
            | Unit -> ()
            | _ -> failwith "trigger returned non-unit") stmt_block))

    (* Sources, for now files only. *)
    type source_impl_t = FileSource.t

    let source src framing (rel_adaptors : (string * adaptor_t) list) =
       let src_impl = match src with
           | FileSource(fn) ->
               FileSource.create src framing 
               (List.map (fun (rel,adaptor) -> 
                   (rel, (Adaptors.create_adaptor adaptor))) rel_adaptors)
               (list_to_string fst rel_adaptors)
           | SocketSource(_) -> failwith "Sockets not yet implemented."
           | PipeSource(_)   -> failwith "Pipes not yet implemented."
       in (src_impl, None, None)

    let main schema patterns sources triggers toplevel_queries =
      Main (fun () ->
        let db = DB.make_empty_db schema patterns in
        let (insert_trigs, delete_trigs) = 
          List.fold_left 
            (fun (insert_acc, delete_acc) trig ->
              let add_trigger acc =
                let (_, rel, t_code) = get_trigger trig
                in (rel, t_code)::acc
              in match get_trigger trig with 
              | (M3.Insert, _, _) -> (add_trigger insert_acc, delete_acc)
              | (M3.Delete, _, _) -> (insert_acc, add_trigger delete_acc))
          ([], []) triggers in
        let dispatcher =
          (fun evt ->
            match evt with 
            | Some(Insert, rel, tuple) when List.mem_assoc rel insert_trigs -> 
              ((List.assoc rel insert_trigs) tuple db; true)
            | Some(Delete, rel, tuple) when List.mem_assoc rel delete_trigs -> 
              ((List.assoc rel delete_trigs) tuple db; true)
            | Some _  | None -> false)
        in
        let mux = List.fold_left
          (fun m (source,_,_) -> FileMultiplexer.add_stream m source)
          (FileMultiplexer.create ()) sources
        in
        let db_tlq = List.map DB.string_to_map_name toplevel_queries in
          synch_main db mux db_tlq dispatcher StringMap.empty ())

    (* For the interpreter, output evaluates the main function and redirects
     * stdout to the desired channel. *)
    let output main out_chan = match main with
      | Main(main_f) ->
          Unix.dup2 Unix.stdout (Unix.descr_of_out_channel out_chan); main_f ()
      | _ -> failwith "invalid M3 interpreter main code"

 
    let rec eval c vars vals db = match c with
      | Eval(f) -> f (Env.make vars vals, []) db
      | Trigger(evt,rel,trig_fn) -> trig_fn vals db; Unit
      | Main(f) -> f(); Unit
end