open M3
open M3.Patterns
(* M3 preparation and compilation *)
module M3P = M3.Prepared

(* TODO: validate x * m[x] *)
let prepare_triggers (triggers : trig_t list) (sanitize_var : string -> string)
   : (M3P.ptrig_t list * pattern_map) =
   let sanitize_vars = List.map sanitize_var in
   let prep_counter = ref [] in
   let add_counter() = prep_counter := 0::(!prep_counter) in
   let remove_counter() =
      if !prep_counter != [] then prep_counter := (List.tl !prep_counter)
   in
   let prepare() =
      if !prep_counter = [] then add_counter();
      let current = List.hd (!prep_counter) in
         prep_counter := (current+1)::(List.tl !prep_counter);
         current
   in
   let save_counter f = add_counter(); let r = f() in remove_counter(); r in
   let rec prepare_calc (update_mapn : string) (lhs_vars: var_t list)
                        (theta_vars : var_t list) (calc : calc_t)
         : (M3P.ecalc_t * pattern_map) =
      let recur = prepare_calc update_mapn lhs_vars in
      let prepare_aux c propagate defv theta_ext
            : (M3P.ecalc_t * var_t list * pattern_map) =
         let outv = calc_schema c in
         let ext = Util.ListAsSet.diff (if propagate then defv else outv)
                      (if propagate then outv else defv) in
         let (pc, pm) = recur (theta_vars@theta_ext) c in 
         (* Override metadata, assumes recursive call to prepare_calc has
          * already done this for its children. *)
         let new_pc_meta = let (x,_,y,z) = M3P.get_meta pc in (x,ext,y,z) in
         let new_pc = (M3P.get_calc pc, new_pc_meta)
         in (new_pc, outv, pm)
      in
      let prepare_op (f : M3P.ecalc_t -> M3P.ecalc_t -> M3P.pcalc_t)
                     (c1: calc_t) (c2: calc_t)
            : (M3P.ecalc_t * pattern_map)
      =
         let (e1, c1_outv, p1_patterns) = prepare_aux c1 false theta_vars [] in
         let (e2, _, p2_patterns) =
            prepare_aux c2 true c1_outv (M3P.get_extensions e1) in
         let patterns = merge_pattern_maps p1_patterns p2_patterns in
         let singleton = (M3P.get_singleton e1) && (M3P.get_singleton e2) in
         let (c1_vars, c2_vars) = (calc_vars c1, calc_vars c2) in
         let product = (Util.ListAsSet.inter c1_vars c2_vars) = []
         (* Safe to use empty theta extensions, since this will get overriden
          * by recursive calls for binary ops *) 
         in ((f e1 e2, (prepare(), [], singleton, product)), patterns) 
      in
      match (fst calc) with
        | Const(c)      -> ((Const(c), (prepare(), [], true, false)), empty_pattern_map())
        | Var(v)        -> 
            let sv = sanitize_var v in
           (* Bigsum vars are not LHS vars, and are slices. *)
           ((Var(sv), (prepare(), [], List.mem sv lhs_vars, false)), empty_pattern_map())

        | Add  (c1,c2)  -> prepare_op (fun e1 e2 -> Add  (e1, e2)) c1 c2
        | Mult (c1,c2)  -> prepare_op (fun e1 e2 -> Mult (e1, e2)) c1 c2
        | Leq  (c1,c2)  -> prepare_op (fun e1 e2 -> Leq  (e1, e2)) c1 c2
        | Eq   (c1,c2)  -> prepare_op (fun e1 e2 -> Eq   (e1, e2)) c1 c2
        | Lt   (c1,c2)  -> prepare_op (fun e1 e2 -> Lt   (e1, e2)) c1 c2
        | IfThenElse0 (c1,c2) -> prepare_op (fun e1 e2 -> IfThenElse0 (e2, e1)) c2 c1
        
        | MapAccess (mapn, inv, outv, init_calc) ->
           let (sinv,soutv) = (sanitize_vars inv,sanitize_vars outv) in
           (* Determine slice or singleton.
            * singleton: no in vars, and fully bound out vars. *)
           let bound_outv = Util.ListAsSet.inter soutv theta_vars in
           let full_agg = ((List.length bound_outv) = (List.length soutv)) in
           let singleton = (List.length inv = 0) && full_agg in
           
           (* Use map scope for lhs vars during recursive prepare for initial
            * value calculus. *)
           let init_lhs_vars =
             Util.ListAsSet.union (Util.ListAsSet.union theta_vars inv) soutv in
           
           let (init_ecalc, patterns) =
              save_counter (fun () -> 
                 prepare_calc mapn init_lhs_vars theta_vars (fst init_calc))
           in
           let new_patterns = 
              if (List.length soutv) = (List.length bound_outv) then patterns
              else merge_pattern_maps patterns (singleton_pattern_map
                      (mapn, make_out_pattern soutv bound_outv)) in
           let new_init_agg_meta = (update_mapn^"_init_"^mapn, full_agg) in
           let new_init_meta = let (x,_,y,z) =
              M3P.get_meta init_ecalc in (x,bound_outv,y,z) in
           let new_init_aggecalc =
              (((M3P.get_calc init_ecalc), new_init_meta), new_init_agg_meta)
           in
           let new_incr_meta = (prepare(), [], singleton, false) in
           let r = (MapAccess(mapn, sinv, soutv, new_init_aggecalc), new_incr_meta)
           in (r, new_patterns)
        
   in

   let prepare_stmt theta_vars (stmt : stmt_t) : (M3P.pstmt_t * pattern_map) =

      let ((lmapn, linv, loutv, init_calc), (incr_calc,_),_) = stmt in
      let (slinv, sloutv) = (sanitize_vars linv,sanitize_vars loutv) in
      let partition v1 v2 =
         (Util.ListAsSet.inter v1 v2, Util.ListAsSet.diff v1 v2) in
      let (bound_inv, loop_inv) = partition slinv theta_vars in
      let (bound_outv, loop_outv) = partition sloutv theta_vars in
      
      (* For compile_pstmt_loop, extend with loop in vars *)
      let theta_w_loopinv = Util.ListAsSet.union theta_vars loop_inv in
      let theta_w_lhs = Util.ListAsSet.union
         (Util.ListAsSet.union theta_vars slinv) sloutv
      in
      let full_agg = (List.length loop_outv) = 0 in 

      (* Checking bigsum vars for slices is now done locally by passing down
       * LHS vars through M3 preparation. *)
      let init_ext = (Util.ListAsSet.diff sloutv (calc_schema (fst init_calc))) in
      
      (* Set up top-level extensions for an entire incr/init RHS.
       * Incr M3 is extended by bound out variables.
       * Init M3 is extended by LHS out vars that do not appear in the RHS out vars. *)
      let prepare_stmt_ext name_suffix calc ext ext_theta =
         let calc_theta_vars = Util.ListAsSet.union theta_w_loopinv
            (if ext_theta then ext else []) in
         let (c, patterns) =
            prepare_calc lmapn theta_w_lhs calc_theta_vars calc in
         let new_c_aggmeta = (lmapn^name_suffix, full_agg) in
         let new_c_meta = let (x,_,y,z) = M3P.get_meta c in (x,ext,y,z) in
         let new_c = ((M3P.get_calc c, new_c_meta), new_c_aggmeta) in
            (*print_endline ("singleton="^(string_of_bool (M3P.get_singleton c))^
                           " calc="^(pcalc_to_string (M3P.get_calc c)));*)
            (new_c, patterns) 
      in

      let (init_ca, init_patterns) = prepare_stmt_ext "_init" (fst init_calc) init_ext true in
      let (incr_ca, incr_patterns) = prepare_stmt_ext "_incr" incr_calc bound_outv false in

      let pstmtmeta = loop_inv in 
      let pstmt = ((lmapn, slinv, sloutv, init_ca), incr_ca, pstmtmeta) in

      let extra_patterns =
         let extras =
            (if (List.length bound_inv) = (List.length slinv) then []
             else [(lmapn, (make_in_pattern slinv bound_inv))])@
            (if (List.length bound_outv) = (List.length sloutv) then []
             else [(lmapn, (make_out_pattern sloutv bound_outv))])
         in List.fold_left add_pattern (empty_pattern_map()) extras
      in

      let patterns = List.fold_left merge_pattern_maps (empty_pattern_map())
        ([ init_patterns; incr_patterns ]@[extra_patterns])
      in
         (pstmt, patterns)
   in

   let prepare_block (trig_args : var_t list) (bl : stmt_t list)
         : (M3P.pstmt_t list * pattern_map) =
      let bl_pat_l = List.map (prepare_stmt trig_args) bl in
      let (pbl, patterns_l) = List.split bl_pat_l in
      let patterns = List.fold_left
         merge_pattern_maps (empty_pattern_map()) patterns_l
      in (pbl, patterns)
   in

   let prepare_trig (t : trig_t) : (M3P.ptrig_t * pattern_map) =
      let (ev,rel,args,block) = t in
      let sargs = sanitize_vars args in
      let (pblock, patterns) = prepare_block sargs block in
         ((ev, rel, sargs, pblock), patterns)
   in
   let blocks_maps_l = List.map prepare_trig triggers in
   let (pblocks, pms) = List.split blocks_maps_l in
      (pblocks, List.fold_left merge_pattern_maps (empty_pattern_map()) pms)

(* M3 compiler, functorized by a code generator *)
module Make = functor(CG : M3Codegen.CG) ->
struct

open CG

let rec compile_pcalc patterns (incr_ecalc) : code_t = 
   let compile_op ecalc op e1 e2 : code_t =
      let aux ecalc = (calc_schema ecalc, M3P.get_extensions ecalc,
                         compile_pcalc patterns ecalc) in
      let (outv1, theta_ext, ce1) = aux e1 in
      let (outv2, schema_ext, ce2) = aux e2 in
      let schema = Util.ListAsSet.union outv1 outv2 in
         begin match (M3P.get_singleton ecalc, M3P.get_singleton e1, M3P.get_singleton e2) with
          | (true, false, _) | (true, _, false) | (false, true, true) ->
             failwith "invalid parent singleton"

          | (true, _, _) -> op_singleton_expr op ce1 ce2
          
          | (_, true, false) -> op_rslice_expr op outv2 schema schema_ext ce1 ce2
          
          | (_, false, true) ->
             if M3P.get_product ecalc then op_lslice_product_expr op outv2 ce1 ce2
             else op_lslice_expr op outv1 outv2 schema theta_ext schema_ext ce1 ce2 

          | (_, false, false) ->
             if M3P.get_product ecalc then op_slice_product_expr op ce1 ce2
             else op_slice_expr op outv1 outv2 schema theta_ext schema_ext ce1 ce2
         end
   in
   let ccalc : code_t =
      match (M3P.get_calc incr_ecalc) with
        MapAccess(mapn, inv, outv, init_aggecalc) ->
            let cinit = compile_pcalc2 patterns
               (M3P.get_agg_meta init_aggecalc) outv (M3P.get_ecalc init_aggecalc) in
            let out_patterns = get_out_patterns patterns mapn in
            (* Note: we extend theta for this map access' init value comp
             * with bound out vars, thus we can use the extension to find
             * bound vars for the partial key here *)
            let patv = M3P.get_extensions (M3P.get_ecalc init_aggecalc) in
            let pat = List.map (index outv) patv in
            (* code that returns the initial value slice *)
            let init_val_code =
               (*print_endline ("generating init lookup for "^mapn^" "^
                              (vars_to_string inv)^" "^
                              (vars_to_string outv)^" "^
                              (string_of_bool (M3P.get_singleton (get_ecalc init_aggecalc))));*) 
               if (M3P.get_singleton (M3P.get_ecalc init_aggecalc)) ||
                  (M3P.get_full_agg (M3P.get_agg_meta init_aggecalc))
               then singleton_init_lookup mapn inv out_patterns outv cinit
               else slice_init_lookup mapn inv out_patterns cinit
            in
            (* code that does the final stage of the lookup on the slice *)
            if M3P.get_singleton incr_ecalc then
               singleton_lookup mapn inv outv init_val_code
            else slice_lookup mapn inv pat patv init_val_code 

      | Add (c1, c2) -> compile_op incr_ecalc CG.add_op  c1 c2
      | Mult(c1, c2) -> compile_op incr_ecalc CG.mult_op c1 c2
      | Lt  (c1, c2) -> compile_op incr_ecalc CG.lt_op   c1 c2
      | Leq (c1, c2) -> compile_op incr_ecalc CG.leq_op  c1 c2
      | Eq  (c1, c2) -> compile_op incr_ecalc CG.eq_op   c1 c2

      | IfThenElse0(c1, c2) ->
           compile_op incr_ecalc CG.ifthenelse0_op c2 c1

      | Const(i)   ->
         if M3P.get_singleton incr_ecalc then (const i)
         else failwith "invalid constant singleton"

      | Var(x)     ->
         if M3P.get_singleton incr_ecalc then (singleton_var x) else slice_var x
      
      in
      let cdebug = debug_expr incr_ecalc
      in debug_sequence cdebug ccalc


(* Optimizations:
 * -- aggregates blindy over entire slice for fully bound lhs_outv 
 * -- skips aggregating when rhs_outv = lhs_outv *)
and compile_pcalc2 patterns agg_meta lhs_outv ecalc : code_t =
   let rhs_outv = calc_schema ecalc in
   (* project slice w/ rhs schema to lhs schema, extending by out vars that
    * are bound. *)
   let rhs_ext = M3P.get_extensions ecalc in
   let rhs_projection = Util.ListAsSet.inter rhs_outv lhs_outv in
   let rhs_pattern = List.map (index rhs_outv) rhs_projection in
   let ccalc = compile_pcalc patterns ecalc in
      if M3P.get_singleton ecalc then
         let cdebug = debug_singleton_rhs_expr lhs_outv in
         singleton_expr ccalc cdebug
      else
         let cdebug = debug_slice_rhs_expr rhs_outv in
         if rhs_outv = lhs_outv then direct_slice_expr ccalc cdebug
         else if M3P.get_full_agg agg_meta then full_agg_slice_expr ccalc cdebug
         else slice_expr rhs_pattern rhs_projection lhs_outv rhs_ext ccalc cdebug


(* Optimizations: handles
 * -- current_slice singleton
 * -- delta_slice singleton, only if all map accesses are singletons, i.e.
 *    no bigsum vars, all out vars of map accesses are bound, and no in vars
 *    in any maps (otherwise there may be initial values). *)
let compile_pstmt patterns
   ((lhs_mapn, lhs_inv, lhs_outv, init_aggecalc), incr_aggecalc, _)
      : code_t
   =
   let aux aggecalc : code_t =
      (*let singleton = M3P.get_singleton (get_ecalc aggecalc) in
      print_endline ((if singleton then "singleton" else "slice")^
                     " calc="^(pcalc_to_string (M3P.get_calc (get_ecalc aggecalc))));*)
      compile_pcalc2 patterns (M3P.get_agg_meta aggecalc) lhs_outv (M3P.get_ecalc aggecalc)
   in
   let (cincr, cinit) = (aux incr_aggecalc, aux init_aggecalc) in
   let init_ext = M3P.get_extensions (M3P.get_ecalc init_aggecalc) in
   let init_value_code =
      let cinit_debug = debug_rhs_init() in
      if (M3P.get_singleton (M3P.get_ecalc init_aggecalc)) ||
         (M3P.get_full_agg (M3P.get_agg_meta init_aggecalc))
      then singleton_init cinit cinit_debug
      else slice_init lhs_outv init_ext cinit cinit_debug
   in
   let cdebug = debug_stmt lhs_mapn lhs_inv lhs_outv in
      if (M3P.get_singleton (M3P.get_ecalc incr_aggecalc)) ||
         (M3P.get_full_agg (M3P.get_agg_meta incr_aggecalc))
      then singleton_update lhs_outv cincr init_value_code cdebug
      else slice_update cincr init_value_code cdebug


let compile_pstmt_loop patterns trig_args pstmt : code_t =
   let ((lhs_mapn, lhs_inv, lhs_outv, _), incr_aggecalc, stmt_meta) = pstmt in
   let cstmt = compile_pstmt patterns pstmt in
   let patv = Util.ListAsSet.inter lhs_inv trig_args in
   let pat = List.map (index lhs_inv) patv in
   let direct = (List.length patv) = (List.length lhs_inv) in 
   let map_out_patterns = get_out_patterns patterns lhs_mapn in
   let lhs_ext = M3P.get_inv_extensions stmt_meta in
   (* Output pattern for partitioning *)
   (*
   let out_patv = Util.ListAsSet.inter lhs_outv trig_args in
   let out_pat = List.map (index lhs_outv) out_patv  in
   *)
   let db_update_code =
      if (M3P.get_singleton (M3P.get_ecalc incr_aggecalc)) ||
         (M3P.get_full_agg (M3P.get_agg_meta incr_aggecalc))
      then db_singleton_update lhs_mapn lhs_outv map_out_patterns cstmt
      else db_slice_update lhs_mapn cstmt
   in statement lhs_mapn lhs_inv lhs_ext patv pat direct db_update_code

let compile_ptrig (ptrig, patterns) =
   let aux ptrig =
      let (event, rel, trig_args, pblock) = ptrig in
      let aux2 = compile_pstmt_loop patterns trig_args in
      let cblock = List.map aux2 pblock in
      trigger event rel trig_args cblock
   in List.map aux ptrig

let compile_query (((schema,m3prog):M3.prog_t), 
                   (sources:M3.relation_input_t list)) 
                  (toplevel_queries:string list)
                  (out_file_name:Util.GenericIO.out_t) =
   let prepared_prog = prepare_triggers m3prog clean_var_name in
   let patterns = snd prepared_prog in
   let ctrigs = compile_ptrig prepared_prog in
   let sources_and_adaptors =
      List.fold_left (fun acc (s,f,rel,a) ->
         if List.mem_assoc (s,f) acc then
            let existing = List.assoc (s,f) acc
            in ((s,f), ((rel,a)::existing))::(List.remove_assoc (s,f) acc)
         else ((s,f),[rel,a])::acc) [] sources in
   let csource =
      List.map (fun ((s,f),ra) -> CG.source s f ra) sources_and_adaptors in
   Util.GenericIO.write out_file_name 
     (fun out_file -> output (main schema patterns csource ctrigs
                              toplevel_queries) out_file; 
                      output_string out_file "\n");
   
end
