#include "pch.hpp"

#include <boost/ut.hpp>

#include "config/configmanager.hpp"
#include "game/instance_strict.hpp"
#include "injection_fixture.hpp"

#include <filesystem>
#include <fstream>

using namespace boost::ut;

namespace {
	void loadStrict(bool strict) {
		const auto path = std::filesystem::temp_directory_path() / "crystalserver_instance_strict_test.lua";
		std::ofstream(path) << "instanceStrict = " << (strict ? "true" : "false") << "\n";
		g_configManager().setConfigFileLua(path.string());
		g_configManager().load();
		std::filesystem::remove(path);
	}
}

suite<"instance_strict"> instanceStrictTest = [] {
	InjectionFixture injectionFixture {};

	test("warn mode counts and allows the inference") = [] {
		loadStrict(false);
		expect(!isInstanceStrict());
		const auto before = instanceInferenceCount("unit-warn");
		expect(!reportInstanceInference("unit-warn", "detail"));
		expect(!reportInstanceInference("unit-warn"));
		expect(eq(instanceInferenceCount("unit-warn"), before + 2));
		expect(eq(instanceInferenceCount("unit-never-reported"), uint64_t { 0 }));
	};

	test("strict mode refuses the inference") = [] {
		loadStrict(true);
		expect(isInstanceStrict());
		const auto before = instanceInferenceCount("unit-strict");
		expect(reportInstanceInference("unit-strict"));
		expect(eq(instanceInferenceCount("unit-strict"), before + 1));
		loadStrict(false);
	};
};
