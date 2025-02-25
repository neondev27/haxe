(*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *)

open Ast
open DisplayTypes.DisplayMode
open Common
open Type
open Typecore
open Resolution
open Error
open Globals

module InterpImpl = Eval (* Hlmacro *)

module Interp = struct
	module BuiltApi = MacroApi.MacroApiImpl(InterpImpl)
	include InterpImpl
	include BuiltApi
end


module HxbWriterConfigReaderEval = HxbWriterConfig.WriterConfigReader(EvalDataApi.EvalReaderApi)
module HxbWriterConfigWriterEval = HxbWriterConfig.WriterConfigWriter(EvalDataApi.EvalWriterApi)

let macro_interp_cache = ref None

let safe_decode com v expected t p f =
	let raise_decode_error s =
		let path = [dump_path com;"decoding_error"] in
		let ch = Path.create_file false ".txt" [] path  in
		let errors = Interp.handle_decoding_error (output_string ch) v t in
		List.iter (fun (s,i) -> Printf.fprintf ch "\nline %i: %s" i s) (List.rev errors);
		close_out ch;
		raise_typing_error (Printf.sprintf "%s (see %s.txt for details)" s (String.concat "/" path)) p
	in

	try f () with
		| EvalContext.RunTimeException (VString emsg,_,_) ->
			raise_decode_error (Printf.sprintf "Eval runtime exception: %s" emsg.sstring)
		| MacroApi.Invalid_expr ->
			raise_decode_error (Printf.sprintf "Expected %s but got %s" expected (Interp.value_string v))


let macro_timer com l =
	Timer.timer (if Common.defined com Define.MacroTimes then ("macro" :: l) else ["macro"])

let typing_timer ctx need_type f =
	let t = Timer.timer ["typing"] in
	let ctx = if need_type && ctx.pass < PTypeField then begin
		enter_field_typing_pass ctx.g ("typing_timer",[]);
		TyperManager.clone_for_expr ctx ctx.e.curfun false
	end else
		ctx
	in

	let old = ctx.com.error_ext in
	let restore_report_mode = disable_report_mode ctx.com in
	let restore_field_state = TypeloadFunction.save_field_state ctx in
	ctx.com.error_ext <- (fun err -> raise_error { err with err_from_macro = true });

	let exit() =
		t();
		ctx.com.error_ext <- old;
		restore_field_state ();
		restore_report_mode ();
	in
	try
		let r = f ctx in
		exit();
		r
	with Error err ->
		exit();
		Interp.compiler_error err
	| WithTypeError err ->
		exit();
		Interp.compiler_error err
	| e ->
		exit();
		raise e

let make_macro_com_api com mcom p =
	let parse_metadata s p =
		try
			match ParserEntry.parse_string Grammar.parse_meta com.defines s null_pos raise_typing_error false with
			| ParseSuccess(meta,_,_) -> meta
			| ParseError(_,_,_) -> raise_typing_error "Malformed metadata string" p
		with _ ->
			raise_typing_error "Malformed metadata string" p
	in
	{
		MacroApi.pos = p;
		get_com = (fun () -> com);
		get_macro_com = (fun () -> mcom);
		get_macro_stack = (fun () ->
			let envs = Interp.call_stack (Interp.get_eval (Interp.get_ctx ())) in
			let envs = match envs with
				| _ :: envs -> envs (* Skip call to getMacroStack() *)
				| _ -> envs
			in
			List.map (fun (env:Interp.env) -> {pfile = EvalHash.rev_hash env.env_info.pfile;pmin = env.env_leave_pmin; pmax = env.env_leave_pmax}) envs
		);
		init_macros_done = (fun () -> com.stage >= CInitMacrosDone);
		get_type = (fun s ->
			Interp.exc_string "unsupported"
		);
		resolve_type = (fun t p ->
			Interp.exc_string "unsupported"
		);
		resolve_complex_type = (fun t ->
			Interp.exc_string "unsupported"
		);
		get_module = (fun s ->
			Interp.exc_string "unsupported"
		);
		include_module = (fun s ->
			Interp.exc_string "unsupported"
		);
		after_init_macros = (fun f ->
			com.callbacks#add_after_init_macros (fun () ->
				let t = macro_timer com ["afterInitMacros"] in
				f ();
				t()
			)
		);
		after_typing = (fun f ->
			com.callbacks#add_after_typing (fun tl ->
				let t = macro_timer com ["afterTyping"] in
				f tl;
				t()
			)
		);
		on_generate = (fun f b ->
			(if b then com.callbacks#add_before_save else com.callbacks#add_after_save) (fun() ->
				let t = macro_timer com ["onGenerate"] in
				f (List.map type_of_module_type com.types);
				t()
			)
		);
		after_generate = (fun f ->
			com.callbacks#add_after_generation (fun() ->
				let t = macro_timer com ["afterGenerate"] in
				f();
				t()
			)
		);
		on_type_not_found = (fun f ->
			com.load_extern_type <- com.load_extern_type @ ["onTypeNotFound",fun path p ->
				let td = f (s_type_path path) in
				if td = Interp.vnull then
					None
				else
					let (pack,name),tdef,p = Interp.decode_type_def td in
					Some (pack,[tdef,p])
			];
		);
		parse_string = (fun s p inl ->
			let old = com.error_ext in
			com.error_ext <- (fun err -> raise_error { err with err_from_macro = true });
			let exit() = com.error_ext <- old in

			try
				let r = match ParserEntry.parse_expr_string com.defines s p raise_typing_error inl with
					| ParseSuccess(data,true,_) when inl -> data (* ignore errors when inline-parsing in display file *)
					| ParseSuccess(data,_,_) -> data
					| ParseError _ -> Interp.exc_string "Invalid expression"
				in
				exit();
				r
			with Error err ->
				exit();
				Interp.compiler_error err
			| WithTypeError err ->
				exit();
				Interp.compiler_error err
			| e ->
				exit();
				raise e
		);
		parse = (fun entry s ->
			match ParserEntry.parse_string entry com.defines s null_pos raise_typing_error false with
			| ParseSuccess(r,_,_) -> r
			| ParseError(_,(msg,p),_) -> Parser.error msg p
		);
		type_expr = (fun e ->
			Interp.exc_string "unsupported"
		);
		flush_context = (fun f ->
			Interp.exc_string "unsupported"
		);
		store_typed_expr = (fun te ->
			let p = te.epos in
			snd (Typecore.store_typed_expr com te p)
		);
		allow_package = (fun v -> Common.allow_package com v);
		set_js_generator = (fun gen ->
			com.js_gen <- Some (fun() ->
				Path.mkdir_from_path com.file;
				let js_ctx = Genjs.alloc_ctx com (get_es_version com) in
				let t = macro_timer com ["jsGenerator"] in
				gen js_ctx;
				t()
			);
		);
		get_local_type = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_expected_type = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_call_arguments = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_local_method = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_local_using = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_local_imports = (fun() ->
			Interp.exc_string "unsupported"
		);
		get_local_vars = (fun () ->
			Interp.exc_string "unsupported"
		);
		get_build_fields = (fun() ->
			Interp.exc_string "unsupported"
		);
		define_type = (fun v mdep ->
			Interp.exc_string "unsupported"
		);
		define_module = (fun m types imports usings ->
			Interp.exc_string "unsupported"
		);
		module_dependency = (fun mpath file ->
			Interp.exc_string "unsupported"
		);
		current_module = (fun() ->
			null_module
		);
		format_string = (fun s p ->
			FormatString.format_string com.defines s p (fun e p -> (e,p))
		);
		cast_or_unify = (fun t e p ->
			Interp.exc_string "unsupported"
		);
		add_global_metadata = (fun s1 s2 config p ->
			let meta = parse_metadata s2 p in
			List.iter (fun (m,el,_) ->
				let m = (m,el,p) in
				com.global_metadata <- (ExtString.String.nsplit s1 ".",m,config) :: com.global_metadata;
			) meta;
		);
		add_module_check_policy = (fun sl il b ->
			Interp.exc_string "unsupported"
		);
		register_define = (fun s data -> Define.register_user_define com.user_defines s data);
		register_metadata = (fun s data -> Meta.register_user_meta com.user_metas s data);
		decode_expr = Interp.decode_expr;
		encode_expr = Interp.encode_expr;
		encode_ctype = Interp.encode_ctype;
		decode_type = Interp.decode_type;
		display_error = display_error com;
		with_imports = (fun imports usings f ->
			Interp.exc_string "unsupported"
		);
		with_options = (fun opts f ->
			Interp.exc_string "unsupported"
		);
		info = (fun ?(depth=0) msg p ->
			com.info ~depth msg p
		);
		warning = (fun ?(depth=0) w msg p ->
			com.warning ~depth w [] msg p
		);
		exc_string = Interp.exc_string;
		get_hxb_writer_config = (fun () ->
			match com.hxb_writer_config with
			| Some config ->
				HxbWriterConfigWriterEval.write_writer_config config
			| None ->
				VNull
		);
		set_hxb_writer_config = (fun v ->
			if v == VNull then
				com.hxb_writer_config <- None
			else begin
				let config = match com.hxb_writer_config with
					| Some config ->
						config
					| None ->
						let config = HxbWriterConfig.create () in
						com.hxb_writer_config <- Some config;
						config
				in
				HxbWriterConfigReaderEval.read_writer_config config v
			end
		);
	}

let make_macro_api ctx mctx p =
	let parse_metadata s p =
		try
			match ParserEntry.parse_string Grammar.parse_meta ctx.com.defines s null_pos raise_typing_error false with
			| ParseSuccess(meta,_,_) -> meta
			| ParseError(_,_,_) -> raise_typing_error "Malformed metadata string" p
		with _ ->
			raise_typing_error "Malformed metadata string" p
	in
	let com_api = make_macro_com_api ctx.com mctx.com p in
	let mk_type_path ?sub path =
		try mk_type_path ?sub path
		with Invalid_argument s -> com_api.exc_string s
	in
	{
		com_api with
		MacroApi.get_type = (fun s ->
			typing_timer ctx false (fun ctx ->
				let path = parse_path s in
				let tp = match List.rev (fst path) with
					| s :: sl when String.length s > 0 && (match s.[0] with 'A'..'Z' -> true | _ -> false) ->
						mk_type_path ~sub:(snd path) (List.rev sl,s)
					| _ ->
						mk_type_path path
				in
				try
					let m = Some (Typeload.load_instance ctx (make_ptp tp p) ParamSpawnMonos LoadAny) in
					m
				with Error { err_message = Module_not_found _; err_pos = p2 } when p == p2 ->
					None
			)
		);
		MacroApi.resolve_type = (fun t p ->
			typing_timer ctx false (fun ctx -> Typeload.load_complex_type ctx false LoadAny (t,p))
		);
		MacroApi.resolve_complex_type = (fun t ->
			typing_timer ctx false (fun ctx ->
				let rec load (t,_) =
					((match t with
					| CTPath ptp ->
						CTPath (load_path ptp)
					| CTFunction (args,ret) ->
						CTFunction (List.map load args, load ret)
					| CTAnonymous fl ->
						CTAnonymous (List.map load_cf fl)
					| CTParent t ->
						CTParent (load t)
					| CTExtend (pl, fl) ->
						CTExtend (List.map (fun ptp -> load_path ptp) pl,List.map load_cf fl)
					| CTOptional t ->
						CTOptional t
					| CTNamed (n,t) ->
						CTNamed (n, load t)
					| CTIntersection tl ->
						CTIntersection (List.map load tl)
					),p)
				and load_cf f =
					let k = match f.cff_kind with
					| FVar (t, e) -> FVar ((match t with None -> None | Some t -> Some (load t)), e)
					| FProp (n1,n2,t,e) -> FProp(n1,n2,(match t with None -> None | Some t -> Some (load t)),e)
					| FFun f ->
						FFun {
							f_params = List.map load_tparam f.f_params;
							f_args = List.map (fun (n,o,m,t,e) -> n,o,m,(match t with None -> None | Some t -> Some (load t)),e) f.f_args;
							f_type = (match f.f_type with None -> None | Some t -> Some (load t));
							f_expr = f.f_expr;
						}
					in
					{ f with cff_kind = k }
				and load_tparam ft =
					{ ft with
						tp_params = List.map load_tparam ft.tp_params;
						tp_constraints = (match ft.tp_constraints with None -> None | Some t -> Some (load t));
						tp_default = (match ft.tp_default with None -> None | Some t -> Some (load t));
					}
				and load_path ptp =
					let t = t_infos (Typeload.load_type_def ctx ptp.pos_path ptp.path) in
					let is_sub = t.mt_module.m_path <> t.mt_path in
					make_ptp {
						tpackage = fst t.mt_path;
						tname = (if is_sub then snd t.mt_module.m_path else snd t.mt_path);
						tparams = List.map (fun ct -> match ct with TPType t -> TPType (load t) | TPExpr _ -> ct) ptp.path.tparams;
						tsub = (if is_sub then Some (snd t.mt_path) else None);
					} ptp.pos_full
				in
				load t
			)
		);
		MacroApi.get_module = (fun s ->
			typing_timer ctx false (fun ctx ->
				let path = parse_path s in
				let m = List.map type_of_module_type (TypeloadModule.load_module ~origin:MDepFromMacro ctx path p).m_types in
				m
			)
		);
		MacroApi.include_module = (fun s ->
			typing_timer ctx false (fun ctx ->
				let path = parse_path s in
				ignore(TypeloadModule.load_module ~origin:MDepFromMacroInclude ctx path p)
			)
		);
		MacroApi.type_expr = (fun e ->
			typing_timer ctx true (fun ctx -> type_expr ctx e WithType.value)
		);
		MacroApi.flush_context = (fun f ->
			typing_timer ctx true (fun _ -> f ())
		);
		MacroApi.get_local_type = (fun() ->
			match ctx.c.get_build_infos() with
			| Some (mt,tl,_) ->
				Some (match mt with
					| TClassDecl c -> TInst (c,tl)
					| TEnumDecl e -> TEnum (e,tl)
					| TTypeDecl t -> TType (t,tl)
					| TAbstractDecl a -> TAbstract(a,tl)
				)
			| _ ->
				if ctx.c.curclass == null_class then
					None
				else
					Some (TInst (ctx.c.curclass,[]))
		);
		MacroApi.get_expected_type = (fun() ->
			match ctx.e.with_type_stack with
				| (WithType.WithType(t,_)) :: _ -> Some t
				| _ -> None
		);
		MacroApi.get_call_arguments = (fun() ->
			match ctx.e.call_argument_stack with
				| [] -> None
				| el :: _ -> Some el
		);
		MacroApi.get_local_method = (fun() ->
			ctx.f.curfield.cf_name;
		);
		MacroApi.get_local_using = (fun() ->
			List.map fst ctx.m.module_using;
		);
		MacroApi.get_local_imports = (fun() ->
			ctx.m.import_statements;
		);
		MacroApi.get_local_vars = (fun () ->
			ctx.f.locals;
		);
		MacroApi.get_build_fields = (fun() ->
			match ctx.c.get_build_infos() with
			| None -> Interp.vnull
			| Some (_,_,fields) -> Interp.encode_array (List.map Interp.encode_field fields)
		);
		MacroApi.define_type = (fun v mdep ->
			let cttype = mk_type_path ~sub:"TypeDefinition" (["haxe";"macro"],"Expr") in
			let mctx = (match ctx.g.macros with None -> die "" __LOC__ | Some (_,mctx) -> mctx) in
			let ttype = Typeload.load_instance mctx (make_ptp cttype p) ParamNormal LoadNormal in
			let f () = Interp.decode_type_def v in
			let m, tdef, pos = safe_decode ctx.com v "TypeDefinition" ttype p f in
			let has_native_meta = match tdef with
				| EClass d -> Meta.has Meta.Native d.d_meta
				| EEnum d -> Meta.has Meta.Native d.d_meta
				| ETypedef d -> Meta.has Meta.Native d.d_meta
				| EAbstract d -> Meta.has Meta.Native d.d_meta
				| _ -> false
			in
			let add is_macro ctx =
				let mdep = Option.map_default (fun s -> TypeloadModule.load_module ~origin:MDepFromMacro ctx (parse_path s) pos) ctx.m.curmod mdep in
				let mnew = TypeloadModule.type_module ctx.com ctx.g ~dont_check_path:(has_native_meta) m (ctx.com.file_keys#generate_virtual ctx.com.compilation_step) [tdef,pos] pos in
				mnew.m_extra.m_kind <- if is_macro then MMacro else MFake;
				add_dependency mnew mdep MDepFromMacro;
				ctx.com.module_nonexistent_lut#clear;
			in
			add false ctx;
			(* if we are adding a class which has a macro field, we also have to add it to the macro context (issue #1497) *)
			if not ctx.com.is_macro_context then match tdef with
			| EClass c when List.exists (fun cff -> (Meta.has Meta.Macro cff.cff_meta || List.mem_assoc AMacro cff.cff_access)) c.d_data ->
				add true mctx
			| _ ->
				()
		);
		MacroApi.define_module = (fun m types imports usings ->
			let types = List.map (fun v ->
				let _, tdef, pos = (try Interp.decode_type_def v with MacroApi.Invalid_expr -> Interp.exc_string "Invalid type definition") in
				tdef, pos
			) types in
			let pos = (match types with [] -> null_pos | (_,p) :: _ -> p) in
			let imports = List.map (fun (il,ik) -> EImport(il,ik),pos) imports in
			let usings = List.map (fun tp ->
				let sl = tp.tpackage @ [tp.tname] @ (match tp.tsub with None -> [] | Some s -> [s]) in
				EUsing (List.map (fun s -> s,null_pos) sl),pos
			) usings in
			let types = imports @ usings @ types in
			let mpath = Ast.parse_path m in
			begin try
				let m = ctx.com.module_lut#find mpath in
				ignore(TypeloadModule.type_types_into_module ctx.com ctx.g m types pos)
			with Not_found ->
				let mnew = TypeloadModule.type_module ctx.com ctx.g mpath (ctx.com.file_keys#generate_virtual ctx.com.compilation_step) types pos in
				mnew.m_extra.m_kind <- MFake;
				add_dependency mnew ctx.m.curmod MDepFromMacro;
				ctx.com.module_nonexistent_lut#clear;
			end
		);
		MacroApi.module_dependency = (fun mpath file ->
			let m = typing_timer ctx false (fun ctx ->
				let old_deps = ctx.m.curmod.m_extra.m_deps in
				let m = TypeloadModule.load_module ~origin:MDepFromMacro ctx (parse_path mpath) p in
				ctx.m.curmod.m_extra.m_deps <- old_deps;
				m
			) in
			add_dependency m (TypeloadCacheHook.create_fake_module ctx.com file) MDepFromMacro;
		);
		MacroApi.current_module = (fun() ->
			ctx.m.curmod
		);
		MacroApi.cast_or_unify = (fun t e p ->
			typing_timer ctx true (fun ctx ->
				try
					ignore(AbstractCast.cast_or_unify_raise ctx t e p);
					true
				with Error { err_message = Unify _ } ->
					false
			)
		);
		MacroApi.add_global_metadata = (fun s1 s2 config p ->
			let meta = parse_metadata s2 p in
			List.iter (fun (m,el,_) ->
				let m = (m,el,p) in
				ctx.com.global_metadata <- (ExtString.String.nsplit s1 ".",m,config) :: ctx.com.global_metadata;
			) meta;
		);
		MacroApi.add_module_check_policy = (fun sl il b ->
			let add ctx =
				ctx.g.module_check_policies <- (List.fold_left (fun acc s -> (ExtString.String.nsplit s ".",List.map Obj.magic il,b) :: acc) ctx.g.module_check_policies sl);
				ctx.com.module_lut#iter (fun _ m -> m.m_extra.m_check_policy <- TypeloadModule.get_policy ctx.g m.m_path);
			in
			add ctx;
			match ctx.g.macros with
				| None -> ()
				| Some(_,mctx) -> add mctx
		);
		MacroApi.with_imports = (fun imports usings f ->
			let restore_resolution = ctx.m.import_resolution#save in
			let old_using = ctx.m.module_using in
			let run () =
				List.iter (fun (path,mode) ->
					ImportHandling.init_import ctx path mode null_pos
				) imports;
				List.iter (fun path ->
					ImportHandling.init_using ctx path null_pos
				) usings;
				flush_pass ctx.g PConnectField ("with_imports",[] (* TODO: ? *));
				f()
			in
			let restore () =
				restore_resolution();
				ctx.m.module_using <- old_using;
			in
			Std.finally restore run ()
		);
		MacroApi.with_options = (fun opts f ->
			let old_inline = ctx.allow_inline in
			let old_transform = ctx.allow_transform in
			(match opts.opt_inlining with
			| None -> ()
			| Some v -> ctx.allow_inline <- v);
			(match opts.opt_transform with
			| None -> ()
			| Some v -> ctx.allow_transform <- v);
			let restore() =
				ctx.allow_inline <- old_inline;
				ctx.allow_transform <- old_transform;
			in
			Std.finally restore f ()
		);
		MacroApi.warning = (fun ?(depth=0) w msg p ->
			warning ~depth ctx w msg p
		);
	}

let init_macro_interp mctx mint =
	let p = null_pos in
	ignore(TypeloadModule.load_module ~origin:MDepFromMacro mctx (["haxe";"macro"],"Expr") p);
	ignore(TypeloadModule.load_module ~origin:MDepFromMacro mctx (["haxe";"macro"],"Type") p);
	Interp.init mint;
	macro_interp_cache := Some mint

and flush_macro_context mint mctx =
	let t = macro_timer mctx.com ["flush"] in
	let mctx = (match mctx.g.macros with None -> die "" __LOC__ | Some (_,mctx) -> mctx) in
	Finalization.finalize mctx;
	let _, types, modules = Finalization.generate mctx in
	mctx.com.types <- types;
	mctx.com.Common.modules <- modules;
	(* we should maybe ensure that all filters in Main are applied. Not urgent atm *)
	let expr_filters = [
		"handle_abstract_casts",AbstractCast.handle_abstract_casts mctx;
		"local_statics",LocalStatic.run mctx;
		"Exceptions",Exceptions.filter mctx;
		"captured_vars",CapturedVars.captured_vars mctx.com;
	] in
	(*
		some filters here might cause side effects that would break compilation server.
		let's save the minimal amount of information we need
	*)
	let minimal_restore t =
		if (t_infos t).mt_module.m_extra.m_processed = 0 then
			(t_infos t).mt_module.m_extra.m_processed <- mctx.com.compilation_step;

		match t with
		| TClassDecl c ->
			let mk_field_restore f =
				let e = f.cf_expr in
				(fun () -> f.cf_expr <- e)
			in
			let meta = c.cl_meta
			and path = c.cl_path
			and field_restores = List.map mk_field_restore c.cl_ordered_fields
			and static_restores = List.map mk_field_restore c.cl_ordered_statics
			and ctor_restore = Option.map mk_field_restore c.cl_constructor
			in
			c.cl_restore <- (fun() ->
				c.cl_meta <- meta;
				c.cl_path <- path;
				c.cl_descendants <- [];
				Option.may (fun fn -> fn()) ctor_restore;
				List.iter (fun fn -> fn()) field_restores;
				List.iter (fun fn -> fn()) static_restores;
			);
		| _ ->
			()
	in
	(* Apply native paths for externs only *)
	let maybe_apply_native_paths t =
		let apply_native = match t with
			| TClassDecl { cl_kind = KAbstractImpl a } -> a.a_extern && a.a_enum
			| TEnumDecl e -> has_enum_flag e EnExtern
			| _ -> false
		in
		if apply_native then Naming.apply_native_paths t
	in
	let type_filters = [
		FiltersCommon.remove_generic_base;
		Exceptions.patch_constructors mctx;
		(fun mt -> AddFieldInits.add_field_inits mctx.c.curclass.cl_path (RenameVars.init mctx.com) mctx.com mt);
		Filters.update_cache_dependencies ~close_monomorphs:false mctx.com;
		minimal_restore;
		maybe_apply_native_paths
	] in
	let ready = fun t ->
		FiltersCommon.apply_filters_once mctx expr_filters t;
		List.iter (fun f -> f t) type_filters
	in
	(try Interp.add_types mint types ready
	with Error err -> t(); raise (Fatal_error err));
	t()

let create_macro_interp api mctx =
	let com2 = mctx.com in
	let mint, init = (match !macro_interp_cache with
		| None ->
			let mint = Interp.create com2 api true in
			Interp.select mint;
			mint, (fun() -> init_macro_interp mctx mint)
		| Some mint ->
			Interp.do_reuse mint api;
			mint, (fun() -> ())
	) in
	let on_error = com2.error_ext in
	com2.error_ext <- (fun err ->
		Interp.set_error (Interp.get_ctx()) true;
		macro_interp_cache := None;
		on_error { err with err_from_macro = true }
	);
	let on_warning = com2.warning in
	com2.warning <- (fun ?(depth=0) ?(from_macro=false) w options msg p ->
		on_warning ~depth ~from_macro:true w options msg p
	);
	let on_info = com2.info in
	com2.info <- (fun ?(depth=0) ?(from_macro=false) msg p ->
		on_info ~depth ~from_macro:true msg p
	);
	(* mctx.g.core_api <- ctx.g.core_api; // causes some issues because of optional args and Null type in Flash9 *)
	init();
	let init = (fun() -> Interp.select mint) in
	mctx.g.macros <- Some (init,mctx);
	(init, mint)

let create_macro_context com =
	let com2 = Common.clone com true in
	com.get_macros <- (fun() -> Some com2);
	com2.package_rules <- PMap.empty;
	(* Inherit most display settings, but require normal typing. *)
	com2.display <- {com.display with dms_kind = DMNone; dms_full_typing = true; dms_force_macro_typing = true; dms_inline = true; };
	com2.class_paths#lock_context "macro" false;
	let name = platform_name Eval in
	let eval_std = ref None in
	com2.class_paths#modify (fun cp -> match cp#scope with
		| StdTarget ->
			[]
		| Std ->
			eval_std := Some (new ClassPath.directory_class_path (cp#path ^ name ^ "/_std/") StdTarget);
			[cp#clone]
		| _ ->
			[cp#clone]
	) com.class_paths#as_list;
	(* Eval _std must be in front so we don't look into hxnodejs or something. *)
	(* This can run before `TyperEntry.create`, so in order to display nice error when std is not found, this needs to be checked here too *)
	(match !eval_std with
	| Some std -> com2.class_paths#add std
	| None -> Error.raise_std_not_found ());
	let defines = adapt_defines_to_macro_context com2.defines; in
	com2.defines.values <- defines.values;
	com2.defines.defines_signature <- None;
	com2.platform <- Eval;
	Common.init_platform com2;
	let mctx = !create_context_ref com2 None in
	mctx.m.is_display_file <- false;
	CommonCache.lock_signature com2 "get_macro_context";
	mctx

let get_macro_context ctx =
	match ctx.g.macros with
	| Some (select,ctx) ->
		select();
		ctx
	| None ->
		let mctx = create_macro_context ctx.com in
		let api = make_macro_api ctx mctx null_pos in
		let init,_ = create_macro_interp api mctx in
		ctx.g.macros <- Some (init,mctx);
		mctx.g.macros <- Some (init,mctx);
		mctx

let load_macro_module mctx com cpath display p =
	let m = (try com.module_lut#get_type_lut#find cpath with Not_found -> cpath) in
	(* Temporarily enter display mode while typing the macro. *)
	let old = mctx.com.display in
	if display then mctx.com.display <- com.display;
	let mloaded = TypeloadModule.load_module ~origin:MDepFromMacro mctx m p in
	mctx.m <- {
		curmod = mloaded;
		import_resolution = new resolution_list ["import";s_type_path cpath];
		own_resolution = None;
		enum_with_type = None;
		module_using = [];
		import_statements = [];
		is_display_file = (com.display.dms_kind <> DMNone && DisplayPosition.display_position#is_in_file (Path.UniqueKey.lazy_key mloaded.m_extra.m_file));
	};
	mloaded,(fun () -> mctx.com.display <- old)

let load_macro'' com mctx display cpath f p =
	let mint = Interp.get_ctx() in
	try mctx.com.cached_macros#find (cpath,f) with Not_found ->
		let t = macro_timer com ["typing";s_type_path cpath ^ "." ^ f] in
		let mpath, sub = (match List.rev (fst cpath) with
			| name :: pack when name.[0] >= 'A' && name.[0] <= 'Z' -> (List.rev pack,name), Some (snd cpath)
			| _ -> cpath, None
		) in
		let mloaded,restore = load_macro_module mctx com mpath display p in
		let cl, meth =
			try
				if sub <> None || mloaded.m_path <> cpath then raise Not_found;
				match mloaded.m_statics with
				| None -> raise Not_found
				| Some c ->
					Finalization.finalize mctx;
					c, PMap.find f c.cl_statics
			with Not_found ->
				let name = Option.default (snd mpath) sub in
				let path = fst mpath, name in
				let mt = try List.find (fun t2 -> (t_infos t2).mt_path = path) mloaded.m_types with Not_found -> raise_typing_error_ext (make_error (Type_not_found (mloaded.m_path,name,Not_defined)) p) in
				match mt with
				| TClassDecl c ->
					Finalization.finalize mctx;
					c, (try PMap.find f c.cl_statics with Not_found -> raise_typing_error ("Method " ^ f ^ " not found on class " ^ s_type_path cpath) p)
				| _ -> raise_typing_error "Macro should be called on a class" p
		in
		let meth = (match follow meth.cf_type with TFun (args,ret) -> (args,ret,cl,meth),mloaded | _ -> raise_typing_error "Macro call should be a method" p) in
		restore();
		if not com.is_macro_context then flush_macro_context mint mctx;
		mctx.com.cached_macros#add (cpath,f) meth;
		mctx.m <- {
			curmod = null_module;
			import_resolution = new resolution_list ["import";s_type_path cpath];
			own_resolution = None;
			enum_with_type = None;
			module_using = [];
			import_statements = [];
			is_display_file = false;
		};
		t();
		meth

let load_macro' ctx display cpath f p =
	(* TODO: The only reason this nonsense is here is because this is the signature
	   that typer.di_load_macro wants, and the only reason THAT exists is the stupid
	   voodoo stuff in displayToplevel.ml *)
	fst (load_macro'' ctx.com (get_macro_context ctx) display cpath f p)

let do_call_macro com api cpath f args p =
	let t = macro_timer com ["execution";s_type_path cpath ^ "." ^ f] in
	incr stats.s_macros_called;
	let r = Interp.call_path (Interp.get_ctx()) ((fst cpath) @ [snd cpath]) f args api in
	t();
	r

let load_macro ctx com mctx api display cpath f p =
	let meth,mloaded = load_macro'' com mctx display cpath f p in
	let _,_,{cl_path = cpath},_ = meth in
	let call args =
		add_dependency ctx.m.curmod mloaded MDepFromMacro;
		do_call_macro ctx.com api cpath f args p
	in
	mctx, meth, call

type macro_arg_type =
	| MAExpr
	| MAFunction
	| MAOther

let type_macro ctx mode cpath f (el:Ast.expr list) p =
	let mctx = get_macro_context ctx in
	let api = make_macro_api ctx mctx p in
	let mctx, (margs,mret,mclass,mfield), call_macro = load_macro ctx ctx.com mctx api (mode = MDisplay) cpath f p in
	let margs =
		(*
			Replace "rest:haxe.Rest<Expr>" in macro signatures with "rest:Array<Expr>".
			This allows to avoid handling special cases for rest args in macros during typing.
		*)
		match List.rev margs with
		| (n,o,t) :: margs_rev ->
			(match follow t with
			| TAbstract ({ a_path = ["haxe"],"Rest" }, [t1]) -> List.rev ((n,o,mctx.t.tarray t1) :: margs_rev)
			| _ -> margs)
		| _ -> margs
	in
	let mpos = mfield.cf_pos in
	let ctexpr = mk_type_path (["haxe";"macro"],"Expr") in
	let expr = Typeload.load_instance mctx (make_ptp ctexpr p) ParamNormal LoadNormal in
	(match mode with
	| MDisplay ->
		raise Exit (* We don't have to actually call the macro. *)
	| MExpr ->
		unify mctx mret expr mpos;
	| MBuild ->
		let params = [TPType (make_ptp_th (mk_type_path ~sub:"Field" (["haxe";"macro"],"Expr")) null_pos)] in
		let ctfields = mk_type_path ~params ([],"Array") in
		let tfields = Typeload.load_instance mctx (make_ptp ctfields p) ParamNormal LoadNormal in
		unify mctx mret tfields mpos
	| MMacroType ->
		let cttype = mk_type_path (["haxe";"macro"],"Type") in
		let ttype = Typeload.load_instance mctx (make_ptp cttype p) ParamNormal LoadNormal in
		try
			unify_raise mret ttype mpos;
			(* TODO: enable this again in the future *)
			(* warning ctx WDeprecated "Returning Type from @:genericBuild macros is deprecated, consider returning ComplexType instead" p; *)
		with Error { err_message = Unify _ } ->
			let cttype = mk_type_path ~sub:"ComplexType" (["haxe";"macro"],"Expr") in
			let ttype = Typeload.load_instance mctx (make_ptp cttype p) ParamNormal LoadNormal in
			unify_raise mret ttype mpos;
	);
	(*
		if the function's last argument is of Array<Expr>, split the argument list and use [] for unify_call_args
	*)
	let el,el2 = match List.rev margs with
		| (_,_,TInst({cl_path=([], "Array")},[e])) :: rest when (try Type.type_eq EqStrict e expr; true with Unify_error _ -> false) ->
			let rec loop (acc1,acc2) el1 el2 = match el1,el2 with
				| [],[] ->
					List.rev acc1, List.rev acc2
				| [], e2 :: [] ->
					(List.rev ((EArrayDecl [],p) :: acc1), [])
				| [], _ ->
					(* not enough arguments, will be handled by unify_call_args *)
					List.rev acc1, List.rev acc2
				| e1 :: l1, e2 :: [] ->
					loop (((EArrayDecl [],p) :: acc1), [e1]) l1 []
				| e1 :: l1, [] ->
					loop (acc1, e1 :: acc2) l1 []
				| e1 :: l1, e2 :: l2 ->
					loop (e1 :: acc1, acc2) l1 l2
			in
			loop ([],[]) el margs
		| _ ->
			el,[]
	in
	let args =
		(*
			force default parameter types to haxe.macro.Expr, and if success allow to pass any value type since it will be encoded
		*)
		let eargs = List.map (fun (n,o,t) ->
			try unify_raise t expr p; (n, o, t_dynamic), MAExpr
			with Error { err_message = Unify _ } -> match follow t with
				| TFun _ ->
					(n,o,t), MAFunction
				| _ ->
					(n,o,t), MAOther
			) margs in
		(*
			this is quite tricky here : we want to use unify_call_args which will type our AST expr
			but we want to be able to get it back after it's been padded with nulls
		*)
		let index = ref (-1) in
		let constants = List.map (fun e ->
			let p = snd e in
			let e =
				let rec is_function e = match fst e with
					| EFunction _ -> true
					| EParenthesis e1 | ECast(e1,_) | EMeta(_,e1) -> is_function e1
					| _ -> false
				in
				if Texpr.is_constant_value ctx.com.basic e then
					(* temporarily disable format strings processing for macro call argument typing since we want to pass raw constants *)
					let rec loop e =
						match e with
						| (EConst (String (s,SSingleQuotes)),p) -> (EConst (String (s,SDoubleQuotes)), p)
						| _ -> Ast.map_expr loop e
					in
					loop e
				else if is_function e then
					(* If we pass a function expression we don't want to type it as part of `unify_call_args` because that result just gets
					   discarded. Use null here so it passes, then do the actual typing in the MAFunction part below. *)
					(EConst (Ident "null"),p)
				else
					(* if it's not a constant, let's make something that is typed as haxe.macro.Expr - for nice error reporting *)
					(ECheckType ((EConst (Ident "null"),p), (make_ptp_th ctexpr p)), p)
			in
			(* let's track the index by doing [e][index] (we will keep the expression type this way) *)
			incr index;
			(EArray ((EArrayDecl [e],p),(EConst (Int (string_of_int (!index), None)),p)),p)
		) el in
		let elt = fst (CallUnification.unify_call_args mctx constants (List.map fst eargs) t_dynamic p false false false) in
		List.map2 (fun ((n,_,t),mct) e ->
			let e, et = (match e.eexpr with
				(* get back our index and real expression *)
				| TArray ({ eexpr = TArrayDecl [e] }, { eexpr = TConst (TInt index) }) -> List.nth el (Int32.to_int index), e
				(* added by unify_call_args *)
				| TConst TNull -> (EConst (Ident "null"),e.epos), e
				| _ -> die "" __LOC__
			) in
			let ictx = Interp.get_ctx() in
			match mct with
			| MAExpr ->
				Interp.encode_expr e
			| MAFunction ->
				let e = type_expr mctx e (WithType.with_argument t n) in
				unify mctx e.etype t e.epos;
				begin match Interp.eval_expr ictx e with
				| Some v -> v
				| None -> Interp.vnull
				end
			| MAOther -> match Interp.eval_expr ictx et with
				| None -> Interp.vnull
				| Some v -> v
		) eargs elt
	in
	let args = match el2 with
		| [] -> args
		| _ -> (match List.rev args with _::args -> List.rev args | [] -> []) @ [Interp.encode_array (List.map Interp.encode_expr el2)]
	in
	let call() =
		match call_macro args with
		| None ->
			MError
		| Some v ->
			let expected,process = match mode with
				| MExpr | MDisplay ->
					"Expr",(fun () -> MSuccess (Interp.decode_expr v))
				| MBuild ->
					"Array<Field>",(fun () ->
						let fields = if v = Interp.vnull then
								(match ctx.c.get_build_infos() with
								| None -> die "" __LOC__
								| Some (_,_,fields) -> fields)
							else
								let ct = make_ptp_th (mk_type_path ~sub:"Field" (["haxe";"macro"], "Expr")) null_pos in
								let t = Typeload.load_complex_type mctx false LoadNormal ct in
								List.map (fun f -> safe_decode ctx.com f "Field" t p (fun () -> Interp.decode_field f)) (Interp.decode_array v)
						in
						MSuccess (EVars [mk_evar ~t:(CTAnonymous fields,p) ("fields",null_pos)],p)
					)
				| MMacroType ->
					"ComplexType",(fun () ->
						let t = if v = Interp.vnull then
							spawn_monomorph ctx.e p
						else try
							let ct = Interp.decode_ctype v in
							Typeload.load_complex_type ctx false LoadNormal ct;
						with MacroApi.Invalid_expr  | EvalContext.RunTimeException _ ->
							Interp.decode_type v
						in
						ctx.e.ret <- t;
						MSuccess (EBlock [],p)
					)
			in
			safe_decode ctx.com v expected mret p process
	in
	let e = if ctx.com.is_macro_context then
		MMacroInMacro
	else
		call()
	in
	e

let call_macro mctx args margs call p =
	mctx.c.curclass <- null_class;
	let el, _ = CallUnification.unify_call_args mctx args margs t_dynamic p false false false in
	call (List.map (fun e -> try Interp.make_const e with Exit -> raise_typing_error "Argument should be a constant" e.epos) el)

let resolve_init_macro com e =
	let p = fake_pos ("--macro " ^ e) in
	let e = try
		if String.get e (String.length e - 1) = ';' then raise_typing_error "Unexpected ;" p;
		begin match ParserEntry.parse_expr_string com.defines e p raise_typing_error false with
		| ParseSuccess(data,_,_) -> data
		| ParseError(_,(msg,p),_) -> (Parser.error msg p)
		end
	with err ->
		display_error com ("Could not parse `" ^ e ^ "`") p;
		raise err
	in
	match fst e with
	| ECall (e,args) ->
		let rec loop e =
			match fst e with
			| EField (e,f,_) -> f :: loop e
			| EConst (Ident i) -> [i]
			| _ -> raise_typing_error "Invalid macro call" p
		in
		let path, meth = (match loop e with
		| [meth] -> (["haxe";"macro"],"Compiler"), meth
		| [meth;"server"] -> (["haxe";"macro"],"CompilationServer"), meth
		| meth :: cl :: path -> (List.rev path,cl), meth
		| _ -> raise_typing_error "Invalid macro call" p) in
		(path,meth,args,p)
	| _ ->
		raise_typing_error "Invalid macro call" p

let call_init_macro com mctx e =
	let (path,meth,args,p) = resolve_init_macro com e in
	let (mctx, api) = match mctx with
	| Some mctx ->
		let api = make_macro_com_api com mctx.com p in
		(mctx, api)
	| None ->
		let mctx = create_macro_context com in
		let api = make_macro_com_api com mctx.com p in
		let init,_ = create_macro_interp api mctx in
		mctx.g.macros <- Some (init,mctx);
		(mctx, api)
	in

	let mctx, (margs,_,mclass,mfield), call = load_macro mctx com mctx api false path meth p in
	ignore(call_macro mctx args margs call p);
	mctx

let finalize_macro_api tctx mctx =
	let api = make_macro_api tctx mctx null_pos in
	match !macro_interp_cache with
		| None -> ignore(create_macro_interp api mctx)
		| Some mint -> mint.curapi <- api

let interpret ctx =
	let mctx = get_macro_context ctx in
	let mctx = Interp.create ctx.com (make_macro_api ctx mctx null_pos) false in
	Interp.add_types mctx ctx.com.types (fun t -> ());
	match ctx.com.main.main_expr with
		| None -> ()
		| Some e -> ignore(Interp.eval_expr mctx e)

let setup() =
	Interp.setup Interp.macro_api
