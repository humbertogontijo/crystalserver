target_sources(${PROJECT_NAME}_lib PRIVATE
    fileloader.cpp
    filestream.cpp
    io_wheel.cpp
    iobestiary.cpp
    io_bosstiary.cpp
    iobountytasks.cpp
    ioguild.cpp
    iologindata.cpp
    functions/iologindata_load_player.cpp
    functions/iologindata_save_player.cpp
    iomap.cpp
    iomapserialize.cpp
    iomarket.cpp
    ioprey.cpp
    ioweeklytasks.cpp
)

# Standalone (no Game/Map deps, outside the unity build) so offline map tooling links it alone.
add_library(idleot_occupancy STATIC occupancy_mask.cpp region_index.cpp)
setup_target(idleot_occupancy)
target_include_directories(idleot_occupancy PUBLIC ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(idleot_occupancy PUBLIC LibLZMA::LibLZMA)
target_link_libraries(${PROJECT_NAME}_lib PUBLIC idleot_occupancy)
