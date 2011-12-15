(*
   A ring of values (i.e., operations for doing arithmetic over constants),
   variables, and functions thereof.
   
   This approach nearly matches the syntax given in the SIGMOD submission, 
   except that we don't include singleton sums.  These can be effected by 
   computing a product with a definition term.  Doing so saves us from having
   a mutual recursion between ValueRing and CalcRing (which in turn saves 
   Oliver's sanity), and ensures that the delta of a value is always 0.
   
   Note that the functions defined herein are assumed to be deterministic and
   have no side effects.
*)

open Types

type 'term arithmetic_leaf_t =
   | AConst of const_t
   | AVar   of var_t
   | AFn    of string * 'term list * type_t

module rec 
ValueBase : sig
      type t = ValueRing.expr_t arithmetic_leaf_t
      val  zero: t
      val  one: t
   end = struct
      type t = ValueRing.expr_t arithmetic_leaf_t
      let zero = AConst(CInt(0))
      let one  = AConst(CInt(1))
   end and
ValueRing : Ring.Ring with type leaf_t = ValueBase.t
         = Ring.Make(ValueBase)

type value_leaf_t = ValueRing.leaf_t
type value_t      = ValueRing.expr_t

(**** Constructors ****)
let mk_bool   (b:bool   ):value_t = ValueRing.mk_val (AConst(CBool(b)))
let mk_int    (i:int    ):value_t = ValueRing.mk_val (AConst(CInt(i)))
let mk_float  (f:float  ):value_t = ValueRing.mk_val (AConst(CFloat(f)))
let mk_string (s:string ):value_t = ValueRing.mk_val (AConst(CString(s)))
let mk_const  (c:const_t):value_t = ValueRing.mk_val (AConst(c))
let mk_var    (v:var_t  ):value_t = ValueRing.mk_val (AVar(v))

(**** Stringifiers ****)
let rec string_of_value_leaf (leaf:value_leaf_t): string =
   begin match leaf with
      | AConst(c) -> string_of_const c
      | AVar(v)   -> string_of_var v
      | AFn(fname,fargs,ftype) ->
         fname^"("^(ListExtras.string_of_list string_of_value fargs)^")"
   end
and string_of_value (a_value:value_t): string = 
   ValueRing.fold
      (fun sum_list  -> "("^(String.concat " + " sum_list )^")")
      (fun prod_list -> "("^(String.concat " * " prod_list)^")")
      (fun neg_term  -> "(-1*"^neg_term^")")
      string_of_value_leaf
      a_value

(**** Info ****)
let rec vars_of_value (v: value_t): var_t list =
   ValueRing.fold
      ListAsSet.multiunion
      ListAsSet.multiunion
      (fun x -> x)
      (fun x -> begin match x with
         | AConst(_) -> []
         | AVar(v) -> [v]
         | AFn(_,tl,_) -> ListAsSet.multiunion (List.map vars_of_value tl)
      end)
      v

(**** Typechecker ****)

let rec type_of_value ?(default_type = TAny) (a_value: value_t): type_t =
   ValueRing.fold
      (escalate_type_list ~opname:"+")
      (escalate_type_list ~opname:"*")
      (fun t -> match t with | TInt | TFloat -> t 
        | _ -> failwith ("Can not compute type of -1 * "^(string_of_type t)))
      (fun leaf -> match leaf with 
         | AConst(c)  -> type_of_const c
         | AVar(_,vt) -> vt
         | AFn(_,fn_args,fn_type) ->
            List.iter (fun x -> let _ = type_of_value 
                                             ~default_type:default_type 
                                             x in ())
                      fn_args;
            fn_type
      )
      a_value

(**** Arithmetic ****)
let binary_op (b_op: bool   -> bool   -> bool)
              (i_op: int    -> int    -> int)
              (f_op: float  -> float  -> float)
              (a: const_t) (b: const_t): const_t =
   begin match (a,b) with
      | (CBool(av),  CBool(bv)) -> 
         CBool(b_op av bv)
      | (CBool(_),   CInt(_))
      | (CInt(_),    CBool(_)) 
      | (CInt(_),    CInt(_)) -> 
         CInt(i_op (int_of_const a) (int_of_const b))
      | (CFloat(_), (CBool(_)|CInt(_)|(CFloat(_))))
      | ((CBool(_)|CInt(_)), CFloat(_)) ->
         CFloat(f_op (float_of_const a) (float_of_const b))
      | (CString(_), _) | (_, CString(_)) -> 
         failwith "Binary math op over a string"
   end

let sum  = binary_op ( fun x->failwith "sum of booleans" ) ( + ) ( +. )
let suml = List.fold_left sum (CInt(0))
let prod = binary_op ( && ) ( * ) ( *. )
let prodl= List.fold_left prod (CInt(1))
let neg  = binary_op (fun x y -> failwith "Negation of a boolean") 
                     ( * ) ( *. ) (CInt(-1))
let div1 a   = binary_op (fun x->failwith "Dividing a boolean 1") 
                         (/) (/.) (CInt(1)) a
let div2 a b = binary_op (fun x->failwith "Dividing a boolean 2")
                         (/) (/.) a b

(**** Functions ****)
let arithmetic_functions: 
   (type_t * (const_t list -> const_t)) StringMap.t ref = ref StringMap.empty

let declare_arithmetic_function (name:string) (out_type:type_t) 
                                (fn:const_t list -> const_t): unit =
   arithmetic_functions := 
      StringMap.add name (out_type, fn) !arithmetic_functions
;;
declare_arithmetic_function "/" TFloat 
   (fun arglist -> 
      match arglist with
         | [v] -> div1 v
         | [v1;v2] -> div2 v1 v2
         | _ ->
            failwith "Invalid arguments to division function"
   )
;;
(**** Evaluation ****)
let rec eval ?(scope=StringMap.empty) (v:value_t): const_t = 
   ValueRing.fold suml prodl neg (fun lf ->
      match lf with 
         | AConst(c) -> c
         | AVar(v,_) -> 
            if StringMap.mem v scope then StringMap.find v scope
            else failwith ("Variable "^v^" not found while evaluating arithmetic")
         | AFn(fn,fargs,_) ->
            if StringMap.mem fn !arithmetic_functions then
               let (_,fn_def) = StringMap.find fn !arithmetic_functions
               in fn_def (List.map (eval ~scope:scope) fargs)
            else failwith ("Function "^fn^" is undefined")
   ) v

let rec eval_partial ?(scope=[]) (v:value_t): value_t = 
   let merge v_op c_op (term_list:value_t list): value_t = 
      let (v, c) = List.fold_right (fun (term) (v,c) ->
         match (term, c) with
            | (ValueRing.Val(AConst(c2)), None) -> (v, Some(c2))
            | (ValueRing.Val(AConst(c2)), Some(c1)) -> (v, Some(c_op c1 c2))
            | (_,_) -> (term :: v, c)
      ) term_list ([], None) 
      in v_op ((match c with 
         | None -> [] 
         | Some(c) -> [mk_const c]
      ) @ v)
   in
   ValueRing.fold 
      (merge ValueRing.mk_sum sum)
      (merge ValueRing.mk_prod prod)
      (fun x -> merge ValueRing.mk_prod prod [mk_int (-1); x])
      (fun lf -> match lf with
         | AFn(fname, fargs, ftype) -> 
            ValueRing.mk_val 
               (AFn(fname, List.map (eval_partial ~scope:scope) fargs, ftype))
         | AVar(vn, vt) ->
            if List.mem_assoc (vn,vt) scope 
               then (List.assoc (vn,vt) scope)
               else ValueRing.mk_val lf
         | AConst(c) -> ValueRing.mk_val lf
      )
      v
   
   