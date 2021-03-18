import haxe.Json;
import haxe.io.Path;
import haxe.macro.Type.ClassType;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.xml.Access;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// TODO add System.ObsoleteAttribute parsing to haxe
class Generate {
	static var docCache:Map<String, String> = null;
	static var docUseCache:Map<String, Bool> = null;

	static function recDeleteDirectory(path:String) {
		if (!FileSystem.exists(path) || !FileSystem.isDirectory(path)) {
			return;
		}

		for (entry in FileSystem.readDirectory(path)) {
			final path = path + "/" + entry;

			if (FileSystem.isDirectory(path)) {
				recDeleteDirectory(path);
			} else {
				FileSystem.deleteFile(path);
			}
		}

		FileSystem.deleteDirectory(path);
	}

	static function rootPath():String {
		return switch (Context.getDefines().get("output")) {
			case null: "";
			case value: value;
		}
	}

	static function api() {
		Sys.println("Generating externs for Godot...");

		final root = Path.join([rootPath(), "godot"]);

		recDeleteDirectory(root);
		FileSystem.createDirectory(root);

		File.saveContent(root + "/Godot.hx", File.getContent("src/Godot.hx"));
		File.saveContent(root + "/Nullable1.hx", File.getContent("src/Nullable1.hx"));

		final doc = new Access(Xml.parse(File.getContent("input/GodotSharp.xml")));
		docCache = new Map<String, String>();
		docUseCache = new Map<String, Bool>();

		for (member in doc.node.doc.node.members.nodes.member) {
			var doc = "";
			var textParse;

			function cref(ref:String):String {
				final t = ref.charAt(0);
				return switch (t) {
					case "T":
						if (ref.startsWith("T:Godot.")) {
							final path = ref.substr(2).split(".");
							path.shift();

							"godot." + path.join("_");
						} else if (ref.startsWith("T:System")) {
							switch (ref) {
								case "T:System.String": "String";
								case "T:System.Boolean": "Bool";
								case "T:System.Int32": "Int";
								case "T:System.Single": "Single";
								case "T:System.Byte": "cs.UInt8";
								default:
									final path = ref.substr(2).split(".");
									final name = path.pop();
									'cs.${path.map(p -> p.toLowerCase()).join(".")}.$name';
							}
						} else {
							throw "Unsupported " + ref;
						}

					case "M", "F", "P":
						if (!ref.substr(1).startsWith(":Godot.")) {
							throw "Unsupported " + ref;
						}

						var p = ref.indexOf("(");
						if (p == -1) {
							p = ref.length;
						}
						final path = ref.substring(2, p).split(".");
						path.shift();
						var field = path.pop();
						final path = path.join("_");

						if (path == "Mathf" && t == "F") {
							field = field.toUpperCase();
						} else {
							field = field.substr(0, 1).toLowerCase() + field.substr(1);
						}

						'godot.${path}.${field}';

					case "!":
						ref.substr(2);

					default:
						throw "Unsupported " + ref;
				}
			}

			function innerParse(elem:Access) {
				switch (elem.name) {
					case "summary", "remarks", "example":
						textParse(elem);

					case "para":
						textParse(elem);
						doc += "\n";

					case "value":
						doc += "\nValue: ";
						textParse(elem);
						doc += "\n";

					case "returns":
						doc += "\n@returns ";
						textParse(elem);
						doc += "\n";

					case "param":
						doc += '\n@param ${elem.att.name} ';
						textParse(elem);

					case "see":
						if (elem.has.cref) {
							doc += '`${cref(elem.att.cref)}`';
						} else if (elem.has.langword) {
							doc += '`${elem.att.langword}`';
						} else {
							throw "Unsupported see " + elem;
						}

					case "exception":
						doc += '@throws ${cref(elem.att.cref)}';

					case "c":
						doc += "`";
						textParse(elem);
						doc += "`";

					case "paramref":
						doc += '`${elem.att.name}`';

					case "code":
						doc += "\n```\n";
						textParse(elem);
						doc += "\n```";

					case "a":
						doc += '[${elem.att.href}](';
						textParse(elem);
						doc += ")";

					default:
						throw "Unsupported " + elem.name;
				}
			}

			function parse(elem:Access) {
				for (child in elem.elements) {
					innerParse(child);
				}
			}

			textParse = (node:Access) -> {
				for (i in node.x) {
					switch (i.nodeType) {
						case Element:
							innerParse(new Access(i));
						case PCData:
							doc += i.toString();
						default:
							throw "Unsupported " + i.nodeType;
					}
				}
			}

			parse(member);

			docCache.set(member.att.name, doc);
			docUseCache.set(member.att.name, false);
		}

		final typeGenCache = new Map<String, TypeDefinition>();
		Context.onTypeNotFound(type -> {
			if (typeGenCache.exists(type)) {
				return typeGenCache.get(type);
			}

			final parts = type.split(".");
			final name = parts.pop();
			final path = parts.join(".");

			if (path == "cs.system.dynamic") {
				final td = {
					pack: ["cs", "system", "dynamic_"],
					name: name,
					pos: (macro null).pos,
					meta: [{
						name: ":native",
						params: [macro $v{type}],
						pos: (macro null).pos,
					}],
					isExtern: true,
					kind: TDClass(),
					fields: [],

				};
				Context.defineType(td);
				typeGenCache.set(type, td);
				return td;
			}

			return null;
		});

		Context.onAfterGenerate(() -> {
			for (member => used in docUseCache) {
				if (!used) {
					Sys.println('Missing $member');
				}
			}

			Sys.println("Done.");
		});
	}

	static function build() {
		final warning = "// Automatically generated Godot externs: DO NOT EDIT\n// MIT licensed, see LICENSE.md\n";
		final fields = Context.getBuildFields();
		final type = Context.getLocalType();

		function pack2path(pack:Array<String>) {
			final path = Path.join([rootPath()].concat(pack));
			FileSystem.createDirectory(path);
			return path;
		}

		function getDoc(id:String, indent = false):String {
			final id = id.replace("FFT.Size", "FFT_Size").replace("TCP.Server", "TCP_Server").replace("Tracking.status", "Tracking_status");
			return switch (docCache.get(id)) {
				case null:
					"";
				case value:
					final indent = indent ? "\t" : "";
					final value = value.split("\n").map(line -> line.trim()); // TODO this removes indentation on code blocs
					while (value.length > 0 && value[value.length - 1] == "") {
						value.pop();
					}
					final value = value.join("\n").replace("\n\n\n", "\n\n").split("\n").map(line -> indent + indent + line).join("\n");
					docUseCache.set(id, true);
					'$indent/**$value\n$indent**/\n';
			}
		}

		function getMetas(metaArray:Array<MetadataEntry>):String {
			var metas = "";

			for (meta in metaArray) {
				switch (meta.name) {
					case ":build", ":abstract":
					// Do nothing

					case ":nativeGen", ":csNative", ":libType", ":struct" if (meta.params.length == 0):
						metas += '@${meta.name}\n';

					case ":native":
						switch (meta.params) {
							case [{expr: EConst(CString(value, DoubleQuotes))}]:
								metas += '@:native("$value")\n';
							default:
								throw "Unsupported " + type + " " + meta;
						}

					default:
						throw "Unsupported " + type + " " + meta.name;
				}
			}

			return metas;
		}

		function path2string(path:ComplexType):String {
			switch path {
				case TPath(p):
					final p = {
						name: p.name,
						pack: p.pack,
						params: p.params,
						sub: p.sub,
					};

					if (p.pack.length == 1 && p.pack[0] == "godot" && p.sub != null) {
						p.name = p.sub;
						p.sub = null;
					}

					var type = p.pack.join(".") + (p.pack.length > 0 ? "." : "") + p.name + (p.sub != null ? '.${p.sub}' : "");

					if (p.params != null && p.params.length > 0) {
						type += "<" + p.params.map(tp -> switch (tp) {
							case TPType(t):
								path2string(t);
							default:
								throw "Unsupported " + type + " " + tp;
						}).join(", ") + ">";
					}

					return type;

				default:
					throw "Unsupported " + type + " " + path;
			}
		}

		function classtype2string(parent:ClassType, c:ClassType, params:Array<haxe.macro.Type>):String {
			function cname(c:ClassType):String {
				return c.pack.join(".") + (c.pack.length > 0 ? "." : "") + c.name;
			}

			switch (c.kind) {
				case KTypeParameter([]) if (cname(parent) == c.module):
					return c.name;
				default:
			}

			var name = cname(c);

			if (params != null && params.length > 0) {
				name += "<" + params.map(p -> switch (p) {
					case TInst(_.get() => t, p):
						classtype2string(parent, t, p);
					case TDynamic(null):
						"Dynamic";
					default:
						throw "Unsupported " + type + " " + p;
				}).join(", ") + ">";
			}

			return name;
		}

		function safename(name:String):String {
			return switch (name) {
				// Escape keywords
				case "abstract", "break", "case", "cast", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern", "false", "final", "for", "function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "null", "operator", "overload", "override", "package", "private", "public", "return", "static", "switch", "this", "throw", "true", "try", "typedef", "untyped", "using", "var", "while":
					'${name}_';

				default:
					name;
			}
		}

		switch (type) {
			case TEnum(_.get() => e, []):
				final path = pack2path(e.pack);
				final filename = path + "/" + e.name + ".hx";
				final doc = getDoc('T:Godot.${e.name.replace("_", ".")}');
				final metas = getMetas(e.meta.get());

				var content = '${warning}package ${e.pack.join(".")};\n\n${doc}${metas}extern enum ${e.name} {';

				for (field in fields) {
					switch (field.kind) {
						case FVar(null, null):
						default:
							throw "Unsupported " + type;
					}

					if (field.access.length != 0
						|| field.meta.length != 1
						|| field.meta[0].name != ":csNative"
						|| field.meta[0].params.length != 1
						|| !field.meta[0].params[0].expr.match(EConst(CInt(_)))) {
						throw "Unsupported " + type;
					}

					final name = field.name;
					final doc = getDoc('F:Godot.${e.name.replace("_", ".")}.$name', true);
					content += '\n${doc}\t${name};\n';
				}

				content += "}\n";

				File.saveContent(filename, content);

			case TInst(_.get() => i, _):
				if (!i.kind.match(KNormal)) {
					throw "Unsupported " + type + " " + i.kind;
				}

				final ops = Lambda.exists(fields, field -> field.name.startsWith("op_") && field.name != "op_Explicit");
				final type = i.isInterface ? "interface" : "class";
				final path = pack2path(i.pack);
				final filename = path + "/" + i.name + ".hx";
				final doc = getDoc('T:Godot.${i.name.replace("_", ".")}');
				final metas = getMetas(i.meta.get());
				final abstr = i.isAbstract ? "abstract " : "";
				final superClass = i.superClass != null ? " extends " + classtype2string(i, i.superClass.t.get(), i.superClass.params) : "";
				final implement = i.isInterface ? " extends " : " implements ";
				final interfaces = i.interfaces.map(si -> implement + classtype2string(i, si.t.get(), si.params)).join("");

				var name = i.name;
				if (i.params != null && i.params.length > 0) {
					name += "<" + i.params.map(p -> p.name).join(", ") + ">";
				}

				final cls = ops -> '${metas}@:autoBuild(godot.Godot.buildUserClass())\nextern ${abstr}${type} ${ops ? name + "_" : name}$superClass$interfaces';

				final fieldList = new Map<String, Int>();
				for (field in fields) {
					if (!fieldList.exists(field.name)) {
						fieldList.set(field.name, 1);
					} else {
						fieldList.set(field.name, fieldList.get(field.name) + 1);
					}
				}

				function arg2doc(atype) {
					return switch (atype) {
						case macro :Nullable1<$x>:
							'System.Nullable{${arg2doc(x)}}';

						case TPath(p) if (p.pack.length > 0 && p.pack[0] == "godot"):
							var pack = "Godot.";
							for (i in 1...p.pack.length) {
								pack += p.pack[i].substr(0, 1).toUpperCase() + p.pack[i].substr(1) + ".";
							}
							pack + p.name + (p.sub != null ? '.${p.sub.substr(p.name.length + 1)}' : "");

						case TPath(p) if (p.pack.length == 0 || (p.pack.length == 1 && p.pack[0] == "std") || (p.pack.length == 2 && p.pack[0] == "cs") && p.pack[1] == "types"):
							return "System." + switch (p.name) {
								case "Bool": "Boolean";
								case "Float": "Double";
								case "Int": "Int32";
								case "Int8": "SByte";
								case "UInt": "UInt32";
								case "UInt8": "Byte";
								case "Dynamic": "Object";
								case value: value;
							}

						case macro :haxe.Int64:
							"System.Int64";

						case macro :cs.system.Decimal:
							"System.Decimal";

						case macro :cs.Out<$x>:
							'${arg2doc(x)}@';

						case macro :cs.NativeArray<$x>:
							'${arg2doc(x)}[]';

						default:
							"Dynamic"; // TODO
					}
				}

				var content = '${warning}package ${i.pack.join(".")};\n\nimport cs.system.*;\n\n${doc}';

				if (ops) {
					content += '#if doc_gen\n${cls(false)} {\n#else\n@:forward\n@:forwardStatics\nextern abstract $name(${name}_) from ${name}_ to ${name}_ {\n#end';

					for (field in fields) {
						if (!field.name.startsWith("op_") && field.name != "new") {
							continue;
						}

						if (field.name == "op_Implicit") {
							switch (field.kind) {
								case FFun(f = {args: [{ type: TPath(argPath) }], ret: TPath(retPath)}):
									final arg = path2string(TPath(argPath));
									final ret = path2string(TPath(retPath));
									final cls = classtype2string(i.superClass != null ? i.superClass.t.get() : null, i, []);

									var name;
									final type = if (arg == cls) { // @:to
										name = retPath.name;
										"to";
									} else if (ret == cls) { // @:from
										name = argPath.name;
										"from";
									} else {
										throw "Unsupported implicit cast " + type + " " + f;
									}

									content += '\n\t/**\n\t\tImplicit cast.\n\t**/\n\t@:$type static inline function $type$name(obj:${argPath.pack.join(".") + (argPath.pack.length > 0 ? "." : "") + argPath.name}):$ret {\n\t\treturn cs.Syntax.code("{0}", obj);\n\t}\n';

								default:
									throw "Unsupported " + type + " " + field.kind;
							}

							continue;
						}

						final fun = switch (field.kind) {
							case FFun(f): f;
							default: throw "assert false";
						};
						final sign = fun.args.map(a -> safename(a.name) + ":" + path2string(a.type)).join(", ");
						final overloaded = fieldList.get(field.name) > 1 ? "overload " : "";
						final call = fun.args.map(a -> safename(a.name)).join(", ");

						if (field.name == "new") {
							final docArgs = fun.args.map(a -> arg2doc(a.type));
							final docArgs = docArgs.length > 0 ? '(${docArgs.join(",")})' : "";
							final doc = getDoc('M:Godot.${i.name.replace("_", ".")}.#ctor${docArgs}', true);

							content += '\n\t#if !doc_gen\n${doc}\tpublic ${overloaded}inline function new($sign) {\n\t\tthis = new ${name}_($call);\n\t}\n\t#end\n';
							continue;
						}

						final opDecl = switch (field.name) {
							case "op_Addition": "A + B";
							case "op_Subtraction": "A - B";
							case "op_UnaryNegation": "-A";
							case "op_Multiply": "A * B";
							case "op_Division": "A / B";
							case "op_Modulus": "A % B";
							case "op_Equality": "A == B";
							case "op_Inequality": "A != B";
							case "op_LessThan": "A < B";
							case "op_GreaterThan": "A > B";
							case "op_LessThanOrEqual": "A <= B";
							case "op_GreaterThanOrEqual": "A >= B";
							default:
								throw "Unsupported " + type + " " + field.name;
						};

						var code = switch (field.name) {
							case "op_Addition": "{0} + {1}";
							case "op_Subtraction": "{0} - {1}";
							case "op_UnaryNegation": "-{0}";
							case "op_Multiply": "{0} * {1}";
							case "op_Division": "{0} / {1}";
							case "op_Modulus": "{0} % {1}";
							case "op_Equality": "{0} == {1}";
							case "op_Inequality": "{0} != {1}";
							case "op_LessThan": "{0} < {1}";
							case "op_GreaterThan": "{0} > {1}";
							case "op_LessThanOrEqual": "{0} <= {1}";
							case "op_GreaterThanOrEqual": "{0} >= {1}";
							default:
								throw "Unsupported " + type + " " + field.name;
						};

						var args = fun.args;

						for (i in 0...args.length) {
							switch (args[i].type) {
								case macro :Single:
									final a = args.slice(0, i);
									a.push({
										name: args[i].name,
										type: macro :Float,
									});

									args = a.concat(args.slice(i + 1));
									code = code.replace('{$i}', '((global::System.Single)({$i}))');

								default:
							}
						}

						var doc = 'Operator overload for $code.';
						for (i in 0...args.length) {
							doc = doc.replace('{$i}', '`${path2string(args[i].type)}`');
						}

						final sign = args.map(a -> safename(a.name) + ":" + path2string(a.type)).join(", ");
						content += '\n\t/**\n\t\t${doc}\n\t**/\n\t@:op($opDecl) static inline ${overloaded}function ${field.name}(${sign}):${path2string(fun.ret)} {\n\t\treturn cs.Syntax.code("${code}", ${call});\n\t}\n';
					}

					content += "#if !doc_gen\n}\n\n";
				}

				content += '${cls(ops)} {';

				if (ops) {
					content += "\n#end";
				}

				for (field in fields) {
					var readOnly = false;
					var metas = ['@:native("${field.name}")'];

					for (meta in field.meta) {
						switch (meta.name) {
							case ":readOnly" if (meta.params.length == 0):
								readOnly = true;

							case ":protected", ":noCompletion", ":skipReflection" if (meta.params.length == 0):
								metas.push('@${meta.name}');

							default:
								throw "Unsuported " + type + " " + field.meta;
						}
					}

					final metas = metas.join(" ") + "\n\t";
					final static_ = field.access.contains(AStatic);

					function uppername(name:String):String {
						var upName = "";

						for (i in 0...name.length) {
							final c = name.charAt(i);
							final cu = c.toUpperCase();

							if (i != 0 && c == cu) {
								upName += "_";
							}

							upName += cu;
						}

						return upName;
					}

					switch (field.kind) {
						case FVar(t, null), FProp(_, _, t, null):
							if (field.kind.match(FProp(_, "never", _, _))) {
								readOnly = true;
							}

							final name = static_ ? uppername(field.name) : safename(field.name.toLowerCase().substr(0, 1) + field.name.substr(1));
							final kind = field.kind.match(FVar(_, _)) || field.kind.match(FProp("default", "never", _, _)) ? "F" : "P";
							final doc = getDoc('$kind:Godot.${i.name.replace("_", ".")}.${field.name}', true);
							final access = readOnly ? "(default, never)" : "";

							content += '\n${doc}\t${metas}public${static_ ? " static" : ""} var $name$access:${path2string(t)};\n';

						case FFun(f):
							if (field.name.startsWith("op_")) {
								// Handled above.
								continue;
							}

							// TODO P:Godot.Vector3.Item(System.Int32) is array access : get_Item & set_Item
							if (field.name.startsWith("get_") || field.name.startsWith("set_")) {
								// Getter and setter are native
								continue;
							}

							final fargs = [for (a in f.args) {
								final t = switch (a.type) {
									case macro :cs.system.Nullable_1<$x>: (macro :Nullable1<$x>);
									case value: value;
								};
								{
									meta: a.meta,
									name: a.name,
									opt: a.opt,
									type: t,
									value: a.value,
								};
							}];

							var name = field.name == "new" ? "new" : safename(field.name.substr(0, 1).toLowerCase() + field.name.substr(1));
							var overloaded = fieldList.get(field.name) > 1;
							final docArgs = fargs.map(a -> arg2doc(a.type));
							final docArgs = docArgs.length > 0 ? '(${docArgs.join(",")})' : "";
							final docName = field.name == "new" ? "#ctor" : field.name;
							var doc = getDoc('M:Godot.${i.name.replace("_", ".")}.${docName}${docArgs}', true);

							if (f.params != null && f.params.length > 0) {
								name += "<" + f.params.map(p -> p.name).join(", ") + ">";
							}

							var singleOverload = false;

							if (fargs.length > 0) {
								switch (fargs[fargs.length - 1].type) {
									case macro :cs.NativeArray<$x>:
										fargs[fargs.length - 1].type = macro:haxe.Rest<$x>;
										fargs[fargs.length - 1].opt = false;
									default:
								}

								if (fargs[fargs.length - 1].opt) {
									overloaded = true;
									singleOverload = true;
								}
							}

							if (singleOverload) {
								content += '\n\t#if doc_gen\n${doc}\t${metas}public${static_ ? " static" : ""}${fieldList.get(field.name) > 1 ? " overload" : ""} function $name(${fargs.map(a -> (a.opt ? "?" : "") + safename(a.name) + ":" +  path2string(a.type)).join(", ")}):${path2string(f.ret)};\n\t#else';
							}

							(function print_function(args_count) {
								final args = [];

								for (i in 0...args_count) {
									final a = fargs[i];
									args.push(safename(a.name) + ":" + path2string(a.type));
								}

								if (args_count > 0 && fargs[args_count - 1].opt) {
									print_function(args_count - 1);
								}

								content += '\n${doc}\t${metas}public${static_ ? " static" : ""}${overloaded ? " overload" : ""} function $name(${args.join(", ")}):${path2string(f.ret)};\n';
							})(fargs.length);

							if (singleOverload) {
								content += "\t#end\n";
							}

						default:
							throw "Unsupported " + type + " " + field;
					}
				}

				content += "}\n";

				File.saveContent(filename, content);

			default:
				throw "Unsupported " + type;
		}

		return fields;
	}
}
