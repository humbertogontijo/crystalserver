target_sources(crystalserver_ut PRIVATE
        area_combat_test.cpp
        instance_id_test.cpp
        instance_registry_test.cpp
        instance_strict_test.cpp
        walk_grid_test.cpp
        zone_items_test.cpp
)

# creature.hpp calls an unqualified log(), ambiguous with boost::ut::log once another
# unity-merged test has `using namespace boost::ut`.
set_source_files_properties(area_combat_test.cpp zone_items_test.cpp TARGET_DIRECTORY crystalserver_ut
        PROPERTIES SKIP_UNITY_BUILD_INCLUSION ON)
