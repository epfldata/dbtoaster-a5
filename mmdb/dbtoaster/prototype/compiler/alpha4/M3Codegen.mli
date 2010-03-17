open M3Common
open M3Common.Prepared
open M3Common.Patterns

(* Note this interface doesn't distinguish Singleton, UpdateSingleton etc. 
 * types as with the current compiled_code type. Since code_t here is an
 * abstract type, it is up to the code generator to decide how to represent
 * code, and perform any subsequent checking for invalid code arguments.  *)

module type CG =
sig
   type op_t
   type code_t
   type debug_code_t
   type db_t

   (* Debugging helpers *)
   val debug_sequence: debug_code_t -> code_t -> code_t
   val debug_expr : pcalc_t -> debug_code_t

   (* lhs_outv *)
   val debug_singleton_rhs_expr : var_t list -> debug_code_t
   
   (* rhs_outv *)
   val debug_slice_rhs_expr : var_t list -> debug_code_t

   val debug_rhs_init : unit -> debug_code_t

   (* lhs_mapn, lhs_inv, lhs_outv *)
   val debug_stmt : string -> var_t list -> var_t list -> debug_code_t

   val const: const_t -> code_t
   val singleton_var: var_t -> code_t
   val slice_var: var_t -> code_t
   (* TODO: remove nulls *)
   val null: unit -> code_t

   val add_op  : op_t
   val mult_op : op_t
   val eq_op   : op_t
   val lt_op   : op_t
   val leq_op  : op_t
   val ifthenelse0_op : op_t

   val op_singleton_expr: op_t -> code_t -> code_t -> code_t 
   
   (* op, outv1, outv2, schema, theta_ext, schema_ext, lhs code, rhs code ->
    * op expr code *)
   val op_slice_expr: op_t ->
      var_t list -> var_t list -> var_t list -> var_t list -> var_t list ->
      code_t -> code_t -> code_t

   val op_slice_product_expr: op_t -> code_t -> code_t -> code_t

   (* op, outv1, outv2, schema, theta_ext, schema_ext, lhs code, rhs code ->
    * op expr code *)
   val op_lslice_expr: op_t ->
      var_t list -> var_t list -> var_t list -> var_t list -> var_t list ->
      code_t -> code_t -> code_t

   (* op, outv2, lhs code, rhs code -> op expr code *)
   val op_lslice_product_expr: op_t -> var_t list -> code_t -> code_t -> code_t
   
   (* op, outv2, schema, schema_ext, lhs code, rhs code -> op expr code *)
   val op_rslice_expr: op_t ->
      var_t list -> var_t list -> var_t list -> code_t -> code_t -> code_t

   (* TODO: this always returns a slice *)
   (* mapn, inv, out_patterns, outv, init rhs expr -> init lookup code *)
   val singleton_init_lookup:
      string -> var_t list -> int list list -> var_t list -> code_t -> code_t
   
   (* mapn, inv, out_patterns, init rhs expr -> init lookup code *)
   val slice_init_lookup:
      string -> var_t list -> int list list -> code_t -> code_t

   (* mapn, inv, outv, init lookup code -> map lookup code *)
   val singleton_lookup: string -> var_t list -> var_t list -> code_t -> code_t
   
   (*  mapn, inv, pat, patv, init lookup code -> map lookup code *)
   val slice_lookup: string -> var_t list -> int list -> var_t list -> code_t -> code_t 

   (* M3 RHS expr generation *)
 
   (* m3 expr code, debug code -> m3 rhs expr code *)
   val singleton_expr : code_t -> debug_code_t -> code_t

   (* m3 expr code, debug code -> m3 rhs expr code *)
   val direct_slice_expr : code_t -> debug_code_t -> code_t

   (* TODO: this does not capture change from slice to singleton *)
   (* m3 expr code, debug code -> m3 rhs expr code *)
   val full_agg_slice_expr : code_t -> debug_code_t -> code_t

   (* rhs_pattern, rhs_projection, lhs_outv, rhs_ext,
    * m3 expr code, debug code -> m3 rhs expr code *)
   val slice_expr : int list -> var_t list -> var_t list -> var_t list ->
      code_t -> debug_code_t -> code_t

   (* Initial value computation for statements *) 
   (* TODO: these compute a single value, and should be reflected in code_t *)

   (* init calc code, debug code -> init code *)
   val singleton_init : code_t -> debug_code_t -> code_t

   (* lhs_outv, init_ext, init calc code, debug code -> init code *)
   val slice_init : var_t list -> var_t list -> code_t -> debug_code_t -> code_t

   (* Incremental statement evaluation *)
   
   (* TODO: the generated code here takes a slice/singleton argument
    * and this is not reflected by the return type *)
   (* lhs_outv, incr_m3 code, init value code, debug code -> update code *)
   val singleton_update : var_t list -> code_t -> code_t -> debug_code_t -> code_t  
   
   (* incr_m3 code, init value code, debug code -> update code *) 
   val slice_update : code_t -> code_t -> debug_code_t -> code_t

   (* Incremental update code generation *)
   (* TODO: the generated code takes a inv_img and an inv slice, and returns unit.
    * This should be reflected in the resulting code type. *)

   (* lhs_mapn, lhs_outv, map out patterns, singleton eval code -> db update code*)
   val db_singleton_update :
      string -> var_t list -> int list list -> code_t -> code_t

   (* lhs_mapn, slice eval code -> db update code *)
   val db_slice_update : string -> code_t -> code_t

   (* Top-level M3 program structure *)

   (* TODO: this code returns unit, and should be reflected in resulting code_t *)
   (* lhs_mapn, lhs_inv, lhs_ext, patv, pat, direct, db update code -> statement code *)
   val statement :
      string -> var_t list -> var_t list -> var_t list -> int list -> bool ->
      code_t -> code_t

   (* trigger args, statement code block -> trigger code *)
   val trigger : var_t list -> code_t list -> code_t
   
   (* Interpreter methods *)
   val eval_trigger : code_t -> const_t list -> db_t -> unit
end
