# IdleOT engine-custom for CrystalServer.
# Linked via -DIDLEOT_CUSTOM_DIR=… (defaults to this directory when present).
# Add new .cpp/.hpp here; keep upstream src/ hooks to IdleOT:: one-liners.
# New TUs that belong on dest src/ paths are MOVE files under idleot/src/ instead.

cmake_minimum_required(VERSION 3.22)

# Placeholder interface target so the subdirectory is valid before TUs exist.
add_library(idleot_custom_crystal INTERFACE)
target_include_directories(idleot_custom_crystal INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})

# Example (uncomment when adding sources compiled from this tree, not idleot/src MOVE):
# add_library(idleot_custom_crystal_obj OBJECT
#   lua/register_methods.cpp
# )
# target_link_libraries(crystalserver PRIVATE idleot_custom_crystal_obj)
