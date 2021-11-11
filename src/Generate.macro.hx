import haxe.Json;
import haxe.io.Eof;
import haxe.io.Path;
import haxe.macro.Type.ClassType;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.xml.Access;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

using StringTools;

typedef Api = {
	name:String,
	signals:Array<Signal>,
}

typedef Signal = {
	name:String,
	arguments:Array<{
		name:String,
		type:String,
		has_default_value:Bool,
		default_value:String
	}>,
	handler:String, // Added custom field
}

// TODO https://github.com/HaxeFoundation/dox/issues/281
// TODO https://github.com/godotengine/godot/issues/28293
// TODO https://github.com/HaxeFoundation/hxcs/issues/51
// TODO check flags xorability
// TODO add C# params argument attribute (rest) to Haxe
class Generate {
	static var docCache:Map<String, String> = null;
	static var docUseCache:Map<String, Bool> = null;
	static var signalCache:Map<String, Array<Signal>> = null;
	static var deprecatedCache:Map<String, Map<String, String>> = null;
	static var deprecatedUseCache:Map<String, Map<String, Bool>> = null;

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

	static function extractDoc(xml:Access):String {
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
					switch (ref) {
						case "M:System.Math.Max(System.Single,System.Single)":
							return "Math.max";
					}

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
				case "summary", "remarks", "example", "description":
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

				case "seealso":
					doc += '@see `${cref(elem.att.cref)}`';

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
					if (!elem.has.cref) {
						doc += '@throws ${elem.att.name}';
					} else {
						doc += '@throws ${cref(elem.att.cref)}';
					}

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

				case "typeparam":
					doc += '\nType parameter `${elem.att.name}`: ';
					textParse(elem);

				case "inheritdoc":

				default:
					throw "Unsupported " + elem.name;
			}
		}

		function parse(elem:Access) {
			final elements = [for (e in elem.elements) e];

			if (elements.length == 0) {
				innerParse(elem);
			} else {
				for (child in elements) {
					innerParse(child);
				}
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

		parse(xml);
		return doc;
	}

	static function reindentDoc(doc:String, indent:Bool):String {
		// TODO this removes indentation on code blocs
		final indent = indent ? "\t" : "";
		final value = doc.split("\n").map(line -> line.trim());
		while (value.length > 0 && value[value.length - 1] == "") {
			value.pop();
		}
		return value.join("\n").replace("\n\n\n", "\n\n").split("\n").map(line -> indent + indent + line).join("\n");
	}

	static function api() {
		Sys.println("Generating externs for Godot...");

		final root = Path.join([rootPath(), "godot"]);

		recDeleteDirectory(root);
		FileSystem.createDirectory(root);

		for (entry in FileSystem.readDirectory("utils")) {
			File.saveContent(root + "/" + entry, File.getContent("utils/" + entry));
		}

		docCache = new Map<String, String>();
		docUseCache = new Map<String, Bool>();

		for (xml in ["GodotSharp", "GodotSharpEditor"]) {
			final doc = new Access(Xml.parse(File.getContent('input/$xml.xml')));
			for (member in doc.node.doc.node.members.nodes.member) {
				final doc = extractDoc(member);
				docCache.set(member.att.name, doc);
				docUseCache.set(member.att.name, false);
			}
		}

		signalCache = new Map<String, Array<Signal>>();
		final json:Array<Api> = Json.parse(File.getContent("input/GodotApi.json"));
		final signalHandlers = new Map<String, Array<String>>();

		for (api in json) {
			function changeType(type:String, pools=true):String {
				final c = type.charAt(0);
				if (c == c.toUpperCase()) {
					if (!pools) {
						return type;
					}
					return switch (type) {
						case "Array": "godot.collections.Array";
						case "PoolIntArray": "std.Array<Int>";
						case "PoolByteArray": "std.Array<cs.types.UInt8>";
						case "PoolFloatArray": "std.Array<Float>";
						case "PoolStringArray": "std.Array<std.String>";
						case "PoolColorArray": "std.Array<godot.Color>";
						case "PoolVector2Array": "std.Array<godot.Vector2>";
						case "PoolVector3Array": "std.Array<godot.Vector3>";
						case "Object": "godot.Object";
						case "String": "std.String";
						case "Variant": "Any";
						default: type;
					}
				}
				return switch (type) {
					case "bool": "Bool";
					case "float": "Float";
					case "int": "Int";
					case "void": "Any";
					default: throw "Unknown type " + type;
				}
			}

			for (signal in api.signals) {
				signal.handler = "SignalHandler" + (signal.arguments.length == 0 ? "Void" : signal.arguments.map(a -> changeType(a.type, false)).join("")) + "Void";

				for (arg in signal.arguments) {
					arg.type = changeType(arg.type);
				}

				signalHandlers.set(signal.handler, signal.arguments.map(a -> a.type));
			}

			signalCache.set(api.name, api.signals);
		}

		var signalHandlerTypes = File.getContent("utils/Signal.hx");

		for (name => types in signalHandlers) {
			final sign = (types.length == 0 ? "Void" : "") + types.join("->") + "->Void";
			final handle = [for (index => type in types) 'arg$index:$type'].join(", ");
			final args = [for (index => type in types) 'arg$index'].join(", ");

			signalHandlerTypes += '\n@:nativeGen\n@:dox(hide)\n@:noCompletion\nclass $name extends Reference {\n\tstatic final refs = new Map<String, Map<Object, Array<$sign>>>();\n\n\tpublic static function isSignalConnected(source:Object, signal:String, callback:$sign):Bool {\n\t\treturn SignalHandler.isSignalConnected(refs, source, signal, callback);\n\t}\n\n\tpublic static function disconnectSignal(source:Object, signal:String, callback:$sign) {\n\t\tSignalHandler.disconnectSignal(refs, source, signal, callback);\n\t}\n\n\tpublic static function connectSignal(source:Object, signal:String, callback:$sign) {\n\t\tSignalHandler.connectSignal(refs, $name.new, source, signal, callback);\n\t}\n\n\tfinal callback:$sign;\n\n\tfunction new(source:Object, signal:String, callback:$sign) {\n\t\tsuper();\n\t\tthis.callback = callback;\n\n\t\tfinal key = "" + source.getInstanceId() + "-" + signal;\n\n\t\tif (!refs.exists(key)) {\n\t\t\trefs.set(key, new Map<Object, Array<$sign>>());\n\t\t}\n\n\t\trefs.get(key).set(this, [callback]);\n\t}\n\n\t@:keep function handleSignal($handle) {\n\t\tcallback($args);\n\t}\n}\n';
		}

		File.saveContent(root + "/Signal.hx", signalHandlerTypes);

		deprecatedCache = new Map<String, Map<String, String>>();
		deprecatedUseCache = new Map<String, Map<String, Bool>>();

		final p = new Process("mono", ["build/bin/ListDeprecated.exe"]);
		final deprecatedList = [];
		while (true) {
			try {
				deprecatedList.push(p.stdout.readLine());
			} catch (e:Eof) {
				break;
			}
		}
		p.close();

		var i = 0;
		while (i < deprecatedList.length) {
			final cls = deprecatedList[i++];
			final member = deprecatedList[i++];
			final message = deprecatedList[i++];

			if (!deprecatedCache.exists(cls)) {
				deprecatedCache[cls] = new Map<String, String>();
				deprecatedUseCache[cls] = new Map<String, Bool>();
			}

			deprecatedCache[cls][member] = message;
			deprecatedUseCache[cls][member] = false;
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
			final missings = [];
			for (member => used in docUseCache) {
				if (!used) {
					missings.push(member);
				}
			}
			missings.sort(Reflect.compare);
			for (member in missings) {
				Sys.println('Missing $member');
			}

			// TODO temp
			var i = 0;
			for (_ => members in deprecatedUseCache) {
				for (used in members) {
					if (!used) {
						i++;
					}
				}
			}
			Sys.println('Unused deprecated message(s): $i');

			Sys.println("Done.");
		});
	}

	static function build() {
		final warning = "// Automatically generated Godot externs: DO NOT EDIT\n// MIT licensed, see LICENSE.md\n";
		final fields = Context.getBuildFields();
		final ttype = Context.getLocalType();

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
					final value = reindentDoc(value, indent);
					final indent = indent ? "\t" : "";
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
								throw "Unsupported " + ttype + " " + meta;
						}

					default:
						throw "Unsupported " + ttype + " " + meta.name;
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
					throw "Unsupported " + ttype + " " + path;
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
						throw "Unsupported " + ttype + " " + p;
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

		switch (ttype) {
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
							throw "Unsupported " + ttype;
					}

					if (field.access.length != 0
						|| field.meta.length != 1
						|| field.meta[0].name != ":csNative"
						|| field.meta[0].params.length != 1
						|| !field.meta[0].params[0].expr.match(EConst(CInt(_)))) {
						throw "Unsupported " + ttype;
					}

					final name = field.name;
					final doc = getDoc('F:Godot.${e.name.replace("_", ".")}.$name', true);
					content += '\n${doc}\t${name};\n';
				}

				content += "}\n";

				File.saveContent(filename, content);

			case TInst(_.get() => i, _):
				if (!i.kind.match(KNormal)) {
					throw "Unsupported " + ttype + " " + i.kind;
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
						case macro :cs.system.Nullable_1<$x>:
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
									throw "Unsupported " + ttype + " " + field.kind;
							}

							continue;
						} else if (field.name == "op_Explicit") {
							Sys.println('TODO op_Explicit $path $name');
							continue;
						}

						final fun = switch (field.kind) {
							case FFun(f): f;
							default: throw "assert false";
						};
						final sign = fun.args.map(a -> safename(a.name) + ":" + path2string(a.type)).join(", ");
						final vectorConstructorPatch = (i.name == "Vector2" || i.name == "Vector3") && fun.args[0].name == "x";
						final overloaded = (vectorConstructorPatch || fieldList.get(field.name) > 1) ? "overload " : "";
						final call = fun.args.map(a -> safename(a.name)).join(", ");

						if (field.name == "new") {
							final docArgs = fun.args.map(a -> arg2doc(a.type));
							final docArgs = docArgs.length > 0 ? '(${docArgs.join(",")})' : "";
							final doc = getDoc('M:Godot.${i.name.replace("_", ".")}.#ctor${docArgs}', true);

							content += '\n\t#if !doc_gen\n${doc}\tpublic ${overloaded}inline function new($sign) {\n\t\tthis = new ${name}_($call);\n\t}\n\t#end\n';

							// Patch Vector constructor with default values
							if (vectorConstructorPatch) {
								for (c in 0...fun.args.length) {
									final args = [for (i in 0...c) fun.args[i]];
									final sign = args.map(a -> safename(a.name) + ":" + path2string(a.type)).join(", ");
									final call = args.map(a -> safename(a.name));

									for (_ in c...fun.args.length) {
										call.push("0");
									}

									content += '\n\t#if !doc_gen\n${doc}\tpublic ${overloaded}inline function new($sign) {\n\t\tthis = new ${name}_(${call.join(", ")});\n\t}\n\t#end\n';
								}
							}

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
								throw "Unsupported " + ttype + " " + field.name;
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
								throw "Unsupported " + ttype + " " + field.name;
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

				// Patch for loop support in godot.collections.Array
				if (name == "Array" && i.pack.length == 2 && i.pack[0] == "godot" && i.pack[1] == "collections") {
					content += "\n\tinline function iterator():Iterator<Any> {\n\t\treturn new godot.GodotArrayIterator(this);\n\t}\n";
				}

				function changeName(name:String, startUppercase = false):String {
					if (startUppercase) {
						name = name.substr(0, 1).toUpperCase() + name.substr(1);
					} else {
						name = name.substr(0, 1).toLowerCase() + name.substr(1);
					}

					for (i in 0...name.length) {
						if (name.charAt(i) == "_") {
							name = name.substring(0, i + 1) + name.substr(i + 1, 1).toUpperCase() + name.substr(i + 2);
						}
					}
					return name.replace("_", "");
				}

				if (signalCache.exists(i.name)) {
					final signalDocsPath = 'input/Godot/doc/classes/${i.name}.xml';
					final signalDocs = new Map<String, String>();

					if (FileSystem.exists(signalDocsPath)) {
						final xml = new Access(Xml.parse(File.getContent(signalDocsPath))).node.resolve("class");

						if (xml.hasNode.signals) {
							for (signal in xml.node.signals.nodes.signal) {
								final doc = reindentDoc(extractDoc(signal.node.description), true);
								if (doc.ltrim().length != 0) {
									final doc = ~/\[([^\]]+)\]/g.map(doc, e -> {
										final content = e.matched(1);
										if (content == "code" || content == "/code") {
											return '`';
										} else if (content.indexOf(" ") == -1) {
											return '`$content`';
										} else if (content.startsWith("method ") || content.startsWith("member ")) {
											return '`${safename(changeName(content.substr(7)))}`';
										} else if (content.startsWith("constant ")) {
											var content = content.substr(9);
											final p = content.indexOf(".");
											if (p != 1) {
												content = content.substr(p + 1);
											}
											return '`$content`';
										} else if (content.startsWith("signal ")) {
											return '`on${changeName(content.substr(7), true)}`';
										}
										throw "Unsupported " + content;
									});
									signalDocs.set(signal.att.name, doc);
								}
							}
						}
					}

					for (signal in signalCache.get(i.name)) {
						// TODO connect flags
						final name = "on" + changeName(signal.name, true);
						final doc = signalDocs.exists(signal.name) ? "\n" + signalDocs.get(signal.name) : "";
						final doc = '\n\t/**\n\t\t`${signal.name}` signal.$doc\n\t**/\n\t';
						final singleton = i.superClass == null && i.name != "Object";
						final visibility = singleton ? "static " : "";
						final handler = singleton ? "SINGLETON" : "this";
						final callback = signal.arguments.length == 0 ? "Void->Void" : '(${signal.arguments.map(s -> '${safename(changeName(s.name))}:${s.type}').join(", ")})->Void';
						content += '${doc}public ${visibility}var ${name}(get, never):Signal<$callback>;\n\t@:dox(hide) @:noCompletion inline ${visibility}function get_${name}():Signal<$callback> {\n\t\treturn new Signal($handler, "${signal.name}", Signal.${signal.handler}.connectSignal, Signal.${signal.handler}.disconnectSignal, Signal.${signal.handler}.isSignalConnected);\n\t}\n';
					}
				}

				for (field in fields) {
					var readOnly = false;
					var metas = [];

					for (meta in field.meta) {
						switch (meta.name) {
							case ":readOnly" if (meta.params.length == 0):
								readOnly = true;

							case ":protected", ":noCompletion", ":skipReflection", ":keep" if (meta.params.length == 0):
								metas.push('@${meta.name}');

							case ":event":
								// TODO

							default:
								throw "Unsuported " + ttype + " " + meta;
						}
					}

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

							final name = static_ ? uppername(field.name) : safename(field.name.substr(0, 1).toLowerCase() + field.name.substr(1));
							final kind = field.kind.match(FVar(_, _)) || field.kind.match(FProp("default", "never", _, _)) ? "F" : "P";
							final doc = getDoc('$kind:Godot.${i.name.replace("_", ".")}.${field.name}', true);
							final access = readOnly ? "(default, never)" : "";
							final metas = ['@:native("${field.name}")'].concat(metas).join(" ") + "\n\t";

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

							var hasNull = false;
							final fargs = [];
							final docfargs = [];

							for (j in 0...f.args.length) {
								final a = f.args[j];
								var arg = a.type;
								var docArg = a.type;

								switch (a.type) {
									case macro :cs.system.Nullable_1<$x>:
										hasNull = true;
										arg = (macro :Nullable1<$x>);
										docArg = (macro :Null<$x>);

									case macro :cs.NativeArray<$x> if (j != f.args.length - 1 || i.name != "GD"):
										arg = (macro :HaxeArray<$x>);
										docArg = (macro :std.Array<$x>);

									default:
								};

								fargs.push({
									meta: a.meta,
									name: a.name,
									opt: a.opt,
									type: arg,
									value: a.value,
								});

								docfargs.push({
									meta: a.meta,
									name: a.name,
									opt: a.opt,
									type: docArg,
									value: a.value,
								});
							}

							var returnArray = false;
							var retType = f.ret;

							switch (f.ret) {
								case macro :cs.NativeArray<$x>:
									returnArray = true;
									retType = (macro :std.Array<$x>);

								default:
							}

							final inlined = returnArray ? " extern inline" : "";
							final metas = (returnArray ? [] : ['@:native("${field.name}")']).concat(metas).join(" ") + ((!returnArray || metas.length > 0) ? "\n\t" : "");
							var name = field.name == "new" ? "new" : safename(field.name.substr(0, 1).toLowerCase() + field.name.substr(1));
							var overloaded = fieldList.get(field.name) > 1;
							final docArgs = f.args.map(a -> arg2doc(a.type));
							final docArgs = docArgs.length > 0 ? '(${docArgs.join(",")})' : "";
							final docName = field.name == "new" ? "#ctor" : field.name;
							var doc = getDoc('M:Godot.${i.name.replace("_", ".")}.${docName}${docArgs}', true);

							if (f.params != null && f.params.length > 0) {
								name += "<" + f.params.map(p -> p.name).join(", ") + ">";
							}

							var singleOverload = false;

							// Patch Actions
							final action = ["IsActionPressed", "IsActionJustPressed", "IsActionJustReleased", "GetActionStrength", "ActionPress", "ActionRelease"];
							if (i.name == "Input" && action.indexOf(field.name) != -1) {
								fargs[0].type = macro :godot.Action;
							}

							if (fargs.length > 0) {
								switch (fargs[fargs.length - 1].type) {
									case macro :cs.NativeArray<$x> if (field.name != "new" && i.name == "GD"):
										fargs[fargs.length - 1].type = macro :haxe.Rest<$x>;
										fargs[fargs.length - 1].opt = false;
									default:
								}

								if (fargs[fargs.length - 1].opt) {
									overloaded = true;
									singleOverload = true;
								}
							}

							if (singleOverload || hasNull) {
								final syntax = [for (i in 0...f.args.length) '{${i + (static_ ? 0 : 1)}}'].join(", ");
								final call = (static_ ? [] : ["this"]).concat(docfargs.map(a -> safename(a.name))).join(", ");
								final body = returnArray ? ' {\n\t\treturn cs.Lib.array(cs.Syntax.code("${static_ ? "" : "{0}."}${field.name}($syntax)"${call != "" ? ", " : ""}$call));\n\t}' : ";";

								content += '\n\t#if doc_gen\n${doc}\t${metas}public${static_ ? " static" : ""}${fieldList.get(field.name) > 1 ? " overload" : ""}${inlined} function $name(${docfargs.map(a -> (a.opt ? "?" : "") + safename(a.name) + ":" +  path2string(a.type)).join(", ")}):${path2string(retType)}${body}\n\t#else';
							}

							(function print_function(args_count) {
								final args = [];
								final patchVectorConstructor = (i.name == "Vector2" || i.name == "Vector3") && name == "new" && fargs[0].name == "x";

								for (i in 0...args_count) {
									final a = fargs[i];
									args.push(safename(a.name) + ":" + path2string(a.type) + (patchVectorConstructor ? "#if doc_gen = 0 #end" : ""));
								}

								if (args_count > 0 && fargs[args_count - 1].opt) {
									print_function(args_count - 1);
								}

								final syntax = [for (i in 0...args.length) '{${i + (static_ ? 0 : 1)}}'].join(", ");
								final call = (static_ ? [] : ["this"]).concat([for (i in 0...args.length) safename(fargs[i].name)]).join(", ");
								final body = returnArray ? ' {\n\t\treturn cs.Lib.array(cs.Syntax.code("${static_ ? "" : "{0}."}${field.name}($syntax)"${call != "" ? ", " : ""}$call));\n\t}' : ";";

								content += '\n${doc}\t${metas}public${static_ ? " static" : ""}${overloaded ? " overload" : ""}${inlined} function $name(${args.join(", ")}):${path2string(retType)}${body}\n';
							})(fargs.length);

							if (singleOverload || hasNull) {
								content += "\t#end\n";
							}

						default:
							throw "Unsupported " + ttype + " " + field;
					}
				}

				content += "}\n";

				File.saveContent(filename, content);

			default:
				throw "Unsupported " + ttype;
		}

		return fields;
	}
}
