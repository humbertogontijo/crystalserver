#include "pch.hpp"

#include <boost/ut.hpp>

#include "game/instance_strict.hpp"
#include "injection_fixture.hpp"

using namespace boost::ut;

suite<"instance_strict"> instanceStrictTest = [] {
	InjectionFixture injectionFixture {};

	test("unscoped calls are counted per site") = [] {
		const auto before = instanceInferenceCount("unit-site");
		reportInstanceInference("unit-site", "detail");
		reportInstanceInference("unit-site");
		expect(eq(instanceInferenceCount("unit-site"), before + 2));
		expect(eq(instanceInferenceCount("unit-never-reported"), uint64_t { 0 }));
	};
};
