package godot;

/**
	Typesafe signal.
**/
@:nativeGen
#if !doc_gen
@:using(godot.SignalUsings)
#end
class Signal<T> {
	final from:Object;
	final signal:String;
	final connectFn:(Object, String, T)->Void;
	final disconnectFn:(Object, String, T)->Void;
	final isConnectedFn:(Object, String, T)->Bool;

	@:allow(godot)
	function new(from:Object, signal:String, connectFn:(Object, String, T)->Void, disconnectFn:(Object, String, T)->Void, isConnectedFn:(Object, String, T)->Bool) {
		this.from = from;
		this.signal = signal;
		this.connectFn = connectFn;
		this.disconnectFn = disconnectFn;
		this.isConnectedFn = isConnectedFn;
	}

	/**
		Connects the signal to the `callback`.

		A signal can only be connected once to a `callback`. It will throw an error if already connected.
		To avoid this, first, use `isConnected` to check for existing connections.
	**/
	public function connect(callback:T):Void {
		connectFn(from, signal, callback);
	}

	/**
		Disconnects the signal from the `callback`.

		If you try to disconnect a connection that does not exist, the method will throw an error.
		Use `isConnected` to ensure that the connection exists.
	**/
	public function disconnect(callback:T):Void {
		disconnectFn(from, signal, callback);
	}

	/**
		Returns `true` if a connection exists between this signal and the `callback`.
	**/
	public function isConnected(callback:T):Bool {
		return isConnectedFn(from, signal, callback);
	}

	#if doc_gen
	/**
		Emit the signal.

		The arguments type and number are checked at compile time.
	**/
	public function emitSignal(args:haxe.Rest<Any>):Void {
	}
	#end
}

@:nativeGen
@:dox(hide)
@:noCompletion
class SignalHandler {
	public static function isSignalConnected<T>(refs:Map<String, Map<Object, Array<T>>>, source:Object, signal:String, callback:T):Bool {
		final key = '${source.getInstanceId()}-$signal';

		if (!refs.exists(key)) {
			return false;
		}

		for (_ => ref in refs.get(key)) {
			if (ref.indexOf(callback) != -1) {
				return true;
			}
		}

		return false;
	}

	public static function disconnectSignal<T>(refs:Map<String, Map<Object, Array<T>>>, source:Object, signal:String, callback:T) {
		final key = '${source.getInstanceId()}-$signal';

		if (!isSignalConnected(refs, source, signal, callback)) {
			source.disconnect(signal, new Reference(), "handleSignal");
			return;
		}

		for (handler => ref in refs.get(key)) {
			if (ref.indexOf(callback) != -1) {
				source.disconnect(signal, handler, "handleSignal");
				refs.get(key).remove(handler);

				if (Lambda.count(refs.get(key)) == 0) {
					refs.remove(key);
				}

				break;
			}
		}
	}

	public static function connectSignal<T>(refs:Map<String, Map<Object, Array<T>>>, builder:(Object, String, T) -> Object, source:Object, signal:String,
			callback:T) {
		final key = '${source.getInstanceId()}-$signal';
		var handler = null;

		if (refs.exists(key)) {
			for (h => ref in refs.get(key)) {
				if (ref.indexOf(callback) != -1) {
					handler = h;
					break;
				}
			}
		}

		if (handler == null) {
			handler = builder(source, signal, callback);
		}

		source.connect(signal, handler, "handleSignal");
	}
}
