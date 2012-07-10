(**
   An internally library of reference implementations of External functions.  
   
   These functions are defined through the Functions module
*)

open Types
open Constants
open Functions
;;

(**
   Floating point division.  
    - [fp_div] num returns [1/(float)num]
    - [fp_div] a;b returns [(float)a / (float)b]
*)
let fp_div (arglist:const_t list) (ftype:type_t) =
   begin match arglist with
      | [v]     -> Constants.Math.div1 ftype v
      | [v1;v2] -> Constants.Math.div2 ftype v1 v2
      | _ -> invalid_args "fp_div" arglist ftype 
   end
;; declare_std_function "/" fp_div 
   (function | (([_;_] as x) | ([_] as x)) -> (escalate (TFloat::x))
             | _ -> inference_error ());;

(**
   Bounded fan-in list minimum.
    - [min_of_list] elems returns the smallest number in the list.
*)
let min_of_list (arglist:const_t list) (ftype:type_t) =
   let (start,cast_type) = 
      match ftype with TInt -> (CInt(max_int), TInt)
                     | TAny 
                     | TFloat -> (CFloat(max_float), TFloat)
                     | _ -> (invalid_args "listmin" arglist ftype, TAny)
   in List.fold_left min start (List.map (Constants.type_cast cast_type) 
                                         arglist)
;; declare_std_function "listmin" min_of_list (fun x -> escalate (TInt::x))

(**
   Bounded fan-in list maximum.
    - [max_of_list] elems returns the largest number in the list.
*)
let max_of_list (arglist:const_t list) (ftype:type_t) =
   let (start,cast_type) = 
      match ftype with TInt -> (CInt(min_int), TInt)
                     | TAny 
                     | TFloat -> (CFloat(min_float), TFloat)
                     | _ -> (invalid_args "listmax" arglist ftype, TAny)
   in List.fold_left max start (List.map (Constants.type_cast cast_type) 
                                         arglist)
;; declare_std_function "listmax" max_of_list (fun x -> escalate (TInt::x)) ;;

(**
   Date part extraction
    - [date_part] 'year';date returns the year of a date as an int
    - [date_part] 'month';date returns the month of a date as an int
    - [date_part] 'day';date returns the day of the month of a date as an int
*)
let date_part (arglist:const_t list) (ftype:type_t) =
   match arglist with
      | [CString(part);  CDate(y,m,d)] -> 
         begin match String.uppercase part with
            | "YEAR"  -> CInt(y)
            | "MONTH" -> CInt(m)
            | "DAY"   -> CInt(d)
            | _       -> invalid_args "date_part" arglist ftype
         end
      | _ -> invalid_args "date_part" arglist ftype
;; declare_std_function "date_part" date_part 
               (function [TString; TDate] -> TInt | _-> inference_error ());;

(**
   Regular expression matching
   - [regexp_match] regex_str; str returns true if regex_str matches str
*)
let regexp_match (arglist:const_t list) (ftype:type_t) =
   match arglist with
      | [CString(regexp); CString(str)] ->
         Debug.print "LOG-REGEXP" (fun () -> "/"^regexp^"/ =~ '"^str^"'");
         if Str.string_match (Str.regexp regexp) str 0
         then CInt(1) else CInt(0)
      | _ -> invalid_args "regexp_match" arglist ftype
;; declare_std_function "regexp_match" regexp_match
               (function [TString; TString] -> TInt | _-> inference_error ()) ;;

(**
   Substring
   - [substring] [str; start; len] returns the substring of str from 
     start to start+len
*)
let substring (arglist:const_t list) (ftype:type_t) =
   match arglist with
      | [CString(str); CInt(start); CInt(len)] ->
            CString(String.sub str start len)
      | _ -> invalid_args "substring" arglist ftype
;; declare_std_function "substring" substring
         (function [TString; TInt; TInt] -> TString | _-> inference_error ()) ;;

(** 
   Type casting -- cast to a particular type
*)
let cast (arglist:const_t list) (ftype:type_t) = 
   let arg = match arglist with 
      [a] -> a | _ -> invalid_args "cast" arglist ftype 
   in
   begin try 
      begin match ftype with
         | TInt -> CInt(Constants.int_of_const arg)
         | TFloat -> CFloat(Constants.float_of_const arg)
         | TDate -> 
            begin match arg with
               | CDate _ -> arg
               | CString(s) -> parse_date s
               | _ -> invalid_args "cast" arglist ftype
            end
         | TString -> CString(Constants.string_of_const arg)
         | _ -> invalid_args "cast" arglist ftype
      end
   with Failure msg -> 
      raise (InvalidFunctionArguments("Error while casting to "^
                  (string_of_type ftype)^": "^msg))
   end
;; List.iter (fun (t, valid_in) ->
      declare_std_function ("cast_"^(Types.string_of_type t))
                           cast
                           (function [a] when List.mem a valid_in -> t
                                   | _ -> inference_error ())
   ) [
      TInt,     [TFloat; TInt; TString]; 
      TFloat,   [TFloat; TInt; TString]; 
      TDate,    [TDate; TString]; 
      TString,  [TInt; TFloat; TDate; TString; TBool];
     ]
;;