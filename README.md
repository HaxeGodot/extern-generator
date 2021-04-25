![](https://raw.github.com/HaxeGodot/godot/main/.github/logo.png)

[haxe externs](https://github.com/HaxeGodot/godot) | [editor plugin](https://github.com/HaxeGodot/editor-plugin) | [demo](https://github.com/HaxeGodot/squash-the-creeps-3d) | [api doc](https://haxegodot.github.io/godot/) | [discussions](https://github.com/HaxeGodot/godot/discussions)

# Godot extern generator

Generate Haxe/C# externs for Godot.

A generated version is available at <https://github.com/HaxeGodot/godot/>.

## How to use

You need the commits from <https://github.com/HaxeGodot/haxe/tree/cs-opt> to properly generate the function overloads.

Create an `input/` directory with:

* `GodotSharp.dll` and `GodotSharp.xml` you can with in the `.mono` folder of a Godot C# project
* `GodotApi.json` generated from `godot --gdnative-generate-json-api GodotApi.json`
* `Godot/` directory of the Godot engine source code, this does **not** require it to be compiled

Run `haxe generate.hxml`, the externs are created in a `godot/` directory.
If the directory exists before the generation it'll be deleted.
You can change the root directory from the current working directory by adding `-D output=some/path` to the haxe command.

## TODOs

* Mark deprecated functions
* Array access on `Vector2`, `Vector3`, `Transform`, `Transform2D`, `Quat`, `Color` and `Basis`
* Missing types `Godot.DynamicGodotObject` and `Godot.MarshalUtils`
* Explicit constructors
* Function with type parameters on `PackedScene.Instance`, `PackedScene.InstanceOrNull`
* `cs.system.EventHandler_1` on `GD.UnhandledException`

## License

The generator is MIT licensed, see <LICENSE.md>.
