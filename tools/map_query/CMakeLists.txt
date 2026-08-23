find_package(nlohmann_json CONFIG REQUIRED)

set(MAP_QUERY_COMMON_SOURCES
	geometry_engine.cpp
	map_query_session.cpp
)

add_executable(map-query
	main.cpp
	${MAP_QUERY_COMMON_SOURCES}
)

target_include_directories(map-query PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(map-query PRIVATE ${CMAKE_PROJECT_NAME}_lib nlohmann_json::nlohmann_json)
setup_target(map-query)
set_output_directory(map-query)

add_library(map_query_ffi SHARED
	map_query_ffi.cpp
	${MAP_QUERY_COMMON_SOURCES}
)

target_compile_definitions(map_query_ffi PRIVATE MAP_QUERY_FFI_EXPORTS)
target_include_directories(map_query_ffi PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(map_query_ffi PRIVATE ${CMAKE_PROJECT_NAME}_lib nlohmann_json::nlohmann_json)
setup_target(map_query_ffi)
set_output_directory(map_query_ffi)
