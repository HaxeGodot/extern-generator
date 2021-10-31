import cs.system.ObsoleteAttribute;
import cs.system.reflection.Assembly;

function main() {
	for (type in Assembly.LoadFrom("input/GodotSharp.dll").GetTypes()) {
		for (field in type.GetFields()) {
			for (attribute in field.GetCustomAttributes(true)) {
				if (attribute is ObsoleteAttribute) {
					Sys.println(type.FullName + "\n" + field + "\n" + cast(attribute, ObsoleteAttribute).Message);
				}
			}
		}

		for (member in type.GetMembers()) {
			for (attribute in member.GetCustomAttributes(true)) {
				if (attribute is ObsoleteAttribute) {
					Sys.println(type.FullName + "\n" + member + "\n" + cast(attribute, ObsoleteAttribute).Message);
				}
			}
		}
	}
}
