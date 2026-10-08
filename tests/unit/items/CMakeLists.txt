target_sources(crystalserver_ut PRIVATE
    containers/container_test.cpp
    tile_test.cpp
)

# tile.hpp pulls in creature.hpp, whose unqualified log() is ambiguous with
# boost::ut::log in a unity batch.
set_source_files_properties(tile_test.cpp TARGET_DIRECTORY crystalserver_ut
        PROPERTIES SKIP_UNITY_BUILD_INCLUSION ON)
