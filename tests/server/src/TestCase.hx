import SkipReason;
import haxe.PosInfos;
import haxe.Exception;
import haxe.display.Position;
import haxeserver.HaxeServerRequestResult;
import haxe.display.JsonModuleTypes;
import haxe.display.Display;
import haxe.display.Protocol;
import haxe.display.Diagnostic;
import haxe.Json;
import haxeserver.process.HaxeServerProcessNode;
import haxeserver.HaxeServerAsync;
import utest.Assert;
import utest.ITest;
import utils.Vfs;

using StringTools;
using Lambda;

@:autoBuild(utils.macro.BuildHub.build())
interface ITestCase {}

class TestCase implements ITest implements ITestCase {
	static public var debugLastResult:{
		hasError:Bool,
		stdout:String,
		stderr:String,
		prints:Array<String>
	};

	static public var server:HaxeServerAsync;
	static public var rootCwd:String;

	var vfs:Vfs;
	var testDir:String;
	var lastResult:HaxeServerRequestResult;
	var messages:Array<String> = [];
	var errorMessages = [];

	static var i:Int = 0;

	public function new() {}

	function debugMessages(?pos:PosInfos) {
		for (m in messages)
			haxe.Log.trace(m, pos);
	}

	function debugErrorMessages(?pos:PosInfos) {
		for (m in errorMessages)
			haxe.Log.trace(m, pos);
	}

	function messagesWith(s:String, ?pos:PosInfos) {
		for (m in messages)
			if (m.contains(s))
				haxe.Log.trace(m, pos);
	}

	function errorMessagesWith(s:String, ?pos:PosInfos) {
		for (m in errorMessages)
			if (m.contains(s))
				haxe.Log.trace(m, pos);
	}

	static public function printSkipReason(ddr:SkipReason) {
		return switch (ddr) {
			case DependencyDirty(path): 'DependencyDirty $path';
			case Tainted(cause): 'Tainted $cause';
			case FileChanged(file): 'FileChanged $file';
			case Shadowed(file): 'Shadowed $file';
			case LibraryChanged: 'LibraryChanged';
		}
	}

	@:timeout(3000)
	public function setup(async:utest.Async) {
		testDir = "test/cases/" + i++;
		vfs = new Vfs(testDir);
		runHaxeJson(["--cwd", rootCwd, "--cwd", testDir], Methods.ResetCache, {}, () -> {
			async.done();
		});
	}

	public function teardown() {}

	function handleResult(result) {
		lastResult = result;
		debugLastResult = {
			hasError: lastResult.hasError,
			prints: lastResult.prints,
			stderr: lastResult.stderr,
			stdout: lastResult.stdout
		};
		sendLogMessage(result.stdout);
		for (print in result.prints) {
			var line = print.trim();
			messages.push('Haxe print: $line');
		}
	}

	function runHaxe(args:Array<String>, done:() -> Void) {
		#if disable-hxb-cache args = ["-D", "disable-hxb-cache"].concat(args); #end
		messages = [];
		errorMessages = [];
		server.rawRequest(args, null, function(result) {
			handleResult(result);
			if (result.hasError) {
				sendErrorMessage(result.stderr);
			}
			done();
		}, sendErrorMessage);
	}

	function runHaxeJson<TParams, TResponse>(args:Array<String>, method:HaxeRequestMethod<TParams, TResponse>, methodArgs:TParams, done:() -> Void) {
		var methodArgs = {method: method, id: 1, params: methodArgs};
		args = args.concat(['--display', Json.stringify(methodArgs)]);
		runHaxe(args, done);
	}

	function runHaxeJsonCb<TParams, TResponse>(args:Array<String>, method:HaxeRequestMethod<TParams, Response<TResponse>>, methodArgs:TParams,
			callback:TResponse->Void, done:() -> Void) {
		var methodArgs = {method: method, id: 1, params: methodArgs};
		args = args.concat(['--display', Json.stringify(methodArgs)]);
		messages = [];
		errorMessages = [];
		server.rawRequest(args, null, function(result) {
			handleResult(result);
			var json = try Json.parse(result.stderr) catch(e) {result: null, error: e.message};
			if (json.result != null) {
				callback(json.result.result);
			} else {
				sendErrorMessage('Error: ' + json.error);
			}
			done();
		}, function(msg) {
			sendErrorMessage(msg);
			done();
		});
	}

	function sendErrorMessage(msg:String) {
		var split = msg.split("\n");
		for (message in split) {
			errorMessages.push(message.trim());
		}
	}

	function sendLogMessage(msg:String) {
		var split = msg.split("\n");
		for (message in split) {
			messages.push(message.trim());
		}
	}

	function getTemplate(templateName:String) {
		return sys.io.File.getContent("test/templates/" + templateName);
	}

	function hasMessage<T>(msg:String) {
		for (message in messages) {
			if (message.endsWith(msg)) {
				return true;
			}
		}
		return false;
	}

	function hasErrorMessage<T>(msg:String) {
		for (message in errorMessages) {
			if (message.endsWith(msg)) {
				return true;
			}
		}
		return false;
	}

	function getStoredType<T>(typePackage:String, typeName:String) {
		var storedTypes:Array<JsonModuleType<T>> = try {
			Json.parse(lastResult.stderr).result.result;
		} catch (e:Dynamic) {
			trace(e);
			[];
		}
		for (type in storedTypes) {
			if (type.pack.join(".") == typePackage && type.name == typeName) {
				return type;
			}
		}
		return null;
	}

	function parseCompletion():CompletionResult {
		return Json.parse(lastResult.stderr).result;
	}

	function parseHover():HoverResult {
		return Json.parse(lastResult.stderr).result;
	}

	function parseSignatureHelp():SignatureHelpResult {
		return Json.parse(lastResult.stderr).result;
	}

	function parseGotoTypeDefinition():GotoTypeDefinitionResult {
		return Json.parse(lastResult.stderr).result;
	}

	function parseGotoDefintion():GotoDefinitionResult {
		return haxe.Json.parse(lastResult.stderr).result;
	}

	function parseDiagnostics():Array<Diagnostic<Any>> {
		var result = haxe.Json.parse(lastResult.stderr)[0];
		return if (result == null) [] else result.diagnostics;
	}

	function parseGotoDefinitionLocations():Array<Location> {
		switch parseGotoTypeDefinition().result {
			case null:
				throw new Exception('No result for GotoDefinition found');
			case result:
				return result;
		}
	}

	function assertSilence() {
		return Assert.isTrue(lastResult.stderr == "");
	}

	function assertSuccess(?p:haxe.PosInfos) {
		return Assert.isTrue(0 == errorMessages.length, p);
	}

	function assertErrorMessage(message:String, ?p:haxe.PosInfos) {
		return Assert.isTrue(hasErrorMessage(message), p);
	}

	function assertHasPrint(line:String, ?p:haxe.PosInfos) {
		return Assert.isTrue(hasMessage("Haxe print: " + line), null, p);
	}

	function assertReuse(module:String, ?p:haxe.PosInfos) {
		return Assert.isTrue(hasMessage('reusing $module'), null, p);
	}

	function assertSkipping(module:String, reason:SkipReason, ?p:haxe.PosInfos) {
		var msg = 'skipping $module (${printSkipReason(reason)})';
		return Assert.isTrue(hasMessage(msg), null, p);
	}

	function assertNotCacheModified(module:String, ?p:haxe.PosInfos) {
		return Assert.isTrue(hasMessage('$module not cached (modified)'), null, p);
	}

	function assertHasType(typePackage:String, typeName:String, ?p:haxe.PosInfos) {
		return Assert.isTrue(getStoredType(typePackage, typeName) != null, null, p);
	}

	function assertHasField(typePackage:String, typeName:String, fieldName:String, isStatic:Bool, ?p:haxe.PosInfos) {
		var type = getStoredType(typePackage, typeName);
		Assert.isTrue(type != null, p);
		function check<T>(type:JsonModuleType<T>) {
			return switch [type.kind, type.args] {
				case [Class, c]:
					(isStatic ? c.statics : c.fields).exists(cf -> cf.name == fieldName);
				case _: false;
			}
		}
		if (type != null) {
			Assert.isTrue(check(type), null, p);
		}
	}

	function assertClassField(completion:CompletionResult, name:String, ?callback:(field:JsonClassField) -> Void, ?pos:PosInfos) {
		for (item in completion.result.items) {
			switch item.kind {
				case ClassField if (item.args.field.name == name):
					switch callback {
						case null: Assert.pass(pos);
						case fn: fn(item.args.field);
					}
					return;
				case _:
			}
		}
		Assert.fail(pos);
	}

	function assertHasCompletion<T>(completion:CompletionResult, f:DisplayItem<T>->Bool, ?p:haxe.PosInfos) {
		for (type in completion.result.items) {
			if (f(type)) {
				Assert.pass();
				return;
			}
		}
		Assert.fail("No such completion", p);
	}

	function assertHasNoCompletion<T>(completion:CompletionResult, f:DisplayItem<T>->Bool, ?p:haxe.PosInfos) {
		for (type in completion.result.items) {
			if (f(type)) {
				Assert.fail("Unexpected completion", p);
				return;
			}
		}
		Assert.pass();
	}

	function strType(t:JsonType<JsonTypePathWithParams>):String {
		var path = t.args.path;
		var params = t.args.params;
		var parts = path.pack.concat([path.typeName]);
		var s = parts.join('.');
		if (params.length == 0) {
			return s;
		}
		var sParams = params.map(strType).join('.');
		return '$s<$sParams>';
	}
}
