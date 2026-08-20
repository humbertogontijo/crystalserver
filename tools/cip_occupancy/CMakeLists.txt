add_executable(cip-occupancy
	main.cpp
	${CMAKE_SOURCE_DIR}/src/io/occupancy_mask.cpp
)

find_package(LibLZMA REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)

target_include_directories(cip-occupancy PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(cip-occupancy PRIVATE LibLZMA::LibLZMA nlohmann_json::nlohmann_json)
setup_target(cip-occupancy)
set_output_directory(cip-occupancy)
